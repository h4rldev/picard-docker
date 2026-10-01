-module (picard_auth_http).
-export ([
  login/1, logout/1, me/1, status/1, list_users/1, create_user/1, delete_user/1, change_password/1, renew/1, change_role/1
]).

login(Req) ->
  case body_json(Req) of
    {ok,    #{<<"username">> := UN, <<"password">> := PW}} -> do_login(UN, PW, Req);
    {ok,    #{<<"username">> := _}}                        -> err(400, "No password");
    {ok,    _}                                             -> err(400, "No username");
    {error, _}                                             -> err(400, "Invalid JSON")
  end.

do_login(UN, PW, Req) ->
  case picard_auth:login(UN, PW) of
    {ok,    Token}               -> session_response(Token, Req);
    {error, invalid_credentials} -> err(401, "Invalid credentials");
    {error, {db_error, _}}       -> err(503, "Database unavailable");
    {error, _}                   -> err(500, "Internal login error")
  end.

logout(_Req) ->
  Delete = errm_http_cookie:set_cookie(
    <<"session">>, <<>>, 
    #{
      path => <<"/">>,
      http_only => true,
      same_site => lax,
      secure => true,
      max_age => 0
    }
  ),

  Resp = {200, #{<<"content-type">> => <<"application/json">>}, <<"{\"message\": \"User logged out successfully.\", \"ok\": true}">>},
  {ok, errm_http_cookie:add_cookies(Resp, [Delete])}.

me(Req) ->
  case maps:get(claims, Req, undefined) of
    undefined -> err(401, "Unauthorized");
    Claims    -> ok_json(#{
      <<"username">> => maps:get(<<"sub">>, Claims),
      <<"role">> => maps:get(<<"role">>, Claims)
    })
  end.

status(_Req) -> ok_json(#{<<"enabled">> => picard_auth:enabled()}).

list_users(Req) ->
  case require_role(Req, "admin") of
    ok ->
      Acting = role_of(Req),
      Me = maps:get(account, Req, ""),
      users_result(Acting, Me, picard_db:query("SELECT username, role FROM users ORDER BY username"));
    {error, S, M} -> err(S, M)
  end.

users_result(Acting, Me, {ok, Rows}) ->
  Visible = [R || R <- Rows, maps:get("username", R) =:= Me orelse picard_auth:can_manage(Acting, maps:get("role", R))],
  ok_json([#{
    <<"username">> => list_to_binary(maps:get("username", R)),
    <<"role">> => list_to_binary(maps:get("role", R))
  } || R <- Visible]);
users_result(_Acting, _Me, {error, Reason}) ->
  logger:error("Failed to list users: ~p", [Reason]),
  err(500, "Database error").

create_user(Req) ->
  case require_role(Req, "admin") of
    ok            -> create_user(Req, role_of(Req));
    {error, S, M} -> err(S, M)
  end.

create_user(Req, ActingRole) ->
  case body_json(Req) of
    {ok, #{<<"username">> := UN, <<"password">> := PW} = Data} ->
      Role = maps:get(<<"role">>, Data, <<"user">>),
      case assignable(ActingRole, binary_to_list(Role)) of
        true -> insert_user(UN, PW, Role);
        false -> err(403, "Forbidden")
      end;
    {ok, _} -> err(400, "No username or password");
    {error, _} -> err(400, "Invalid JSON")
  end.

delete_user(Req) ->
  Name = binary_to_list(name_param(Req)),
  case require_role(Req, "admin") of
    ok            -> delete_user(Name, maps:get(account, Req, ""), role_of(Req));
    {error, S, M} -> err(S, M)
  end.

delete_user(Name, Name, _) -> err(400, "You cannot delete yourself");
delete_user(Name, _Acting, ActingRole) ->
  case target_role(Name) of
    undefined -> err(400, "No such user");
    TRole ->
      case picard_auth:can_manage(ActingRole, TRole) of
        true  -> do_delete(Name);
        false -> err(403, "Forbidden")
      end
  end.

do_delete(Name) ->
  sql_ok(picard_db:query("DELETE FROM users WHERE username = ?1", [list_to_binary(Name)]), "User deleted successfully.").

change_password(Req) ->
  Name = binary_to_list(name_param(Req)),
  case body_json(Req) of
    {ok, #{<<"password">> := NewPW}} ->
      case allowed_target(Req, Name) of
        ok            -> set_password(Name, NewPW);
        {error, S, M} -> err(S, M)
      end;
    {ok,    _} -> err(400, "No password");
    {error, _} -> err(400, "Invalid JSON")
  end.

renew(Req) ->
  Name = binary_to_list(name_param(Req)),
  case allowed_target(Req, Name) of
    ok            -> do_renew(Name);
    {error, S, M} -> err(S, M)
  end.

do_renew(Name) ->
  sql_ok(picard_db:query("UPDATE users SET auth_version = auth_version + 1 WHERE username = ?1", [list_to_binary(Name)]), "Renew successful.").

change_role(Req) ->
  Name = binary_to_list(name_param(Req)),
  case require_role(Req, "superadmin") of
    ok            -> change_role(Req, Name, target_role(Name));
    {error, S, M} -> err(S, M)
  end.

change_role(_Req, _Name, undefined)  -> err(400, "No such user");
change_role(_Req, _Name, "superadmin") -> err(400, "Super-Admin is env-managed");
change_role(Req, Name, _) ->
  case body_json(Req) of
    {ok, #{<<"role">> := Role}} when Role =:= <<"user">>; Role =:= <<"admin">> ->
      sql_ok(picard_db:query("UPDATE users SET role = ?2, auth_version = auth_version + 1 WHERE username = ?1", [list_to_binary(Name), Role]), "Role changed successfully.");
    {ok, _} -> err(400, "Invalid role");
    {error, _} -> err(400, "Invalid JSON")
  end.

allowed_target(Req, Name) ->
  case maps:get(account, Req, "") of
    Name -> ok;
    _ ->
      case require_role(Req, "admin") of
        ok -> allowed_target(Name, maps:get(account, Req, ""), role_of(Req));
        E -> E
      end
  end.

allowed_target(Name, Name, _) -> ok;
allowed_target(Name, _Acting, ActingRole) ->
  case target_role(Name) of
    undefined -> {error, 404, "No such user"};
    TRole ->
      case picard_auth:can_manage(ActingRole, TRole) of
        true  -> ok;
        false -> {error, 403, "Forbidden"}
      end
  end.

assignable(Acting, "superadmin") -> Acting =:= "superadmin" andalso not exists_superadmin();
assignable("superadmin", _) -> true;
assignable("admin", "user") -> true;
assignable(_, _) -> false.

exists_superadmin() ->
  exists_superadmin(picard_db:query("SELECT 1 FROM users WHERE role = 'superadmin' LIMIT 1")).

exists_superadmin({ok, [_]}) -> true;
exists_superadmin(_) -> false.

set_password(_Name, <<>>) -> err(400, "Password required");
set_password(Name, NewPW) ->
  case errm_argon:hash(binary_to_list(NewPW)) of
    {ok, Hash} ->
      sql_ok(picard_db:query("UPDATE users SET password_hash = ?2, auth_version = auth_version + 1 WHERE username = ?1", [list_to_binary(Name), Hash]), "Password set successfully.");
    {error, _} -> err(500, "Hash error.")
  end.

insert_user(<<>>, _PW, _Role) -> err(400, "Username required");
insert_user(_UN, <<>>, _Role) -> err(400, "Password required");
insert_user(UN, PW, Role) ->
  case picard_auth:valid_username(UN) of
    false -> err(400, "Username must be 1-32 chars of letters, digits, dot, dash, or underscore");
    true ->
      case errm_argon:hash(binary_to_list(PW)) of
        {ok, Hash} ->
          case picard_db:query("INSERT INTO users (username, password_hash, role) VALUES ($1, $2, $3)", [UN, Hash, Role]) of
            {ok,    _} -> ok_json(#{<<"message">> => <<"User added successfully.">>, <<"ok">> => true});
            {error, {db_unavailable, _}} -> err(503, "Database unavailable");
            {error, _} -> err(400, "User already exists")
          end;
        {error, _} -> err(500, "Hash error")
      end
  end.

require_role(Req, Min) ->
  case maps:get(claims, Req, undefined) of
    undefined -> {error, 401, "Unauthorized"};
    Claims -> check_role(Claims, Min)
  end.

check_role(Claims, Min) ->
  Role = binary_to_list(maps:get(<<"role">>, Claims, <<"user">>)),
  case picard_auth:rank(Role) >= picard_auth:rank(Min) of
    true  -> ok;
    false -> {error, 403, "Forbidden"}
  end.

role_of(Req) ->
  case maps:get(claims, Req, undefined) of
    undefined -> "user";
    Claims -> binary_to_list(maps:get(<<"role">>, Claims, <<"user">>))
  end.

target_role(Name) ->
  role_result(picard_db:query("SELECT role FROM users WHERE username = $1", [list_to_binary(Name)])).

role_result({ok, [Row]}) -> maps:get("role", Row);
role_result(_) -> undefined.

name_param(Req) -> maps:get(<<"name">>, maps:get(params, Req, #{}), <<>>).

body_json(Req) ->
  case errm_json:decode(maps:get(body, Req, <<>>)) of
    {ok,    Data} when is_map(Data) -> {ok,    Data};
    _                               -> {error, invalid_json}
  end.

session_response(Token, Req) ->
  Secure = maps:get(<<"x-forwarded-proto">>, maps:get(headers, Req, #{}), <<"http">>) =:= <<"https">>,
  Set = errm_http_cookie:set_cookie(<<"session">>, Token, #{path => <<"/">>, http_only => true, same_site => lax, secure => Secure, max_age => 30 * 86400}),
  Resp = {200, #{<<"content-type">> => <<"application/json">>}, <<"{\"ok\": true}">>},
  {ok, errm_http_cookie:add_cookies(Resp, [Set])}.

ok_json(Term) ->
  {ok, {200, #{<<"content-type">> => <<"application/json">>}, errm_json:to_binary(Term)}}.

err(Status, Message) ->
  {ok, {Status, #{<<"content-type">> => <<"application/json">>}, errm_json:to_binary(#{<<"error">> => list_to_binary(Message)})}}.

sql_ok(Result, Message) ->
  case Result of
    {ok, _} ->
      ok_json(#{<<"message">> => list_to_binary(Message), <<"ok">> => true});
    {error, _} -> err(500, "Database Error")
  end.
