#!/usr/bin/env bash
# One-shot validation cycle: diagnose SWD, then run the best available path.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:-validation_$(date +%Y%m%d_%H%M%S)}"
LOGDIR="${LOGDIR:-$ROOT/log/validation-cycle}"
HANDOFF_DIR="${HANDOFF_DIR:-$ROOT/log/handoff}"
DRY_RUN="${DRY_RUN:-0}"
FAIL_ON_ERROR="${FAIL_ON_ERROR:-0}"
SWD_STATUS_OVERRIDE="${SWD_STATUS_OVERRIDE:-}"
RUN_NO_FLASH_ON_SWD_FAIL="${RUN_NO_FLASH_ON_SWD_FAIL:-1}"
RUN_STACK_HWM_ON_CONTRACT_PASS="${RUN_STACK_HWM_ON_CONTRACT_PASS:-0}"
USE_RECOMMENDED_STAIRCASE_CASES="${USE_RECOMMENDED_STAIRCASE_CASES:-1}"
START_OVERNIGHT_WATCH_ON_SWD_FAIL="${START_OVERNIGHT_WATCH_ON_SWD_FAIL:-0}"
NOFLASH_RUN_SECONDS="${NOFLASH_RUN_SECONDS:-18}"
NOFLASH_WARMUP_SECONDS="${NOFLASH_WARMUP_SECONDS:-5}"
NOFLASH_HZ_SECONDS="${NOFLASH_HZ_SECONDS:-10}"

DIAGNOSE_CMD="${DIAGNOSE_CMD:-$ROOT/tools/diagnose-swd.sh}"
STAIRCASE_CMD="${STAIRCASE_CMD:-$ROOT/tools/run-com-staircase.sh}"
RECOMMEND_STAIRCASE_CMD="${RECOMMEND_STAIRCASE_CMD:-$ROOT/tools/recommend-staircase-command.sh}"
COM_PERF_CMD="${COM_PERF_CMD:-$ROOT/tools/run-com-perf.sh}"
CONTRACT_CMD="${CONTRACT_CMD:-$ROOT/tools/check-com-staircase-contract.py}"
STAIRCASE_CONTRACT_ARGS="${STAIRCASE_CONTRACT_ARGS:-}"
STATUS_REPORT_CMD="${STATUS_REPORT_CMD:-$ROOT/tools/com-status-report.sh}"
START_WATCH_CMD="${START_WATCH_CMD:-$ROOT/tools/start-overnight-com-watch.sh}"
OVERNIGHT_WATCH_TAG="${OVERNIGHT_WATCH_TAG:-${TAG}_watch}"
STACK_HWM_CMD="${STACK_HWM_CMD:-$ROOT/tools/measure-stack-hwm.sh}"
FIRMWARE_ELF="${FIRMWARE_ELF:-$ROOT/firmware/f103-microros/build/f103-microros.elf}"

mkdir -p "$LOGDIR" "$HANDOFF_DIR"
LOG="$LOGDIR/$TAG.log"
DIAG_REPORT="$HANDOFF_DIR/${TAG}.swd.md"
CONTRACT_LOG="$LOGDIR/$TAG.contract.log"
STACK_HWM_LOG="$LOGDIR/$TAG.stack-hwm.log"
START_WATCH_LOG="$LOGDIR/$TAG.watch-start.log"

: >"$LOG"

record() {
  printf '%s\n' "$*" | tee -a "$LOG"
}

run_or_record() {
  if [ "$DRY_RUN" = "1" ]; then
    record "DRY_RUN $*"
    return 0
  fi
  record "RUN $*"
  "$@"
}

extract_swd_status() {
  local file="$1"
  awk -F= '$1 == "SWD_STATUS" {print $2; exit}' "$file"
}

record "validation_cycle tag=$TAG dry_run=$DRY_RUN fail_on_error=$FAIL_ON_ERROR"

if [ -n "$SWD_STATUS_OVERRIDE" ]; then
  swd_status="$SWD_STATUS_OVERRIDE"
  record "SWD_STATUS override=$swd_status"
else
  if [ "$DRY_RUN" = "1" ]; then
    swd_status="dry_run_unknown"
    record "DRY_RUN $DIAGNOSE_CMD > $DIAG_REPORT"
  else
    record "RUN $DIAGNOSE_CMD > $DIAG_REPORT"
    "$DIAGNOSE_CMD" >"$DIAG_REPORT"
    swd_status="$(extract_swd_status "$DIAG_REPORT")"
  fi
fi
swd_status="${swd_status:-unknown}"
record "SWD_STATUS=$swd_status"

