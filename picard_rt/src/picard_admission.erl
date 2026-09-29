-module (picard_admission).
-export ([can_start/0]).

-define (PER_SESSION_MB, 500).
-define (HEADROOM_MB, 512).

can_start() ->
  available_mb() > ?PER_SESSION_MB + ?HEADROOM_MB.

available_mb() ->
  case file:read_file("/proc/meminfo") of
    {ok, Data} -> mem_available_kb(binary:split(Data, <<"\n">>, [global])) bsr 10;
    _ -> 0
  end.

mem_available_kb([]) -> 0;
mem_available_kb([Line | Rest]) ->
  case line_kb(Line) of
    {ok, Kb} -> Kb;
    error -> mem_available_kb(Rest)
  end.

line_kb(Line) ->
  case binary:match(Line, <<"MemAvailable:">>) of
    nomatch -> error;
    _ ->
      Fields = [F || F <- binary:split(Line, <<" ">>, [global]), F =/= <<>>],
      case Fields of
        [_Name, Kb | _] -> {ok, binary_to_integer(Kb)};
        _ -> error
      end
  end.
