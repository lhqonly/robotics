#!/usr/bin/env bash
# Build/flash one STM32 micro-ROS communication profile and collect ROS-side
# status frequency + LinkHealth summary.
#
# Usage:
#   tools/run-com-perf.sh [tag]
#
# Common overrides:
#   CMD_RATE_HZ=200 QOS_RELIABILITY=best_effort STATUS_EVERY_N=40 \
#   TRACKING_MODE=sampled tools/run-com-perf.sh n40_sampled
#
# Defaults are the stable baseline: reliable, 921600 baud, 1kHz local loop,
# status_every_1, PC command node at 20Hz.
set -eo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:-com_perf}"
LOGDIR="${LOGDIR:-$ROOT/log/com-perf}"

DEV="${DEV:-/dev/ttyUSB0}"
BAUD="${BAUD:-921600}"
CMD_RATE_HZ="${CMD_RATE_HZ:-20}"
QOS_DEPTH="${QOS_DEPTH:-1}"
QOS_RELIABILITY="${QOS_RELIABILITY:-reliable}"
TRACKING_MODE="${TRACKING_MODE:-echo}"
STATUS_EVERY_N="${STATUS_EVERY_N:-1}"
SAMPLE_WINDOW="${SAMPLE_WINDOW:-4096}"
RTT_WARN_MS="${RTT_WARN_MS:-10.0}"
RTT_DEADLINE_MS="${RTT_DEADLINE_MS:-100.0}"
SWEEP_PERIOD_S="${SWEEP_PERIOD_S:-0.02}"
EXECUTOR_THREADS="${EXECUTOR_THREADS:-0}"
CONTROL_LOOP_HZ="${CONTROL_LOOP_HZ:-1000}"
RUN_SECONDS="${RUN_SECONDS:-18}"
WARMUP_SECONDS="${WARMUP_SECONDS:-5}"
HZ_SECONDS="${HZ_SECONDS:-10}"
BUILD_FIRMWARE="${BUILD_FIRMWARE:-1}"
FLASH_FIRMWARE="${FLASH_FIRMWARE:-1}"
KEEP_BRIDGE="${KEEP_BRIDGE:-0}"
MICROROS_AGENT_VERBOSITY="${MICROROS_AGENT_VERBOSITY:-1}"

case "$QOS_RELIABILITY" in
  reliable) EXO_QOS_BEST_EFFORT=OFF ;;
  best_effort) EXO_QOS_BEST_EFFORT=ON ;;
  *)
    echo "ERROR: QOS_RELIABILITY must be reliable or best_effort, got '$QOS_RELIABILITY'" >&2
    exit 1
    ;;
esac

mkdir -p "$LOGDIR"
CMD_LOG="$LOGDIR/$TAG.cmd.log"
BRIDGE_LOG="$LOGDIR/$TAG.bridge.log"
HZ_LOG="$LOGDIR/$TAG.hz.log"
GRAPH_LOG="$LOGDIR/$TAG.graph.log"
OPENOCD_LOG="$LOGDIR/$TAG.openocd.log"

graph_snapshot() {
  {
    echo "--- $1 ---"
    ros2 node list | sort
    ros2 topic list | grep /com | sort || true
  } >>"$GRAPH_LOG" 2>&1
}

if [ ! -e "$DEV" ]; then
  echo "ERROR: serial device does not exist: $DEV" >&2
  exit 1
fi

echo "[com-perf] tag=$TAG"
echo "[com-perf] firmware: qos_best_effort=$EXO_QOS_BEST_EFFORT baud=$BAUD control_loop_hz=$CONTROL_LOOP_HZ status_every_n=$STATUS_EVERY_N"
echo "[com-perf] pc: cmd_rate_hz=$CMD_RATE_HZ qos_depth=$QOS_DEPTH qos_reliability=$QOS_RELIABILITY tracking_mode=$TRACKING_MODE rtt_warn_ms=$RTT_WARN_MS rtt_deadline_ms=$RTT_DEADLINE_MS executor_threads=$EXECUTOR_THREADS"
echo "[com-perf] logs: $LOGDIR/$TAG.*.log"

flash_firmware() {
  local bin="$1"
  if st-flash --connect-under-reset write "$bin" 0x08000000; then
    return 0
  fi

  echo "[com-perf] WARN: st-flash failed once; reset-halt and retry" >&2
  openocd -f interface/stlink.cfg -f target/stm32f1x.cfg \
    -c 'init; reset halt; shutdown' >"$OPENOCD_LOG" 2>&1 || true
  sleep 1
  st-flash --connect-under-reset write "$bin" 0x08000000
}

if [ "$BUILD_FIRMWARE" = "1" ]; then
  cmake -S "$ROOT/firmware/f103-microros" -B "$ROOT/firmware/f103-microros/build" \
    -DEXO_QOS_BEST_EFFORT="$EXO_QOS_BEST_EFFORT" \
    -DEXO_UART_BAUD="$BAUD" \
    -DEXO_CONTROL_LOOP_HZ="$CONTROL_LOOP_HZ" \
    -DEXO_STATUS_EVERY_N="$STATUS_EVERY_N"
  cmake --build "$ROOT/firmware/f103-microros/build"
