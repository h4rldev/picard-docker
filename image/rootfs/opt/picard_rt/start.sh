#!/bin/sh
: "${PICARD_COOKIE:?PICARD_COOKIE must be set}"
exec erl -noshell -sname picard -setcookie "$PICARD_COOKIE" -kernel start_pg true \
  -pa /opt/picard_rt/*/ebin \
  -eval 'application:ensure_all_started(picard_rt), timer:sleep(infinity)'
