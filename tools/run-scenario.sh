#!/usr/bin/env bash
# Phase A link-health integration scenario runner (主 agent 实跑用).
# Launches exo_cmd_node + loopback_node with given fault-injection params,
# runs for N seconds, then kills BY PID (never pkill -f: the script's own
# argv contains the node names, so pkill -f would self-terminate -> exit 144).
#
# Usage: run-scenario.sh <tag> <run_seconds> [loopback ros-args...]
#   tag           label for log files (log/<tag>.cmd.log, log/<tag>.lb.log)
#   run_seconds   how long to let it run before killing
#   remaining args are passed straight to `ros2 run exo_cmd loopback_node`
set +u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/host-common.sh"
exo_source_ros || exit 1
set -e

TAG="$1"; SECS="$2"; shift 2
LOGDIR="$EXO_LOGDIR"
mkdir -p "$LOGDIR"
CMD_LOG="$LOGDIR/$TAG.cmd.log"
LB_LOG="$LOGDIR/$TAG.lb.log"

# Kill the `ros2 run` wrapper and its child process tree together. macOS does
# not ship Linux setsid/timeout by default, so process-tree cleanup is the
# portable primitive for this branch.
ros2 run exo_cmd loopback_node "$@" > "$LB_LOG" 2>&1 &
LB=$!
ros2 run exo_cmd exo_cmd_node > "$CMD_LOG" 2>&1 &
CMD=$!
sleep "$SECS"
exo_kill_tree "$CMD"
exo_kill_tree "$LB"
sleep 1
# Hard assert no exo node survived this scenario before the next one starts.
LEAK=$(pgrep -f 'exo_cmd/lib/exo_cmd/(exo_cmd_node|loopback_node)' | tr '\n' ' ')
if [ -n "$LEAK" ]; then
  echo "!!! LEAK after '$TAG': surviving node PIDs: $LEAK" >&2
  kill -9 $LEAK 2>/dev/null || true
fi
echo "=== scenario '$TAG' done (lb=$LB cmd=$CMD, ${SECS}s) ==="
