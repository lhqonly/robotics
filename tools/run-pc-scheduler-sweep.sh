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
  local safe_label tag console_log status

  safe_label="$(sanitize_label "$label")"
  tag="${TAG_PREFIX}_${safe_label}_r${run_index}"
  console_log="$LOGDIR/$tag.console.log"
  record "START label=$label run=$run_index tag=$tag prefix=${prefix:-none}"

  if [ "$DRY_RUN" = "1" ]; then
    record "DRY_RUN tag=$tag PC_LAUNCH_PREFIX=${prefix:-}"
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
    PC_LAUNCH_PREFIX="$prefix" \
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

record "pc_scheduler_sweep tag_prefix=$TAG_PREFIX runs=$RUNS dry_run=$DRY_RUN"
record "profile cmd_rate_hz=$CMD_RATE_HZ qos=$QOS_RELIABILITY depth=$QOS_DEPTH tracking=$TRACKING_MODE status_every_n=$STATUS_EVERY_N run_seconds=$RUN_SECONDS warmup_seconds=$WARMUP_SECONDS hz_seconds=$HZ_SECONDS"
record "logdir=$LOGDIR com_perf_logdir=$COM_PERF_LOGDIR"
: >"$LOGDIR/$TAG_PREFIX.tags"

failures=0
while IFS='|' read -r label prefix; do
  [ -n "$label" ] || continue
  for run_index in $(seq 1 "$RUNS"); do
    run_case "$label" "$prefix" "$run_index" || failures=$((failures + 1))
  done
done < <(case_lines)

if [ -s "$LOGDIR/$TAG_PREFIX.tags" ]; then
  mapfile -t tags <"$LOGDIR/$TAG_PREFIX.tags"
  LOGDIR="$COM_PERF_LOGDIR" \
    PERF_EXPECTED_RATE_HZ="$CMD_RATE_HZ" \
    "$ROOT/tools/summarize-com-perf.sh" "${tags[@]}" >"$METRICS_MD"
  LOGDIR="$COM_PERF_LOGDIR" \
    PERF_EXPECTED_RATE_HZ="$CMD_RATE_HZ" \
    FORMAT=csv "$ROOT/tools/summarize-com-perf.sh" \
    "${tags[@]}" >"$METRICS_CSV"
  record "METRICS_TABLE markdown=$METRICS_MD csv=$METRICS_CSV"
fi

record "DONE failures=$failures summary=$SUMMARY"
if [ "$failures" -ne 0 ]; then
  exit 1
fi
