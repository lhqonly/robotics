#!/usr/bin/env bash
# Run the staged STM32 micro-ROS communication profiles.
#
# The full staircase flashes firmware for each local-loop frequency. If ST-LINK
# cannot currently access the target, the script records that blocker and falls
# back to a no-flash smoke run so serial/ROS validation can still continue.
set -eo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG_PREFIX="${1:-com_staircase}"
LOGDIR="${LOGDIR:-$ROOT/log/com-staircase}"
SUMMARY="$LOGDIR/$TAG_PREFIX.summary.log"
METRICS_MD="$LOGDIR/$TAG_PREFIX.metrics.md"
METRICS_CSV="$LOGDIR/$TAG_PREFIX.metrics.csv"

DRY_RUN="${DRY_RUN:-0}"
CONTINUE_ON_ERROR="${CONTINUE_ON_ERROR:-1}"
FAIL_ON_STAGE_ERROR="${FAIL_ON_STAGE_ERROR:-0}"
RUN_NO_FLASH_SMOKE_ON_STLINK_FAIL="${RUN_NO_FLASH_SMOKE_ON_STLINK_FAIL:-1}"
RUN_NO_FLASH_LATEST_QOS_PROBE_ON_STLINK_FAIL="${RUN_NO_FLASH_LATEST_QOS_PROBE_ON_STLINK_FAIL:-1}"
STAIRCASE_FORCE_STLINK_FAIL="${STAIRCASE_FORCE_STLINK_FAIL:-0}"

BUILD_FIRMWARE="${BUILD_FIRMWARE:-1}"
FLASH_FIRMWARE="${FLASH_FIRMWARE:-1}"
STLINK_PREFLIGHT="${STLINK_PREFLIGHT:-1}"
FLASH_TIMEOUT_SECONDS="${FLASH_TIMEOUT_SECONDS:-90}"

BASELINE_RUN_SECONDS="${BASELINE_RUN_SECONDS:-30}"
BASELINE_WARMUP_SECONDS="${BASELINE_WARMUP_SECONDS:-5}"
BASELINE_HZ_SECONDS="${BASELINE_HZ_SECONDS:-15}"

LATEST_RUN_SECONDS="${LATEST_RUN_SECONDS:-65}"
LATEST_WARMUP_SECONDS="${LATEST_WARMUP_SECONDS:-5}"
LATEST_HZ_SECONDS="${LATEST_HZ_SECONDS:-50}"
LATEST_STATUS_EVERY_N="${LATEST_STATUS_EVERY_N:-40}"
STAIRCASE_BAUDS="${STAIRCASE_BAUDS:-921600 2000000}"
STAIRCASE_CONTROL_TIMER_IRQ_PRIORITIES="${STAIRCASE_CONTROL_TIMER_IRQ_PRIORITIES:-${STAIRCASE_CONTROL_TIMER_IRQ_PRIORITY:-4}}"
STAIRCASE_UART_READ_POLL_YIELDS="${STAIRCASE_UART_READ_POLL_YIELDS:-0}"
STAIRCASE_EXECUTOR_SPIN_TIMEOUT_US="${STAIRCASE_EXECUTOR_SPIN_TIMEOUT_US:-1000}"
STAIRCASE_PC_LAUNCH_PREFIX_CASES="${STAIRCASE_PC_LAUNCH_PREFIX_CASES:-default|${PC_LAUNCH_PREFIX:-}}"
POST_STAGE_SETTLE_SECONDS="${POST_STAGE_SETTLE_SECONDS:-3}"
STAIRCASE_ISOLATE_ROS_DOMAIN_PER_STAGE="${STAIRCASE_ISOLATE_ROS_DOMAIN_PER_STAGE:-0}"
STAIRCASE_ROS_DOMAIN_BASE="${STAIRCASE_ROS_DOMAIN_BASE:-${ROS_DOMAIN_ID:-0}}"

