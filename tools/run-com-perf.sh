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

SUMMARY_PERIOD_S_SET="${SUMMARY_PERIOD_S+x}"
LINK_HEALTH_PERIOD_S_SET="${LINK_HEALTH_PERIOD_S+x}"

PRINT_CONFIG_ONLY="${PRINT_CONFIG_ONLY:-0}"
DEV="${DEV:-/dev/ttyUSB0}"
BAUD="${BAUD:-921600}"
CMD_RATE_HZ="${CMD_RATE_HZ:-20}"
CMD_CATCHUP_MAX="${CMD_CATCHUP_MAX:-0}"
QOS_DEPTH="${QOS_DEPTH:-2}"
QOS_RELIABILITY="${QOS_RELIABILITY:-reliable}"
TRACKING_MODE="${TRACKING_MODE:-echo}"
STATUS_EVERY_N="${STATUS_EVERY_N:-1}"
SAMPLE_WINDOW="${SAMPLE_WINDOW:-1024}"
RTT_WARN_MS="${RTT_WARN_MS:-10.0}"
RTT_DEADLINE_MS="${RTT_DEADLINE_MS:-120.0}"
SWEEP_PERIOD_S="${SWEEP_PERIOD_S:-0.02}"
SUMMARY_PERIOD_S="${SUMMARY_PERIOD_S:-1.0}"
LINK_HEALTH_PERIOD_S="${LINK_HEALTH_PERIOD_S:-1.0}"
STARTUP_GRACE_S="${STARTUP_GRACE_S:-3.0}"
EXECUTOR_THREADS="${EXECUTOR_THREADS:-0}"
PC_LAUNCH_PREFIX="${PC_LAUNCH_PREFIX:-}"
LOG_MATCHED_EVENTS="${LOG_MATCHED_EVENTS:-false}"
LOG_SENT_COMMANDS="${LOG_SENT_COMMANDS:-false}"
RTT_WARN_LOG_PERIOD_S="${RTT_WARN_LOG_PERIOD_S:-1.0}"
CONTROL_LOOP_HZ="${CONTROL_LOOP_HZ:-1000}"
CONTROL_TIMER_IRQ_PRIORITY="${CONTROL_TIMER_IRQ_PRIORITY:-4}"
UART_READ_POLL_YIELDS="${UART_READ_POLL_YIELDS:-0}"
EXECUTOR_SPIN_TIMEOUT_US="${EXECUTOR_SPIN_TIMEOUT_US:-1000}"
RUN_SECONDS="${RUN_SECONDS:-18}"
WARMUP_SECONDS="${WARMUP_SECONDS:-5}"
HZ_SECONDS="${HZ_SECONDS:-10}"
SAMPLER_SPIN_TIMEOUT_S="${SAMPLER_SPIN_TIMEOUT_S:-0.005}"
BUILD_FIRMWARE="${BUILD_FIRMWARE:-1}"
FLASH_FIRMWARE="${FLASH_FIRMWARE:-1}"
RESET_TARGET="${RESET_TARGET:-$FLASH_FIRMWARE}"
KEEP_BRIDGE="${KEEP_BRIDGE:-0}"
MICROROS_AGENT_VERBOSITY="${MICROROS_AGENT_VERBOSITY:-1}"
WIRE_STATS="${WIRE_STATS:-auto}"
WIRE_STATS_SKIP_SECONDS="${WIRE_STATS_SKIP_SECONDS:-$STARTUP_GRACE_S}"
FLASH_TIMEOUT_SECONDS="${FLASH_TIMEOUT_SECONDS:-90}"
RESET_TIMEOUT_SECONDS="${RESET_TIMEOUT_SECONDS:-15}"
STLINK_PREFLIGHT="${STLINK_PREFLIGHT:-1}"
REQUIRE_CORE_METRICS="${REQUIRE_CORE_METRICS:-1}"
REQUIRE_HEALTH_PASS="${REQUIRE_HEALTH_PASS:-1}"
PERF_MIN_RATE_RATIO="${PERF_MIN_RATE_RATIO:-0.90}"
PERF_MAX_RATE_RATIO="${PERF_MAX_RATE_RATIO:-1.10}"
PERF_MAX_LOST="${PERF_MAX_LOST:-0}"
PERF_MAX_DUPLICATE="${PERF_MAX_DUPLICATE:-0}"
PERF_MAX_P99_GAP_S="${PERF_MAX_P99_GAP_S:-auto}"
PERF_MAX_MAX_GAP_S="${PERF_MAX_MAX_GAP_S:-auto}"
SERIAL_LOCK_WAIT_SECONDS="${SERIAL_LOCK_WAIT_SECONDS:-0}"
SERIAL_LOCK="${SERIAL_LOCK:-$LOGDIR/.com-perf-$(basename "$DEV").lock}"

