-module (picard_secrets).
-export ([init/0, get/0]).

init() ->
  case picard_config:get_str("jwt_secret", undefined) of
    undefined ->
      persistent_term:put(?MODULE, persisted_or_new_secret()), ok;
    Secret ->
      persistent_term:put(?MODULE, base64:decode(list_to_binary(Secret), #{mode => 'urlsafe', padding => false})), ok
  end.

persisted_or_new_secret() ->
  File = "/data/picard_jwt_secret.txt",
  case file:read_file(File) of
    {ok, Bin} ->
      [_, Rest] = binary:split(Bin, <<"PICARD_JWT_SECRET=">>),
      [Val | _] = binary:split(Rest, <<"\n">>),
      base64:decode(Val, #{mode => 'urlsafe', padding => false});
    _ ->
      Gen = base64:encode(crypto:strong_rand_bytes(32), #{mode => 'urlsafe', padding => false}),
      _ = file:write_file(File, <<"# Put this where you store your other environment vars for the container\nPICARD_JWT_SECRET=", Gen/binary, "\n">>),
      logger:warning("PICARD_JWT_SECRET unset; generated and saved to ~s", [File]),
      base64:decode(Gen, #{mode => 'urlsafe', padding => false})
  end.

get() ->
  persistent_term:get(?MODULE).