SMOKE_RUN_SECONDS="${SMOKE_RUN_SECONDS:-18}"
SMOKE_WARMUP_SECONDS="${SMOKE_WARMUP_SECONDS:-5}"
SMOKE_HZ_SECONDS="${SMOKE_HZ_SECONDS:-10}"

mkdir -p "$LOGDIR"
: >"$SUMMARY"
stage_index=0

record() {
  printf '%s\n' "$*" | tee -a "$SUMMARY"
}

extract_com_perf_metric() {
  local log="$1"
  local key="$2"
  grep -F "[com-perf] $key=" "$log" 2>/dev/null |
    tail -1 |
    sed -E "s/^.*\\[com-perf\\] $key=//"
}

extract_summary_counter() {
  local line="$1"
  local key="$2"
  printf '%s\n' "$line" |
    tr ' ' '\n' |
    awk -F= -v k="$key" '$1 == k && $2 ~ /^[0-9]+$/ {print $2}' |
    tail -1
}

extract_key_value() {
  local line="$1"
  local key="$2"
  printf '%s\n' "$line" |
    tr ' ' '\n' |
    awk -F= -v k="$key" '$1 == k {print $2}' |
    tail -1
}

value_or_na() {
  local value="$1"
  if [ -n "$value" ]; then
    printf '%s' "$value"
  else
    printf 'NA'
  fi
}

qos_incompatibility_flag() {
  local value="$1"
  if [ -z "$value" ]; then
    return 0
  fi
  case "$value" in
    none|NA) printf '0' ;;
    *) printf '1' ;;
  esac
}

sanitize_label() {
  printf '%s' "$1" |
    tr '[:upper:]' '[:lower:]' |
    sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//'
}

pc_launch_case_lines() {
  printf '%s\n' "$STAIRCASE_PC_LAUNCH_PREFIX_CASES"
}

pc_launch_case_count() {
  local count=0
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      \#*) continue ;;
    esac
    count=$((count + 1))
  done < <(pc_launch_case_lines)
  printf '%s' "$count"
}