case "$QOS_RELIABILITY" in
  reliable) EXO_QOS_BEST_EFFORT=OFF ;;
  best_effort) EXO_QOS_BEST_EFFORT=ON ;;
  *)
    echo "ERROR: QOS_RELIABILITY must be reliable or best_effort, got '$QOS_RELIABILITY'" >&2
    exit 1
    ;;
esac

if [ "$QOS_RELIABILITY" = "best_effort" ] &&
    [ "$TRACKING_MODE" = "sampled" ] &&
    [ "$STATUS_EVERY_N" -gt 1 ]; then
  if [ -z "$SUMMARY_PERIOD_S_SET" ]; then
    SUMMARY_PERIOD_S=5.0
  fi
  if [ -z "$LINK_HEALTH_PERIOD_S_SET" ]; then
    LINK_HEALTH_PERIOD_S=5.0
  fi
fi

mkdir -p "$LOGDIR"
CMD_LOG="$LOGDIR/$TAG.cmd.log"
BRIDGE_LOG="$LOGDIR/$TAG.bridge.log"
HZ_LOG="$LOGDIR/$TAG.hz.log"
SAMPLER_LOG="$LOGDIR/$TAG.sampler.log"
GRAPH_LOG="$LOGDIR/$TAG.graph.log"
WIRE_LOG="$LOGDIR/$TAG.wire.log"
OPENOCD_LOG="$LOGDIR/$TAG.openocd.log"

extract_metric() {
  local line="$1"
  local key="$2"
  printf '%s\n' "$line" | tr ' ' '\n' | awk -F= -v k="$key" '$1 == k {print $2}' | tail -1
}

qos_incompatibility_from_log() {
  local file="$1"
  if [ ! -f "$file" ]; then
    return 0
  fi
  grep -E 'incompatible QoS|requesting incompatible QoS|Last incompatible policy' "$file" |
    tail -1 || true
}

graph_snapshot() {
  {
    echo "--- $1 ---"
    ros2 node list | sort
    ros2 topic list | grep /com | sort || true
    for topic in /com/tp_cmd_heartbeat /com/tp_mcu_status /com/tp_link_health; do
      echo "--- topic info -v $topic ---"
      timeout 5 ros2 topic info -v "$topic" || true
    done
  } >>"$GRAPH_LOG" 2>&1
}

check_stlink_ready() {
  local out
  if ! command -v st-info >/dev/null; then
    echo "[com-perf] WARN: st-info not found; skipping ST-LINK preflight" >&2
    return 0
  fi
  if ! out="$(timeout "$FLASH_TIMEOUT_SECONDS" st-info --probe 2>&1)"; then
    echo "$out" >&2
    echo "ERROR: ST-LINK preflight failed; check USB/SWD before flashing" >&2
    return 1
  fi
  if printf '%s\n' "$out" |
      grep -Eq 'Found[[:space:]]+0 stlink programmers|dev-type:[[:space:]]+unknown|chipid:[[:space:]]+0x000'; then
    echo "$out" >&2
    echo "ERROR: ST-LINK/SWD preflight is invalid; check USBIP/ST-LINK/SWD/reset before flashing" >&2
    return 1
  fi
}

