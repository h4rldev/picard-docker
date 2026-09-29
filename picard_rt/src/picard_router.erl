-module (picard_router).
-behaviour (gen_server).
-export ([start_link/0, route/1, freeze/2, alive/2, lookup_token/2]).
-export ([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(TAB, picard_sessions).
-define(IDLE_TIMEOUT, 600).
-define(SWEEP_INTERVAL, 60000).

start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

route(Account) -> gen_server:call(?MODULE, {route, Account}, 60000).
freeze(Token, Account) -> gen_server:call(?MODULE, {freeze, Token, Account}).
alive(Token, Account) -> gen_server:call(?MODULE, {alive, Token, Account}).
lookup_token(Token, Account) -> gen_server:call(?MODULE, {lookup_token, Token, Account}).

init([]) ->
  ets:new(?TAB, [named_table, public, set, {read_concurrency, true}]),
  picard_route_http:start(),
  erlang:send_after(?SWEEP_INTERVAL, self(), idle_sweep),
  {ok, #{}}.

handle_call({route, Account}, _From, State) ->
  case select_by(Account, frozen) of
    [Pid] ->
      picard_session:resume(Pid),

      Token = picard_session:token(Pid),
      mark_alive(Token, Account, Pid, running, picard_session:wayvnc_port(Pid)),
      {reply, {ok, Token}, State};
    [] ->
      case picard_admission:can_start() of
        true ->
          {ok, Pid} = picard_sessions_sup:start_session(Account),
          erlang:monitor(process, Pid),
          
          Token = picard_session:token(Pid),
          mark_alive(Token, Account, Pid, running, picard_session:wayvnc_port(Pid)),
          {reply, {ok, Token}, State};
        false ->
          {reply, {error, capacity}, State}
      end
  end;

handle_call({freeze, Token, Account}, _From, State) ->
  case lookup(Token) of
    {ok, Account, Pid, running, _Port} ->
      picard_session:freeze(Pid),
      {reply, ok, State};
    _ ->
      {reply, ok, State}
  end;

handle_call({alive, Token, Account}, _From, State) ->
  case lookup(Token) of
    {ok, Account, Pid, Status, Port} ->
      case Status of
        frozen ->
          picard_session:resume(Pid),
          mark_alive(Token, Account, Pid, running, Port);
        running ->
          mark_alive(Token, Account, Pid, running, Port)
      end,
      {reply, ok, State};
    _ ->
      {reply, ok, State}
  end;

handle_call({lookup_token, Token, Account}, _From, State) ->
  case lookup(Token) of
    {ok, Account, _Pid, _Status, Port} -> {reply, {ok, Port}, State};
    _ -> {reply, error, State}
  end;

handle_call(_Req, _From, State) ->
  {reply, {error, unknown}, State}.


handle_cast({session_frozen, Pid}, State) ->
  case lookup_pid(Pid) of
    {ok, Account, Token, Port} ->
      ets:insert(?TAB, {Token, Account, Pid, frozen, Port, now_sec()}),
      Older = [P2 || {_, A2, P2, frozen, _, _} <- ets:tab2list(?TAB), A2 =:= Account, P2 =/= Pid],

      case Older of
        [Old | _] ->
          ets:match_delete(?TAB, {'_', '_', Old, '_', '_', '_'}),
          picard_session:destroy(Old);
        [] -> ok
      end;
    error -> ok
  end,
  {noreply, State};

handle_cast(_Msg, State) ->
  {noreply, State}.


handle_info(idle_sweep, State) ->
  Now = now_sec(),
  [picard_session:freeze(P2) || {_, _, P2, running, _, Last} <- ets:tab2list(?TAB), Now - Last > ?IDLE_TIMEOUT],
  erlang:send_after(?SWEEP_INTERVAL, self(), idle_sweep),
  {noreply, State};

handle_info({'DOWN', _Ref, process, Pid, _Reason}, State) ->
  ets:match_delete(?TAB, {'_', '_', Pid, '_', '_', '_'}),
  {noreply, State};

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.


mark_alive(Token, Account, Pid, Status, Port) ->
  ets:insert(?TAB, {Token, Account, Pid, Status, Port, now_sec()}).

lookup(Token) ->
  case ets:lookup(?TAB, Token) of
    [{Token, Account, Pid, Status, Port, _Last}] -> {ok, Account, Pid, Status, Port};
    [] -> error
  end.

lookup_pid(Pid) ->
  case ets:match_object(?TAB, {'_', '_', Pid, '_', '_', '_'}) of
    [{Token, Account, _Pid, _Status, Port, _Last}] -> {ok, Account, Token, Port};
    _ -> error
  end.

select_by(Account, Status) ->
  ets:select(?TAB, [{{'_', '$1', '$2', '$3', '_', '_'}, [{'=:=', '$1', Account}, {'=:=', '$3', Status}], ['$2']}]).

now_sec() ->
  erlang:monotonic_time(second).
