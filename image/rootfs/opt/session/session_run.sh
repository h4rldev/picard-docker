#!/bin/sh
set -e

SESSION_USER=$1
RTDIR=$2
HOME_DIR=$3
WAYVNC_PORT=$4
PIDFILE=$5

if ! id "$SESSION_USER" >/dev/null 2>&1; then
  adduser -D -H -s /bin/sh "$SESSION_USER"
fi

rm -rf "$RTDIR"
mkdir -p "$RTDIR" "$HOME_DIR"
chown -R "$SESSION_USER:$SESSION_USER" "$RTDIR" "$HOME_DIR"
chmod 700 "$RTDIR"

setsid su "$SESSION_USER" -s /bin/sh -c '
  echo 1000 > /proc/self/oom_score_adj 2>/dev/null || true

  export XDG_RUNTIME_DIR="$1" HOME="$2"
  export WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_LIBINPUT_NO_DEVICES=1

  sway -c /etc/sway/config &
  SWAY_PID=$!

  i=0
  until ls "$1"/sway-ipc.* >/dev/null 2>&1 || [ $i -ge 100 ]; do
    sleep 0.1
    i=$((i+1))
  done
  for sock in "$1"/wayland-*; do
    case "$sock" in
      *.lock) ;;
      *) export WAYLAND_DISPLAY=$(basename "$sock"); break ;;
    esac
  done

  wayvnc --keyboard picard 0.0.0.0 "$3" &
  wait "$SWAY_PID"
' sh "$RTDIR" "$HOME_DIR" "$WAYVNC_PORT" &
SESSION_PID=$!
echo "$SESSION_PID" > "$PIDFILE"

wait "$SESSION_PID" 2>/dev/null || true

kill -TERM -"$SESSION_PID" 2>/dev/null || true
sleep 1
kill -KILL -"$SESSION_PID" 2>/dev/null || true
wait 2>/dev/null || true