print_config() {
  echo "[com-perf] tag=$TAG"
  echo "[com-perf] firmware: qos_best_effort=$EXO_QOS_BEST_EFFORT baud=$BAUD control_loop_hz=$CONTROL_LOOP_HZ control_timer_irq_priority=$CONTROL_TIMER_IRQ_PRIORITY status_every_n=$STATUS_EVERY_N uart_read_poll_yields=$UART_READ_POLL_YIELDS executor_spin_timeout_us=$EXECUTOR_SPIN_TIMEOUT_US"
  echo "[com-perf] pc: cmd_rate_hz=$CMD_RATE_HZ cmd_catchup_max=$CMD_CATCHUP_MAX qos_depth=$QOS_DEPTH qos_reliability=$QOS_RELIABILITY tracking_mode=$TRACKING_MODE status_every_n=$STATUS_EVERY_N sample_window=$SAMPLE_WINDOW rtt_warn_ms=$RTT_WARN_MS rtt_deadline_ms=$RTT_DEADLINE_MS sweep_period_s=$SWEEP_PERIOD_S summary_period_s=$SUMMARY_PERIOD_S link_health_period_s=$LINK_HEALTH_PERIOD_S startup_grace_s=$STARTUP_GRACE_S executor_threads=$EXECUTOR_THREADS launch_prefix=${PC_LAUNCH_PREFIX:-none} log_matched_events=$LOG_MATCHED_EVENTS log_sent_commands=$LOG_SENT_COMMANDS rtt_warn_log_period_s=$RTT_WARN_LOG_PERIOD_S"
  echo "[com-perf] sampler: spin_timeout_s=$SAMPLER_SPIN_TIMEOUT_S"
  echo "[com-perf] wire_stats: mode=$WIRE_STATS skip_s=$WIRE_STATS_SKIP_SECONDS agent_verbosity=$MICROROS_AGENT_VERBOSITY"
  echo "[com-perf] flash: flash_firmware=$FLASH_FIRMWARE reset_target=$RESET_TARGET stlink_preflight=$STLINK_PREFLIGHT flash_timeout_s=$FLASH_TIMEOUT_SECONDS reset_timeout_s=$RESET_TIMEOUT_SECONDS"
  echo "[com-perf] serial_lock: lock=$SERIAL_LOCK wait_s=$SERIAL_LOCK_WAIT_SECONDS"
  echo "[com-perf] logs: $LOGDIR/$TAG.*.log"
}

if [ "$PRINT_CONFIG_ONLY" = "1" ]; then
  print_config
  echo "[com-perf] print_config_only=1"
  exit 0
fi

if [ ! -e "$DEV" ]; then
  echo "ERROR: serial device does not exist: $DEV" >&2
  exit 1
fi

if command -v flock >/dev/null; then
  exec 9>"$SERIAL_LOCK"
  if ! flock -w "$SERIAL_LOCK_WAIT_SECONDS" 9; then
    echo "ERROR: serial device is busy: $DEV (lock=$SERIAL_LOCK)" >&2
    echo "       Set SERIAL_LOCK_WAIT_SECONDS=<seconds> to wait instead of failing fast." >&2
    exit 1
  fi
else
  echo "[com-perf] WARN: flock not found; serial collision guard disabled" >&2
fi

print_config
if [ "$CMD_CATCHUP_MAX" -gt 0 ] &&
    { [ "$QOS_RELIABILITY" != "best_effort" ] ||
      [ "$TRACKING_MODE" != "sampled" ] ||
      [ "$STATUS_EVERY_N" -le 1 ]; }; then
  echo "[com-perf] WARN: cmd_catchup_max=$CMD_CATCHUP_MAX is intended for latest-target profiles (best_effort + sampled + status_every_n>1); reliable/status_every_1 full-echo can flood status return"
fi

flash_firmware() {
  local bin="$1"
  if timeout "$FLASH_TIMEOUT_SECONDS" \
      st-flash --connect-under-reset write "$bin" 0x08000000; then
    return 0
  fi

  echo "[com-perf] WARN: st-flash failed or timed out once; reset-halt and retry" >&2
  openocd -f interface/stlink.cfg -f target/stm32f1x.cfg \
    -c 'init; reset halt; shutdown' >"$OPENOCD_LOG" 2>&1 || true
  sleep 1
  timeout "$FLASH_TIMEOUT_SECONDS" \
    st-flash --connect-under-reset write "$bin" 0x08000000
}

if [ "$FLASH_FIRMWARE" = "1" ] && [ "$STLINK_PREFLIGHT" = "1" ]; then
  check_stlink_ready
fi

