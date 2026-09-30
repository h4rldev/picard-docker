-module (picard_sessions_sup).
-behaviour (supervisor).
-export ([start_link/0, start_session/1, init/1]).

start_link() ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_session(Account) ->
  supervisor:start_child(?MODULE, [Account]).
  
init([]) ->
  Session = #{
    id => picard_session,
    start => {picard_session, start_link, []},
    restart => temporary,
    shutdown => 5000,
    type => worker,
    modules => [picard_session]
  },
  {ok, {#{strategy => simple_one_for_one, intensity => 0, period => 1}, [Session]}}.
