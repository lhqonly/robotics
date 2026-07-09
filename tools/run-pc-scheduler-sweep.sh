#!/usr/bin/env bash
# Compare PC-side scheduling prefixes for no-flash communication jitter.
set -eo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG_PREFIX="${1:-pc_scheduler_sweep}"
LOGDIR="${LOGDIR:-$ROOT/log/pc-scheduler-sweep}"
COM_PERF_LOGDIR="${COM_PERF_LOGDIR:-$ROOT/log/com-perf}"
SUMMARY="$LOGDIR/$TAG_PREFIX.summary.log"
METRICS_MD="$LOGDIR/$TAG_PREFIX.metrics.md"
METRICS_CSV="$LOGDIR/$TAG_PREFIX.metrics.csv"

DRY_RUN="${DRY_RUN:-0}"
FAIL_ON_CASE_ERROR="${FAIL_ON_CASE_ERROR:-0}"
RUNS="${RUNS:-1}"
TASKSET_CPUS="${TASKSET_CPUS:-2}"
PC_SCHEDULER_CASES="${PC_SCHEDULER_CASES:-}"

# Defaults intentionally stay on the stable no-flash 20Hz reliable baseline.
RUN_SECONDS="${RUN_SECONDS:-18}"
WARMUP_SECONDS="${WARMUP_SECONDS:-5}"
HZ_SECONDS="${HZ_SECONDS:-10}"
CMD_RATE_HZ="${CMD_RATE_HZ:-20}"
CMD_CATCHUP_MAX="${CMD_CATCHUP_MAX:-0}"
QOS_RELIABILITY="${QOS_RELIABILITY:-reliable}"
QOS_DEPTH="${QOS_DEPTH:-2}"
TRACKING_MODE="${TRACKING_MODE:-echo}"
STATUS_EVERY_N="${STATUS_EVERY_N:-1}"
SAMPLE_WINDOW="${SAMPLE_WINDOW:-1024}"
SUMMARY_PERIOD_S="${SUMMARY_PERIOD_S:-1.0}"
LINK_HEALTH_PERIOD_S="${LINK_HEALTH_PERIOD_S:-1.0}"
STARTUP_GRACE_S="${STARTUP_GRACE_S:-3.0}"
EXECUTOR_THREADS="${EXECUTOR_THREADS:-0}"
REQUIRE_CORE_METRICS="${REQUIRE_CORE_METRICS:-1}"
REQUIRE_HEALTH_PASS="${REQUIRE_HEALTH_PASS:-1}"
MAX_CATCHUP_EVENTS="${MAX_CATCHUP_EVENTS:-}"
MAX_CATCHUP_EXTRA="${MAX_CATCHUP_EXTRA:-}"
PC_SCHEDULER_ISOLATE_ROS_DOMAIN_PER_CASE="${PC_SCHEDULER_ISOLATE_ROS_DOMAIN_PER_CASE:-auto}"
PC_SCHEDULER_ROS_DOMAIN_BASE="${PC_SCHEDULER_ROS_DOMAIN_BASE:-${ROS_DOMAIN_ID:-0}}"

case "$PC_SCHEDULER_ISOLATE_ROS_DOMAIN_PER_CASE" in
  auto)
    if [ "$REQUIRE_CORE_METRICS" = "0" ] && [ "$REQUIRE_HEALTH_PASS" = "0" ]; then
      PC_SCHEDULER_ISOLATE_ROS_DOMAIN_PER_CASE_RESOLVED=1
    else
      PC_SCHEDULER_ISOLATE_ROS_DOMAIN_PER_CASE_RESOLVED=0
    fi
    ;;
  0|1)
    PC_SCHEDULER_ISOLATE_ROS_DOMAIN_PER_CASE_RESOLVED="$PC_SCHEDULER_ISOLATE_ROS_DOMAIN_PER_CASE"
    ;;
  *)
    echo "ERROR: PC_SCHEDULER_ISOLATE_ROS_DOMAIN_PER_CASE must be auto, 0, or 1" >&2
    exit 1
    ;;
