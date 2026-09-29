#!/bin/sh
set -e

SIG=$1

case "$SIG" in
  STOP) SIGNAL=STOP ;;
  CONT) SIGNAL=CONT ;;
  TERM) SIGNAL=TERM ;;
  KILL) SIGNAL=KILL ;;
esac

signal_tree() {
  pid=$1
  for child in $(ps -o pid,ppid | awk -v p="$pid" '$2==p {print $1}'); do
    signal_tree "$child"
  done
  if [ "$pid" != "1" ] && [ "$pid" != "$$" ]; then
    kill -"$SIGNAL" "$pid" 2>/dev/null || true
  fi
}

signal_tree 1
