#!/usr/bin/env bash
# Offline regression tests for tools/com-wire-budget.py.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

WIRE_LOG="$TMPDIR/sample.wire.log"
cat >"$WIRE_LOG" <<'LOG'
METRICS duration_s=10 total_serial_kbit_s=17.53 baud_util_pct=1.90 tx_serial_kbit_s=8.86 rx_serial_kbit_s=8.67
LOG

single="$("$ROOT/tools/com-wire-budget.py" \
  --wire-log "$WIRE_LOG" \
  --cmd-hz 200 \
  --status-every-n 40 \
  --baud 921600)"

matrix="$("$ROOT/tools/com-wire-budget.py" \
  --wire-log "$WIRE_LOG" \
  --cmd-hz 200,1000 \
  --status-every-n 1,40 \
  --baud 921600,2000000)"

contract="$("$ROOT/tools/com-wire-budget.py" \
  --wire-log "$WIRE_LOG" \
  --cmd-hz 200,1000 \
  --status-every-n 1,40 \
  --baud 921600 \
  --max-baud-util-pct 30)"

wire_time="$("$ROOT/tools/com-wire-budget.py" \
  --wire-log "$WIRE_LOG" \
  --cmd-hz 200 \
  --status-every-n 40 \
  --baud 921600,2000000 \
  --show-wire-time)"

repeated_args="$("$ROOT/tools/com-wire-budget.py" \
  --wire-log "$WIRE_LOG" \
  --cmd-hz 200 \
  --cmd-hz 500 \
  --status-every 20 \
  --status-every 40 \
  --baud 921600 \
  --baud 2000000)"

motor="$("$ROOT/tools/com-wire-budget.py" \
  --profile motor-m2 \
  --cmd-hz 200 \
  --baud 921600,2000000 \
  --max-baud-util-pct 30)"

motor_wire_time="$("$ROOT/tools/com-wire-budget.py" \
  --profile motor-m2 \
  --cmd-hz 200,1000 \
  --motor-state-hz 5,50 \
  --motor-health-hz 5 \
  --baud 921600 \
  --max-baud-util-pct 30 \
  --show-wire-time)"

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if ! grep -Fq "$needle" <<<"$haystack"; then
    echo "ERROR: expected output to contain: $needle" >&2
    echo "$haystack" >&2
    exit 1
  fi
}

assert_contains "$single" "| 200.00 | 40 | 5.00 | 921600 | 88.60 | 2.17 | 90.77 | 9.85 |"
assert_contains "$matrix" "| 200.00 | 1 | 200.00 | 921600 | 88.60 | 86.70 | 175.30 | 19.02 |"
assert_contains "$matrix" "| 1000.00 | 40 | 25.00 | 2000000 | 443.00 | 10.84 | 453.84 | 22.69 |"
assert_contains "$contract" "budget contract: baud_util_pct <= 30.00"
assert_contains "$contract" "budget math: min_baud = total_kbit/s * 1000 * 100 / max_baud_util_pct"
assert_contains "$contract" "| 200.00 | 40 | 5.00 | 921600 | 88.60 | 2.17 | 90.77 | 9.85 | 302559 | 20.15 | PASS |"
assert_contains "$contract" "| 1000.00 | 1 | 1000.00 | 921600 | 443.00 | 433.50 | 876.50 | 95.11 | 2921667 | -65.11 | OVER_BUDGET |"
assert_contains "$wire_time" "| cmd Hz | status every N | status Hz | baud | tx kbit/s | rx kbit/s | total kbit/s | baud util % | cmd wire ms | status wire ms | full echo wire ms |"
assert_contains "$wire_time" "| 200.00 | 40 | 5.00 | 921600 | 88.60 | 2.17 | 90.77 | 9.85 | 0.481 | 0.470 | 0.951 |"
assert_contains "$wire_time" "| 200.00 | 40 | 5.00 | 2000000 | 88.60 | 2.17 | 90.77 | 4.54 | 0.222 | 0.217 | 0.438 |"
assert_contains "$wire_time" "Wire-time columns are UART serialization lower bounds"
assert_contains "$repeated_args" "| 500.00 | 20 | 25.00 | 921600 | 221.50 | 10.84 | 232.34 | 25.21 |"
assert_contains "$repeated_args" "| 500.00 | 40 | 12.50 | 2000000 | 221.50 | 5.42 | 226.92 | 11.35 |"
assert_contains "$motor" "# M2 Motor Wire Budget Estimate"
assert_contains "$motor" 'profile: `/motor` topics with empty `std_msgs/Header.frame_id`'
assert_contains "$motor" "payload bytes: JointTarget=104, JointState=90, MotorHealth=89"
assert_contains "$motor" "serial bytes per sample: payload + 32.0B XRCE/framing allowance"
assert_contains "$motor" "| 200.00 | 50.00 | 5.00 | 921600 | 272.00 | 67.05 | 339.05 | 36.79 | 1130167 | -6.79 | OVER_BUDGET |"
assert_contains "$motor" "| 200.00 | 50.00 | 5.00 | 2000000 | 272.00 | 67.05 | 339.05 | 16.95 | 1130167 | 13.05 | PASS |"
assert_contains "$motor" "Motor suggestion: worst projected row is target=200.00Hz state=50.00Hz health=5.00Hz baud=921600 at 36.79% baud utilization."
assert_contains "$motor_wire_time" "| target Hz | state Hz | health Hz | baud | tx kbit/s | rx kbit/s | total kbit/s | baud util % | target wire ms | state wire ms | health wire ms | target+state wire ms | min baud @ budget | budget margin % | verdict |"
assert_contains "$motor_wire_time" "| 1000.00 | 50.00 | 5.00 | 921600 | 1360.00 | 67.05 | 1427.05 | 154.84 | 1.476 | 1.324 | 1.313 | 2.799 | 4756834 | -124.84 | OVER_BUDGET |"
assert_contains "$motor_wire_time" "Wire-time columns are UART serialization lower bounds for one motor sample."

row_count="$(grep -c '^| [0-9]' <<<"$matrix")"
if [ "$row_count" -ne 8 ]; then
  echo "ERROR: expected 8 matrix rows, got $row_count" >&2
  echo "$matrix" >&2
  exit 1
fi

if "$ROOT/tools/com-wire-budget.py" \
    --wire-log "$WIRE_LOG" \
    --cmd-hz 1000 \
    --status-every-n 1 \
    --baud 921600 \
    --max-baud-util-pct 30 \
    --fail-on-over-budget >/dev/null; then
  echo "ERROR: expected over-budget contract check to fail" >&2
  exit 1
fi

if "$ROOT/tools/com-wire-budget.py" \
    --profile motor-m2 \
    --cmd-hz 200 \
    --baud 921600 \
    --max-baud-util-pct 30 \
    --fail-on-over-budget >/dev/null; then
  echo "ERROR: expected motor over-budget contract check to fail" >&2
  exit 1
fi

echo "PASS: communication wire budget tests"
