-module (picard_auth).
-export ([ensure_superadmin/0, enabled/0, login/2, authenticate/1, middleware/0, rank/1, can_manage/2, valid_username/1]).

-define (PROTECTED, [["route"], ["vnc"], ["sleep"], ["alive"], ["users"]]).

ensure_superadmin() ->
  ensure_superadmin(
    picard_config:get_str("superadmin_user", undefined), 
    picard_config:get_str("superadmin_password", undefined)
  ).

ensure_superadmin(undefined, _)   -> default_superadmin();
ensure_superadmin(_, undefined)   -> default_superadmin();
ensure_superadmin("", _)          -> default_superadmin();
ensure_superadmin(_, "")          -> default_superadmin();
ensure_superadmin(User, Password) -> upsert_superadmin(User, Password).

default_superadmin() ->
  case superadmin_name() of
    undefined ->
      logger:warning("PICARD_SUPERADMIN_USER/PASSWORD not set - created default superadmin 'superadmin'/'superadmin'. Set them in your environment"),
      upsert_superadmin("superadmin", "superadmin");
    _ -> ok
  end.

upsert_superadmin(User, Password) ->
  case valid_username(list_to_binary(User)) of
    false -> superadmin_fatal(invalid_username, User);
    true  ->
      case errm_argon:hash(Password) of
        {ok, Hash} ->
          Sql = "INSERT INTO users (username, password_hash, role) VALUES ($1, $2, 'superadmin')
                ON CONFLICT(username) DO UPDATE SET password_hash = excluded.password_hash, role = 'superadmin'",
          Demote = "UPDATE users SET role = 'admin' WHERE role = 'superadmin' AND username <> $1",
          case {picard_db:query(Sql, [list_to_binary(User), Hash]),
                picard_db:query(Demote, [list_to_binary(User)])} of
            {{ok, _}, {ok, _}} -> ok;
            {E1, E2}           -> superadmin_fatal(E1, E2)
          end;
        {error, Reason} -> superadmin_fatal(hash_failed, Reason)
      end
  end.

superadmin_fatal(E1, E2) ->
  logger:error("FATAL: failed to upsert superadmin: ~p ~p", [E1, E2]),
  halt(1).

superadmin_name() ->
  superadmin_name(picard_db:query("SELECT username FROM users WHERE role = 'superadmin' LIMIT 1")).

superadmin_name({ok, []}) -> undefined;
superadmin_name({ok, [Row]}) -> maps:get("username", Row);
superadmin_name({error, Reason}) -> 
  logger:error("Failed to query superadmin name: ~p", [Reason]),
  undefined.

enabled() ->
  enabled(picard_db:query("SELECT COUNT(*) AS c FROM users")).

enabled({ok, [Row]}) -> maps:get("c", Row) > 0;
enabled({ok, _}) -> false;
enabled({error, _}) -> true;
enabled(_) -> false. 

login(Username, Password) ->
  login_result(picard_db:query("SELECT username, password_hash, role, auth_version FROM users WHERE username = $1", [Username]), Password).
login_result({ok, []}, _Password) -> {error, invalid_credentials};
login_result({ok, [Row]}, Password) -> verify_password(Row, Password);
login_result({error, Reason}, _Password) -> {error, {db_error, Reason}}.

verify_password(Row, Password) ->
  Hash = iolist_to_binary(io_lib:format("~s", [maps:get("password_hash", Row)])),
  case errm_argon:verify(binary_to_list(Password), Hash) of
    true -> issue_token(Row);
    false -> {error, invalid_credentials}
  end.

issue_token(Row) ->
  Claims = #{
    <<"sub">> => maps:get("username", Row),
    <<"role">> => list_to_binary(maps:get("role", Row)),
    <<"ver">> => maps:get("auth_version", Row)
  },
  errm_jwt:sign(Claims, picard_secrets:get(), hs256, #{ttl => 30 * 86400}).

authenticate(Req) ->
  Jar = errm_http_cookie_jar:from_request(Req, undefined),
  case errm_http_cookie_jar:get(Jar, <<"session">>) of
    undefined -> {error, no_session};
    Token -> verify_token(Token)
  end.

verify_token(Token) ->
  jwt_result(errm_jwt:verify(Token, picard_secrets:get(), hs256)).
jwt_result({ok, Claims}) -> check_version(Claims);
jwt_result({error, Reason}) -> {error, {invalid_token, Reason}}.

check_version(Claims) ->
  check_version(session_valid(Claims), Claims).

check_version(true, Claims) -> {ok, Claims};
check_version(false, _Claims) -> {error, stale_session}.

session_valid(Claims) ->
  Sub = maps:get(<<"sub">>, Claims, undefined),
  Ver = maps:get(<<"ver">>, Claims, undefined),
  version_matches(picard_db:query("SELECT auth_version FROM users WHERE username = $1", [Sub]), Ver).

version_matches({ok, [Row]}, Ver) -> maps:get("auth_version", Row) =:= Ver;
version_matches(_, _) -> false.

middleware() ->
  fun(Req, Next) ->
    Segments = [segment(S) || S <- maps:get(path, Req, [<<"/">>])],
    Auth = authenticate(Req),
    case is_protected(Segments) of
      true  -> protect(Req, Next, Auth);
      false -> Next(authenticated(Req, Auth))
    end
  end.

protect(Req, Next, {ok, Claims}) ->
  Next(Req#{account => username(Claims), claims => Claims});
protect(Req, Next, {error, _}) ->
  case xfu(Req) of
    undefined -> enforce(Req, Next);
    User -> Next(Req#{account => User, claims => undefined})
  end.

enforce(Req, Next) ->
  case enabled() of
    true -> {ok, {401, #{<<"content-type">> => <<"application/json">>}, <<"{\"error\":\"Unauthorized\"}">>}};
    false -> Next(Req#{account => "generic", claims => undefined})
  end.

authenticated(Req, {ok, Claims}) -> Req#{account => username(Claims), claims => Claims};
authenticated(Req, {error, _}) -> Req#{account => "generic", claims => undefined}.

username(Claims) -> binary_to_list(maps:get(<<"sub">>, Claims)).

xfu(Req) ->
  xfu_result(maps:get(<<"x-forwarded-user">>, maps:get(headers, Req, #{}), undefined)).
xfu_result(undefined) -> undefined;
xfu_result(User) when is_binary(User) -> binary_to_list(User);
xfu_result(User) when is_list(User) -> User.

is_protected(Segments) -> lists:any(fun(P) -> starts_with(P, Segments) end, ?PROTECTED).

starts_with([], _) -> true;
starts_with([_ | _], []) -> false;
starts_with([H | T], [SH | ST]) -> H =:= SH andalso starts_with(T, ST).

segment(S) when is_binary(S) -> S;
segment(S) when is_list(S) -> list_to_binary(S);
segment(S) when is_atom(S) -> atom_to_binary(S, utf8).

rank("superadmin") -> 2;
rank("admin") -> 1;
rank(_) -> 0.

valid_username(UN) when byte_size(UN) > 32 -> false;
valid_username(UN) -> lists:all(fun(C) -> username_char(C) end, binary_to_list(UN)) andalso UN =/= <<>>.
username_char(C) -> (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z)
  orelse (C >= $0 andalso C =< $9) orelse C =:= $. orelse C =:= $_ orelse C =:= $-.

can_manage(Acting, Target) -> rank(Acting) > rank(Target).
