#!/bin/sh
# Start the bundled gateway once; validate the PID against the executable path.
set -eu
UPSTREAM_DIR=${WB_UPSTREAM_DIR:-/opt/workbuddy2api}
BIN="$UPSTREAM_DIR/wb2api"
CONFIG=${WB_UPSTREAM_CONFIG:-$UPSTREAM_DIR/config.json}
DATA_DIR="$UPSTREAM_DIR/data"
PID_FILE="$DATA_DIR/wb2api.pid"

[ -x "$BIN" ] || { echo "Missing executable: $BIN" >&2; exit 1; }
[ -f "$CONFIG" ] || { echo "Missing config file: $CONFIG" >&2; exit 1; }
mkdir -p "$DATA_DIR"
: >> "$DATA_DIR/server.out.log"
: >> "$DATA_DIR/server.err.log"

is_our_process() {
  [ -r "/proc/$1/cmdline" ] || return 1
  exe=$(readlink -f "/proc/$1/exe" 2>/dev/null) || return 1
  [ "$exe" = "$(readlink -f "$BIN")" ]
}

if [ -f "$PID_FILE" ]; then
  old_pid=$(cat "$PID_FILE" 2>/dev/null || true)
  case "$old_pid" in
    ''|*[!0-9]*) rm -f "$PID_FILE" ;;
    *)
      if is_our_process "$old_pid"; then
        echo "workbuddy2api already running (pid $old_pid)"
        exit 0
      fi
      rm -f "$PID_FILE"
      ;;
  esac
fi

cd "$UPSTREAM_DIR"
nohup "$BIN" -config "$CONFIG" >>"$DATA_DIR/server.out.log" 2>>"$DATA_DIR/server.err.log" </dev/null &
pid=$!
printf '%s\n' "$pid" > "$PID_FILE"
sleep 1
if ! is_our_process "$pid"; then
  rm -f "$PID_FILE"
  echo "workbuddy2api exited during startup; see $DATA_DIR/server.err.log" >&2
  exit 1
fi
echo "workbuddy2api started (pid $pid)"
