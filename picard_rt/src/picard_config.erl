-module (picard_config).
-export ([load/0, get/2, get_str/2]).

load() ->
  Config = case file:read_file(config_path()) of
    {ok, Bin} -> case errm_json:decode(Bin) of
                   {ok, M} when is_map(M) -> M;
                   _ -> #{}
                 end;
    _ -> #{}
  end,
  persistent_term:put(?MODULE, Config),
  ok.

%% env > config file > default. Keys are lowercase snake_case; env var is PICARD_<UPPER>.
get(Key, Default) ->
  EnvKey = "PICARD_" ++ string:uppercase(Key),
  case os:getenv(EnvKey) of
    false ->
      Config = persistent_term:get(?MODULE, #{}),
      case maps:get(list_to_binary(Key), Config, undefined) of
        undefined -> Default;
        Value -> Value
      end;
    Value -> Value
  end.

config_path() ->
  os:getenv("PICARD_CONFIG", "/data/picard.config.json").

%% string-typed value (env gives list, JSON gives binary)
get_str(Key, Default) ->
  case get(Key, Default) of
    Bin when is_binary(Bin) -> binary_to_list(Bin);
    Str when is_list(Str) -> Str;
    _ -> Default
  end.