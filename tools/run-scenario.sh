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
source /opt/ros/jazzy/setup.bash
source /home/lhq24/robotics/ros2_ws/install/setup.bash
set -e

TAG="$1"; SECS="$2"; shift 2
LOGDIR=/home/lhq24/robotics/log
CMD_LOG="$LOGDIR/$TAG.cmd.log"
LB_LOG="$LOGDIR/$TAG.lb.log"

# setsid: each node leads its OWN process group, so `kill -- -PGID` takes down
# the `ros2 run` wrapper AND the real python node child together. Killing the
# bare wrapper PID leaves the node orphaned (PPID->init) still publishing on the
# shared DDS graph -> successive runs crosstalk -> garbage metrics. (Root cause
# of the 2026-06-18 "matched=0" / runaway-sent bug.)
setsid ros2 run exo_cmd loopback_node "$@" > "$LB_LOG" 2>&1 &
LB=$!
setsid ros2 run exo_cmd exo_cmd_node > "$CMD_LOG" 2>&1 &
CMD=$!
sleep "$SECS"
# Negative PID == "the whole process group led by this PID".
kill -TERM -- -"$CMD" -"$LB" 2>/dev/null || true
sleep 1
kill -9 -- -"$CMD" -"$LB" 2>/dev/null || true
sleep 1
# Hard assert no exo node survived this scenario before the next one starts.
LEAK=$(pgrep -f 'exo_cmd/lib/exo_cmd/(exo_cmd_node|loopback_node)' | tr '\n' ' ')
if [ -n "$LEAK" ]; then
  echo "!!! LEAK after '$TAG': surviving node PIDs: $LEAK" >&2
  kill -9 $LEAK 2>/dev/null || true
fi
echo "=== scenario '$TAG' done (lb=$LB cmd=$CMD, ${SECS}s) ==="
