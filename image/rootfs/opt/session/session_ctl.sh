#!/bin/sh
set -e

SIG=$1
PIDFILE=$2

case "$SIG" in
  STOP) SIGNAL=STOP ;;
  CONT) SIGNAL=CONT ;;
  TERM) SIGNAL=TERM ;;
  KILL) SIGNAL=KILL ;;
  *) exit 1 ;;
esac

PGID=$(cat "$PIDFILE" 2>/dev/null) || exit 0
[ -n "$PGID" ] || exit 0
kill -"$SIGNAL" -"$PGID" 2>/dev/null || true
