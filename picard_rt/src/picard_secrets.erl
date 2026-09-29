-module (picard_secrets).
-export ([init/0, get/0]).

init() ->
  case picard_config:get_str("jwt_secret", undefined) of
    undefined ->
      ensure_secret_file(),
      logger:error("PICARD_JWT_SECRET is not set - copy it from /data/picard_jwt_secret.txt into your environment and restart"),
      halt(1);
    Secret ->
      SecretBin = base64:decode(list_to_binary(Secret), #{mode => 'urlsafe', padding => false}),
      persistent_term:put(?MODULE, SecretBin),
      ok
  end.

ensure_secret_file() ->
  File = "/data/picard_jwt_secret.txt",
  case filelib:is_file(File) of
    true -> ok;   %% value already persisted; keep it stable across boots
    false ->
      Gen = base64:encode(crypto:strong_rand_bytes(32), #{mode => 'urlsafe', padding => false}),
      _ = file:write_file(File, <<"# Put this where you store your other environment vars for the container\nPICARD_JWT_SECRET=", Gen/binary, "\n">>),
      ok
  end.

get() ->
  persistent_term:get(?MODULE).
