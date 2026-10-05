#!/bin/sh
# Stop only the gateway executable belonging to this image.
set -eu
UPSTREAM_DIR=${WB_UPSTREAM_DIR:-/opt/workbuddy2api}
BIN="$UPSTREAM_DIR/wb2api"
PID_FILE="$UPSTREAM_DIR/data/wb2api.pid"

if [ ! -f "$PID_FILE" ]; then
  echo 'workbuddy2api is not running: no PID file'
  exit 0
fi
pid=$(cat "$PID_FILE" 2>/dev/null || true)
case "$pid" in
  ''|*[!0-9]*)
    rm -f "$PID_FILE"
    echo 'Removed invalid PID file; no process was stopped'
    exit 0
    ;;
esac
exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
expected=$(readlink -f "$BIN" 2>/dev/null || true)
if [ -z "$exe" ] || [ -z "$expected" ] || [ "$exe" != "$expected" ]; then
  rm -f "$PID_FILE"
  echo 'Removed stale PID file; no matching workbuddy2api process'
  exit 0
fi

kill -TERM "$pid"
i=0
while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 15 ]; do
  sleep 1
  i=$((i + 1))
done
if kill -0 "$pid" 2>/dev/null; then
  exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
  [ "$exe" != "$expected" ] || kill -KILL "$pid"
fi
rm -f "$PID_FILE"
echo "workbuddy2api stopped (pid $pid)"