esac

mkdir -p "$LOGDIR" "$COM_PERF_LOGDIR"
: >"$SUMMARY"

record() {
  printf '%s\n' "$*" | tee -a "$SUMMARY"
}

sanitize_label() {
  printf '%s' "$1" |
    tr '[:upper:]' '[:lower:]' |
    sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//'
}

default_cases() {
  printf '%s\n' 'default|'
  if command -v taskset >/dev/null; then
    local cpu
    for cpu in $TASKSET_CPUS; do
      printf 'taskset_cpu%s|taskset -c %s\n' "$cpu" "$cpu"
    done
  else
    record "WARN taskset not found; default cases include baseline only"
  fi
}

case_lines() {
  if [ -n "$PC_SCHEDULER_CASES" ]; then
    printf '%s\n' "$PC_SCHEDULER_CASES"
  else
    default_cases
  fi
}

run_case() {
  local label="$1"
  local prefix="$2"
  local run_index="$3"
  local safe_label tag console_log status stage_ros_domain_id

  safe_label="$(sanitize_label "$label")"
  tag="${TAG_PREFIX}_${safe_label}_r${run_index}"
  console_log="$LOGDIR/$tag.console.log"
  stage_ros_domain_id="$PC_SCHEDULER_ROS_DOMAIN_BASE"
  if [ "$PC_SCHEDULER_ISOLATE_ROS_DOMAIN_PER_CASE_RESOLVED" = "1" ]; then
    stage_ros_domain_id=$((PC_SCHEDULER_ROS_DOMAIN_BASE + case_index))
  fi
  case_index=$((case_index + 1))
  record "START label=$label run=$run_index tag=$tag prefix=${prefix:-none} stage_ros_domain_id=$stage_ros_domain_id"

  if [ "$DRY_RUN" = "1" ]; then
    record "DRY_RUN tag=$tag PC_LAUNCH_PREFIX=${prefix:-} EXECUTOR_THREADS=$EXECUTOR_THREADS ROS_DOMAIN_ID=$stage_ros_domain_id"
    return 0
  fi

  set +e
  env \
    LOGDIR="$COM_PERF_LOGDIR" \
    BUILD_FIRMWARE=0 \
    FLASH_FIRMWARE=0 \
    RESET_TARGET=0 \
    RUN_SECONDS="$RUN_SECONDS" \
    WARMUP_SECONDS="$WARMUP_SECONDS" \
    HZ_SECONDS="$HZ_SECONDS" \
    CMD_RATE_HZ="$CMD_RATE_HZ" \
    CMD_CATCHUP_MAX="$CMD_CATCHUP_MAX" \
    QOS_RELIABILITY="$QOS_RELIABILITY" \
    QOS_DEPTH="$QOS_DEPTH" \
    TRACKING_MODE="$TRACKING_MODE" \
    STATUS_EVERY_N="$STATUS_EVERY_N" \
    SAMPLE_WINDOW="$SAMPLE_WINDOW" \
    SUMMARY_PERIOD_S="$SUMMARY_PERIOD_S" \
    LINK_HEALTH_PERIOD_S="$LINK_HEALTH_PERIOD_S" \
    STARTUP_GRACE_S="$STARTUP_GRACE_S" \
    EXECUTOR_THREADS="$EXECUTOR_THREADS" \
    REQUIRE_CORE_METRICS="$REQUIRE_CORE_METRICS" \
    REQUIRE_HEALTH_PASS="$REQUIRE_HEALTH_PASS" \
    PC_LAUNCH_PREFIX="$prefix" \
    ROS_DOMAIN_ID="$stage_ros_domain_id" \
    "$ROOT/tools/run-com-perf.sh" "$tag" 2>&1 | tee "$console_log"
  status=${PIPESTATUS[0]}
  set -e

  if [ "$status" -eq 0 ]; then
    record "OK label=$label run=$run_index tag=$tag log=$console_log"
  else
    record "FAIL label=$label run=$run_index tag=$tag status=$status log=$console_log"
  fi
  printf '%s\n' "$tag" >>"$LOGDIR/$TAG_PREFIX.tags"
  return "$status"
}