if [ "$BUILD_FIRMWARE" = "1" ]; then
  cmake -S "$ROOT/firmware/f103-microros" -B "$ROOT/firmware/f103-microros/build" \
    -DEXO_QOS_BEST_EFFORT="$EXO_QOS_BEST_EFFORT" \
    -DEXO_UART_BAUD="$BAUD" \
    -DEXO_CONTROL_LOOP_HZ="$CONTROL_LOOP_HZ" \
    -DEXO_CONTROL_TIMER_IRQ_PRIORITY="$CONTROL_TIMER_IRQ_PRIORITY" \
    -DEXO_STATUS_EVERY_N="$STATUS_EVERY_N" \
    -DEXO_UART_READ_POLL_YIELDS="$UART_READ_POLL_YIELDS" \
    -DEXO_EXECUTOR_SPIN_TIMEOUT_US="$EXECUTOR_SPIN_TIMEOUT_US"
  cmake --build "$ROOT/firmware/f103-microros/build"
fi

if [ "$FLASH_FIRMWARE" = "1" ]; then
  flash_firmware "$ROOT/firmware/f103-microros/build/f103-microros.bin"
fi

for pid in $(lsof -t "$DEV" 2>/dev/null || true); do
  kill "$pid" 2>/dev/null || true
done
sleep 1

RUN_BRIDGE_LOCK_HELD=1 MICROROS_AGENT_VERBOSITY="$MICROROS_AGENT_VERBOSITY" \
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
if [ "$RESET_TARGET" = "1" ]; then
  if [ "$STLINK_PREFLIGHT" = "1" ]; then
    check_stlink_ready
  fi
  timeout "$RESET_TIMEOUT_SECONDS" openocd \
    -f interface/stlink.cfg -f target/stm32f1x.cfg \
    -c 'init; reset run; shutdown' >"$OPENOCD_LOG" 2>&1 || {
      echo "[com-perf] WARN: OpenOCD reset failed or timed out; continuing" >&2
    }
  sleep 5
else
  echo "[com-perf] reset: skipped reset_target=$RESET_TARGET"
fi

set +u
source /opt/ros/jazzy/setup.bash
source "$ROOT/ros2_ws/install/setup.bash"
set -u

: >"$GRAPH_LOG"
graph_snapshot "after_bridge"

pc_launch_args=(
  cmd_rate_hz:="$CMD_RATE_HZ" \
  cmd_catchup_max:="$CMD_CATCHUP_MAX" \
  qos_depth:="$QOS_DEPTH" \
  qos_reliability:="$QOS_RELIABILITY" \
  tracking_mode:="$TRACKING_MODE" \
  status_every_n:="$STATUS_EVERY_N" \
  sample_window:="$SAMPLE_WINDOW" \
  rtt_warn_ms:="$RTT_WARN_MS" \
  rtt_deadline_ms:="$RTT_DEADLINE_MS" \
  sweep_period_s:="$SWEEP_PERIOD_S" \
  summary_period_s:="$SUMMARY_PERIOD_S" \
  link_health_period_s:="$LINK_HEALTH_PERIOD_S" \
  startup_grace_s:="$STARTUP_GRACE_S" \
  executor_threads:="$EXECUTOR_THREADS" \
  log_matched_events:="$LOG_MATCHED_EVENTS" \
  log_sent_commands:="$LOG_SENT_COMMANDS" \
  rtt_warn_log_period_s:="$RTT_WARN_LOG_PERIOD_S" \
  log_level:=info
)
if [ -n "$PC_LAUNCH_PREFIX" ]; then
  pc_launch_args+=(launch_prefix:="$PC_LAUNCH_PREFIX")
fi

setsid ros2 launch com_bringup pc_cmd.launch.py \
  "${pc_launch_args[@]}" >"$CMD_LOG" 2>&1 &
CMD_PID=$!

sleep "$WARMUP_SECONDS"
graph_snapshot "after_pc_warmup"
ros2 run exo_cmd status_sampler \
  --duration-s "$HZ_SECONDS" \
  --qos-depth "$QOS_DEPTH" \
  --qos-reliability "$QOS_RELIABILITY" \
  --spin-timeout-s "$SAMPLER_SPIN_TIMEOUT_S" >"$SAMPLER_LOG" 2>&1 &
