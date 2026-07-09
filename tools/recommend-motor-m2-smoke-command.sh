#!/usr/bin/env bash
# Emit the first hardware smoke sequence for M2 motor micro-ROS entities.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORMAT="${FORMAT:-markdown}"
M2_MOTOR_BAUD="${M2_MOTOR_BAUD:-2000000}"
M2_MOTOR_SERIAL="${M2_MOTOR_SERIAL:-/dev/ttyUSB0}"
M2_MOTOR_BUILD_DIR="${M2_MOTOR_BUILD_DIR:-firmware/f103-microros/build-motor}"
M2_MOTOR_CONTROL_LOOP_HZ="${M2_MOTOR_CONTROL_LOOP_HZ:-10000}"
M2_MOTOR_STATUS_EVERY_N="${M2_MOTOR_STATUS_EVERY_N:-40}"
M2_MOTOR_STATE_PERIOD_MS="${M2_MOTOR_STATE_PERIOD_MS:-20}"
M2_MOTOR_HEALTH_PERIOD_MS="${M2_MOTOR_HEALTH_PERIOD_MS:-200}"
M2_MOTOR_REQUIRE_BUDGET_BAUDS="${M2_MOTOR_REQUIRE_BUDGET_BAUDS:-$M2_MOTOR_BAUD}"
M2_MOTOR_QOS_BEST_EFFORT="${M2_MOTOR_QOS_BEST_EFFORT:-ON}"
M2_MOTOR_ENABLED_SOAK_HZ="${M2_MOTOR_ENABLED_SOAK_HZ:-200}"
M2_MOTOR_ENABLED_SOAK_DURATION_S="${M2_MOTOR_ENABLED_SOAK_DURATION_S:-2}"
M2_MOTOR_ENABLED_SOAK_START_SEQ="${M2_MOTOR_ENABLED_SOAK_START_SEQ:-1000}"
M2_MOTOR_TAG="${M2_MOTOR_TAG:-motor_m2_smoke_$(date +%Y%m%d_%H%M)}"
M2_MOTOR_EVIDENCE_DIR="${M2_MOTOR_EVIDENCE_DIR:-log/motor-m2-smoke/$M2_MOTOR_TAG}"

case "$FORMAT" in
  markdown|commands|checklist) ;;
  *)
    echo "ERROR: FORMAT must be markdown, commands, or checklist, got '$FORMAT'" >&2
    exit 1
    ;;
esac

shell_quote() {
  local value="$1"
  printf "'%s'" "$(printf '%s' "$value" | sed "s/'/'\\\\''/g")"
}

hz_from_period_ms() {
  local period_ms="$1"
  awk -v ms="$period_ms" 'BEGIN {
    if (ms <= 0) {
      exit 1
    }
    printf "%.6f", 1000.0 / ms
  }'
}