record_stage_metrics() {
  local tag="$1"
  local stage_log="$2"
  local status_hz sampler_hz sampler_target_rx_hz
  local sampler_max_gap_s sampler_p95_gap_s sampler_p99_gap_s
  local sampler_zero_gap_count sampler_seq_rate_hz sampler_seq_delta_avg
  local sampler_seq_delta_min sampler_seq_delta_max
  local pc_target_rate_hz pc_target_window_hz last_summary
  local pc_wire_gap_p95_ms pc_wire_gap_p99_ms pc_wire_gap_max_ms
  local pc_cmd_catchup_events pc_cmd_catchup_extra
  local wire_metrics wire_kbit_s wire_baud_util_pct tx_kbit_s rx_kbit_s
  local lost duplicate inflight qos_incompatibility

  if [ ! -f "$stage_log" ]; then
    record "METRICS $tag missing_log=$stage_log"
    return
  fi

  status_hz="$(extract_com_perf_metric "$stage_log" status_hz)"
  sampler_hz="$(extract_com_perf_metric "$stage_log" sampler_hz)"
  sampler_target_rx_hz="$(
    extract_com_perf_metric "$stage_log" sampler_target_rx_hz)"
  sampler_max_gap_s="$(extract_com_perf_metric "$stage_log" sampler_max_gap_s)"
  sampler_p95_gap_s="$(extract_com_perf_metric "$stage_log" sampler_p95_gap_s)"
  sampler_p99_gap_s="$(extract_com_perf_metric "$stage_log" sampler_p99_gap_s)"
  sampler_zero_gap_count="$(
    extract_com_perf_metric "$stage_log" sampler_zero_gap_count)"
  sampler_seq_rate_hz="$(
    extract_com_perf_metric "$stage_log" sampler_seq_rate_hz)"
  sampler_seq_delta_avg="$(
    extract_com_perf_metric "$stage_log" sampler_seq_delta_avg)"
  sampler_seq_delta_min="$(
    extract_com_perf_metric "$stage_log" sampler_seq_delta_min)"
  sampler_seq_delta_max="$(
    extract_com_perf_metric "$stage_log" sampler_seq_delta_max)"
  pc_target_rate_hz="$(extract_com_perf_metric "$stage_log" pc_target_rate_hz)"
  pc_target_window_hz="$(
    extract_com_perf_metric "$stage_log" pc_target_window_hz)"
  pc_wire_gap_p95_ms="$(
    extract_com_perf_metric "$stage_log" pc_wire_gap_p95_ms)"
  pc_wire_gap_p99_ms="$(
    extract_com_perf_metric "$stage_log" pc_wire_gap_p99_ms)"
  pc_wire_gap_max_ms="$(
    extract_com_perf_metric "$stage_log" pc_wire_gap_max_ms)"
  pc_cmd_catchup_events="$(
    extract_com_perf_metric "$stage_log" pc_cmd_catchup_events)"
  pc_cmd_catchup_extra="$(
    extract_com_perf_metric "$stage_log" pc_cmd_catchup_extra)"
  wire_metrics="$(extract_com_perf_metric "$stage_log" wire_metrics)"
  wire_kbit_s="$(extract_key_value "$wire_metrics" total_serial_kbit_s)"
  wire_baud_util_pct="$(extract_key_value "$wire_metrics" baud_util_pct)"
  tx_kbit_s="$(extract_key_value "$wire_metrics" tx_serial_kbit_s)"
  rx_kbit_s="$(extract_key_value "$wire_metrics" rx_serial_kbit_s)"
  last_summary="$(grep -F '[com-perf] last_summary=' "$stage_log" |
    tail -1 || true)"
  lost="$(extract_summary_counter "$last_summary" lost)"
  duplicate="$(extract_summary_counter "$last_summary" duplicate)"
  inflight="$(extract_summary_counter "$last_summary" inflight)"
  qos_incompatibility="$(
    qos_incompatibility_flag "$(
      extract_com_perf_metric "$stage_log" qos_incompatibility
    )"
  )"

  record "METRICS $tag status_hz=$(value_or_na "$status_hz") sampler_hz=$(value_or_na "$sampler_hz") sampler_target_rx_hz=$(value_or_na "$sampler_target_rx_hz") sampler_p95_gap_s=$(value_or_na "$sampler_p95_gap_s") sampler_p99_gap_s=$(value_or_na "$sampler_p99_gap_s") sampler_max_gap_s=$(value_or_na "$sampler_max_gap_s") sampler_zero_gap_count=$(value_or_na "$sampler_zero_gap_count") sampler_seq_rate_hz=$(value_or_na "$sampler_seq_rate_hz") seq_delta_avg=$(value_or_na "$sampler_seq_delta_avg") seq_delta_min=$(value_or_na "$sampler_seq_delta_min") seq_delta_max=$(value_or_na "$sampler_seq_delta_max") pc_target_rate_hz=$(value_or_na "$pc_target_rate_hz") pc_target_window_hz=$(value_or_na "$pc_target_window_hz") pc_wire_gap_p95_ms=$(value_or_na "$pc_wire_gap_p95_ms") pc_wire_gap_p99_ms=$(value_or_na "$pc_wire_gap_p99_ms") pc_wire_gap_max_ms=$(value_or_na "$pc_wire_gap_max_ms") pc_cmd_catchup_events=$(value_or_na "$pc_cmd_catchup_events") pc_cmd_catchup_extra=$(value_or_na "$pc_cmd_catchup_extra") wire_kbit_s=$(value_or_na "$wire_kbit_s") wire_baud_util_pct=$(value_or_na "$wire_baud_util_pct") tx_kbit_s=$(value_or_na "$tx_kbit_s") rx_kbit_s=$(value_or_na "$rx_kbit_s") lost=$(value_or_na "$lost") duplicate=$(value_or_na "$duplicate") inflight=$(value_or_na "$inflight") qos_incompatibility=$(value_or_na "$qos_incompatibility")"
}

