#!/usr/bin/env bash
# Generate a communication validation handoff report from current logs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTDIR="${OUTDIR:-$ROOT/log/handoff}"
TAG="${1:-handoff_$(date +%Y%m%d_%H%M)}"
REPORT="$OUTDIR/$TAG.md"
COM_LOGDIR="$ROOT/log/com-perf"
SIZE_LOGDIR="$ROOT/log/firmware-size-matrix"
STACK_LOGDIR="$ROOT/log/firmware-stack-sweep"
SPIN_TIMEOUT_LOGDIR="$ROOT/log/firmware-spin-timeout-sweep"
LINKER_RESERVE_LOGDIR="$ROOT/log/firmware-linker-reserve-sweep"
COMBINED_MEMORY_LOGDIR="$ROOT/log/firmware-combined-memory-sweep"
WATCH_LOGDIR="$ROOT/log/overnight-com-watch"
SCHED_LOGDIR="$ROOT/log/pc-scheduler-sweep"
STAIRCASE_LOGDIR="$ROOT/log/com-staircase"
FIRMWARE_ELF="$ROOT/firmware/f103-microros/build/f103-microros.elf"
MICROROS_META="$ROOT/firmware/f103-microros/colcon.meta"
MICROROS_UXR_CONFIG="$ROOT/firmware/f103-microros/ThirdParty/microros/include/uxr/client/config.h"
MICROROS_RMW_CONFIG="$ROOT/firmware/f103-microros/ThirdParty/microros/include/rmw_microxrcedds_c/config.h"
COM_STATUS_PROBE_STLINK="${COM_STATUS_PROBE_STLINK:-1}"
COM_STATUS_LONG_WATCH_MIN_SAMPLES="${COM_STATUS_LONG_WATCH_MIN_SAMPLES:-6}"

mkdir -p "$OUTDIR"

latest_file() {
  local dir="$1"
  local pattern="$2"
  find "$dir" -maxdepth 1 -type f -name "$pattern" -printf '%T@ %p\n' 2>/dev/null |
    sort -nr |
    awk 'NR == 1 {sub(/^[^ ]+ /, ""); print; exit}' || true
}

watch_sample_count() {
  local summary="$1"
  if [ ! -f "$summary" ]; then
    printf '0'
    return 0
  fi
  awk '/^- smoke samples:/ {print $4; found = 1; exit} END {if (!found) print 0}' "$summary"
}

latest_watch_summary_min_samples() {
  local min_samples="${1:-1}"
  local sample_count
  find "$WATCH_LOGDIR" -maxdepth 1 -type f -name '*.summary.md' -printf '%T@ %p\n' 2>/dev/null |
    sort -nr |
    while read -r _ path; do
      sample_count="$(watch_sample_count "$path")"
      if [ "$sample_count" -ge "$min_samples" ] 2>/dev/null; then
        printf '%s\n' "$path"
        break
      fi
    done
}

relpath() {
  local path="${1:-}"
  if [ -z "$path" ]; then
    printf '-'
  else
    printf '%s' "${path#$ROOT/}"
  fi
}

tag_from_log_file() {
  local path="${1:-}"
  local base
  if [ -z "$path" ]; then
    return 0
  fi
  base="$(basename "$path")"
  case "$base" in
    *.cmd.log) printf '%s' "${base%.cmd.log}" ;;
    *.sampler.log) printf '%s' "${base%.sampler.log}" ;;
    *.hz.log) printf '%s' "${base%.hz.log}" ;;
    *.wire.log) printf '%s' "${base%.wire.log}" ;;
    *) printf '%s' "$base" ;;
  esac
}

metric_from_line() {
  local line="$1"
  local key="$2"
  printf '%s\n' "$line" |
    tr ' ' '\n' |
    awk -F= -v key="$key" '$1 == key {print $2}' |
    tail -1
}

first_table_rows() {
  local file="$1"
  local rows="${2:-12}"
  if [ -f "$file" ]; then
    sed -n "1,${rows}p" "$file"
  else
    echo "-"
  fi
}

markdown_table_from_prefix() {
  local file="$1"
  local prefix="$2"
  if [ ! -f "$file" ]; then
    echo "-"
    return 0
  fi
  awk -v prefix="$prefix" '
    index($0, prefix) == 1 {in_table = 1}
    in_table && /^\|/ {print; next}
    in_table && !/^\|/ {exit}
  ' "$file"
}

markdown_table_from_text() {
  local prefix="$1"
  awk -v prefix="$prefix" '
    index($0, prefix) == 1 {in_table = 1}
    in_table && /^\|/ {print; next}
    in_table && !/^\|/ {exit}
  '
}

markdown_section_body_from_text() {
  local header="$1"
  awk -v header="$header" '
    $0 == header {in_section = 1; next}
    in_section && /^## / {exit}
    in_section {print}
  '
}

graph_qos_snapshot() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "-"
    return 0
  fi
  awk '
    /^--- after_pc_warmup ---/ {capture = 1; next}
    capture && /^--- after_/ {exit}
    capture && /^--- topic info -v / {print; next}
    capture && /^(Publisher count:|Subscription count:|Node name:|Endpoint type:|Unknown topic)/ {print; next}
    capture && /^  Reliability:/ {print; next}
  ' "$file"
}

graph_duplicate_node_warning() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "unknown: missing graph log"
    return 0
  fi
  if grep -q 'share an exact name' "$file"; then
    echo "detected: ROS graph 报告了重复节点名；在 no-reset/no-flash 的 agent 重启后，这通常可能是 graph discovery 残留。除非进程/串口证据也对应异常，否则先按 graph hygiene warning 处理。"
  else
    echo "none"
  fi
}

status_every_from_cmd_log() {
  local file="$1"
  if [ ! -f "$file" ]; then
    return 0
  fi
  grep 'status_every_n=' "$file" |
    head -1 |
    awk '{
      for (idx = 1; idx <= NF; idx++) {
        if ($idx ~ /^status_every_n=/) {
          split($idx, parts, "=")
          print parts[2]
          exit
        }
      }
    }'
}