SAMPLER_PID=$!
timeout -s INT "$HZ_SECONDS" ros2 topic hz /com/tp_mcu_status \
  >"$HZ_LOG" 2>&1 || true
wait "$SAMPLER_PID" || true

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
sampler_summary="$(grep 'status_sampler:' "$SAMPLER_LOG" | tail -1 || true)"
sampler_count="$(extract_metric "$sampler_summary" count)"
sampler_hz="$(extract_metric "$sampler_summary" rate_hz)"
sampler_max_gap_s="$(extract_metric "$sampler_summary" max_gap_s)"
sampler_p95_gap_s="$(extract_metric "$sampler_summary" p95_gap_s)"
sampler_p99_gap_s="$(extract_metric "$sampler_summary" p99_gap_s)"
sampler_zero_gap_count="$(extract_metric "$sampler_summary" zero_gap_count)"
sampler_seq_rate_hz="$(extract_metric "$sampler_summary" seq_rate_hz)"
sampler_seq_delta_avg="$(extract_metric "$sampler_summary" seq_delta_avg)"
sampler_seq_delta_min="$(extract_metric "$sampler_summary" seq_delta_min)"
sampler_seq_delta_max="$(extract_metric "$sampler_summary" seq_delta_max)"
sampler_target_rx_hz=""
if [ -n "$sampler_hz" ]; then
  sampler_target_rx_hz="$(awk -v r="$sampler_hz" -v n="$STATUS_EVERY_N" 'BEGIN { printf "%.2f", r * n }')"
fi

summary="$(grep 'link-health summary' "$CMD_LOG" | tail -1 || true)"
wire_sent="$(printf '%s\n' "$summary" | grep -o 'wire_sent=[0-9]*' | tail -1 | cut -d= -f2 || true)"
wire_rate_hz="$(printf '%s\n' "$summary" | grep -o 'wire_rate_hz=[0-9.]*' | tail -1 | cut -d= -f2 || true)"
target_rate_hz="$(printf '%s\n' "$summary" | grep -o 'target_rate_hz=[0-9.]*' | tail -1 | cut -d= -f2 || true)"
wire_window_hz="$(printf '%s\n' "$summary" | grep -o 'wire_window_hz=[0-9.]*' | tail -1 | cut -d= -f2 || true)"
sent_window_hz="$(printf '%s\n' "$summary" | grep -o 'sent_window_hz=[0-9.]*' | tail -1 | cut -d= -f2 || true)"
matched_window_hz="$(printf '%s\n' "$summary" | grep -o 'matched_window_hz=[0-9.]*' | tail -1 | cut -d= -f2 || true)"
target_window_hz="$(printf '%s\n' "$summary" | grep -o 'target_window_hz=[0-9.]*' | tail -1 | cut -d= -f2 || true)"
wire_gap_avg_ms="$(extract_metric "$summary" wire_gap_avg_ms)"
wire_gap_p95_ms="$(extract_metric "$summary" wire_gap_p95_ms)"
wire_gap_p99_ms="$(extract_metric "$summary" wire_gap_p99_ms)"
wire_gap_max_ms="$(extract_metric "$summary" wire_gap_max_ms)"
cmd_catchup_events="$(extract_metric "$summary" cmd_catchup_events)"
cmd_catchup_extra="$(extract_metric "$summary" cmd_catchup_extra)"
lost="$(extract_metric "$summary" lost)"
duplicate="$(extract_metric "$summary" duplicate)"
inflight="$(extract_metric "$summary" inflight)"
qos_incompatibility="$(qos_incompatibility_from_log "$CMD_LOG")"

wire_metrics=""
case "$WIRE_STATS" in
  1|true|yes)
    if "$ROOT/tools/agent-wire-stats.sh" "$BRIDGE_LOG" "$WIRE_STATS_SKIP_SECONDS" >"$WIRE_LOG" 2>&1; then
      wire_metrics="$(grep '^METRICS ' "$WIRE_LOG" | tail -1 || true)"
    else
      wire_metrics="unavailable"
    fi
    ;;
  auto)
    if [ "$MICROROS_AGENT_VERBOSITY" -ge 6 ] 2>/dev/null; then
      if "$ROOT/tools/agent-wire-stats.sh" "$BRIDGE_LOG" "$WIRE_STATS_SKIP_SECONDS" >"$WIRE_LOG" 2>&1; then
        wire_metrics="$(grep '^METRICS ' "$WIRE_LOG" | tail -1 || true)"
      else
        wire_metrics="unavailable"
      fi
    fi
    ;;
  0|false|no)
    ;;
  *)
    echo "[com-perf] WARN: unknown WIRE_STATS=$WIRE_STATS; expected auto/1/0" >&2
    ;;
