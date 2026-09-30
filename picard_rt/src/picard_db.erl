-module (picard_db).
-export ([init/0, db/0, query/1, query/2, is_owner/0]).

init() ->
  case is_owner() of
    true ->
      Path = picard_config:get_str("db_path", "/data/picard.db"),
      {ok, Db} = errm_sqlite:open(Path),
      ok = errm_sqlite_migrate:migrate(Db, filename:join(code:priv_dir(picard_rt), "migrations")),
      persistent_term:put(?MODULE, Db);
    false ->
      ok
  end.

db() ->
  persistent_term:get(?MODULE).

query(Sql) ->
  query(Sql, []).

query(Sql, Args) ->
  case is_owner() of
    true -> errm_sqlite:query(db(), Sql, Args);
    false -> gen_server:call({picard_db_owner, db_node()}, { query, Sql, Args}, 30000)
  end.

is_owner() ->
  os:getenv("PICARD_DB_OWNER") =:= "1".

db_node() ->
  case pg:get_members(picard_db) of
    [Pid | _] -> node(Pid);
    _ -> node()
  end.

