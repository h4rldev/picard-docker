-module (picard_rt_app).
-behaviour (application).
-export ([start/2, stop/1, prep_stop/1]).

start(_StartType, _StartArgs) ->
  logger:set_primary_config(level, info),
  picard_config:load(),
  picard_secrets:init(),
  picard_db:init(),
  picard_cluster:join(),
  case picard_db:is_owner() of
    true -> picard_auth:ensure_superadmin();
    false -> ok
  end,
  picard_rt_sup:start_link().

prep_stop(State) ->
  picard_router:freeze_all(),
  State.

stop(_State) ->
    ok.
