#!/bin/sh
# Run the upstream beside the manager; stop both on Pod termination.
set -eu

/opt/workbuddy2api/start-upstream.sh
python -m uvicorn server.main:app --host "${WB_MANAGER_HOST:-0.0.0.0}" --port "${WB_MANAGER_PORT:-7864}" &
manager_pid=$!

shutdown() {
  echo '[entrypoint] stopping manager and upstream'
  /opt/workbuddy2api/stop-upstream.sh || true
  kill -TERM "$manager_pid" 2>/dev/null || true
  wait "$manager_pid" 2>/dev/null || true
}
trap shutdown TERM INT
wait "$manager_pid"