esac

echo "[com-perf] graph:"
cat "$GRAPH_LOG"
echo "[com-perf] status_hz=${status_hz:-NA}"
echo "[com-perf] estimated_mcu_target_rx_hz=${estimated_rx_hz:-NA}"
echo "[com-perf] hz_stats=${hz_stats:-NA}"
echo "[com-perf] sampler_count=${sampler_count:-NA}"
echo "[com-perf] sampler_hz=${sampler_hz:-NA}"
echo "[com-perf] sampler_target_rx_hz=${sampler_target_rx_hz:-NA}"
echo "[com-perf] sampler_max_gap_s=${sampler_max_gap_s:-NA}"
echo "[com-perf] sampler_p95_gap_s=${sampler_p95_gap_s:-NA}"
echo "[com-perf] sampler_p99_gap_s=${sampler_p99_gap_s:-NA}"
echo "[com-perf] sampler_zero_gap_count=${sampler_zero_gap_count:-NA}"
echo "[com-perf] sampler_seq_rate_hz=${sampler_seq_rate_hz:-NA}"
echo "[com-perf] sampler_seq_delta_avg=${sampler_seq_delta_avg:-NA}"
echo "[com-perf] sampler_seq_delta_min=${sampler_seq_delta_min:-NA}"
echo "[com-perf] sampler_seq_delta_max=${sampler_seq_delta_max:-NA}"
echo "[com-perf] pc_wire_sent=${wire_sent:-NA}"
echo "[com-perf] pc_wire_rate_hz=${wire_rate_hz:-NA}"
echo "[com-perf] pc_target_rate_hz=${target_rate_hz:-NA}"
echo "[com-perf] pc_wire_window_hz=${wire_window_hz:-NA}"
echo "[com-perf] pc_sent_window_hz=${sent_window_hz:-NA}"
echo "[com-perf] pc_matched_window_hz=${matched_window_hz:-NA}"
echo "[com-perf] pc_target_window_hz=${target_window_hz:-NA}"
echo "[com-perf] pc_wire_gap_avg_ms=${wire_gap_avg_ms:-NA}"
echo "[com-perf] pc_wire_gap_p95_ms=${wire_gap_p95_ms:-NA}"
echo "[com-perf] pc_wire_gap_p99_ms=${wire_gap_p99_ms:-NA}"
echo "[com-perf] pc_wire_gap_max_ms=${wire_gap_max_ms:-NA}"
echo "[com-perf] pc_cmd_catchup_events=${cmd_catchup_events:-NA}"
echo "[com-perf] pc_cmd_catchup_extra=${cmd_catchup_extra:-NA}"
echo "[com-perf] lost=${lost:-NA}"
echo "[com-perf] duplicate=${duplicate:-NA}"
echo "[com-perf] inflight=${inflight:-NA}"
echo "[com-perf] qos_incompatibility=${qos_incompatibility:-none}"
echo "[com-perf] wire_metrics=${wire_metrics:-NA}"
echo "[com-perf] last_summary=${summary:-NA}"
echo "[com-perf] sampler_summary=${sampler_summary:-NA}"
echo "[com-perf] hz_tail:"
tail -n 12 "$HZ_LOG"

validation_failed=0
health_p99_gap_limit="$PERF_MAX_P99_GAP_S"
health_max_gap_limit="$PERF_MAX_MAX_GAP_S"
if [ "$health_p99_gap_limit" = "auto" ]; then
  health_p99_gap_limit="0.10"
  if [ "$CMD_RATE_HZ" -gt 20 ] 2>/dev/null ||
      [ "$STATUS_EVERY_N" -gt 1 ] 2>/dev/null; then
    health_p99_gap_limit="0.50"
  fi
