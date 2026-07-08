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

DRY_RUN="${DRY_RUN:-0}"
CONTINUE_ON_ERROR="${CONTINUE_ON_ERROR:-1}"
FAIL_ON_STAGE_ERROR="${FAIL_ON_STAGE_ERROR:-0}"
RUN_NO_FLASH_SMOKE_ON_STLINK_FAIL="${RUN_NO_FLASH_SMOKE_ON_STLINK_FAIL:-1}"

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

SMOKE_RUN_SECONDS="${SMOKE_RUN_SECONDS:-18}"
SMOKE_WARMUP_SECONDS="${SMOKE_WARMUP_SECONDS:-5}"
SMOKE_HZ_SECONDS="${SMOKE_HZ_SECONDS:-10}"

mkdir -p "$LOGDIR"
: >"$SUMMARY"

record() {
  printf '%s\n' "$*" | tee -a "$SUMMARY"
}

check_stlink_ready() {
  local out
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

  record "START $tag"
  if [ "$DRY_RUN" = "1" ]; then
    printf '[dry-run] env LOGDIR=%q' "$LOGDIR" | tee -a "$SUMMARY"
    printf ' %q' "$@" | tee -a "$SUMMARY"
    printf ' %q %q\n' "$ROOT/tools/run-com-perf.sh" "$tag" | tee -a "$SUMMARY"
    record "OK $tag dry_run=1"
    return 0
  fi

  set +e
  env LOGDIR="$LOGDIR" "$@" "$ROOT/tools/run-com-perf.sh" "$tag" \
    2>&1 | tee "$stage_log"
  status=${PIPESTATUS[0]}
  set -e

  if [ "$status" -eq 0 ]; then
    record "OK $tag log=$stage_log"
  else
    record "FAIL $tag status=$status log=$stage_log"
    if [ "$CONTINUE_ON_ERROR" != "1" ]; then
      exit "$status"
    fi
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
  run_stage "latest_${hz}hz_200hz_be_n${LATEST_STATUS_EVERY_N}" \
    BUILD_FIRMWARE="$BUILD_FIRMWARE" \
    FLASH_FIRMWARE="$FLASH_FIRMWARE" \
    CONTROL_LOOP_HZ="$hz" \
    CMD_RATE_HZ=200 \
    CMD_CATCHUP_MAX=1 \
    QOS_RELIABILITY=best_effort \
    QOS_DEPTH=1 \
    TRACKING_MODE=sampled \
    STATUS_EVERY_N="$LATEST_STATUS_EVERY_N" \
    SUMMARY_PERIOD_S=5.0 \
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

record "staircase tag_prefix=$TAG_PREFIX logdir=$LOGDIR"
record "mode build_firmware=$BUILD_FIRMWARE flash_firmware=$FLASH_FIRMWARE dry_run=$DRY_RUN"

failures=0
if check_stlink_ready; then
  run_baseline_flash_stage || failures=$((failures + 1))
  for hz in 1000 2000 5000 10000; do
    run_latest_flash_stage "$hz" || failures=$((failures + 1))
  done
else
  failures=$((failures + 1))
  record "SKIP flash staircase stages because ST-LINK target access is not ready"
  if [ "$RUN_NO_FLASH_SMOKE_ON_STLINK_FAIL" = "1" ]; then
    run_no_flash_smoke || failures=$((failures + 1))
  fi
fi

record "DONE failures=$failures summary=$SUMMARY"
if [ "$failures" -ne 0 ] && [ "$FAIL_ON_STAGE_ERROR" = "1" ]; then
  exit 1
fi