check_stlink_ready() {
  local out
  if [ "$STAIRCASE_FORCE_STLINK_FAIL" = "1" ]; then
    record "BLOCKED forced ST-LINK failure via STAIRCASE_FORCE_STLINK_FAIL=1"
    return 1
  fi
  if [ "$DRY_RUN" = "1" ]; then
    return 0
  fi
  if [ "$FLASH_FIRMWARE" != "1" ] || [ "$STLINK_PREFLIGHT" != "1" ]; then
    return 0
  fi
  if ! command -v st-info >/dev/null; then
    record "WARN st-info not found; staircase will let run-com-perf handle flash"
    return 0
  fi
  if ! out="$(timeout "$FLASH_TIMEOUT_SECONDS" st-info --probe 2>&1)"; then
    record "$out"
    record "BLOCKED ST-LINK preflight failed before staircase flash stages"
    return 1
  fi
  if printf '%s\n' "$out" |
      grep -Eq 'dev-type:[[:space:]]+unknown|chipid:[[:space:]]+0x000'; then
    record "$out"
    record "BLOCKED ST-LINK target probe invalid before staircase flash stages"
    return 1
  fi
}

run_stage() {
  local tag="$1"
  shift
  local stage_log="$LOGDIR/$TAG_PREFIX.$tag.console.log"
  local status=0
  local stage_ros_domain_id="$STAIRCASE_ROS_DOMAIN_BASE"

  if [ "$STAIRCASE_ISOLATE_ROS_DOMAIN_PER_STAGE" = "1" ]; then
    stage_ros_domain_id=$((STAIRCASE_ROS_DOMAIN_BASE + stage_index))
  fi
  stage_index=$((stage_index + 1))

  record "START $tag stage_ros_domain_id=$stage_ros_domain_id"
  if [ "$DRY_RUN" = "1" ]; then
    printf '[dry-run] env LOGDIR=%q ROS_DOMAIN_ID=%q' \
      "$LOGDIR" "$stage_ros_domain_id" | tee -a "$SUMMARY"
    printf ' %q' "$@" | tee -a "$SUMMARY"
    printf ' %q %q\n' "$ROOT/tools/run-com-perf.sh" "$tag" | tee -a "$SUMMARY"
    record "OK $tag dry_run=1"
    return 0
  fi

  set +e
  env LOGDIR="$LOGDIR" ROS_DOMAIN_ID="$stage_ros_domain_id" \
    "$@" "$ROOT/tools/run-com-perf.sh" "$tag" \
    2>&1 | tee "$stage_log"
  status=${PIPESTATUS[0]}
  set -e
  record_stage_metrics "$tag" "$stage_log"

  if [ "$status" -eq 0 ]; then
    record "OK $tag log=$stage_log"
  else
    record "FAIL $tag status=$status log=$stage_log"
    if [ "$CONTINUE_ON_ERROR" != "1" ]; then
      exit "$status"
    fi
  fi
  if [ "$POST_STAGE_SETTLE_SECONDS" -gt 0 ] 2>/dev/null; then
    record "SETTLE $tag seconds=$POST_STAGE_SETTLE_SECONDS"
    sleep "$POST_STAGE_SETTLE_SECONDS"
  fi
  return "$status"
}

run_baseline_flash_stage() {
  run_stage "baseline_1khz_20hz_reliable" \
    BUILD_FIRMWARE="$BUILD_FIRMWARE" \
    FLASH_FIRMWARE="$FLASH_FIRMWARE" \
    CONTROL_LOOP_HZ=1000 \
    CMD_RATE_HZ=20 \
    CMD_CATCHUP_MAX=0 \
    QOS_RELIABILITY=reliable \
    QOS_DEPTH=2 \
    TRACKING_MODE=echo \
    STATUS_EVERY_N=1 \
    RUN_SECONDS="$BASELINE_RUN_SECONDS" \
    WARMUP_SECONDS="$BASELINE_WARMUP_SECONDS" \
    HZ_SECONDS="$BASELINE_HZ_SECONDS"
}