expected_cmd_hz_from_summary() {
  local summary="$1"
  local expected
  expected="$(metric_from_line "$summary" target_rate_hz)"
  if ! awk -v value="${expected:-0}" 'BEGIN {exit !((value + 0) > 0)}'; then
    expected="$(metric_from_line "$summary" wire_rate_hz)"
  fi
  printf '%s' "$expected"
}

perf_contract_for_tag() {
  local tag="$1"
  local cmd_log="$COM_LOGDIR/$tag.cmd.log"
  local summary expected_cmd_hz status_every_n
  if [ -z "$tag" ] || [ ! -f "$cmd_log" ] ||
      [ ! -x "$ROOT/tools/check-com-perf-contract.sh" ]; then
    return 0
  fi
  summary="$(grep 'link-health summary' "$cmd_log" | tail -1 || true)"
  expected_cmd_hz="$(expected_cmd_hz_from_summary "$summary")"
  status_every_n="$(status_every_from_cmd_log "$cmd_log")"
  (cd "$ROOT" && EXPECTED_CMD_RATE_HZ="${expected_cmd_hz:-20}" \
    STATUS_EVERY_N="${status_every_n:-1}" \
    tools/check-com-perf-contract.sh "$tag" 2>&1 || true)
}

latest_passing_perf_tag() {
  local max_logs="${1:-30}"
  local path tag contract
  find "$COM_LOGDIR" -maxdepth 1 -type f -name '*.cmd.log' -printf '%T@ %p\n' 2>/dev/null |
    sort -nr |
    awk -v max="$max_logs" 'NR <= max {sub(/^[^ ]+ /, ""); print}' |
    while read -r path; do
      tag="$(tag_from_log_file "$path")"
      if [ ! -f "$COM_LOGDIR/$tag.sampler.log" ]; then
        continue
      fi
      contract="$(perf_contract_for_tag "$tag")"
      case "$contract" in
        PASS\ tag=*)
          printf '%s\n' "$tag"
          break
          ;;
      esac
    done
}

firmware_ram_categories() {
  if [ ! -f "$FIRMWARE_ELF" ]; then
    echo "-"
    return 0
  fi
  if [ ! -x "$ROOT/tools/firmware-size-report.sh" ]; then
    echo "-"
    return 0
  fi

  local size_report
  size_report="$("$ROOT/tools/firmware-size-report.sh" "$FIRMWARE_ELF" 2>/dev/null || true)"
  printf '%s\n' "$size_report" |
    awk '
      /^ram_category_summary:/ {in_section = 1; print; next}
      in_section && NF == 0 {exit}
      in_section {print}
    '
}

firmware_ram_category_symbols() {
  if [ ! -f "$FIRMWARE_ELF" ]; then
    echo "-"
    return 0
  fi
  if [ ! -x "$ROOT/tools/firmware-size-report.sh" ]; then
    echo "-"
    return 0
  fi

  local size_report
  size_report="$(CATEGORY_LIMIT=5 "$ROOT/tools/firmware-size-report.sh" "$FIRMWARE_ELF" 2>/dev/null || true)"
  printf '%s\n' "$size_report" |
    awk '
      /^largest_ram_symbols_by_category:/ {in_section = 1; print; next}
      /^largest_ram_symbols:/ {exit}
      in_section {print}
    '
}

firmware_rosidl_metadata_breakdown() {
  if [ ! -f "$FIRMWARE_ELF" ]; then
    echo "-"
    return 0
  fi
  if [ ! -x "$ROOT/tools/firmware-size-report.sh" ]; then
    echo "-"
    return 0
  fi

  local size_report
  size_report="$(CATEGORY_LIMIT=5 "$ROOT/tools/firmware-size-report.sh" "$FIRMWARE_ELF" 2>/dev/null || true)"
  printf '%s\n' "$size_report" |
    awk '
      /^rosidl_type_metadata_breakdown:/ {in_section = 1; print; next}
      in_section && NF == 0 {exit}
      in_section {print}
    '
}

firmware_optimization_recommendations() {
  if [ ! -x "$ROOT/tools/recommend-firmware-optimizations.sh" ]; then
    echo "-"
    return 0
  fi
  "$ROOT/tools/recommend-firmware-optimizations.sh" 2>/dev/null |
    awk '/^RECOMMENDATION / || /^CANDIDATE / {print}'
}

communication_optimization_recommendations() {
  if [ ! -x "$ROOT/tools/recommend-communication-optimizations.py" ]; then
    echo "-"
    return 0
  fi
  "$ROOT/tools/recommend-communication-optimizations.py" 2>/dev/null |
    awk '/^RECOMMENDATION / || /^CANDIDATE / {print}'
}

staircase_contract_status() {
  if [ -z "$latest_staircase_contract_metrics" ] ||
      [ ! -f "$latest_staircase_contract_metrics" ]; then
    echo "FAIL com_staircase_contract reason=missing_metrics"
    return 0
  fi
  if [ ! -x "$ROOT/tools/check-com-staircase-contract.py" ]; then
    echo "FAIL com_staircase_contract reason=missing_checker"
    return 0
  fi
  "$ROOT/tools/check-com-staircase-contract.py" \
    "$latest_staircase_contract_metrics" 2>&1 || true
}

cmake_arg_value() {
  local file="$1"
  local key="$2"
  if [ ! -f "$file" ]; then
    return 0
  fi
  grep -F -- "-D$key=" "$file" |
    head -1 |
    sed -E "s/.*-D${key}=([^\" ]+).*/\\1/"
}

define_value() {
  local file="$1"
  local key="$2"
  if [ ! -f "$file" ]; then
    return 0
  fi
  awk -v key="$key" '$1 == "#define" && $2 == key && $3 != "" {value = $3} END {print value}' "$file"
}

