-module (picard_session).
-behaviour (gen_server).
-export ([start_link/1, info/1, freeze/1, resume/1, destroy/1]).
-export ([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, handle_continue/2]).

start_link(Account) ->
  gen_server:start_link(?MODULE, [Account], []).

info(Pid) -> gen_server:call(Pid, info).
freeze(Pid) -> gen_server:call(Pid, freeze, 60000).
resume(Pid) -> gen_server:call(Pid, resume).
destroy(Pid) -> gen_server:call(Pid, destroy, 60000).

init([Account]) ->
  Sid = erlang:unique_integer([positive]),
  Token = binary:encode_hex(crypto:strong_rand_bytes(8)),
  User = "s" ++ integer_to_list(Sid rem 1000000),
  Port = pick_port(),
  RtDir = filename:join(rt_root(), "s" ++ integer_to_list(Sid)),
  WorkDir = filename:join(work_root(), "s" ++ integer_to_list(Sid)),
  SnapDir = filename:join(snap_root(), Account),

  ok = prepare_dirs(User, RtDir, WorkDir, SnapDir),
  _ = pg:join({picard_session, Account}, self()),
  _ = pg:join({picard_token, Token}, self()),
  {ok, #{
    account => Account,
    token => Token,
    user => User,
    rt_dir => RtDir,
    pid_file => filename:join(RtDir, "session.pgid"),
    work_dir => WorkDir,
    snap_dir => SnapDir,
    port => Port,
    status => running,
    os_port => undefined
  }, {continue, boot}}.

handle_continue(boot, State) ->
  #{user := User, rt_dir := RtDir, work_dir := WorkDir, port := Port} = State,

  PidFile = maps:get(pid_file, State),
  OsPort = open_port(
    {spawn_executable, "/opt/session/session_run.sh"}, 
    [{args, [User, RtDir, WorkDir, integer_to_list(Port), PidFile]}, exit_status, stderr_to_stdout]
  ),

  {noreply, State#{os_port => OsPort}}.

handle_call(token, _From, State) ->
  {reply, maps:get(token, State), State};

handle_call(wayvnc_port, _From, State) ->
  {reply, maps:get(port, State), State};

handle_call(info, _From, State) ->
  {reply, #{account => maps:get(account, State), token => maps:get(token, State),
            status => maps:get(status, State), port => maps:get(port, State)}, State};

handle_call(freeze, _From, #{status := running} = State) ->
  os:cmd("/opt/session/session_ctl.sh STOP " ++ maps:get(pid_file, State)),
  #{snap_dir := SnapDir, work_dir := WorkDir} = State,
  os:cmd("rm -rf " ++ SnapDir ++ " && cp -a " ++ WorkDir ++ " " ++ SnapDir),
  gen_server:cast(picard_router, {session_frozen, self()}),
  logger:info("[session] fresh-freeze user=~s work_dir=~s", [maps:get(user, State), WorkDir]),
  {reply, ok, State#{status := frozen}};
handle_call(freeze, _From, State) ->
  {reply, ok, State};

handle_call(resume, _From, #{status := frozen} = State) ->
  os:cmd("/opt/session/session_ctl.sh CONT " ++ maps:get(pid_file, State)),
  logger:info("[session] resume user=~s", [maps:get(user, State)]),
  {reply, ok, State#{status := running}};

handle_call(resume, _From, State) ->
  {reply, ok, State};

handle_call(destroy, _From, State) ->
  os:cmd("/opt/session/session_ctl.sh KILL " ++ maps:get(pid_file, State)),
  #{work_dir := WorkDir} = State,
  os:cmd("rm -rf " ++ WorkDir),
  logger:info("[session] destroy user=~s", [maps:get(user, State)]),
  {stop, normal, ok, State};

handle_call(_Req, _From, State) ->
  {reply, {error, unknown}, State}.


handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info({OsPort, {exit_status, _}}, #{os_port := OsPort} = State) ->
  #{work_dir := WorkDir} = State,
  os:cmd("rm -rf " ++ WorkDir),
  {stop, normal, State};
handle_info({OsPort, {data, Data}}, #{os_port := OsPort} = State) ->
  logger:info("[picard_session] ~s", [Data]),
  {noreply, State};
handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, #{account := Account, token := Token}) ->
  _ = pg:leave({picard_session, Account}, self()),
  _ = pg:leave({picard_token, Token}, self()),
  ok;
terminate(_Reason, _State) ->
  ok.

prepare_dirs(User, RtDir, WorkDir, SnapDir) ->
  os:cmd("adduser -D -H -s /bin/sh " ++ User ++ " 2>/dev/null || true"),
  os:cmd("rm -rf " ++ WorkDir),
  ok = filelib:ensure_dir(filename:join(RtDir, "x")),
  ok = filelib:ensure_dir(filename:join(WorkDir, "x")),
  ok = filelib:ensure_dir(filename:join(SnapDir, "x")),
  os:cmd("cp -a " ++ SnapDir ++ "/. " ++ WorkDir ++ " 2>/dev/null || true"),
  os:cmd("chown -R " ++ User ++ ":" ++ User ++ " " ++ RtDir ++ " " ++ WorkDir),
  link_storage(User, WorkDir),
  ok.

link_storage(User, WorkDir) ->
  Dir = storage_dir(),
  os:cmd("mkdir -p " ++ Dir ++ " && chmod 1777 " ++ Dir ++ " && chown root:root " ++ Dir),
  os:cmd("ln -sfn " ++ Dir ++ " " ++ filename:join(WorkDir, "storage")),
  os:cmd("chown -h " ++ User ++ ":" ++ User ++ " " ++ filename:join(WorkDir, "storage")),
  ok.

storage_dir() ->
   os:getenv("PICARD_STORAGE_DIR", "/storage").

pick_port() -> pick_port(5900).
pick_port(Port) when Port > 6000 -> error(no_free_port);
pick_port(Port) ->
  case gen_tcp:listen(Port, [{ip, {127,0,0,1}}, {reuseaddr, true}, {active, false}]) of
    {ok, L} -> gen_tcp:close(L), Port;
    {error, _} -> pick_port(Port + 1)
  end.

rt_root() -> os:getenv("PICARD_RT_ROOT", "/run/picard").
work_root() -> os:getenv("PICARD_WORK_ROOT", "/data/work").
snap_root() -> os:getenv("PICARD_SNAP_ROOT", "/data/snapshots").
