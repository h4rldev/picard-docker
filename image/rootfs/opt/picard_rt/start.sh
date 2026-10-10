#!/bin/sh
set -e

COOKIE_FILE=/data/picard_erlang_cookie.txt
if [ -z "${PICARD_COOKIE:-}" ] && [ -f "$COOKIE_FILE" ]; then
  PICARD_COOKIE=$(cat "$COOKIE_FILE")
fi
if [ -z "${PICARD_COOKIE:-}" ]; then
  PICARD_COOKIE=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')
  echo "$PICARD_COOKIE" > "$COOKIE_FILE"
  echo "[start] PICARD_COOKIE unset; generated and saved to $COOKIE_FILE" >&2
fi
export PICARD_COOKIE

STORAGE="${PICARD_STORAGE_DIR:-/storage}"
PGID="${PICARD_STORAGE_GID:-1000}"
addgroup -g "$PGID" picard 2>/dev/null || true
if [ -d "$STORAGE" ]; then
  chgrp -R picard "$STORAGE" 2>/dev/null || true
  chmod -R g+rwX "$STORAGE" 2>/dev/null || true
  find "$STORAGE" -type d -exec chmod g+s {} + 2>/dev/null || true
fi

exec erl -noshell -sname picard -setcookie "$PICARD_COOKIE" -kernel start_pg true \
  -pa /opt/picard_rt/*/ebin \
  -eval 'application:ensure_all_started(picard_rt), timer:sleep(infinity)'
