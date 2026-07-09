#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README="$ROOT/ros2_ws/README.md"

assert_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if ! grep -Fq -- "$needle" "$file"; then
    echo "FAIL: $label missing '$needle' in $file" >&2
    exit 1
  fi
}

assert_contains "$README" "link_health_period_s" \
  "latest-target preset documents link health period"
assert_contains "$README" "summary_period_s" \
  "latest-target preset documents summary period"
assert_contains "$README" "200Hz PC latest-target 通信是否仍然稳定" \
  "staircase purpose documents PC/MCU frequency split"
assert_contains "$README" "sampler_target_rx_hz" \
  "staircase success metric documents target receive rate"
assert_contains "$README" "pc_wire_gap_p99/max_ms" \
  "staircase success metric documents PC publish gap"
assert_contains "$README" "pc_cmd_catchup_events" \
  "latest-target docs include PC catch-up event metric"
assert_contains "$README" "pc_cmd_catchup_extra" \
  "latest-target docs include PC catch-up extra command metric"
assert_contains "$README" "tools/diagnose-swd.sh" \
  "SWD diagnostic command is documented"
assert_contains "$README" "SWD_STATUS=ok" \
  "SWD diagnostic status is documented"
assert_contains "$README" "qos_incompatibility" \
  "staircase documents QoS incompatibility metric"
assert_contains "$README" "tools/check-com-staircase-contract.py" \
  "staircase acceptance contract command is documented"
assert_contains "$README" "tools/run-com-validation-cycle.sh" \
  "unattended validation cycle command is documented"
assert_contains "$README" "PATH full_staircase" \
  "validation cycle full staircase path is documented"
assert_contains "$README" "PATH no_flash_fallback" \
  "validation cycle no-flash fallback path is documented"
assert_contains "$README" "missing_required_stage" \
  "staircase contract fallback failure is documented"
assert_contains "$README" "tools/recommend-firmware-optimizations.sh" \
  "firmware optimization recommendations command is documented"
assert_contains "$README" "default_policy=keep_defaults_until_runtime_evidence" \
  "firmware optimization default policy is documented"
assert_contains "$README" "tools/recommend-communication-optimizations.py" \
  "communication optimization recommendations command is documented"
assert_contains "$README" "control_link=pc_200hz_latest_target_mcu_status_decimated" \
  "communication optimization default policy is documented"

echo "PASS: communication docs checks"