fi

if [ "$FLASH_FIRMWARE" = "1" ]; then
  flash_firmware "$ROOT/firmware/f103-microros/build/f103-microros.bin"
fi

for pid in $(lsof -t "$DEV" 2>/dev/null || true); do
  kill "$pid" 2>/dev/null || true
done
sleep 1

MICROROS_AGENT_VERBOSITY="$MICROROS_AGENT_VERBOSITY" \
  setsid "$ROOT/tools/run-bridge.sh" "$DEV" "$BAUD" >"$BRIDGE_LOG" 2>&1 &
BRIDGE_PID=$!

cleanup() {
  if [ "$KEEP_BRIDGE" != "1" ]; then
    kill -TERM -- "-$BRIDGE_PID" 2>/dev/null || true
    sleep 1
    kill -9 -- "-$BRIDGE_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

sleep 4
openocd -f interface/stlink.cfg -f target/stm32f1x.cfg \
  -c 'init; reset run; shutdown' >"$OPENOCD_LOG" 2>&1 || true
sleep 5

set +u
source /opt/ros/jazzy/setup.bash
source "$ROOT/ros2_ws/install/setup.bash"
set -u

: >"$GRAPH_LOG"
graph_snapshot "after_bridge"

setsid ros2 launch com_bringup pc_cmd.launch.py \
  cmd_rate_hz:="$CMD_RATE_HZ" \
  qos_depth:="$QOS_DEPTH" \
  qos_reliability:="$QOS_RELIABILITY" \
  tracking_mode:="$TRACKING_MODE" \
  status_every_n:="$STATUS_EVERY_N" \
  sample_window:="$SAMPLE_WINDOW" \
  rtt_warn_ms:="$RTT_WARN_MS" \
  rtt_deadline_ms:="$RTT_DEADLINE_MS" \
  sweep_period_s:="$SWEEP_PERIOD_S" \
  executor_threads:="$EXECUTOR_THREADS" \
  log_level:=info >"$CMD_LOG" 2>&1 &
CMD_PID=$!

sleep "$WARMUP_SECONDS"
graph_snapshot "after_pc_warmup"
timeout "$HZ_SECONDS" ros2 topic hz /com/tp_mcu_status >"$HZ_LOG" 2>&1 || true

elapsed=$((WARMUP_SECONDS + HZ_SECONDS))
if [ "$RUN_SECONDS" -gt "$elapsed" ]; then
  sleep $((RUN_SECONDS - elapsed))
fi

kill -TERM -- "-$CMD_PID" 2>/dev/null || true
sleep 1
kill -9 -- "-$CMD_PID" 2>/dev/null || true

status_hz="$(awk '/average rate:/ {rate=$3} END {print rate}' "$HZ_LOG")"
hz_stats="$(awk '
  /^\s*min:/ {
    min_s = $2
    max_s = $4
    std_s = $7
    window = $9
    sub(/s$/, "", min_s)
    sub(/s$/, "", max_s)
    sub(/s$/, "", std_s)
    last_min = min_s
    last_max = max_s
    last_std = std_s
    last_window = window
    if (max_gap == "" || max_s + 0 > max_gap + 0) {
      max_gap = max_s
    }
  }
  END {
    if (last_window != "") {
      printf "last_min_s=%s last_max_s=%s last_std_s=%s last_window=%s max_gap_s=%s",
        last_min, last_max, last_std, last_window, max_gap
    }
  }
' "$HZ_LOG")"
estimated_rx_hz=""
if [ -n "$status_hz" ]; then
  estimated_rx_hz="$(awk -v r="$status_hz" -v n="$STATUS_EVERY_N" 'BEGIN { printf "%.2f", r * n }')"
fi

summary="$(grep 'link-health summary' "$CMD_LOG" | tail -1 || true)"
wire_sent="$(printf '%s\n' "$summary" | grep -o 'wire_sent=[0-9]*' | tail -1 | cut -d= -f2 || true)"
wire_rate_hz="$(printf '%s\n' "$summary" | grep -o 'wire_rate_hz=[0-9.]*' | tail -1 | cut -d= -f2 || true)"
wire_window_hz="$(printf '%s\n' "$summary" | grep -o 'wire_window_hz=[0-9.]*' | tail -1 | cut -d= -f2 || true)"

echo "[com-perf] graph:"
cat "$GRAPH_LOG"
echo "[com-perf] status_hz=${status_hz:-NA}"
echo "[com-perf] estimated_mcu_target_rx_hz=${estimated_rx_hz:-NA}"
echo "[com-perf] hz_stats=${hz_stats:-NA}"
echo "[com-perf] pc_wire_sent=${wire_sent:-NA}"
echo "[com-perf] pc_wire_rate_hz=${wire_rate_hz:-NA}"
echo "[com-perf] pc_wire_window_hz=${wire_window_hz:-NA}"
echo "[com-perf] last_summary=${summary:-NA}"
echo "[com-perf] hz_tail:"
tail -n 12 "$HZ_LOG"
