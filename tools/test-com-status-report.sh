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

assert_not_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -Fq -- "$needle" "$file"; then
    echo "FAIL: $label unexpectedly contains '$needle' in $file" >&2
    exit 1
  fi
}

assert_contains "$ROOT/tools/com-status-report.sh" 'STATUS_EVERY_N="${status_every_n:-1}"' \
  "perf contract status decimation env"

OUTDIR="$TMPDIR" COM_STATUS_PROBE_STLINK=0 \
  "$ROOT/tools/com-status-report.sh" status_report_smoke >/dev/null

report="$TMPDIR/status_report_smoke.md"
if [ ! -f "$report" ]; then
  echo "FAIL: report was not generated: $report" >&2
  exit 1
fi

assert_contains "$report" "status=skipped reason=COM_STATUS_PROBE_STLINK=0" \
  "ST-LINK skip marker"
assert_contains "$report" "## staircase preflight" \
  "staircase preflight section"
assert_contains "$report" "PREFLIGHT_READY=no" \
  "staircase preflight readiness"
assert_contains "$report" "PREFLIGHT_NEXT_ACTION=run_tools_diagnose_swd" \
  "staircase preflight next action"
assert_contains "$report" "## micro-ROS 配置快照" \
  "micro-ROS config section"
assert_contains "$report" "## 固件静态内存矩阵" \
  "firmware size matrix section"
assert_contains "$report" "### 当前 ELF ROSIDL metadata 拆分" \
  "current ELF ROSIDL metadata breakdown section"
assert_contains "$report" "toplevel_type_raw_source" \
  "current ELF ROSIDL metadata raw source row"
assert_contains "$report" "## micro-ROS 栈候选" \
  "micro-ROS stack candidates section"
assert_contains "$report" "## 固件优化推荐" \
  "firmware optimization recommendations section"
assert_contains "$report" "CANDIDATE microros_stack_min_static" \
  "firmware stack recommendation row"
assert_contains "$report" "CANDIDATE rosidl_raw_source_metadata" \
  "firmware ROSIDL raw source recommendation row"
assert_contains "$report" "## executor spin timeout 候选" \
  "executor spin-timeout candidates section"
assert_contains "$report" "## linker heap/MSP 预留候选" \
  "linker heap/MSP reserve candidates section"
assert_contains "$report" "## combined stack/linker 内存候选" \
  "combined stack/linker memory candidates section"
assert_contains "$report" "combined_stack_linker_min_static" \
  "combined stack/linker recommendation row"
assert_contains "$report" "meta_stream_history=2" \
  "micro-ROS stream history"
if [ -d "$ROOT/firmware/f103-microros/ThirdParty/microros/include/exo_motor_msgs" ]; then
  expected_generated_stream_history="generated_stream_history=in:4/out:4"
else
  expected_generated_stream_history="generated_stream_history=in:2/out:2"
fi
assert_contains "$report" "$expected_generated_stream_history" \
  "generated stream history"
assert_contains "$report" "## overnight no-flash 趋势" \
  "overnight section"
assert_contains "$report" "overnight_watch_contract" \
  "overnight contract status"
assert_contains "$report" "## 活跃 overnight watcher" \
  "active overnight watcher section"
assert_contains "$report" "next_wake_at" \
  "active watcher freshness fields"
assert_contains "$report" "## 最新 topic endpoint QoS" \
  "topic endpoint QoS section"
assert_contains "$report" "PC catch-up events/extra" \
  "PC catch-up metric in latest communication section"
assert_contains "$report" "duplicate node warning" \
  "duplicate node warning field"
assert_contains "$report" "## 通信优化推荐" \
  "communication optimization recommendation section"
assert_contains "$report" "CANDIDATE wire_budget_200hz_status40_921600" \
  "communication wire budget recommendation row"
assert_contains "$report" "CANDIDATE motor_m2_wire_budget_200hz_state50_health5_921600" \
  "M2 motor communication recommendation row"
assert_contains "$report" "CANDIDATE staircase_acceptance_contract" \
  "communication staircase acceptance recommendation row"
assert_contains "$report" "## M2 micro-ROS motor 状态" \
  "M2 motor status section"
assert_contains "$report" "generated exo_motor_msgs headers" \
  "M2 generated headers status"
assert_contains "$report" "firmware/f103-microros/colcon.motor.notypedesc.meta" \
  "M2 motor meta path"
assert_contains "$report" "### M2 motor build size" \
  "M2 motor build size section"
assert_contains "$report" "### M2 motor memory optimization candidate" \
  "M2 motor optimized build size section"
assert_contains "$report" "# M2 Motor Wire Budget Estimate" \
  "M2 motor wire budget output"
assert_contains "$report" "200Hz target + 50Hz state + 5Hz health" \
  "M2 motor unresolved communication budget"
