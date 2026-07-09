#!/usr/bin/env bash
# Offline PASS/FAIL contract check for one tools/run-com-perf.sh log tag.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGDIR="${LOGDIR:-$ROOT/log/com-perf}"
TAG="${1:-}"

MIN_RATE_RATIO="${MIN_RATE_RATIO:-0.90}"
MAX_RATE_RATIO="${MAX_RATE_RATIO:-1.10}"
STATUS_EVERY_N="${STATUS_EVERY_N:-1}"
MAX_PC_P99_GAP_RATIO="${MAX_PC_P99_GAP_RATIO:-4.0}"
MAX_PC_MAX_GAP_RATIO="${MAX_PC_MAX_GAP_RATIO:-10.0}"
MAX_LOST="${MAX_LOST:-0}"
MAX_DUPLICATE="${MAX_DUPLICATE:-0}"

if [ -z "$TAG" ]; then
  echo "Usage: tools/check-com-perf-contract.sh <tag>" >&2
  echo "       Optional env: EXPECTED_CMD_RATE_HZ=200 STATUS_EVERY_N=40" >&2
  exit 2
fi

metric_from_line() {
  local line="$1"
  local key="$2"
  printf '%s\n' "$line" |
    tr ' ' '\n' |
    awk -F= -v key="$key" '$1 == key {print $2}' |
    tail -1
}

cmd_log="$LOGDIR/$TAG.cmd.log"
sampler_log="$LOGDIR/$TAG.sampler.log"

if [ ! -f "$cmd_log" ]; then
  echo "FAIL tag=$TAG reason=missing_cmd_log path=$cmd_log" >&2
  exit 1
fi
if [ ! -f "$sampler_log" ]; then
  echo "FAIL tag=$TAG reason=missing_sampler_log path=$sampler_log" >&2
  exit 1
fi

cmd_line="$(grep 'link-health summary' "$cmd_log" | tail -1 || true)"
sampler_line="$(grep 'status_sampler:' "$sampler_log" | tail -1 || true)"
qos_incompatibility="$(grep -E 'incompatible QoS|requesting incompatible QoS|Last incompatible policy' "$cmd_log" |
  tail -1 || true)"
if [ -z "$cmd_line" ] || [ -z "$sampler_line" ]; then
  echo "FAIL tag=$TAG reason=missing_summary_line" >&2
  exit 1
fi

pc_target_hz="$(metric_from_line "$cmd_line" target_rate_hz)"
pc_target_window_hz="$(metric_from_line "$cmd_line" target_window_hz)"
pc_wire_gap_p99_ms="$(metric_from_line "$cmd_line" wire_gap_p99_ms)"
pc_wire_gap_max_ms="$(metric_from_line "$cmd_line" wire_gap_max_ms)"
lost="$(metric_from_line "$cmd_line" lost)"
duplicate="$(metric_from_line "$cmd_line" duplicate)"
sampler_hz="$(metric_from_line "$sampler_line" rate_hz)"
sampler_seq_delta_min="$(metric_from_line "$sampler_line" seq_delta_min)"
sampler_seq_delta_max="$(metric_from_line "$sampler_line" seq_delta_max)"

expected_cmd_hz="${EXPECTED_CMD_RATE_HZ:-$pc_target_hz}"
expected_status_hz="${EXPECTED_STATUS_RATE_HZ:-}"
if [ -z "$expected_status_hz" ]; then
  expected_status_hz="$(awk -v cmd="$expected_cmd_hz" -v n="$STATUS_EVERY_N" \
    'BEGIN { printf "%.6f", cmd / n }')"
fi

period_ms="$(awk -v hz="$expected_cmd_hz" 'BEGIN { printf "%.6f", 1000.0 / hz }')"
pc_p99_limit_ms="$(awk -v p="$period_ms" -v ratio="$MAX_PC_P99_GAP_RATIO" \
  'BEGIN { printf "%.6f", p * ratio }')"
pc_max_limit_ms="$(awk -v p="$period_ms" -v ratio="$MAX_PC_MAX_GAP_RATIO" \
  'BEGIN { printf "%.6f", p * ratio }')"