microros_config_summary() {
  local single_ts out_be out_rel in_be in_rel mtu history creation gen_mtu gen_hist_in gen_hist_out
  single_ts="$(cmake_arg_value "$MICROROS_META" ROSIDL_TYPESUPPORT_SINGLE_TYPESUPPORT)"
  out_be="$(cmake_arg_value "$MICROROS_META" UCLIENT_MAX_OUTPUT_BEST_EFFORT_STREAMS)"
  out_rel="$(cmake_arg_value "$MICROROS_META" UCLIENT_MAX_OUTPUT_RELIABLE_STREAMS)"
  in_be="$(cmake_arg_value "$MICROROS_META" UCLIENT_MAX_INPUT_BEST_EFFORT_STREAMS)"
  in_rel="$(cmake_arg_value "$MICROROS_META" UCLIENT_MAX_INPUT_RELIABLE_STREAMS)"
  mtu="$(cmake_arg_value "$MICROROS_META" UCLIENT_CUSTOM_TRANSPORT_MTU)"
  history="$(cmake_arg_value "$MICROROS_META" RMW_UXRCE_STREAM_HISTORY)"
  creation="$(cmake_arg_value "$MICROROS_META" RMW_UXRCE_CREATION_MODE)"
  gen_mtu="$(define_value "$MICROROS_UXR_CONFIG" UXR_CONFIG_CUSTOM_TRANSPORT_MTU)"
  gen_hist_in="$(define_value "$MICROROS_RMW_CONFIG" RMW_UXRCE_STREAM_HISTORY_INPUT)"
  gen_hist_out="$(define_value "$MICROROS_RMW_CONFIG" RMW_UXRCE_STREAM_HISTORY_OUTPUT)"

  cat <<EOF
meta_single_typesupport=${single_ts:-unknown}
meta_best_effort_streams=out:${out_be:-unknown}/in:${in_be:-unknown}
meta_reliable_streams=out:${out_rel:-unknown}/in:${in_rel:-unknown}
meta_custom_transport_mtu=${mtu:-unknown}
meta_stream_history=${history:-unknown}
meta_creation_mode=${creation:-unknown}
generated_custom_transport_mtu=${gen_mtu:-unknown}
generated_stream_history=in:${gen_hist_in:-unknown}/out:${gen_hist_out:-unknown}
EOF
}

probe_stlink() {
  if [ "$COM_STATUS_PROBE_STLINK" = "0" ]; then
    echo "status=skipped reason=COM_STATUS_PROBE_STLINK=0"
    return 0
  fi
  if ! command -v st-info >/dev/null; then
    echo "status=unknown reason=st-info-not-found"
    return 0
  fi

  local out rc
  set +e
  out="$(timeout 15 st-info --probe 2>&1)"
  rc=$?
  set -e

  if [ "$rc" -ne 0 ]; then
    echo "status=bad rc=$rc"
    printf '%s\n' "$out"
    return 0
  fi

  if printf '%s\n' "$out" | grep -Eq 'dev-type:[[:space:]]+unknown|chipid:[[:space:]]+0x000'; then
    echo "status=bad_unknown_target"
  else
    echo "status=ok"
  fi
  printf '%s\n' "$out"
}

serial_presence() {
  local dev
  for dev in /dev/ttyUSB0 /dev/ttyACM0; do
    if [ -e "$dev" ]; then
      printf '%s=present ' "$dev"
    else
      printf '%s=missing ' "$dev"
    fi
  done
  echo
}

usb_snapshot() {
  if command -v lsusb >/dev/null; then
    lsusb 2>&1 || true
  else
    echo "lsusb not found"
  fi
}

serial_lsof() {
  if command -v lsof >/dev/null; then
    local out
    out="$(lsof /dev/ttyUSB0 /dev/ttyACM0 2>/dev/null || true)"
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
    else
      echo "no ttyUSB0/ttyACM0 lsof users"
    fi
  else
    echo "lsof not found"
  fi
}

git_branch="$(git -C "$ROOT" branch --show-current 2>/dev/null || echo unknown)"
git_rev="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
git_status="$(git -C "$ROOT" status --short 2>/dev/null || true)"
git_recent="$(git -C "$ROOT" log --oneline -8 2>/dev/null || true)"
if [ -z "$git_status" ]; then
  git_status="clean"
fi
if [ -z "$git_recent" ]; then
  git_recent="unknown"
fi

latest_sampler="$(latest_file "$COM_LOGDIR" '*.sampler.log')"
latest_hz="$(latest_file "$COM_LOGDIR" '*.hz.log')"
latest_cmd="$(latest_file "$COM_LOGDIR" '*.cmd.log')"
latest_tag="$(tag_from_log_file "$latest_cmd")"
latest_graph=""
if [ -n "$latest_tag" ] && [ -f "$COM_LOGDIR/$latest_tag.graph.log" ]; then
  latest_graph="$COM_LOGDIR/$latest_tag.graph.log"
fi
latest_wire=""
if [ -n "$latest_tag" ] && [ -f "$COM_LOGDIR/$latest_tag.wire.log" ]; then
  latest_wire="$COM_LOGDIR/$latest_tag.wire.log"
fi
latest_any_wire="$(latest_file "$COM_LOGDIR" '*.wire.log')"
latest_size_md="$(latest_file "$SIZE_LOGDIR" '*.md')"
latest_stack_md="$(latest_file "$STACK_LOGDIR" '*.md')"
latest_spin_timeout_md="$(latest_file "$SPIN_TIMEOUT_LOGDIR" '*.md')"
latest_linker_reserve_md="$(latest_file "$LINKER_RESERVE_LOGDIR" '*.md')"
latest_combined_memory_md="$(latest_file "$COMBINED_MEMORY_LOGDIR" '*.md')"
latest_watch_summary="$(latest_file "$WATCH_LOGDIR" '*.summary.md')"
latest_watch_log=""
if [ -n "$latest_watch_summary" ]; then
  latest_watch_log="${latest_watch_summary%.summary.md}.log"
