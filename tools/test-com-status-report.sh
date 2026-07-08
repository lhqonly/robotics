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
    exit 1
  fi
}

OUTDIR="$TMPDIR" COM_STATUS_PROBE_STLINK=0 \
  "$ROOT/tools/com-status-report.sh" status_report_smoke >/dev/null

report="$TMPDIR/status_report_smoke.md"
if [ ! -f "$report" ]; then
  echo "FAIL: report was not generated: $report" >&2
  exit 1
fi

assert_contains "$report" "status=skipped reason=COM_STATUS_PROBE_STLINK=0" \
  "ST-LINK skip marker"
assert_contains "$report" "## micro-ROS 配置快照" \
  "micro-ROS config section"
assert_contains "$report" "## 固件静态内存矩阵" \
  "firmware size matrix section"
assert_contains "$report" "## micro-ROS 栈候选" \
  "micro-ROS stack candidates section"
assert_contains "$report" "## executor spin timeout 候选" \
  "executor spin-timeout candidates section"
assert_contains "$report" "## linker heap/MSP 预留候选" \
  "linker heap/MSP reserve candidates section"
assert_contains "$report" "meta_stream_history=2" \
  "micro-ROS stream history"
assert_contains "$report" "generated_stream_history=in:2/out:2" \
  "generated stream history"
assert_contains "$report" "## overnight no-flash 趋势" \
  "overnight section"
assert_contains "$report" "## staircase 阶梯汇总" \
  "staircase section"
assert_contains "$report" "## 未解决项" \
  "unresolved section"

unresolved="$(
  OUTDIR="$TMPDIR" COM_STATUS_PROBE_STLINK=0 \
    "$ROOT/tools/summarize-com-unresolved.sh" status_report_unresolved_smoke
)"
printf '%s\n' "$unresolved" | grep -Fq -- "## 未解决项" || {
  echo "FAIL: unresolved summary missing section header" >&2
  exit 1
}
printf '%s\n' "$unresolved" | grep -Fq -- "SWD 仍需恢复" || {
  echo "FAIL: unresolved summary missing SWD blocker" >&2
  exit 1
}

if find "$ROOT/log/overnight-com-watch" -maxdepth 1 -type f -name '*.log' | grep -q .; then
  assert_contains "$report" "### Verdict Summary" \
    "live overnight verdict summary"
fi

echo "PASS: communication status report tests"
