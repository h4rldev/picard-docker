-module (picard_route_http).
-export ([start/0]).

start() ->
  Routes = [
    {post, ["auth", "login"], fun picard_auth_http:login/1},
    {get, ["auth", "logout"], fun picard_auth_http:logout/1},
    {get, ["auth", "me"], fun picard_auth_http:me/1},
    {get, ["auth", "status"], fun picard_auth_http:status/1},
    {get, ["users"], fun picard_auth_http:list_users/1},
    {post, ["users"], fun picard_auth_http:create_user/1},
    {delete, ["users", ":name"], fun picard_auth_http:delete_user/1},
    {post, ["users", ":name", "password"], fun picard_auth_http:change_password/1},
    {post, ["users", ":name", "auth", "renew"], fun picard_auth_http:renew/1},
    {post, ["users", ":name", "role"], fun picard_auth_http:change_role/1},
    {get, ["route"], fun route_handler/1},
    {get, ["vnc", ":token"], fun vnc_handler/1},
    {get, ["sleep", ":token"], fun sleep_handler/1},
    {get, ["alive", ":token"], fun alive_handler/1},
    {get, [":path*"], errm_http_file:serve_dir(web_root())}
  ],

  case errm_http:start(#{
    server_name => "picard_rt",
    port => http_port(),
    routes => Routes,
    middlewares => [errm_http_cookie:with_cookies(), picard_auth:middleware()]
  }) of
    {ok, _} -> ok;
    {error, {already_started, _}} -> ok;
    {error, Reason} -> error(Reason)
  end.


route_handler(Req) ->
  Account = account_from(Req),
  case picard_router:route(Account) of
    {ok, Token} ->
      Body = <<"{\"token\":\"", Token/binary, "\"}">>,
      {ok, {200, #{<<"content-type">> => <<"application/json">>}, Body}};
    {error, capacity} ->
      {ok, {503, #{<<"content-type">> => <<"text/plain">>}, <<"Capacity limit reached">>}}
  end.

vnc_handler(Req) ->
  Token = token_from(Req),
  Account = account_from(Req),
  case Token of
    <<>> ->
      {ok, {400, #{<<"content-type">> => <<"text/plain">>}, <<"Not found">>}};
    _ ->
      case picard_router:lookup_token(Token, Account) of
        {ok, Port, Owner} ->
          {upgrade, errm_ws, {picard_vnc_proxy, #{token => Token, host => host(Owner), port => Port}}};
        error ->
          {ok, {400, #{<<"content-type">> => <<"text/plain">>}, <<"Not found">>}}
      end
  end.

sleep_handler(Req) ->
  picard_router:freeze(token_from(Req), account_from(Req)),
  {ok, {200, #{<<"content-type">> => <<"text/plain">>}, <<"OK">>}}.

alive_handler(Req) ->
  picard_router:alive(token_from(Req), account_from(Req)),
  {ok, {200, #{<<"content-type">> => <<"text/plain">>}, <<"OK">>}}.


account_from(Req) -> maps:get(account, Req, "generic").

token_from(Req) ->
  Params = maps:get(params, Req, #{}),
  maps:get(<<"token">>, Params, <<>>).

http_port() ->
  case os:getenv("PICARD_HTTP_PORT") of
    false -> 8080;
    Port -> list_to_integer(Port)
  end.

web_root() ->
  os:getenv("PICARD_WEB_ROOT", "/opt/web").

host(Owner) ->
  case Owner =:= node() of
    true ->
      "127.0.0.1";
    false ->
      case string:split(atom_to_list(Owner), "@", trailing) of
        [_Name, Host] ->
          Host;
        _ -> "127.0.0.1"
      end
  end.