record "pc_scheduler_sweep tag_prefix=$TAG_PREFIX runs=$RUNS dry_run=$DRY_RUN fail_on_case_error=$FAIL_ON_CASE_ERROR"
record "profile cmd_rate_hz=$CMD_RATE_HZ cmd_catchup_max=$CMD_CATCHUP_MAX qos=$QOS_RELIABILITY depth=$QOS_DEPTH tracking=$TRACKING_MODE status_every_n=$STATUS_EVERY_N sample_window=$SAMPLE_WINDOW summary_period_s=$SUMMARY_PERIOD_S link_health_period_s=$LINK_HEALTH_PERIOD_S startup_grace_s=$STARTUP_GRACE_S executor_threads=$EXECUTOR_THREADS require_core_metrics=$REQUIRE_CORE_METRICS require_health_pass=$REQUIRE_HEALTH_PASS max_catchup_events=${MAX_CATCHUP_EVENTS:-NA} max_catchup_extra=${MAX_CATCHUP_EXTRA:-NA} isolate_ros_domain_per_case=$PC_SCHEDULER_ISOLATE_ROS_DOMAIN_PER_CASE resolved_isolate_ros_domain_per_case=$PC_SCHEDULER_ISOLATE_ROS_DOMAIN_PER_CASE_RESOLVED ros_domain_base=$PC_SCHEDULER_ROS_DOMAIN_BASE run_seconds=$RUN_SECONDS warmup_seconds=$WARMUP_SECONDS hz_seconds=$HZ_SECONDS"
record "logdir=$LOGDIR com_perf_logdir=$COM_PERF_LOGDIR"
: >"$LOGDIR/$TAG_PREFIX.tags"

failures=0
case_index=0
while IFS= read -r case_line; do
  [ -n "$case_line" ] || continue
  case "$case_line" in
    \#*) continue ;;
    *'|'*) ;;
    *)
      record "FAIL invalid_case='$case_line' expected='label|prefix'"
      failures=$((failures + 1))
      continue
      ;;
  esac
  label="${case_line%%|*}"
  prefix="${case_line#*|}"
  if [ -z "$label" ]; then
    record "FAIL invalid_case='$case_line' reason=empty_label"
    failures=$((failures + 1))
    continue
  fi
  for run_index in $(seq 1 "$RUNS"); do
    run_case "$label" "$prefix" "$run_index" || failures=$((failures + 1))
  done
done < <(case_lines)

if [ -s "$LOGDIR/$TAG_PREFIX.tags" ]; then
  mapfile -t tags <"$LOGDIR/$TAG_PREFIX.tags"
  LOGDIR="$COM_PERF_LOGDIR" \
    PERF_EXPECTED_RATE_HZ="$CMD_RATE_HZ" \
    PERF_MAX_CATCHUP_EVENTS="$MAX_CATCHUP_EVENTS" \
    PERF_MAX_CATCHUP_EXTRA="$MAX_CATCHUP_EXTRA" \
    "$ROOT/tools/summarize-com-perf.sh" "${tags[@]}" >"$METRICS_MD"
  LOGDIR="$COM_PERF_LOGDIR" \
    PERF_EXPECTED_RATE_HZ="$CMD_RATE_HZ" \
    PERF_MAX_CATCHUP_EVENTS="$MAX_CATCHUP_EVENTS" \
    PERF_MAX_CATCHUP_EXTRA="$MAX_CATCHUP_EXTRA" \
    FORMAT=csv "$ROOT/tools/summarize-com-perf.sh" \
    "${tags[@]}" >"$METRICS_CSV"
  record "METRICS_TABLE markdown=$METRICS_MD csv=$METRICS_CSV"
fi

record "DONE failures=$failures summary=$SUMMARY"
if [ "$failures" -ne 0 ] && [ "$FAIL_ON_CASE_ERROR" = "1" ]; then
  exit 1
fi
