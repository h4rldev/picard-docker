-module (picard_db).
-export ([init/0, db/0]).

init() ->
  Path = picard_config:get_str("db_path", "/data/picard.db"),
  {ok, Db} = errm_sqlite:open(Path),
  Migrations = filename:join(code:priv_dir(picard_rt), "migrations"),
  ok = errm_sqlite_migrate:migrate(Db, Migrations),
  persistent_term:put(?MODULE, Db),
  ok.

db() ->
  persistent_term:get(?MODULE).