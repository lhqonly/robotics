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

run_expect_fail() {
  local label="$1"
  shift
  local out="$TMPDIR/fail.out"
  set +e
  "$@" >"$out" 2>&1
  local rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "FAIL: $label unexpectedly passed" >&2
    cat "$out" >&2
    exit 1
  fi
  cat "$out"
}

sweep="$TMPDIR/sweep.md"
"$ROOT/tools/motor-m2-telemetry-sweep.py" >"$sweep"

assert_contains "$sweep" "# M2 Motor Telemetry Period Sweep" \
  "sweep title"
assert_contains "$sweep" "source: static CDR field-size estimate from \`tools/com-wire-budget.py\`" \
  "budget source"
assert_contains "$sweep" "budget contract: baud_util_pct <= 30.00" \
  "budget threshold"
assert_contains "$sweep" "conservative static margin floor: 0.00 percentage points" \
  "default conservative margin floor"
assert_contains "$sweep" "state20_health200_921600 | 20 | 200 | 50.00 | 5.00 | 921600 | 272.00 | 67.05 | 339.05 | 36.79 | -6.79" \
  "default 921600 over budget"
assert_contains "$sweep" "state20_health200_921600 | 20 | 200 | 50.00 | 5.00 | 921600" \
  "default 921600 row"
assert_contains "$sweep" "OVER_BUDGET | over_budget | comparison_only" \
  "default 921600 comparison marker"
assert_contains "$sweep" "state20_health200_2000000 | 20 | 200 | 50.00 | 5.00 | 2000000 | 272.00 | 67.05 | 339.05 | 16.95 | 13.05" \
  "default 2Mbps pass"
assert_contains "$sweep" "PASS_STATIC | static_margin | first_smoke" \
  "default 2Mbps first smoke marker"
assert_contains "$sweep" "state500_health1000_921600 | 500 | 1000 | 2.00 | 1.00 | 921600 | 272.00 | 3.65 | 275.65 | 29.91 | 0.09" \
  "low telemetry 921600 pass"
assert_contains "$sweep" "PASS_STATIC | thin_margin | low_telemetry_candidate" \
  "low telemetry thin margin marker"
assert_contains "$sweep" "M2_MOTOR_BAUD=921600 M2_MOTOR_STATE_PERIOD_MS=500 M2_MOTOR_HEALTH_PERIOD_MS=1000 M2_MOTOR_REQUIRE_BUDGET_BAUDS=921600" \
  "smoke env includes budget baud"

pass_only="$TMPDIR/pass-only.md"
"$ROOT/tools/motor-m2-telemetry-sweep.py" --pass-only >"$pass_only"
assert_contains "$pass_only" "state500_health1000_921600" \
  "pass-only keeps low telemetry pass"
if grep -Fq "state20_health200_921600" "$pass_only"; then
  echo "FAIL: pass-only should not include default 921600 over-budget row" >&2
  cat "$pass_only" >&2
  exit 1
fi

conservative="$TMPDIR/conservative.md"
"$ROOT/tools/motor-m2-telemetry-sweep.py" --min-margin-pct 1 >"$conservative"
assert_contains "$conservative" "conservative static margin floor: 1.00 percentage points" \
  "custom conservative margin floor"
assert_contains "$conservative" "state500_health1000_921600 | 500 | 1000 | 2.00 | 1.00 | 921600 | 272.00 | 3.65 | 275.65 | 29.91 | 0.09" \
  "conservative sweep keeps low telemetry row"
assert_contains "$conservative" "PASS_THIN | thin_margin | comparison_only" \
  "conservative sweep downgrades thin 921600 row"
conservative_pass_only="$TMPDIR/conservative-pass-only.md"
"$ROOT/tools/motor-m2-telemetry-sweep.py" --min-margin-pct 1 --pass-only >"$conservative_pass_only"
if grep -Fq "state500_health1000_921600" "$conservative_pass_only"; then
  echo "FAIL: conservative pass-only should exclude thin 921600 row" >&2
  cat "$conservative_pass_only" >&2
  exit 1
fi

custom="$TMPDIR/custom.md"
"$ROOT/tools/motor-m2-telemetry-sweep.py" \
  --state-period-ms "20 500" \
  --health-period-ms "200 1000" \
  --baud "921600" >"$custom"
assert_contains "$custom" "state500_health1000_921600" \
  "custom sweep accepts period lists"

out="$(run_expect_fail "state period zero" \
  "$ROOT/tools/motor-m2-telemetry-sweep.py" --state-period-ms 0)"
grep -Fq -- "--state-period-ms values must be in [10, 1000]" <<<"$out" || {
  echo "FAIL: state period zero error missing" >&2
  echo "$out" >&2
  exit 1
}
out="$(run_expect_fail "health period text" \
  "$ROOT/tools/motor-m2-telemetry-sweep.py" --health-period-ms 200abc)"
grep -Fq -- "--health-period-ms expects integers" <<<"$out" || {
  echo "FAIL: health period text error missing" >&2
  echo "$out" >&2
  exit 1
}
out="$(run_expect_fail "bad baud" \
  "$ROOT/tools/motor-m2-telemetry-sweep.py" --baud 0)"
grep -Fq -- "--baud values must be > 0" <<<"$out" || {
  echo "FAIL: bad baud error missing" >&2
  echo "$out" >&2
  exit 1
}
out="$(run_expect_fail "nan cmd" \
  "$ROOT/tools/motor-m2-telemetry-sweep.py" --cmd-hz nan)"
grep -Fq -- "ERROR: --cmd-hz must be finite" <<<"$out" || {
  echo "FAIL: nan cmd error missing" >&2
  echo "$out" >&2
  exit 1
}
out="$(run_expect_fail "bad min margin" \
  "$ROOT/tools/motor-m2-telemetry-sweep.py" --min-margin-pct -1)"
grep -Fq -- "ERROR: --min-margin-pct must be >= 0" <<<"$out" || {
  echo "FAIL: bad min margin error missing" >&2
  echo "$out" >&2
  exit 1
}
out="$(run_expect_fail "health faster than state has no rows" \
  "$ROOT/tools/motor-m2-telemetry-sweep.py" --state-period-ms 1000 --health-period-ms 200 --pass-only)"
grep -Fq -- "ERROR: no valid period combinations after applying health period >= state period" <<<"$out" || {
  echo "FAIL: no valid period combination error missing" >&2
  echo "$out" >&2
  exit 1
}

echo "PASS: M2 motor telemetry sweep tests"
