#!/bin/sh
set -e
IMAGE=${IMAGE:-picard-node:test}

cid=$(docker run -d \
  -e WLR_BACKENDS=headless -e WLR_HEADLESS_OUTPUTS=1 -e WLR_LIBINPUT_NO_DEVICES=1 \
  --name picard-selfcheck "$IMAGE" \
  /opt/session/session_run.sh app /tmp/run /home/app 5999 /tmp/session.pgid)
trap 'docker rm -f picard-selfcheck >/dev/null 2>&1' EXIT

sleep 9
echo "== sockets + shot =="
docker exec picard-selfcheck sh -c '
  ls /tmp/run | grep -E "wayland-|sway-ipc"
  WD=$(ls /tmp/run/wayland-* | grep -v "\.lock$" | head -1); WD=$(basename "$WD")
  su app -s /bin/sh -c "XDG_RUNTIME_DIR=/tmp/run WAYLAND_DISPLAY=$WD grim /tmp/shot.png"
  ls -la /tmp/shot.png
  nc -z 127.0.0.1 5999 && echo "wayvnc port open"
'
echo "== safeguards =="
docker exec picard-selfcheck sh -c '
  P=$(pgrep -x sway | head -1)
  echo "sway pid: $P"
  echo -n "oom_score_adj(sway): "; cat /proc/$P/oom_score_adj
  ps -eo pid,user,comm | grep -w sway
'
echo "== freeze (expect T) =="
docker exec picard-selfcheck /opt/session/session_ctl.sh STOP /tmp/session.pgid
sleep 1
docker exec picard-selfcheck sh -c 'ps -eo pid,ppid,stat,comm | grep -E "sway|picard|wayvnc"'
echo "== resume (expect S) =="
docker exec picard-selfcheck /opt/session/session_ctl.sh CONT /tmp/session.pgid
sleep 1
docker exec picard-selfcheck sh -c 'ps -eo pid,ppid,stat,comm | grep -E "sway|picard|wayvnc"'
echo "== teardown =="
docker exec picard-selfcheck /opt/session/session_ctl.sh TERM /tmp/session.pgid
sleep 2
docker inspect -f '{{.State.Running}}' picard-selfcheck