assert_contains "$report" "graph/QoS" \
  "graph QoS source"
assert_contains "$report" "## 最近 PASS 通信基线" \
  "latest PASS communication baseline section"
assert_contains "$report" "latest PASS baseline tag" \
  "latest PASS baseline source"
assert_contains "$report" "latest watch summary" \
  "latest watch summary source"
assert_contains "$report" "long overnight summary" \
  "long overnight summary source"
assert_contains "$report" "## staircase 阶梯汇总" \
  "staircase section"
assert_contains "$report" "contract：FAIL com_staircase_contract" \
  "staircase acceptance contract status"
assert_contains "$report" "pc_cmd_catchup_events=0" \
  "staircase catch-up event acceptance gate"
assert_contains "$report" "pc_cmd_catchup_extra=0" \
  "staircase catch-up extra acceptance gate"
assert_contains "$report" "pc_wire_gap_p99_ms<=20" \
  "staircase PC p99 gap acceptance gate"
assert_contains "$report" "target_rx_hz 和 pc_target_window_hz" \
  "staircase target-rate acceptance gate"
assert_contains "$report" "--max-wire-baud-util-pct 30" \
  "optional wire baud utilization acceptance gate"
assert_contains "$report" "missing_required_stage" \
  "staircase contract missing stage reason"
if find "$ROOT/log/com-perf" -maxdepth 1 -type f -name '*.wire.log' | grep -q .; then
  assert_contains "$report" "full echo wire ms" \
    "wire-time budget columns"
fi
assert_contains "$report" "## 未解决项" \
  "unresolved section"
assert_contains "$report" "staircase preflight 未 ready" \
  "unresolved preflight blocker"
assert_contains "$report" "1000Hz PC-only scheduler probe" \
  "1000Hz exploratory scheduler unresolved note"
assert_contains "$report" "M2 motor 真机首轮" \
  "M2 motor runtime next step"
assert_contains "$report" "tools/recommend-motor-m2-smoke-command.sh" \
  "M2 motor smoke command generator in next steps"
assert_contains "$report" "tools/check-motor-m2-smoke-evidence.py" \
  "M2 motor smoke evidence checker in next steps"
assert_contains "$report" "/motor/tp_joint_target" \
  "M2 motor target topic in report"
assert_contains "$report" "tools/diagnose-swd.sh" \
  "SWD diagnostic command in next steps"
assert_contains "$report" "tools/recommend-staircase-command.sh" \
  "recommended staircase command in next steps"
assert_contains "$report" "tools/check-com-staircase-contract.py" \
  "recommended staircase contract command in next steps"
assert_contains "$report" "STAIRCASE_CONTRACT_ARGS" \
  "recommended staircase contract args in next steps"
assert_not_contains "$report" "division by zero" \
  "status report contract output"

fakebin="$TMPDIR/fakebin"
mkdir -p "$fakebin"
cat >"$fakebin/st-info" <<'EOF'
#!/usr/bin/env bash
echo "Found 0 stlink programmers"
EOF
chmod +x "$fakebin/st-info"
PATH="$fakebin:$PATH" OUTDIR="$TMPDIR" COM_STATUS_PROBE_STLINK=1 \
  "$ROOT/tools/com-status-report.sh" status_report_no_stlink >/dev/null
no_stlink_report="$TMPDIR/status_report_no_stlink.md"
assert_contains "$no_stlink_report" "status=bad_no_stlink" \
  "zero ST-LINK programmers must be reported as bad"
assert_contains "$no_stlink_report" "PREFLIGHT_READY=no" \
  "zero ST-LINK programmers must block staircase preflight"
assert_contains "$no_stlink_report" "PREFLIGHT_BLOCKER=swd_not_ok:bad_no_stlink" \
  "zero ST-LINK programmers must surface preflight blocker"

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
printf '%s\n' "$unresolved" | grep -Fq -- "staircase preflight 未 ready" || {
  echo "FAIL: unresolved summary missing preflight blocker" >&2
  exit 1
}
printf '%s\n' "$unresolved" | grep -Fq -- "1000Hz PC-only scheduler probe" || {
  echo "FAIL: unresolved summary missing 1000Hz exploratory scheduler note" >&2
  exit 1
}
if find "$ROOT/log/overnight-com-watch" -maxdepth 1 -type f -name '*.summary.md' \
    -print0 2>/dev/null | xargs -0r grep -q '^| .* | FAIL |'; then
  printf '%s\n' "$unresolved" | grep -Fq -- "overnight reliable/full-echo" || {
    echo "FAIL: unresolved summary missing overnight failure item" >&2
    exit 1
  }
fi

if find "$ROOT/log/overnight-com-watch" -maxdepth 1 -type f -name '*.log' | grep -q .; then
  assert_contains "$report" "### Verdict Summary" \
    "live overnight verdict summary"
fi

echo "PASS: communication status report tests"
