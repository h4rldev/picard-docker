#!/bin/sh
set -e
PGID=$(cat "$1")
kill -TERM -"$PGID" 2>/dev/null || true
sleep 1
kill -KILL -"$PGID" 2>/dev/null || true
