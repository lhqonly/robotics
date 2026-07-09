#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

assert_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if ! grep -Fq -- "$needle" "$file"; then
    echo "FAIL: $label missing '$needle' in $file" >&2
    cat "$file" >&2
    exit 1
  fi
}

bash -n "$ROOT/tools/recommend-motor-m2-smoke-command.sh"

out="$TMPDIR/default.md"
"$ROOT/tools/recommend-motor-m2-smoke-command.sh" >"$out"

assert_contains "$out" "# Recommended M2 Motor Smoke Command" \
  "title"
assert_contains "$out" "EXO_MOTOR_ROS_ENTITIES=ON" \
  "motor entity build flag"
assert_contains "$out" "-DEXO_UART_BAUD=2000000" \
  "default first smoke baud"
assert_contains "$out" "-DEXO_MOTOR_STATE_PERIOD_MS=20" \
  "default motor state period"
assert_contains "$out" "-DEXO_MOTOR_HEALTH_PERIOD_MS=200" \
  "default motor health period"
assert_contains "$out" "tools/com-wire-budget.py --profile motor-m2" \
  "motor wire budget precheck"
assert_contains "$out" "--baud \"2000000\" --max-baud-util-pct 30 --fail-on-over-budget" \
  "default target baud budget gate"
assert_contains "$out" "--motor-state-hz 50.000000 --motor-health-hz 5.000000" \
  "default motor wire budget rates"
assert_contains "$out" "tools/diagnose-swd.sh" \
  "SWD gate"
assert_contains "$out" "tools/run-bridge.sh '/dev/ttyUSB0' '2000000'" \
  "default bridge command"
assert_contains "$out" "evidence dir: log/motor-m2-smoke/" \
  "default evidence directory"
assert_contains "$out" "tools/check-motor-m2-smoke-evidence.py --template" \
  "evidence template command"
assert_contains "$out" "ros2 topic info -v /motor/tp_joint_target" \
  "target topic info command"
assert_contains "$out" "ros2 topic info -v /motor/tp_joint_state" \
  "state topic info command"
assert_contains "$out" "ros2 topic info -v /motor/tp_motor_health" \
  "health topic info command"
assert_contains "$out" "ros2 topic info -v /com/tp_mcu_status" \
  "com coexistence topic info command"
assert_contains "$out" "frame_id: ''" \
  "empty frame_id positive publish"
assert_contains "$out" "control_mode: 0" \
  "disabled target for clean reject counters"
assert_contains "$out" "frame_id: reject" \
  "non-empty frame_id negative publish"
assert_contains "$out" "last_target_seq remains 42" \
  "negative frame_id last_target_seq assertion"
assert_contains "$out" "targets_received/targets_applied do not increase" \
  "negative frame_id health counter assertion"
assert_contains "$out" "seq: 44" \
  "legal target after negative frame_id"
assert_contains "$out" "seq: 45" \
  "clamp target after negative frame_id"
assert_contains "$out" "state.after_ttl.yaml" \
  "TTL stale evidence capture"
assert_contains "$out" 'tools/check-motor-m2-smoke-evidence.py "$evidence_dir"' \
  "evidence checker command"
assert_contains "$out" "--min-motor-state-hz 45.000000 --max-motor-state-hz 55.000000" \
  "default motor state checker rate band"
assert_contains "$out" "--min-motor-health-hz 4.500000 --max-motor-health-hz 5.500000" \
  "default motor health checker rate band"
assert_contains "$out" "timeout 11 ros2 topic hz /motor/tp_joint_state" \
  "default motor state hz timeout"
assert_contains "$out" "timeout 12 ros2 topic hz /motor/tp_motor_health" \
  "default motor health hz timeout"
assert_contains "$out" "rate.motor_health.txt" \
  "motor health hz evidence capture"
assert_contains "$out" "tools/measure-stack-hwm.sh 'firmware/f103-microros/build-motor/f103-microros.elf'" \
  "motor stack HWM command"
assert_contains "$out" "Passing \`/com\` 10kHz/200Hz validation is not a substitute" \
  "surrogate evidence warning"