fi
long_watch_summary="$(latest_watch_summary_min_samples "$COM_STATUS_LONG_WATCH_MIN_SAMPLES")"
long_watch_log=""
if [ -n "$long_watch_summary" ]; then
  long_watch_log="${long_watch_summary%.summary.md}.log"
fi
baseline_watch_summary="${long_watch_summary:-$latest_watch_summary}"
baseline_watch_log="${long_watch_log:-$latest_watch_log}"
latest_scheduler_metrics="$(latest_file "$SCHED_LOGDIR" '*.metrics.md')"
latest_staircase_metrics="$(latest_file "$STAIRCASE_LOGDIR" '*.metrics.md')"
latest_staircase_contract_metrics="$(latest_file "$STAIRCASE_LOGDIR" '*.metrics.csv')"
latest_staircase_summary="$(latest_file "$STAIRCASE_LOGDIR" '*.summary.log')"
ram_categories="$(firmware_ram_categories)"
rosidl_metadata_breakdown="$(firmware_rosidl_metadata_breakdown)"
ram_category_symbols="$(firmware_ram_category_symbols)"
firmware_optimization_recs="$(firmware_optimization_recommendations)"
communication_optimization_recs="$(communication_optimization_recommendations)"
staircase_contract="$(staircase_contract_status)"
microros_config="$(microros_config_summary)"
topic_qos_snapshot="$(graph_qos_snapshot "$latest_graph")"
duplicate_node_warning="$(graph_duplicate_node_warning "$latest_graph")"
latest_watch_live_summary=""
if [ -n "$latest_watch_log" ] && [ -f "$latest_watch_log" ] &&
    [ -x "$ROOT/tools/summarize-overnight-com-watch.sh" ]; then
  latest_watch_live_summary="$(cd "$ROOT" && tools/summarize-overnight-com-watch.sh "$latest_watch_log" 2>/dev/null || true)"
fi
latest_watch_summary_source="$latest_watch_live_summary"
if [ -z "$latest_watch_summary_source" ] && [ -n "$latest_watch_summary" ] &&
    [ -f "$latest_watch_summary" ]; then
  latest_watch_summary_source="$(cat "$latest_watch_summary")"
fi
latest_watch_counts=""
latest_watch_fail_count=""
latest_watch_reasons=""
if [ -n "$latest_watch_summary_source" ]; then
  latest_watch_counts="$(printf '%s\n' "$latest_watch_summary_source" |
    awk -F': ' '/PASS\/WARN\/FAIL\/INFO/ {print $2; exit}')"
  latest_watch_fail_count="$(printf '%s\n' "$latest_watch_counts" |
    awk -F/ 'NF >= 3 {print $3}')"
  latest_watch_reasons="$(printf '%s\n' "$latest_watch_summary_source" |
    awk -F': ' '/^- reasons:/ {print $2; exit}')"
fi
overnight_live_summary=""
if [ -n "$baseline_watch_log" ] && [ -f "$baseline_watch_log" ] &&
    [ -x "$ROOT/tools/summarize-overnight-com-watch.sh" ]; then
  overnight_live_summary="$(cd "$ROOT" && tools/summarize-overnight-com-watch.sh "$baseline_watch_log" 2>/dev/null || true)"
fi
overnight_summary_source="$overnight_live_summary"
if [ -z "$overnight_summary_source" ] && [ -n "$baseline_watch_summary" ] &&
    [ -f "$baseline_watch_summary" ]; then
  overnight_summary_source="$(cat "$baseline_watch_summary")"
fi
overnight_counts=""
overnight_fail_count=""
overnight_reasons=""
if [ -n "$overnight_summary_source" ]; then
  overnight_counts="$(printf '%s\n' "$overnight_summary_source" |
    awk -F': ' '/PASS\/WARN\/FAIL\/INFO/ {print $2; exit}')"
  overnight_fail_count="$(printf '%s\n' "$overnight_counts" |
    awk -F/ 'NF >= 3 {print $3}')"
  overnight_reasons="$(printf '%s\n' "$overnight_summary_source" |
    awk -F': ' '/^- reasons:/ {print $2; exit}')"
fi
latest_is_scheduler_experiment=0
case "${latest_tag:-}" in
  scheduler_*|pc_sched_*|latest_gate_*)
    latest_is_scheduler_experiment=1
    ;;
esac

scheduler_comparison_tags=""
for scheduler_tag in latest_gate_taskset_20hz_smoke scheduler_chrt_batch_smoke; do
  if [ -f "$COM_LOGDIR/$scheduler_tag.cmd.log" ] &&
      [ -f "$COM_LOGDIR/$scheduler_tag.sampler.log" ]; then
    scheduler_comparison_tags="$scheduler_comparison_tags $scheduler_tag"
  fi
done
scheduler_comparison_md=""
if [ -n "$scheduler_comparison_tags" ] &&
    [ -x "$ROOT/tools/summarize-com-perf.sh" ]; then
  scheduler_comparison_md="$(cd "$ROOT" && PERF_EXPECTED_RATE_HZ=20 \
    tools/summarize-com-perf.sh $scheduler_comparison_tags 2>/dev/null || true)"
fi

sampler_summary=""
if [ -f "$latest_sampler" ]; then
  sampler_summary="$(grep 'status_sampler:' "$latest_sampler" | tail -1 || true)"
fi
status_hz=""
if [ -f "$latest_hz" ]; then
  status_hz="$(awk '/average rate:/ {rate=$3} END {print rate}' "$latest_hz")"
fi
link_summary=""
if [ -f "$latest_cmd" ]; then
  link_summary="$(grep 'link-health summary' "$latest_cmd" | tail -1 || true)"