status=0
contract_status=0
if [ "$swd_status" = "ok" ]; then
  record "PATH full_staircase"
  recommended_cases=""
  recommended_contract_args=""
  if [ "$USE_RECOMMENDED_STAIRCASE_CASES" = "1" ] &&
      [ -x "$RECOMMEND_STAIRCASE_CMD" ]; then
    if recommended_cases="$(FORMAT=cases "$RECOMMEND_STAIRCASE_CMD" 2>/dev/null)"; then
      record "STAIRCASE_PC_LAUNCH_PREFIX_CASES_SOURCE=recommended"
      printf '%s\n' "$recommended_cases" |
        sed 's/^/STAIRCASE_PC_CASE /' | tee -a "$LOG" >/dev/null
    else
      record "WARN recommended staircase cases unavailable; using run-com-staircase defaults"
      recommended_cases=""
    fi
    if [ -z "$STAIRCASE_CONTRACT_ARGS" ] &&
        recommended_contract_args="$(FORMAT=contract_args "$RECOMMEND_STAIRCASE_CMD" 2>/dev/null)"; then
      STAIRCASE_CONTRACT_ARGS="$recommended_contract_args"
      record "STAIRCASE_CONTRACT_ARGS_SOURCE=recommended"
      record "STAIRCASE_CONTRACT_ARGS=$STAIRCASE_CONTRACT_ARGS"
    elif [ -n "$STAIRCASE_CONTRACT_ARGS" ]; then
      record "STAIRCASE_CONTRACT_ARGS_SOURCE=env"
      record "STAIRCASE_CONTRACT_ARGS=$STAIRCASE_CONTRACT_ARGS"
    else
      record "STAIRCASE_CONTRACT_ARGS_SOURCE=default_empty"
    fi
  else
    record "STAIRCASE_PC_LAUNCH_PREFIX_CASES_SOURCE=default"
    if [ -n "$STAIRCASE_CONTRACT_ARGS" ]; then
      record "STAIRCASE_CONTRACT_ARGS_SOURCE=env"
      record "STAIRCASE_CONTRACT_ARGS=$STAIRCASE_CONTRACT_ARGS"
    else
      record "STAIRCASE_CONTRACT_ARGS_SOURCE=default_empty"
    fi
  fi
  if [ -n "$recommended_cases" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      record "DRY_RUN STAIRCASE_PC_LAUNCH_PREFIX_CASES=recommended $STAIRCASE_CMD $TAG"
      :
    else
      record "RUN STAIRCASE_PC_LAUNCH_PREFIX_CASES=recommended $STAIRCASE_CMD $TAG"
      if env STAIRCASE_PC_LAUNCH_PREFIX_CASES="$recommended_cases" \
          "$STAIRCASE_CMD" "$TAG"; then
        :
      else
        status=$?
        record "ERROR staircase_status=$status"
      fi
    fi
  elif run_or_record "$STAIRCASE_CMD" "$TAG"; then
      :
    else
      status=$?
      record "ERROR staircase_status=$status"
    fi
  metrics_csv="$ROOT/log/com-staircase/$TAG.metrics.csv"
  if [ "$DRY_RUN" = "1" ]; then
    record "DRY_RUN $CONTRACT_CMD $metrics_csv $STAIRCASE_CONTRACT_ARGS > $CONTRACT_LOG"
  else
    read -r -a contract_args <<<"$STAIRCASE_CONTRACT_ARGS"
    if "$CONTRACT_CMD" "$metrics_csv" "${contract_args[@]}" >"$CONTRACT_LOG" 2>&1; then
      contract_status=0
    else
      contract_status=$?
    fi
    record "CONTRACT_STATUS=$contract_status log=$CONTRACT_LOG"
    if [ "$contract_status" -ne 0 ] && [ "$FAIL_ON_ERROR" = "1" ]; then
      status="$contract_status"
    fi
  fi
  if [ "$RUN_STACK_HWM_ON_CONTRACT_PASS" = "1" ] &&
      [ "$contract_status" -eq 0 ]; then
    if run_or_record "$STACK_HWM_CMD" "$FIRMWARE_ELF" >"$STACK_HWM_LOG" 2>&1; then
      record "STACK_HWM_STATUS=0 log=$STACK_HWM_LOG"
    else
      stack_status=$?
      record "WARN stack_hwm_status=$stack_status log=$STACK_HWM_LOG"
    fi
  fi
else
  record "PATH no_flash_fallback"
  if [ "$RUN_NO_FLASH_ON_SWD_FAIL" = "1" ]; then
    noflash_tag="${TAG}_noflash_smoke"
    if BUILD_FIRMWARE=0 FLASH_FIRMWARE=0 \
        RUN_SECONDS="$NOFLASH_RUN_SECONDS" \
        WARMUP_SECONDS="$NOFLASH_WARMUP_SECONDS" \
        HZ_SECONDS="$NOFLASH_HZ_SECONDS" \
        run_or_record "$COM_PERF_CMD" "$noflash_tag"; then
      :
    else
      status=$?
      record "ERROR noflash_status=$status"
    fi
  else
    record "SKIP no_flash_fallback RUN_NO_FLASH_ON_SWD_FAIL=0"
  fi
  if [ "$START_OVERNIGHT_WATCH_ON_SWD_FAIL" = "1" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      record "DRY_RUN $START_WATCH_CMD $OVERNIGHT_WATCH_TAG > $START_WATCH_LOG"
    elif "$START_WATCH_CMD" "$OVERNIGHT_WATCH_TAG" >"$START_WATCH_LOG" 2>&1; then
      record "OVERNIGHT_WATCH_STATUS=0 log=$START_WATCH_LOG"
    else
      watch_status=$?
      record "WARN overnight_watch_status=$watch_status log=$START_WATCH_LOG"
    fi
  else
    record "SKIP overnight_watch START_OVERNIGHT_WATCH_ON_SWD_FAIL=0"
  fi
fi

run_or_record "$STATUS_REPORT_CMD" "${TAG}_handoff" || true

record "DONE status=$status swd_status=$swd_status log=$LOG"
if [ "$status" -ne 0 ] && [ "$FAIL_ON_ERROR" = "1" ]; then
  exit "$status"
fi