run_latest_flash_stage() {
  local hz="$1"
  local baud="$2"
  local irq_priority="$3"
  local poll_yields="$4"
  local spin_timeout_us="$5"
  local pc_case_label="${6:-default}"
  local pc_launch_prefix="${7:-}"
  local tag_suffix=""
  if [ "$STAIRCASE_PC_LAUNCH_CASE_COUNT" -gt 1 ] ||
      [ "$pc_case_label" != "default" ]; then
    tag_suffix="_pc${pc_case_label}"
  fi
  run_stage "latest_${hz}hz_${baud}baud_irqp${irq_priority}_poll${poll_yields}_spin${spin_timeout_us}us_200hz_be_n${LATEST_STATUS_EVERY_N}${tag_suffix}" \
    BUILD_FIRMWARE="$BUILD_FIRMWARE" \
    FLASH_FIRMWARE="$FLASH_FIRMWARE" \
    BAUD="$baud" \
    CONTROL_LOOP_HZ="$hz" \
    CONTROL_TIMER_IRQ_PRIORITY="$irq_priority" \
    UART_READ_POLL_YIELDS="$poll_yields" \
    EXECUTOR_SPIN_TIMEOUT_US="$spin_timeout_us" \
    CMD_RATE_HZ=200 \
    CMD_CATCHUP_MAX=1 \
    QOS_RELIABILITY=best_effort \
    QOS_DEPTH=1 \
    TRACKING_MODE=sampled \
    STATUS_EVERY_N="$LATEST_STATUS_EVERY_N" \
    SUMMARY_PERIOD_S=5.0 \
    LINK_HEALTH_PERIOD_S=5.0 \
    PC_LAUNCH_PREFIX="$pc_launch_prefix" \
    RUN_SECONDS="$LATEST_RUN_SECONDS" \
    WARMUP_SECONDS="$LATEST_WARMUP_SECONDS" \
    HZ_SECONDS="$LATEST_HZ_SECONDS"
}

run_no_flash_smoke() {
  run_stage "no_flash_smoke" \
    BUILD_FIRMWARE=0 \
    FLASH_FIRMWARE=0 \
    CMD_RATE_HZ=20 \
    CMD_CATCHUP_MAX=0 \
    QOS_RELIABILITY=reliable \
    QOS_DEPTH=2 \
    TRACKING_MODE=echo \
    STATUS_EVERY_N=1 \
    RUN_SECONDS="$SMOKE_RUN_SECONDS" \
    WARMUP_SECONDS="$SMOKE_WARMUP_SECONDS" \
    HZ_SECONDS="$SMOKE_HZ_SECONDS"
}

run_no_flash_latest_qos_probe() {
  run_stage "no_flash_latest_target_qos_probe" \
    BUILD_FIRMWARE=0 \
    FLASH_FIRMWARE=0 \
    REQUIRE_CORE_METRICS=0 \
    REQUIRE_HEALTH_PASS=0 \
    CMD_RATE_HZ=200 \
    CMD_CATCHUP_MAX=1 \
    QOS_RELIABILITY=best_effort \
    QOS_DEPTH=1 \
    TRACKING_MODE=sampled \
    STATUS_EVERY_N="$LATEST_STATUS_EVERY_N" \
    SUMMARY_PERIOD_S=5.0 \
    LINK_HEALTH_PERIOD_S=5.0 \
    RUN_SECONDS="$SMOKE_RUN_SECONDS" \
    WARMUP_SECONDS="$SMOKE_WARMUP_SECONDS" \
    HZ_SECONDS="$SMOKE_HZ_SECONDS"
}