fi
pc_wire_gap_p95_ms="$(metric_from_line "$link_summary" wire_gap_p95_ms)"
pc_wire_gap_p99_ms="$(metric_from_line "$link_summary" wire_gap_p99_ms)"
pc_wire_gap_max_ms="$(metric_from_line "$link_summary" wire_gap_max_ms)"
pc_cmd_catchup_events="$(metric_from_line "$link_summary" cmd_catchup_events)"
pc_cmd_catchup_extra="$(metric_from_line "$link_summary" cmd_catchup_extra)"
latest_contract=""
if [ -n "$latest_tag" ]; then
  latest_contract="$(perf_contract_for_tag "$latest_tag")"
fi
latest_pass_tag="$(latest_passing_perf_tag 30)"
latest_pass_cmd=""
latest_pass_sampler=""
latest_pass_hz=""
latest_pass_graph=""
latest_pass_contract=""
latest_pass_sampler_summary=""
latest_pass_status_hz=""
latest_pass_link_summary=""
if [ -n "$latest_pass_tag" ]; then
  latest_pass_cmd="$COM_LOGDIR/$latest_pass_tag.cmd.log"
  latest_pass_sampler="$COM_LOGDIR/$latest_pass_tag.sampler.log"
  latest_pass_hz="$COM_LOGDIR/$latest_pass_tag.hz.log"
  latest_pass_graph="$COM_LOGDIR/$latest_pass_tag.graph.log"
  latest_pass_contract="$(perf_contract_for_tag "$latest_pass_tag")"
  if [ -f "$latest_pass_sampler" ]; then
    latest_pass_sampler_summary="$(grep 'status_sampler:' "$latest_pass_sampler" | tail -1 || true)"
  fi
  if [ -f "$latest_pass_hz" ]; then
    latest_pass_status_hz="$(awk '/average rate:/ {rate=$3} END {print rate}' "$latest_pass_hz")"
  fi
  if [ -f "$latest_pass_cmd" ]; then
    latest_pass_link_summary="$(grep 'link-health summary' "$latest_pass_cmd" | tail -1 || true)"
  fi
fi
wire_metrics=""
if [ -f "$latest_wire" ]; then
  wire_metrics="$(grep '^METRICS ' "$latest_wire" | tail -1 || true)"
fi
wire_budget_source="$latest_wire"
if [ -z "$wire_budget_source" ]; then
  wire_budget_source="$latest_any_wire"
fi
wire_budget_matrix=""
if [ -n "$wire_budget_source" ] && [ -f "$wire_budget_source" ] &&
    [ -x "$ROOT/tools/com-wire-budget.py" ]; then
  wire_budget_source_rel="${wire_budget_source#$ROOT/}"
  wire_budget_tag="$(tag_from_log_file "$wire_budget_source")"
  wire_budget_cmd="$COM_LOGDIR/$wire_budget_tag.cmd.log"
  wire_budget_sampler="$COM_LOGDIR/$wire_budget_tag.sampler.log"
  wire_budget_summary=""
  wire_budget_sampler_summary=""
  wire_budget_baseline_cmd_hz=""
  wire_budget_baseline_status_hz=""
  if [ -f "$wire_budget_cmd" ]; then
    wire_budget_summary="$(grep 'link-health summary' "$wire_budget_cmd" | tail -1 || true)"
    wire_budget_baseline_cmd_hz="$(metric_from_line "$wire_budget_summary" target_rate_hz)"
  fi
  if [ -f "$wire_budget_sampler" ]; then
    wire_budget_sampler_summary="$(grep 'status_sampler:' "$wire_budget_sampler" | tail -1 || true)"
    wire_budget_baseline_status_hz="$(metric_from_line "$wire_budget_sampler_summary" rate_hz)"
  fi
  wire_budget_baseline_cmd_hz="${wire_budget_baseline_cmd_hz:-20}"
  wire_budget_baseline_status_hz="${wire_budget_baseline_status_hz:-20}"
  wire_budget_matrix="$(cd "$ROOT" && tools/com-wire-budget.py \
    --wire-log "$wire_budget_source_rel" \
    --baseline-cmd-hz "$wire_budget_baseline_cmd_hz" \
    --baseline-status-hz "$wire_budget_baseline_status_hz" \
    --cmd-hz 200,500,1000 \
    --status-every-n 1,10,20,40 \
    --baud 921600,2000000 \
    --max-baud-util-pct 30 \
    --show-wire-time 2>/dev/null || true)"
fi

recovery_sampler="$COM_LOGDIR/noflash_recovery_20hz_after_200hz.sampler.log"
recovery_hz="$COM_LOGDIR/noflash_recovery_20hz_after_200hz.hz.log"
recovery_cmd="$COM_LOGDIR/noflash_recovery_20hz_after_200hz.cmd.log"
stress_sampler="$COM_LOGDIR/noflash_200hz_reliable_v6.sampler.log"
stress_wire="$COM_LOGDIR/noflash_200hz_reliable_v6.wire.log"
stress_cmd="$COM_LOGDIR/noflash_200hz_reliable_v6.cmd.log"

recovery_sampler_summary=""
recovery_status_hz=""
recovery_link_summary=""
if [ -f "$recovery_sampler" ]; then
  recovery_sampler_summary="$(grep 'status_sampler:' "$recovery_sampler" | tail -1 || true)"
fi
if [ -f "$recovery_hz" ]; then
  recovery_status_hz="$(awk '/average rate:/ {rate=$3} END {print rate}' "$recovery_hz")"
fi
if [ -f "$recovery_cmd" ]; then
  recovery_link_summary="$(grep 'link-health summary' "$recovery_cmd" | tail -1 || true)"
fi

stress_sampler_summary=""
stress_wire_metrics=""
stress_link_summary=""
if [ -f "$stress_sampler" ]; then
  stress_sampler_summary="$(grep 'status_sampler:' "$stress_sampler" | tail -1 || true)"
fi
if [ -f "$stress_wire" ]; then
  stress_wire_metrics="$(grep '^METRICS ' "$stress_wire" | tail -1 || true)"
