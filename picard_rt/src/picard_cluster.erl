-module (picard_cluster).
-export ([join/0, peers/0]).

join() ->
  [net_adm:ping(N) || N <- seeds()],
  logger:info("[cluster] node=~p peers=~p", [node(), peers()]),
  ok.

peers() ->
   nodes().

%% Atoms exhaustion risk is handled.
seeds() ->
  case os:getenv("PICARD_SEED_NODES") of
    false -> [];
    S -> [list_to_atom(N) || N <- string:split(S, ",", all), N =/= ""]
  end.
