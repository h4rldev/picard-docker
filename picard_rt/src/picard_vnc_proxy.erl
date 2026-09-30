-module (picard_vnc_proxy).
-behaviour (errm_ws_handler).
-export ([init/2, handle_text/2, handle_binary/2, handle_info/2, handle_ping/2, handle_pong/2, terminate/2]).

init(_RequestInfo, #{port := Port, token := Token} = Args) ->
  Host = maps:get(host, Args, "127.0.0.1"),
  case connect_vnc(Host, Port, 50) of
    {ok, Sock} ->
      ok = inet:setopts(Sock, [{active, once}, {packet, raw}, {nodelay, true}]),
      {ok, #{vnc => Sock, token => Token}};
    {error, Reason} ->
        {error, Reason}
  end.

handle_binary(Data, #{vnc := Sock} = State) ->
  gen_tcp:send(Sock, Data),
  {ok, State}.

handle_text(_Data, State) ->
  {ok, State}.

handle_info({tcp, Sock, Data}, #{vnc := Sock} = State) ->
  errm_ws:send_binary(self(), Data),
  inet:setopts(Sock, [{active, once}]),
  {ok, State};
handle_info({tcp_closed, Sock}, #{vnc := Sock} = State) ->
  {close, State};
handle_info(_Info, State) ->
  {ok, State}.

handle_ping(_Data, State) -> {ok, State}.

handle_pong(_Data, State) -> {ok, State}.

terminate(_Reason, #{vnc := Sock}) ->
  _ = gen_tcp:close(Sock),
  ok;
terminate(_Reason, _State) ->
  ok.

connect_vnc(_Host, _Port, 0) -> {error, timeout};
connect_vnc(Host, Port, N) ->
  case gen_tcp:connect(Host, Port, [binary, {active, false}], 200) of
    {ok, Sock} -> logger:info("[vnc] connected to ~s:~p (~p tries left)", [Host, Port, N]), {ok, Sock};
    {error, _} -> timer:sleep(100), connect_vnc(Host, Port, N - 1)
  end.