assert_contains "$out" "CHECK non_empty_frame_id_keeps_last_target_seq_at_previous_accepted_seq" \
  "negative frame_id seq checklist"
assert_contains "$out" "CHECK non_empty_frame_id_does_not_increment_targets_received_or_applied" \
  "negative frame_id counter checklist"
assert_contains "$out" "CHECK legal_target_after_reject_proves_executor_still_serves_topics" \
  "negative frame_id executor checklist"
assert_contains "$out" "CHECK 921600_is_comparison_only_when_static_budget_is_over_30_percent" \
  "921600 budget warning checklist"
assert_contains "$out" "seq42/seq43/seq44 targets intentionally use \`control_mode=0\`" \
  "disabled baseline warning"

commands="$TMPDIR/commands.sh"
FORMAT=commands M2_MOTOR_BAUD=921600 M2_MOTOR_SERIAL=/dev/ttyACM0 \
  M2_MOTOR_BUILD_DIR=firmware/f103-microros/build-motor-921k \
  M2_MOTOR_STATE_PERIOD_MS=500 M2_MOTOR_HEALTH_PERIOD_MS=1000 \
  "$ROOT/tools/recommend-motor-m2-smoke-command.sh" >"$commands"

assert_contains "$commands" "-DEXO_UART_BAUD=921600" \
  "custom baud in commands format"
assert_contains "$commands" "-DEXO_MOTOR_STATE_PERIOD_MS=500" \
  "custom state period in commands format"
assert_contains "$commands" "-DEXO_MOTOR_HEALTH_PERIOD_MS=1000" \
  "custom health period in commands format"
assert_contains "$commands" "--baud \"921600\" --max-baud-util-pct 30 --fail-on-over-budget" \
  "custom 921600 budget gate"
assert_contains "$commands" "--motor-state-hz 2.000000 --motor-health-hz 1.000000" \
  "custom motor wire budget rates"
assert_contains "$commands" "--min-motor-state-hz 1.800000 --max-motor-state-hz 2.200000" \
  "custom motor checker rate band"
assert_contains "$commands" "--min-motor-health-hz 0.900000 --max-motor-health-hz 1.100000" \
  "custom motor health checker rate band"
assert_contains "$commands" "timeout 13 ros2 topic hz /motor/tp_joint_state" \
  "custom motor state hz timeout"
assert_contains "$commands" "timeout 16 ros2 topic hz /motor/tp_motor_health" \
  "custom motor health hz timeout"
assert_contains "$commands" "tools/run-bridge.sh '/dev/ttyACM0' '921600'" \
  "custom serial in commands format"
assert_contains "$commands" "cmake --build 'firmware/f103-microros/build-motor-921k'" \
  "custom build dir in commands format"
assert_contains "$commands" "st-flash --connect-under-reset write 'firmware/f103-microros/build-motor-921k/f103-microros.bin' 0x08000000" \
  "custom flash path in commands format"
assert_contains "$commands" "evidence_dir='log/motor-m2-smoke/" \
  "default evidence dir in commands format"

checklist="$TMPDIR/checklist.txt"
FORMAT=checklist M2_MOTOR_TAG=demo_motor "$ROOT/tools/recommend-motor-m2-smoke-command.sh" >"$checklist"
assert_contains "$checklist" "M2_MOTOR_SMOKE_TAG=demo_motor" \
  "custom tag in checklist"
assert_contains "$checklist" "M2_MOTOR_SMOKE_EVIDENCE_DIR=log/motor-m2-smoke/demo_motor" \
  "custom evidence dir in checklist"
assert_contains "$checklist" "M2_MOTOR_SMOKE_STATE_PERIOD_MS=20" \
  "state period in checklist"
assert_contains "$checklist" "M2_MOTOR_SMOKE_HEALTH_PERIOD_MS=200" \
  "health period in checklist"
assert_contains "$checklist" "M2_MOTOR_SMOKE_REQUIRE_BUDGET_BAUDS=2000000" \
  "budget gate bauds in checklist"

set +e
bad_period_out="$(M2_MOTOR_STATE_PERIOD_MS=0 "$ROOT/tools/recommend-motor-m2-smoke-command.sh" 2>&1 >/dev/null)"
bad_period_rc=$?
set -e
if [ "$bad_period_rc" -eq 0 ]; then
  echo "FAIL: invalid motor state period should fail" >&2
  exit 1