fi
if [ "$health_max_gap_limit" = "auto" ]; then
  health_max_gap_limit="0.25"
  if [ "$CMD_RATE_HZ" -gt 20 ] 2>/dev/null ||
      [ "$STATUS_EVERY_N" -gt 1 ] 2>/dev/null; then
    health_max_gap_limit="1.00"
  fi
fi
if [ "$REQUIRE_CORE_METRICS" = "1" ]; then
  if [ -z "$summary" ]; then
    echo "[com-perf] ERROR: missing link-health summary; PC command node may not have started" >&2
    validation_failed=1
  fi
  if [ -z "$sampler_count" ] || [ "$sampler_count" -le 0 ] 2>/dev/null; then
    echo "[com-perf] ERROR: sampler received no status messages" >&2
    validation_failed=1
  fi
fi
if [ "$REQUIRE_HEALTH_PASS" = "1" ]; then
  if [ -n "$qos_incompatibility" ]; then
    echo "[com-perf] ERROR: QoS incompatibility detected: $qos_incompatibility" >&2
    validation_failed=1
  fi
  health_rate="$sampler_hz"
  health_rate_label="sampler_hz"
  if [ "$TRACKING_MODE" = "sampled" ] ||
      [ "$STATUS_EVERY_N" -gt 1 ] 2>/dev/null; then
    health_rate="$sampler_target_rx_hz"
    health_rate_label="sampler_target_rx_hz"
  fi
  if [ -n "$health_rate" ]; then
    if ! awk \
        -v actual="$health_rate" \
        -v expected="$CMD_RATE_HZ" \
        -v min_ratio="$PERF_MIN_RATE_RATIO" \
        -v max_ratio="$PERF_MAX_RATE_RATIO" \
        'BEGIN { ok = (actual + 0 >= expected * min_ratio && actual + 0 <= expected * max_ratio); exit !ok }'; then
      echo "[com-perf] ERROR: $health_rate_label=$health_rate outside expected band for cmd_rate_hz=$CMD_RATE_HZ" >&2
      validation_failed=1
    fi
  fi
  if [ "$STATUS_EVERY_N" -eq 1 ] 2>/dev/null &&
      [ -n "$sampler_seq_delta_min" ] && [ -n "$sampler_seq_delta_max" ] &&
      { [ "$sampler_seq_delta_min" -ne 1 ] ||
        [ "$sampler_seq_delta_max" -ne 1 ]; } 2>/dev/null; then
    echo "[com-perf] ERROR: status seq delta not 1/1: min=$sampler_seq_delta_min max=$sampler_seq_delta_max" >&2
    validation_failed=1
  fi
  if [ -n "$sampler_p99_gap_s" ]; then
    if ! awk \
        -v actual="$sampler_p99_gap_s" \
        -v limit="$health_p99_gap_limit" \
        'BEGIN { exit !(actual + 0 <= limit + 0) }'; then
      echo "[com-perf] ERROR: sampler_p99_gap_s=$sampler_p99_gap_s exceeds $health_p99_gap_limit" >&2
      validation_failed=1
    fi
  fi
  if [ -n "$sampler_max_gap_s" ]; then
    if ! awk \
        -v actual="$sampler_max_gap_s" \
        -v limit="$health_max_gap_limit" \
        'BEGIN { exit !(actual + 0 <= limit + 0) }'; then
      echo "[com-perf] ERROR: sampler_max_gap_s=$sampler_max_gap_s exceeds $health_max_gap_limit" >&2
      validation_failed=1
    fi
  fi
  if [ -n "$lost" ] && [ "$lost" -gt "$PERF_MAX_LOST" ] 2>/dev/null; then
    echo "[com-perf] ERROR: lost=$lost exceeds $PERF_MAX_LOST" >&2
    validation_failed=1
  fi
  if [ -n "$duplicate" ] &&
      [ "$duplicate" -gt "$PERF_MAX_DUPLICATE" ] 2>/dev/null; then
    echo "[com-perf] ERROR: duplicate=$duplicate exceeds $PERF_MAX_DUPLICATE" >&2
    validation_failed=1
  fi
fi
if [ "$validation_failed" -ne 0 ]; then
  exit 1
fi
