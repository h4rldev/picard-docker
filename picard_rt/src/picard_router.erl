-module (picard_router).
-behaviour (gen_server).
-export ([start_link/0, route/1, freeze/2, alive/2, lookup_token/2]).
-export ([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-export ([freeze_token/1, freeze_all/0]).

-define(TAB, picard_sessions).
-define(IDLE_TIMEOUT, 600).
-define(SWEEP_INTERVAL, 60000).

start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

route(Account) -> gen_server:call(?MODULE, {route, Account}, 60000).
freeze(Token, Account) -> gen_server:call(?MODULE, {freeze, Token, Account}, 60000).
alive(Token, Account) -> gen_server:call(?MODULE, {alive, Token, Account}).
lookup_token(Token, Account) -> gen_server:call(?MODULE, {lookup_token, Token, Account}).

init([]) ->
  ets:new(?TAB, [named_table, public, set, {read_concurrency, true}]),
  os:set_signal(sigterm, handle),
  picard_route_http:start(),
  erlang:send_after(?SWEEP_INTERVAL, self(), idle_sweep),
  {ok, #{}}.

handle_call({route, Account}, _From, State) ->
 {reply, route_account(Account), State};
handle_call({freeze, Token, Account}, _From, State) ->
  case session_by_token(Token, Account) of
    {ok, Pid} -> freeze_quietly(Pid);
    error -> ok
  end,
  {reply, ok, State};
handle_call({alive, Token, Account}, _From, State) ->
  case session_by_token(Token, Account) of
    {ok, Pid} ->
      try
        ok = picard_session:resume(Pid),
        #{port := Port} = picard_session:info(Pid),
        mark_alive(Token, Account, Pid, running, Port)
      catch _:_ -> ok
      end;
    error -> ok
  end,
  {reply, ok, State};
handle_call({lookup_token, Token, Account}, _From, State) ->
  case session_by_token(Token, Account) of
    {ok, Pid} ->
      try
        ok = picard_session:resume(Pid),
        #{port := Port} = picard_session:info(Pid),
        {reply, {ok, Port, node(Pid)}, State}
      catch _:_ -> {reply, error, State}
      end;
    error -> {reply, error, State}
  end;
handle_call(_Req, _From, State) ->
  {reply, {error, unknown}, State}.


freeze_token(Token) ->
  gen_server:cast(?MODULE, {freeze_token, Token}).

handle_cast({freeze_token, Token}, State) ->
  Pids = try pg:get_members({picard_token, Token}) catch _:_ -> [] end,
  lists:foreach(fun freeze_quietly/1, Pids),
  {noreply, State};
handle_cast({session_frozen, Pid}, State) ->
  case lookup_pid(Pid) of
    {ok, Account, Token, Port} ->
      ets:insert(?TAB, {Token, Account, Pid, frozen, Port, now_sec()}),
      Older = [P2 || {_, A2, P2, frozen, _, _} <- ets:tab2list(?TAB), A2 =:= Account, P2 =/= Pid],
      logger:info("[router] frozen pid=~p older=~p",  [Pid, Older]),
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
  freeze_sessions([P || {_, _, P, running, _, Last} <- ets:tab2list(?TAB), Now - Last > ?IDLE_TIMEOUT]),
  erlang:send_after(?SWEEP_INTERVAL, self(), idle_sweep),
  {noreply, State};
handle_info({'DOWN', _Ref, process, Pid, _Reason}, State) ->
  ets:match_delete(?TAB, {'_', '_', Pid, '_', '_', '_'}),
  {noreply, State};
handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

freeze_sessions(Pids) ->
  lists:foreach(fun(P) -> try picard_session:freeze(P) catch _:_ -> ok end end, Pids).

freeze_all() ->
  Running = [P || {_,_,P, running, _,_} <- ets:tab2list(?TAB)],
  logger:info("[router] shutdown: freezing ~p running session(s)", [length(Running)]),
  freeze_sessions(Running).

mark_alive(Token, Account, Pid, Status, Port) ->
  ets:insert(?TAB, {Token, Account, Pid, Status, Port, now_sec()}).

lookup_pid(Pid) ->
  case ets:match_object(?TAB, {'_', '_', Pid, '_', '_', '_'}) of
    [{Token, Account, _Pid, _Status, Port, _Last}] -> {ok, Account, Token, Port};
    _ -> error
  end.

now_sec() ->
  erlang:monotonic_time(second).

route_account(Account) ->
  case find_frozen(Account) of
    {ok, Pid} ->
      try
        ok = picard_session:resume(Pid),
        attach(Account, Pid)
      catch _:_ -> new_session(Account)
      end;
    error -> new_session(Account)
  end.

attach(Account, Pid) ->
  #{token := Token, port := Port} = picard_session:info(Pid),
  mark_alive(Token, Account, Pid, running, Port),
  logger:info("[router] attached account=~s token=~s", [Account, Token]),
  {ok, Token}.

new_session(Account) ->
  case picard_admission:can_start() of
    true ->
      {ok, Pid} = picard_sessions_sup:start_session(Account),
      erlang:monitor(process, Pid),
      #{token := Token, port := Port} = picard_session:info(Pid),
      mark_alive(Token, Account, Pid, running, Port),
      logger:info("[router] spawned account=~s token=~s", [Account, Token]),
      {ok, Token};
    false ->
      {error, capacity}
  end.

find_frozen(Account) ->
  Pids = try pg:get_members({picard_session, Account}) catch _:_ -> [] end,
  find_status(Pids, frozen).

find_status([], _Status) -> error;
find_status([Pid | Rest], Status) ->
  try picard_session:info(Pid) of
    #{status := Status} ->
       {ok, Pid};
    _ ->
       find_status(Rest, Status)
  catch _:_ ->
      find_status(Rest, Status)
  end.

session_by_token(Token, Account) ->
  Pids = try pg:get_members({picard_token, Token}) catch _:_ ->
                                                       [] end,
  find_account(Pids, Account).

find_account([], _Account) -> error;
find_account([Pid | Rest], Account) -> 
  try picard_session:info(Pid) of
    #{account := Account} ->
       {ok, Pid};
    _ ->
      find_account(Rest, Account)
  catch _:_ ->
      find_account(Rest, Account)
  end.

freeze_quietly(Pid) ->
  try picard_session:freeze(Pid) catch _:_ -> ok end.
