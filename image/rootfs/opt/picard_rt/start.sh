#!/bin/sh
exec erl -noshell -pa /opt/picard_rt/*/ebin \
  -eval 'application:ensure_all_started(picard_rt), timer:sleep(infinity)'