fi
if [ -f "$stress_cmd" ]; then
  stress_link_summary="$(grep 'link-health summary' "$stress_cmd" | tail -1 || true)"
fi

stlink_probe="$(probe_stlink)"
serial_status="$(serial_presence)"
usb_status="$(usb_snapshot)"
serial_users="$(serial_lsof)"

{
  echo "# 通信验证交接报告"
  echo
  echo "- 生成时间：$(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "- 仓库版本：branch=$git_branch rev=$git_rev"
  echo "- 工作区状态：$git_status"
  echo "- 串口设备：$serial_status"
  echo
  echo "## 最近提交"
  echo
  echo '```text'
  printf '%s\n' "$git_recent"
  echo '```'
  echo
  echo "## USB/串口占用"
  echo
  echo '```text'
  printf '%s\n' "$usb_status"
  echo
  printf '%s\n' "$serial_users"
  echo '```'
  echo
  echo "## ST-LINK/SWD"
  echo
  echo '```text'
  printf '%s\n' "$stlink_probe"
  echo '```'
  echo
  echo "结论：如果出现 \`status=bad_unknown_target\`、\`chipid: 0x000\` 或 \`dev-type: unknown\`，说明 ST-LINK 本身可见，但 SWD 没读到 STM32 目标；此时不要阻塞 ROS/串口 no-flash 验证，但不能烧录新固件或复测运行期栈水位。"
  echo
  echo "## 最近日志"
  echo
  echo "- latest tag：${latest_tag:-unknown}"
  echo "- sampler：$(relpath "$latest_sampler")"
  echo "- topic hz：$(relpath "$latest_hz")"
  echo "- PC cmd：$(relpath "$latest_cmd")"
  echo "- graph/QoS：$(relpath "$latest_graph")"
  echo "- same-tag wire stats：$(relpath "$latest_wire")"
  echo "- latest standalone wire stats：$(relpath "$latest_any_wire")"
  echo "- latest PASS baseline tag：${latest_pass_tag:-unknown}"
  echo "- size matrix：$(relpath "$latest_size_md")"
  echo "- stack sweep：$(relpath "$latest_stack_md")"
  echo "- spin timeout sweep：$(relpath "$latest_spin_timeout_md")"
  echo "- linker reserve sweep：$(relpath "$latest_linker_reserve_md")"
  echo "- combined memory sweep：$(relpath "$latest_combined_memory_md")"
  echo "- latest watch summary：$(relpath "$latest_watch_summary")"
  echo "- long overnight summary：$(relpath "$baseline_watch_summary")"
  echo "- PC scheduler sweep：$(relpath "$latest_scheduler_metrics")"
  echo "- staircase metrics：$(relpath "$latest_staircase_metrics")"
  echo "- staircase contract CSV：$(relpath "$latest_staircase_contract_metrics")"
  echo "- staircase summary：$(relpath "$latest_staircase_summary")"
  echo
  echo "## 最新通信指标"
  echo
  echo "- ros2 topic hz status_hz=${status_hz:-unknown}"
  echo "- sampler：${sampler_summary:-unknown}"
  echo "- LinkHealth：${link_summary:-unknown}"
  echo "- PC publish gap p95/p99/max ms：${pc_wire_gap_p95_ms:-unknown}/${pc_wire_gap_p99_ms:-unknown}/${pc_wire_gap_max_ms:-unknown}"
  echo "- PC catch-up events/extra：${pc_cmd_catchup_events:-unknown}/${pc_cmd_catchup_extra:-unknown}"
  echo "- same-tag wire：${wire_metrics:-unknown}"
  echo "- perf contract：${latest_contract:-unknown}"
  if [ "$latest_is_scheduler_experiment" -eq 1 ]; then
    echo
    echo "说明：latest tag 是调度/健康门槛实验样本，只代表最后一次运行；PC 调度结论请看下面的 sweep/短测对照表。"
  fi
  echo
  echo "## 最近 PASS 通信基线"
  echo
  if [ -n "$latest_pass_tag" ]; then
    echo "- tag：$latest_pass_tag"
    echo "- ros2 topic hz status_hz=${latest_pass_status_hz:-unknown}"
    echo "- sampler：${latest_pass_sampler_summary:-unknown}"
    echo "- LinkHealth：${latest_pass_link_summary:-unknown}"
    echo "- graph/QoS：$(relpath "$latest_pass_graph")"
    echo "- perf contract：${latest_pass_contract:-unknown}"
    if [ "$latest_pass_tag" != "$latest_tag" ]; then
      echo
      echo "说明：latest tag 可能是故意采集的失败/压力样本；这个 section 用最近一个 contract PASS 样本表示基础链路健康基线。"
    fi
  else
    echo "- 未找到最近 PASS 的通信样本。"
  fi
  echo
  echo "## 最新 topic endpoint QoS"
  echo
  echo "来源：$(relpath "$latest_graph")"
  echo
  echo "- duplicate node warning：$duplicate_node_warning"
  echo
  echo '```text'
  printf '%s\n' "$topic_qos_snapshot"
  echo '```'
  echo
  echo "## 通信优化推荐"
  echo
  echo '```text'
  printf '%s\n' "$communication_optimization_recs"
  echo '```'
  echo
  echo "## 线速预算外推"
  echo
  echo "来源：$(relpath "$wire_budget_source")"
  echo
  if [ -n "$wire_budget_matrix" ]; then
    printf '%s\n' "$wire_budget_matrix"
    echo
  else
    echo "- missing wire budget: no usable .wire.log"
    echo
  fi
  if [ -n "$latest_watch_summary" ] && [ "$latest_watch_summary" != "$baseline_watch_summary" ]; then
    echo "## 最近 watch/no-flash 趋势"
    echo
    echo "来源：$(relpath "$latest_watch_log")"
    echo
    if [ -n "$latest_watch_live_summary" ]; then
      echo "### Verdict Summary"
      echo
      printf '%s\n' "$latest_watch_live_summary" |
        markdown_section_body_from_text "## Verdict Summary"
      echo
      echo "### Failure Events"
      echo
      printf '%s\n' "$latest_watch_live_summary" |
        markdown_section_body_from_text "## Failure Events"
      echo
      printf '%s\n' "$latest_watch_live_summary" |
        markdown_table_from_text '| Tag |'
    else
      markdown_table_from_prefix "$latest_watch_summary" '| Tag |'
    fi
    echo
    echo "说明：这个 section 只代表最近一次 watch，可能是 mini-watch；长时间 baseline 见下一节。"
    echo
  fi
  echo "## overnight no-flash 趋势"
  echo
  echo "来源：$(relpath "$baseline_watch_log")"
  echo
  if [ -n "$overnight_live_summary" ]; then
    echo "### Verdict Summary"
    echo
    printf '%s\n' "$overnight_live_summary" |
      markdown_section_body_from_text "## Verdict Summary"
    echo
    echo "### Failure Events"
    echo
    printf '%s\n' "$overnight_live_summary" |
      markdown_section_body_from_text "## Failure Events"
    echo
    printf '%s\n' "$overnight_live_summary" |
      markdown_table_from_text '| Tag |'
  else
    markdown_table_from_prefix "$baseline_watch_summary" '| Tag |'
  fi
  echo
  echo "## PC 主机调度 sweep"
  echo
  echo "来源：$(relpath "$latest_scheduler_metrics")"
  echo
  markdown_table_from_prefix "$latest_scheduler_metrics" '| Tag |'
  echo
  echo "当前低权限候选优先观察 \`taskset -c 2\`：已有 sweep 中 baseline 出现 lost/duplicate，taskset 样本 clean；\`chrt -b 0\` 可作为对照，但当前短测 PC publish gap 长尾更大。"
  if [ -n "$scheduler_comparison_md" ]; then
    echo
    echo "### 调度短测对照"
    echo
    echo "判读：这里的 PASS 只表示短测未丢包/不跳号；调度优先级主要看 PC publish gap 的 p99/max 长尾和 sweep 中的 lost/duplicate。"
    echo
    printf '%s\n' "$scheduler_comparison_md"
  fi
  echo
  echo "## staircase 阶梯汇总"
  echo
  echo "来源：$(relpath "$latest_staircase_metrics")"
  echo
  echo "contract：$staircase_contract"
  echo "默认验收门槛：1/2/5/10kHz × 921600/2000000 latest-target；lost=0，duplicate=0，qos_incompatibility=0，pc_cmd_catchup_events=0，pc_cmd_catchup_extra=0。"
  echo
  markdown_table_from_prefix "$latest_staircase_metrics" '| Stage |'
  echo
  echo "说明：完整上板 staircase 需要 SWD 恢复；若当前表格只有 fallback/no-flash 或为空，表示还没有完成 1/2/5/10kHz 真机矩阵。"
  echo
  echo "## 已知关键样本"
  echo
  echo "### no-flash 200Hz reliable/status_every_1 压力样本"
  echo
  echo "- sampler：${stress_sampler_summary:-missing}"
  echo "- LinkHealth：${stress_link_summary:-missing}"
  echo "- wire：${stress_wire_metrics:-missing}"
  if [ -n "$stress_wire_metrics" ]; then
    echo "- 线速占用：total_serial_kbit_s=$(metric_from_line "$stress_wire_metrics" total_serial_kbit_s) kbit/s，baud_util_pct=$(metric_from_line "$stress_wire_metrics" baud_util_pct)%"
  fi
  echo
  echo "解释：这个样本证明 PC 侧可以约 200Hz 下发，MCU status seq 也能快速前进，但 full-echo 状态回传跟不上；高频控制应采用 latest-target + 状态降频/采样，而不是要求每条 200Hz 命令 reliable 回显。"
  echo
  echo "### no-flash 20Hz 恢复样本"
  echo
  echo "- ros2 topic hz status_hz=${recovery_status_hz:-missing}"
  echo "- sampler：${recovery_sampler_summary:-missing}"
  echo "- LinkHealth：${recovery_link_summary:-missing}"
  echo
  echo "解释：用于确认 200Hz 压力后链路能回到稳定 20Hz 基线。"
  echo
  echo "## 固件静态内存矩阵"
  echo
  echo "来源：$(relpath "$latest_size_md")"
  echo
  echo '```markdown'
  first_table_rows "$latest_size_md" 12
  echo '```'
  echo
  echo "## micro-ROS 配置快照"
  echo
  echo "来源：$(relpath "$MICROROS_META")"
  echo
  echo '```text'
  printf '%s\n' "$microros_config"
  echo '```'
  echo
  echo "说明：这些值影响通信效率和 SRAM。当前默认保留 best-effort stream、\`STREAM_HISTORY=2\`、\`CREATION_MODE=bin\`，是为了支持 200Hz latest-target profile 和 vanilla agent 建链；进一步压缩需重建 libmicroros 并重跑兼容性验证。"
  echo
  echo "### 当前 ELF RAM 分类"
  echo
  echo "来源：$(relpath "$FIRMWARE_ELF")"
  echo
  echo '```text'
  printf '%s\n' "$ram_categories"
  echo '```'
  echo
  echo "### 当前 ELF ROSIDL metadata 拆分"
  echo
  echo '```text'
  printf '%s\n' "$rosidl_metadata_breakdown"
  echo '```'
  echo
  echo "### 当前 ELF RAM 分类大项"
  echo
  echo '```text'
  printf '%s\n' "$ram_category_symbols"
  echo '```'
  echo
  echo "## 固件优化推荐"
  echo
  echo '```text'
  printf '%s\n' "$firmware_optimization_recs"
  echo '```'
  echo
  echo "## micro-ROS 栈候选"
  echo
  echo "来源：$(relpath "$latest_stack_md")"
  echo
  echo '```markdown'
  first_table_rows "$latest_stack_md" 8
  echo '```'
  echo
  echo "## executor spin timeout 候选"
  echo
  echo "来源：$(relpath "$latest_spin_timeout_md")"
  echo
  echo '```markdown'
  first_table_rows "$latest_spin_timeout_md" 8
  echo '```'
  echo
  echo "## linker heap/MSP 预留候选"
  echo
  echo "来源：$(relpath "$latest_linker_reserve_md")"
  echo
  echo '```markdown'
  first_table_rows "$latest_linker_reserve_md" 8
  echo '```'
  echo
  echo "## combined stack/linker 内存候选"
  echo "来源：$(relpath "$latest_combined_memory_md")"
  echo
  echo '```markdown'
  first_table_rows "$latest_combined_memory_md" 8
  echo '```'
  echo
  echo "## 未解决项"
  echo
  echo "- SWD 仍需恢复：当前无法 flash 新 profile，也无法读取高频运行期栈水位。"
  echo "- 10kHz/200Hz/best_effort/status_every_40 和 2Mbps profile 已能编译，但运行收益待 SWD 恢复后实测。"
  echo "- 1000Hz PC-only scheduler probe 当前只证明 PC 侧发包节拍候选（threads4 p99≈1.17ms/max≈5.02ms）；它尚未经过 matching best-effort firmware、2Mbps/921600 线速、MCU 接收率和 1/2/5/10kHz 本地闭环联合验证，不能替代 200Hz 上板验收默认。"
  echo "- UART read polling 候选 \`EXO_UART_READ_POLL_YIELDS=4\` 仅完成编译/size 验证，是否改善 RTT/gap 长尾待上板实测。"
  echo "- executor spin timeout 候选 \`EXO_EXECUTOR_SPIN_TIMEOUT_US=500/200/100\` 仅完成编译/size 验证，是否改善 RTT/gap 长尾待上板实测。"
  echo "- linker heap/MSP reserve 候选 \`EXO_NEWLIB_HEAP_BYTES=0\`、\`EXO_MSP_STACK_BYTES=512/768\` 仅完成静态验证；默认仍保持 512B/1024B，必须等 SWD 恢复后确认 MSP/ISR 栈和 newlib malloc 失败路径。"
  echo "- combined stack/linker 候选不能只把单项 saved_bytes 相加后直接采用；必须跑 combined sweep，并在同一个高频 firmware profile 下同时验证 HWM、MSP/heap 和 HardFault 行为。"
  echo "- 当前 ELF 中 \`rosidl_type_metadata\` 约 2.8KB RAM，是新的内存优化重点；但 \`ROSIDL_TYPESUPPORT_SINGLE_TYPESUPPORT\` 曾是 T5 HardFault/agent 兼容修复的一部分，需用独立 libmicroros rebuild 矩阵验证后再改默认。"
  echo "- DWT snapshot 算法已有 host-side 模型测试 \`tools/test-dwt-snapshot-model.sh\`，但真实 stamp 单调性仍需 SWD 恢复后做 >60s 静默恢复对抗。"
  echo "- idle stack 96 words、micro-ROS stack 704/640 words 目前是静态候选，必须上板用 \`tools/measure-stack-hwm.sh\` 复测后再设为默认。"
  if [ -n "$latest_watch_fail_count" ] && [ "$latest_watch_fail_count" -gt 0 ] 2>/dev/null &&
      [ -n "$latest_watch_summary" ] && [ "$latest_watch_summary" != "$baseline_watch_summary" ]; then
    echo "- 最近 watch/no-flash 短测也有失败样本：PASS/WARN/FAIL/INFO=${latest_watch_counts:-unknown}，reasons=${latest_watch_reasons:-unknown}。短测不能替代 overnight baseline，但可作为调度/链路候选的快速筛查。"
  fi
  if [ -n "$overnight_fail_count" ] && [ "$overnight_fail_count" -gt 0 ] 2>/dev/null; then
    echo "- overnight reliable/full-echo no-flash 仍有失败样本：PASS/WARN/FAIL/INFO=${overnight_counts:-unknown}，reasons=${overnight_reasons:-unknown}。这类长尾需继续用 sampler + PC publish gap + LinkHealth 交叉判断，并优先做 \`taskset\` 整夜对比。"
  fi
  echo "- latest-target 默认 \`cmd_catchup_max=0\`，优先避免补发 burst；\`cmd_catchup_max=1\` 只作为 best-effort/status decimation/sampled 的吞吐对比实验，不用于 reliable/status_every_1/full-echo 默认诊断。"
  echo "- 200Hz reliable/status_every_1/full-echo 不适合作为控制链路目标；后续验收重点应转向 latest-target 接收率、状态采样频率、长尾 gap、lost/duplicate/inflight。"
  echo
  echo "## 下一步建议"
  echo
  echo "1. 先跑只读 SWD 诊断：\`tools/diagnose-swd.sh\`；若要自动化 gate，用 \`STRICT=1 tools/diagnose-swd.sh\`。"
  echo "2. 若 \`SWD_STATUS\` 不是 \`ok\`，按诊断输出检查线缆、供电、BOOT/RESET、SWDIO/SWCLK/NRST、usbip 独占和 ST-LINK 连接状态。"
  echo "3. SWD 恢复后先生成推荐阶梯命令：\`tools/recommend-staircase-command.sh\`，再执行其中的 \`tools/run-com-staircase.sh ...\`。"
  echo "4. 高频 profile 跑通后读栈水位：\`tools/measure-stack-hwm.sh firmware/f103-microros/build/f103-microros.elf\`。"
  echo "5. 若 SWD 仍未恢复，继续 no-flash：\`BUILD_FIRMWARE=0 FLASH_FIRMWARE=0 tools/run-com-perf.sh noflash_\$(date +%H%M)\`。"
} >"$REPORT"

echo "[com-status-report] report=$REPORT"