if [ "${RUN_COM_STAIRCASE_SOURCE_ONLY:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

STAIRCASE_PC_LAUNCH_CASE_COUNT="$(pc_launch_case_count)"

record "staircase tag_prefix=$TAG_PREFIX logdir=$LOGDIR"
record "mode build_firmware=$BUILD_FIRMWARE flash_firmware=$FLASH_FIRMWARE dry_run=$DRY_RUN force_stlink_fail=$STAIRCASE_FORCE_STLINK_FAIL fallback_smoke=$RUN_NO_FLASH_SMOKE_ON_STLINK_FAIL fallback_latest_qos_probe=$RUN_NO_FLASH_LATEST_QOS_PROBE_ON_STLINK_FAIL post_stage_settle_seconds=$POST_STAGE_SETTLE_SECONDS isolate_ros_domain_per_stage=$STAIRCASE_ISOLATE_ROS_DOMAIN_PER_STAGE ros_domain_base=$STAIRCASE_ROS_DOMAIN_BASE staircase_bauds=$STAIRCASE_BAUDS staircase_control_timer_irq_priorities=$STAIRCASE_CONTROL_TIMER_IRQ_PRIORITIES staircase_uart_read_poll_yields=$STAIRCASE_UART_READ_POLL_YIELDS staircase_executor_spin_timeout_us=$STAIRCASE_EXECUTOR_SPIN_TIMEOUT_US pc_launch_prefix=${PC_LAUNCH_PREFIX:-none} staircase_pc_launch_case_count=$STAIRCASE_PC_LAUNCH_CASE_COUNT"

failures=0
if check_stlink_ready; then
  run_baseline_flash_stage || failures=$((failures + 1))
  for hz in 1000 2000 5000 10000; do
    for baud in $STAIRCASE_BAUDS; do
      for irq_priority in $STAIRCASE_CONTROL_TIMER_IRQ_PRIORITIES; do
        for poll_yields in $STAIRCASE_UART_READ_POLL_YIELDS; do
          for spin_timeout_us in $STAIRCASE_EXECUTOR_SPIN_TIMEOUT_US; do
            while IFS= read -r pc_case_line; do
              [ -n "$pc_case_line" ] || continue
              case "$pc_case_line" in
                \#*) continue ;;
                *'|'*) ;;
                *)
                  record "FAIL invalid_pc_launch_case='$pc_case_line' expected='label|prefix'"
                  failures=$((failures + 1))
                  continue
                  ;;
              esac
              pc_case_label="${pc_case_line%%|*}"
              pc_launch_prefix="${pc_case_line#*|}"
              if [ -z "$pc_case_label" ]; then
                record "FAIL invalid_pc_launch_case='$pc_case_line' reason=empty_label"
                failures=$((failures + 1))
                continue
              fi
              pc_case_label="$(sanitize_label "$pc_case_label")"
              if [ -z "$pc_case_label" ]; then
                record "FAIL invalid_pc_launch_case='$pc_case_line' reason=empty_safe_label"
                failures=$((failures + 1))
                continue
              fi
              run_latest_flash_stage "$hz" "$baud" "$irq_priority" "$poll_yields" "$spin_timeout_us" "$pc_case_label" "$pc_launch_prefix" || failures=$((failures + 1))
            done < <(pc_launch_case_lines)
          done
        done
      done
    done
  done
else
  failures=$((failures + 1))
  record "SKIP flash staircase stages because ST-LINK target access is not ready"
  if [ "$RUN_NO_FLASH_SMOKE_ON_STLINK_FAIL" = "1" ]; then
    run_no_flash_smoke || failures=$((failures + 1))
  fi
  if [ "$RUN_NO_FLASH_LATEST_QOS_PROBE_ON_STLINK_FAIL" = "1" ]; then
    run_no_flash_latest_qos_probe || failures=$((failures + 1))
  fi
fi

record "DONE failures=$failures summary=$SUMMARY"
if grep -q '^METRICS ' "$SUMMARY"; then
  "$ROOT/tools/summarize-com-staircase.sh" "$SUMMARY" >"$METRICS_MD"
  FORMAT=csv "$ROOT/tools/summarize-com-staircase.sh" "$SUMMARY" >"$METRICS_CSV"
  record "METRICS_TABLE markdown=$METRICS_MD csv=$METRICS_CSV"
fi
if [ "$failures" -ne 0 ] && [ "$FAIL_ON_STAGE_ERROR" = "1" ]; then
  exit 1
fi