reasons=""
add_reason() {
  if [ -z "$reasons" ]; then
    reasons="$1"
  else
    reasons="$reasons;$1"
  fi
}

if [ -n "$qos_incompatibility" ]; then
  add_reason "qos_incompatible"
fi

require_number() {
  local value="$1"
  local name="$2"
  if [ -z "$value" ] || [ "$value" = "NA" ]; then
    add_reason "missing_$name"
    return 1
  fi
  return 0
}

if require_number "$pc_target_window_hz" pc_target_window_hz; then
  if ! awk -v actual="$pc_target_window_hz" -v expected="$expected_cmd_hz" \
      -v min="$MIN_RATE_RATIO" -v max="$MAX_RATE_RATIO" \
      'BEGIN { exit !((actual + 0) >= expected * min && (actual + 0) <= expected * max) }'; then
    add_reason "pc_target_rate_out_of_band"
  fi
fi

if require_number "$sampler_hz" sampler_hz; then
  if ! awk -v actual="$sampler_hz" -v expected="$expected_status_hz" \
      -v min="$MIN_RATE_RATIO" -v max="$MAX_RATE_RATIO" \
      'BEGIN { exit !((actual + 0) >= expected * min && (actual + 0) <= expected * max) }'; then
    add_reason "status_rate_out_of_band"
  fi
fi

if require_number "$pc_wire_gap_p99_ms" pc_wire_gap_p99_ms; then
  if ! awk -v actual="$pc_wire_gap_p99_ms" -v limit="$pc_p99_limit_ms" \
      'BEGIN { exit !((actual + 0) <= (limit + 0)) }'; then
    add_reason "pc_wire_gap_p99_high"
  fi
fi

if require_number "$pc_wire_gap_max_ms" pc_wire_gap_max_ms; then
  if ! awk -v actual="$pc_wire_gap_max_ms" -v limit="$pc_max_limit_ms" \
      'BEGIN { exit !((actual + 0) <= (limit + 0)) }'; then
    add_reason "pc_wire_gap_max_high"
  fi
fi

if require_number "$lost" lost && [ "$lost" -gt "$MAX_LOST" ] 2>/dev/null; then
  add_reason "lost_high"
fi
if require_number "$duplicate" duplicate &&
    [ "$duplicate" -gt "$MAX_DUPLICATE" ] 2>/dev/null; then
  add_reason "duplicate_high"
fi
if [ "$STATUS_EVERY_N" -eq 1 ] 2>/dev/null &&
    require_number "$sampler_seq_delta_min" seq_delta_min &&
    require_number "$sampler_seq_delta_max" seq_delta_max &&
    { [ "$sampler_seq_delta_min" -ne 1 ] ||
      [ "$sampler_seq_delta_max" -ne 1 ]; } 2>/dev/null; then
  add_reason "seq_delta_not_1"
fi

if [ -n "$reasons" ]; then
  echo "FAIL tag=$TAG reason=$reasons expected_cmd_hz=$expected_cmd_hz expected_status_hz=$expected_status_hz pc_p99_limit_ms=$pc_p99_limit_ms pc_max_limit_ms=$pc_max_limit_ms pc_target_window_hz=${pc_target_window_hz:-NA} sampler_hz=${sampler_hz:-NA} pc_wire_gap_p99_ms=${pc_wire_gap_p99_ms:-NA} pc_wire_gap_max_ms=${pc_wire_gap_max_ms:-NA} lost=${lost:-NA} duplicate=${duplicate:-NA} qos_incompatibility=${qos_incompatibility:-none}"
  exit 1
fi

echo "PASS tag=$TAG expected_cmd_hz=$expected_cmd_hz expected_status_hz=$expected_status_hz pc_p99_limit_ms=$pc_p99_limit_ms pc_max_limit_ms=$pc_max_limit_ms pc_target_window_hz=$pc_target_window_hz sampler_hz=$sampler_hz pc_wire_gap_p99_ms=$pc_wire_gap_p99_ms pc_wire_gap_max_ms=$pc_wire_gap_max_ms lost=$lost duplicate=$duplicate qos_incompatibility=none"