validate_periods() {
  if ! [[ "$M2_MOTOR_STATE_PERIOD_MS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: M2_MOTOR_STATE_PERIOD_MS must be an integer in [10, 1000]" >&2
    exit 1
  fi
  if ! [[ "$M2_MOTOR_HEALTH_PERIOD_MS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: M2_MOTOR_HEALTH_PERIOD_MS must be an integer in [100, 5000]" >&2
    exit 1
  fi
  if (( M2_MOTOR_STATE_PERIOD_MS < 10 || M2_MOTOR_STATE_PERIOD_MS > 1000 )); then
    echo "ERROR: M2_MOTOR_STATE_PERIOD_MS must be an integer in [10, 1000]" >&2
    exit 1
  fi
  if (( M2_MOTOR_HEALTH_PERIOD_MS < 100 || M2_MOTOR_HEALTH_PERIOD_MS > 5000 )); then
    echo "ERROR: M2_MOTOR_HEALTH_PERIOD_MS must be an integer in [100, 5000]" >&2
    exit 1
  fi
  if (( M2_MOTOR_HEALTH_PERIOD_MS < M2_MOTOR_STATE_PERIOD_MS )); then
    echo "ERROR: M2_MOTOR_HEALTH_PERIOD_MS must be >= M2_MOTOR_STATE_PERIOD_MS" >&2
    exit 1
  fi
}

validate_positive_integer_list() {
  local label="$1"
  local raw="$2"
  local item
  for item in $raw; do
    if ! [[ "$item" =~ ^[0-9]+$ ]] || (( item <= 0 )); then
      echo "ERROR: $label must contain positive integer baud values" >&2
      exit 1
    fi
  done
}

rate_min_from_hz() {
  local hz="$1"
  awk -v hz="$hz" 'BEGIN { printf "%.6f", hz * 0.90 }'
}

rate_max_from_hz() {
  local hz="$1"
  awk -v hz="$hz" 'BEGIN { printf "%.6f", hz * 1.10 }'
}

rate_timeout_from_period_ms() {
  local period_ms="$1"
  awk -v ms="$period_ms" 'BEGIN {
    timeout = int((ms * 6.0 / 1000.0) + 10.999999)
    if (timeout < 10) {
      timeout = 10
    }
    printf "%d", timeout
  }'
}

elf="$M2_MOTOR_BUILD_DIR/f103-microros.elf"
bin="$M2_MOTOR_BUILD_DIR/f103-microros.bin"
validate_positive_integer_list "M2_MOTOR_BAUD" "$M2_MOTOR_BAUD"
validate_positive_integer_list "M2_MOTOR_REQUIRE_BUDGET_BAUDS" "$M2_MOTOR_REQUIRE_BUDGET_BAUDS"
validate_periods
M2_MOTOR_STATE_HZ="$(hz_from_period_ms "$M2_MOTOR_STATE_PERIOD_MS")"
M2_MOTOR_HEALTH_HZ="$(hz_from_period_ms "$M2_MOTOR_HEALTH_PERIOD_MS")"
M2_MOTOR_STATE_MIN_HZ="$(rate_min_from_hz "$M2_MOTOR_STATE_HZ")"
M2_MOTOR_STATE_MAX_HZ="$(rate_max_from_hz "$M2_MOTOR_STATE_HZ")"
M2_MOTOR_HEALTH_MIN_HZ="$(rate_min_from_hz "$M2_MOTOR_HEALTH_HZ")"
M2_MOTOR_HEALTH_MAX_HZ="$(rate_max_from_hz "$M2_MOTOR_HEALTH_HZ")"
M2_MOTOR_STATE_RATE_TIMEOUT_S="$(rate_timeout_from_period_ms "$M2_MOTOR_STATE_PERIOD_MS")"
M2_MOTOR_HEALTH_RATE_TIMEOUT_S="$(rate_timeout_from_period_ms "$M2_MOTOR_HEALTH_PERIOD_MS")"
M2_MOTOR_ENABLED_SOAK_MID_SLEEP_S="$(
  awk -v seconds="$M2_MOTOR_ENABLED_SOAK_DURATION_S" 'BEGIN {
    printf "%.3f", seconds / 2.0
  }')"
M2_MOTOR_ENABLED_SOAK_TIMEOUT_S="$(
  awk -v seconds="$M2_MOTOR_ENABLED_SOAK_DURATION_S" 'BEGIN {
    printf "%d", int(seconds + 10.999999)
  }')"
M2_MOTOR_ENABLED_SOAK_MIN_HZ="$(rate_min_from_hz "$M2_MOTOR_ENABLED_SOAK_HZ")"
M2_MOTOR_ENABLED_SOAK_MAX_HZ="$(rate_max_from_hz "$M2_MOTOR_ENABLED_SOAK_HZ")"

print_commands() {
  cat <<EOF
STRICT=1 tools/diagnose-swd.sh
tools/com-wire-budget.py --profile motor-m2 --cmd-hz 200 --motor-state-hz $M2_MOTOR_STATE_HZ --motor-health-hz $M2_MOTOR_HEALTH_HZ --baud "$M2_MOTOR_REQUIRE_BUDGET_BAUDS" --max-baud-util-pct 30 --fail-on-over-budget --show-wire-time
tools/com-wire-budget.py --profile motor-m2 --cmd-hz 200 --motor-state-hz $M2_MOTOR_STATE_HZ --motor-health-hz $M2_MOTOR_HEALTH_HZ --baud '921600 2000000' --max-baud-util-pct 30 --show-wire-time
cmake -S firmware/f103-microros -B $(shell_quote "$M2_MOTOR_BUILD_DIR") \\
  -DCMAKE_TOOLCHAIN_FILE="\$(pwd)/firmware/f103-microros/toolchain-arm-m3.cmake" \\
  -DCMAKE_BUILD_TYPE=MinSizeRel \\
  -DEXO_MOTOR_ROS_ENTITIES=ON \\
  -DEXO_QOS_BEST_EFFORT=$M2_MOTOR_QOS_BEST_EFFORT \\
  -DEXO_UART_BAUD=$M2_MOTOR_BAUD \\
  -DEXO_CONTROL_LOOP_HZ=$M2_MOTOR_CONTROL_LOOP_HZ \\
  -DEXO_STATUS_EVERY_N=$M2_MOTOR_STATUS_EVERY_N \\
  -DEXO_MOTOR_STATE_PERIOD_MS=$M2_MOTOR_STATE_PERIOD_MS \\
  -DEXO_MOTOR_HEALTH_PERIOD_MS=$M2_MOTOR_HEALTH_PERIOD_MS
cmake --build $(shell_quote "$M2_MOTOR_BUILD_DIR")
tools/firmware-size-report.sh $(shell_quote "$elf")
st-flash --connect-under-reset write $(shell_quote "$bin") 0x08000000
evidence_dir=$(shell_quote "$M2_MOTOR_EVIDENCE_DIR")
mkdir -p "\$evidence_dir"
MICROROS_AGENT_VERBOSITY=6 tools/run-bridge.sh $(shell_quote "$M2_MOTOR_SERIAL") $(shell_quote "$M2_MOTOR_BAUD") 2>&1 | tee "\$evidence_dir/agent.log"

source /opt/ros/jazzy/setup.bash
source ros2_ws/install/setup.bash
cat >"\$evidence_dir/evidence.env" <<'EVIDENCE_ENV'
sample_only=false
template_generated=false
swd_status=ok
firmware_build=ok
firmware_flash=ok
agent_connected=ok
reject_baseline_target_enabled=false
clamp_target_ttl_us=100000
EVIDENCE_ENV
ros2 topic list | tee "\$evidence_dir/topics.txt" | grep -E '^/(com|motor)/'
ros2 topic info -v /motor/tp_joint_target | tee "\$evidence_dir/info.motor_target.txt"
ros2 topic info -v /motor/tp_joint_state | tee "\$evidence_dir/info.motor_state.txt"
ros2 topic info -v /motor/tp_motor_health | tee "\$evidence_dir/info.motor_health.txt"
ros2 topic info -v /com/tp_mcu_status | tee "\$evidence_dir/info.com_status.txt"
ros2 topic echo --once /motor/tp_joint_state | tee "\$evidence_dir/state.before_seq42.yaml"
ros2 topic pub --once /motor/tp_joint_target exo_motor_msgs/msg/JointTarget "{header: {frame_id: ''}, seq: 42, joint_id: 0, control_mode: 0, position_rad: 0.0, velocity_rad_s: 0.0, torque_nm: 0.0, kp_nm_per_rad: 0.0, kd_nm_s_per_rad: 0.0, max_torque_nm: 0.2, max_velocity_rad_s: 0.5, max_position_rad: 0.5, min_position_rad: -0.5, ttl_us: 100000, flags: 0}"
ros2 topic echo --once /motor/tp_joint_state | tee "\$evidence_dir/state.after_seq42.yaml"
ros2 topic echo --once /motor/tp_motor_health | tee "\$evidence_dir/health.before_reject.yaml"
timeout $M2_MOTOR_STATE_RATE_TIMEOUT_S ros2 topic hz /motor/tp_joint_state | tee "\$evidence_dir/rate.motor_state.txt"
timeout $M2_MOTOR_HEALTH_RATE_TIMEOUT_S ros2 topic hz /motor/tp_motor_health | tee "\$evidence_dir/rate.motor_health.txt"
timeout 10 ros2 topic hz /com/tp_mcu_status | tee "\$evidence_dir/rate.com_status.txt"
# Record last_target_seq plus targets_received/targets_applied before the negative frame_id test.
ros2 topic pub --once /motor/tp_joint_target exo_motor_msgs/msg/JointTarget "{header: {frame_id: reject}, seq: 43, joint_id: 0, control_mode: 0, position_rad: 0.0, velocity_rad_s: 0.0, torque_nm: 0.0, kp_nm_per_rad: 0.0, kd_nm_s_per_rad: 0.0, max_torque_nm: 0.2, max_velocity_rad_s: 0.5, max_position_rad: 0.5, min_position_rad: -0.5, ttl_us: 100000, flags: 0}"
# Negative-test pass condition: last_target_seq remains 42 and targets_received/targets_applied do not increase because of seq=43.
ros2 topic echo --once /motor/tp_joint_state | tee "\$evidence_dir/state.after_reject_seq43.yaml"
ros2 topic echo --once /motor/tp_motor_health | tee "\$evidence_dir/health.after_reject_seq43.yaml"
# Follow with a legal target so the negative test also proves the executor is still alive.
ros2 topic pub --once /motor/tp_joint_target exo_motor_msgs/msg/JointTarget "{header: {frame_id: ''}, seq: 44, joint_id: 0, control_mode: 0, position_rad: 0.0, velocity_rad_s: 0.0, torque_nm: 0.0, kp_nm_per_rad: 0.0, kd_nm_s_per_rad: 0.0, max_torque_nm: 0.2, max_velocity_rad_s: 0.5, max_position_rad: 0.5, min_position_rad: -0.5, ttl_us: 100000, flags: 0}"
ros2 topic echo --once /motor/tp_joint_state | tee "\$evidence_dir/state.after_seq44.yaml"
# Clamp/fault path: POSITION target exceeds the allowed max position and should set fault bit 4.
ros2 topic pub --once /motor/tp_joint_target exo_motor_msgs/msg/JointTarget "{header: {frame_id: ''}, seq: 45, joint_id: 0, control_mode: 4, position_rad: 9.0, velocity_rad_s: 0.0, torque_nm: 0.0, kp_nm_per_rad: 0.0, kd_nm_s_per_rad: 0.0, max_torque_nm: 0.2, max_velocity_rad_s: 0.5, max_position_rad: 0.5, min_position_rad: -0.5, ttl_us: 100000, flags: 0}"
ros2 topic echo --once /motor/tp_joint_state | tee "\$evidence_dir/state.after_clamp_seq45.yaml"
ros2 topic echo --once /motor/tp_motor_health | tee "\$evidence_dir/health.before_ttl.yaml"
sleep 0.2
ros2 topic echo --once /motor/tp_joint_state | tee "\$evidence_dir/state.after_ttl.yaml"
ros2 topic echo --once /motor/tp_motor_health | tee "\$evidence_dir/health.after_ttl.yaml"
ros2 topic echo --once /motor/tp_motor_health | tee "\$evidence_dir/health.before_enabled_soak.yaml"
timeout $M2_MOTOR_ENABLED_SOAK_TIMEOUT_S ros2 topic hz /com/tp_mcu_status | tee "\$evidence_dir/rate.com_status.soak.txt" &
com_soak_hz_pid=\$!
tools/pub-motor-m2-enabled-target-soak.py --hz $M2_MOTOR_ENABLED_SOAK_HZ --duration-s $M2_MOTOR_ENABLED_SOAK_DURATION_S --start-seq $M2_MOTOR_ENABLED_SOAK_START_SEQ --control-mode 1 --ttl-us 100000 | tee "\$evidence_dir/enabled_soak.summary.txt" &
enabled_soak_pid=\$!
sleep $M2_MOTOR_ENABLED_SOAK_MID_SLEEP_S
ros2 topic echo --once /motor/tp_motor_health | tee "\$evidence_dir/health.mid_enabled_soak.yaml"
ros2 topic echo --once /motor/tp_joint_state | tee "\$evidence_dir/state.mid_enabled_soak.yaml"
wait "\$enabled_soak_pid"
wait "\$com_soak_hz_pid" || true
ros2 topic echo --once /motor/tp_joint_state | tee "\$evidence_dir/state.after_enabled_soak.yaml"
ros2 topic echo --once /motor/tp_motor_health | tee "\$evidence_dir/health.after_enabled_soak.yaml"

tools/measure-stack-hwm.sh $(shell_quote "$elf") | tee "\$evidence_dir/stack-hwm.txt"
# Generate this only after all runtime raw files are complete and agent.log is no longer appending.
(cd "\$evidence_dir" && sha256sum topics.txt info.motor_target.txt info.motor_state.txt info.motor_health.txt info.com_status.txt state.before_seq42.yaml state.after_seq42.yaml health.before_reject.yaml state.after_reject_seq43.yaml health.after_reject_seq43.yaml state.after_seq44.yaml state.after_clamp_seq45.yaml health.before_ttl.yaml state.after_ttl.yaml health.after_ttl.yaml health.before_enabled_soak.yaml enabled_soak.summary.txt health.mid_enabled_soak.yaml state.mid_enabled_soak.yaml rate.motor_state.txt rate.motor_health.txt rate.com_status.txt rate.com_status.soak.txt state.after_enabled_soak.yaml health.after_enabled_soak.yaml stack-hwm.txt agent.log > raw.sha256)
tools/check-motor-m2-smoke-evidence.py "\$evidence_dir" --min-motor-state-hz $M2_MOTOR_STATE_MIN_HZ --max-motor-state-hz $M2_MOTOR_STATE_MAX_HZ --min-motor-health-hz $M2_MOTOR_HEALTH_MIN_HZ --max-motor-health-hz $M2_MOTOR_HEALTH_MAX_HZ --min-enabled-soak-target-hz $M2_MOTOR_ENABLED_SOAK_MIN_HZ --max-enabled-soak-target-hz $M2_MOTOR_ENABLED_SOAK_MAX_HZ --min-enabled-soak-duration-s $M2_MOTOR_ENABLED_SOAK_DURATION_S
EOF
}

print_checklist() {
  cat <<EOF
M2_MOTOR_SMOKE_TAG=$M2_MOTOR_TAG
M2_MOTOR_SMOKE_BAUD=$M2_MOTOR_BAUD
M2_MOTOR_SMOKE_SERIAL=$M2_MOTOR_SERIAL
M2_MOTOR_SMOKE_BUILD_DIR=$M2_MOTOR_BUILD_DIR
M2_MOTOR_SMOKE_EVIDENCE_DIR=$M2_MOTOR_EVIDENCE_DIR
M2_MOTOR_SMOKE_STATE_PERIOD_MS=$M2_MOTOR_STATE_PERIOD_MS
M2_MOTOR_SMOKE_HEALTH_PERIOD_MS=$M2_MOTOR_HEALTH_PERIOD_MS
M2_MOTOR_SMOKE_REQUIRE_BUDGET_BAUDS=$M2_MOTOR_REQUIRE_BUDGET_BAUDS
M2_MOTOR_SMOKE_ENABLED_SOAK_HZ=$M2_MOTOR_ENABLED_SOAK_HZ
M2_MOTOR_SMOKE_ENABLED_SOAK_DURATION_S=$M2_MOTOR_ENABLED_SOAK_DURATION_S
M2_MOTOR_SMOKE_ENABLED_SOAK_START_SEQ=$M2_MOTOR_ENABLED_SOAK_START_SEQ
M2_MOTOR_SMOKE_STATE_RATE_TIMEOUT_S=$M2_MOTOR_STATE_RATE_TIMEOUT_S
M2_MOTOR_SMOKE_HEALTH_RATE_TIMEOUT_S=$M2_MOTOR_HEALTH_RATE_TIMEOUT_S
CHECK swd_status_ok
CHECK motor_enabled_firmware_builds
CHECK motor_firmware_flashes
CHECK agent_connects_without_reconnect_loop
CHECK ros_graph_has_motor_target_state_health_and_com_status
CHECK empty_frame_id_target_updates_joint_state_last_target_seq
CHECK ttl_stale_or_stop_publish_safes_target
CHECK clamp_or_fault_fields_observable_for_limited_target
CHECK non_empty_frame_id_keeps_last_target_seq_at_previous_accepted_seq
CHECK non_empty_frame_id_does_not_increment_targets_received_or_applied
CHECK legal_target_after_reject_proves_executor_still_serves_topics
CHECK motor_state_hz_and_com_status_hz_match_expected_decimation
CHECK enabled_200hz_target_soak_received_and_applied_grow
CHECK enabled_soak_last_target_seq_tracks_latest_seq
CHECK com_status_hz_during_enabled_soak_stays_in_range
CHECK stack_hwm_msp_heap_margin_recorded_before_default_memory_reduction
CHECK agent_log_has_no_session_loss_disconnect_or_hardfault
CHECK 921600_is_comparison_only_when_static_budget_is_over_30_percent
EOF
}

if [ "$FORMAT" = "commands" ]; then
  print_commands
  exit 0
fi

if [ "$FORMAT" = "checklist" ]; then
  print_checklist
  exit 0
fi

cat <<EOF
# Recommended M2 Motor Smoke Command

- tag: $M2_MOTOR_TAG
- serial: $M2_MOTOR_SERIAL
- baud: $M2_MOTOR_BAUD
- build dir: $M2_MOTOR_BUILD_DIR
- evidence dir: $M2_MOTOR_EVIDENCE_DIR
- motor state period: ${M2_MOTOR_STATE_PERIOD_MS}ms (${M2_MOTOR_STATE_HZ}Hz)
- motor health period: ${M2_MOTOR_HEALTH_PERIOD_MS}ms (${M2_MOTOR_HEALTH_HZ}Hz)
- ELF: $elf
- profile: EXO_MOTOR_ROS_ENTITIES=ON, best_effort=$M2_MOTOR_QOS_BEST_EFFORT, loop=${M2_MOTOR_CONTROL_LOOP_HZ}Hz, status_every_n=$M2_MOTOR_STATUS_EVERY_N, motor_state_period_ms=$M2_MOTOR_STATE_PERIOD_MS, motor_health_period_ms=$M2_MOTOR_HEALTH_PERIOD_MS

Gate: run \`STRICT=1 tools/diagnose-swd.sh\` first; only flash when \`SWD_STATUS=ok\`.

The first M2 smoke should prefer 2Mbps. Static budget says the default 200Hz
target + 20ms state + 200ms health profile is over the 30% budget at 921600
baud, so 921600 is a comparison case after the 2Mbps smoke connects. If the
2Mbps smoke passes but 921600 margin is required, re-run with lower telemetry
periods such as \`M2_MOTOR_STATE_PERIOD_MS=500 M2_MOTOR_HEALTH_PERIOD_MS=1000\`
and keep the 200Hz target path unchanged.

## Commands

\`\`\`bash
$(print_commands)
\`\`\`

## Acceptance Checklist

\`\`\`text
$(print_checklist)
\`\`\`

## Evidence Boundaries

- Passing \`/com\` 10kHz/200Hz validation is not a substitute for this \`/motor\` topic smoke.
- The non-empty \`header.frame_id\` command is a negative test. Do not count it as passing just because \`/motor/tp_joint_state\` still publishes: \`last_target_seq\` must remain at the previous accepted seq, \`targets_received/targets_applied\` must not increase because of the rejected target, and a later legal target must still be accepted.
- The seq42/seq43/seq44 targets intentionally use \`control_mode=0\` so \`targets_applied\` is not naturally incremented by the enabled control loop during the negative frame_id check.
- The enabled soak uses \`control_mode=1\` (ZERO_TORQUE) with empty \`frame_id\` and monotonic seq. It is the evidence for 200Hz target receive plus 10kHz control tick applied growth; do not substitute the disabled negative-test counters for this gate.
- Do not reduce motor-enabled stack/linker reserve defaults until \`tools/measure-stack-hwm.sh\` records task-stack HWM plus \`newlib_heap\` MSP/heap margin, and \`agent.log\` shows no reconnect/session-loss/HardFault during the motor-enabled smoke.
EOF