fi
grep -Fq "ERROR: M2_MOTOR_STATE_PERIOD_MS must be an integer in [10, 1000]" <<<"$bad_period_out" || {
  echo "FAIL: invalid motor state period error missing" >&2
  echo "$bad_period_out" >&2
  exit 1
}

set +e
bad_health_out="$(M2_MOTOR_HEALTH_PERIOD_MS=0 "$ROOT/tools/recommend-motor-m2-smoke-command.sh" 2>&1 >/dev/null)"
bad_health_rc=$?
bad_order_out="$(M2_MOTOR_STATE_PERIOD_MS=1000 M2_MOTOR_HEALTH_PERIOD_MS=100 "$ROOT/tools/recommend-motor-m2-smoke-command.sh" 2>&1 >/dev/null)"
bad_order_rc=$?
bad_text_out="$(M2_MOTOR_STATE_PERIOD_MS=20abc "$ROOT/tools/recommend-motor-m2-smoke-command.sh" 2>&1 >/dev/null)"
bad_text_rc=$?
bad_decimal_out="$(M2_MOTOR_HEALTH_PERIOD_MS=100.5 "$ROOT/tools/recommend-motor-m2-smoke-command.sh" 2>&1 >/dev/null)"
bad_decimal_rc=$?
set -e
if [ "$bad_health_rc" -eq 0 ]; then
  echo "FAIL: invalid motor health period should fail" >&2
  exit 1
fi
grep -Fq "ERROR: M2_MOTOR_HEALTH_PERIOD_MS must be an integer in [100, 5000]" <<<"$bad_health_out" || {
  echo "FAIL: invalid motor health period error missing" >&2
  echo "$bad_health_out" >&2
  exit 1
}
if [ "$bad_order_rc" -eq 0 ]; then
  echo "FAIL: motor health period faster than state should fail" >&2
  exit 1
fi
grep -Fq "ERROR: M2_MOTOR_HEALTH_PERIOD_MS must be >= M2_MOTOR_STATE_PERIOD_MS" <<<"$bad_order_out" || {
  echo "FAIL: health/state order error missing" >&2
  echo "$bad_order_out" >&2
  exit 1
}
if [ "$bad_text_rc" -eq 0 ]; then
  echo "FAIL: non-integer motor state period should fail" >&2
  exit 1
fi
grep -Fq "ERROR: M2_MOTOR_STATE_PERIOD_MS must be an integer in [10, 1000]" <<<"$bad_text_out" || {
  echo "FAIL: non-integer motor state period error missing" >&2
  echo "$bad_text_out" >&2
  exit 1
}
if [ "$bad_decimal_rc" -eq 0 ]; then
  echo "FAIL: decimal motor health period should fail" >&2
  exit 1
fi
grep -Fq "ERROR: M2_MOTOR_HEALTH_PERIOD_MS must be an integer in [100, 5000]" <<<"$bad_decimal_out" || {
  echo "FAIL: decimal motor health period error missing" >&2
  echo "$bad_decimal_out" >&2
  exit 1
}

minmax="$TMPDIR/minmax.md"
M2_MOTOR_STATE_PERIOD_MS=10 M2_MOTOR_HEALTH_PERIOD_MS=5000 \
  "$ROOT/tools/recommend-motor-m2-smoke-command.sh" >"$minmax"
assert_contains "$minmax" "- motor state period: 10ms (100.000000Hz)" \
  "minimum state period accepted"
assert_contains "$minmax" "- motor health period: 5000ms (0.200000Hz)" \
  "maximum health period accepted"
assert_contains "$minmax" "timeout 40 ros2 topic hz /motor/tp_motor_health" \
  "maximum health period gets longer hz timeout"
assert_contains "$checklist" "CHECK ros_graph_has_motor_target_state_health_and_com_status" \
  "graph checklist"
assert_contains "$checklist" "CHECK stack_hwm_msp_heap_margin_recorded_before_default_memory_reduction" \
  "memory gate checklist"

echo "PASS: recommended M2 motor smoke command tests"
