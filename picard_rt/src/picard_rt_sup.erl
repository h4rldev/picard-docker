-module(picard_rt_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
  DbOwner = #{
    id => picard_db_owner,
    start => {picard_db_owner, start_link, []},
    restart => permanent, shutdown => 5000,
    type => worker,
    modules => [picard_db_owner]
  },

  Sessions = #{
    id => picard_sessions_sup,
    start => {picard_sessions_sup, start_link, []},
    restart => permanent, shutdown => infinity,
    type => supervisor, 
    modules => [picard_sessions_sup]
  },

  Router = #{
    id => picard_router,
    start => {picard_router, start_link, []},
    restart => permanent, shutdown => 5000,
    type => worker, 
    modules => [picard_router]
  },

  {ok, {#{strategy => one_for_one, intensity => 5, period => 10},
        [DbOwner, Sessions, Router]}}.
