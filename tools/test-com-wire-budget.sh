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
assert_contains "$contract" "| 200.00 | 40 | 5.00 | 921600 | 88.60 | 2.17 | 90.77 | 9.85 | PASS |"
assert_contains "$contract" "| 1000.00 | 1 | 1000.00 | 921600 | 443.00 | 433.50 | 876.50 | 95.11 | OVER_BUDGET |"

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

echo "PASS: communication wire budget tests"
