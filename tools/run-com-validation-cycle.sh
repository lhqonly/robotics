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
NOFLASH_RUN_SECONDS="${NOFLASH_RUN_SECONDS:-18}"
NOFLASH_WARMUP_SECONDS="${NOFLASH_WARMUP_SECONDS:-5}"
NOFLASH_HZ_SECONDS="${NOFLASH_HZ_SECONDS:-10}"

DIAGNOSE_CMD="${DIAGNOSE_CMD:-$ROOT/tools/diagnose-swd.sh}"
STAIRCASE_CMD="${STAIRCASE_CMD:-$ROOT/tools/run-com-staircase.sh}"
COM_PERF_CMD="${COM_PERF_CMD:-$ROOT/tools/run-com-perf.sh}"
CONTRACT_CMD="${CONTRACT_CMD:-$ROOT/tools/check-com-staircase-contract.py}"
STATUS_REPORT_CMD="${STATUS_REPORT_CMD:-$ROOT/tools/com-status-report.sh}"
STACK_HWM_CMD="${STACK_HWM_CMD:-$ROOT/tools/measure-stack-hwm.sh}"
FIRMWARE_ELF="${FIRMWARE_ELF:-$ROOT/firmware/f103-microros/build/f103-microros.elf}"

mkdir -p "$LOGDIR" "$HANDOFF_DIR"
LOG="$LOGDIR/$TAG.log"
DIAG_REPORT="$HANDOFF_DIR/${TAG}.swd.md"
CONTRACT_LOG="$LOGDIR/$TAG.contract.log"
STACK_HWM_LOG="$LOGDIR/$TAG.stack-hwm.log"

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
  if run_or_record "$STAIRCASE_CMD" "$TAG"; then
    :
  else
    status=$?
    record "ERROR staircase_status=$status"
  fi
  metrics_csv="$ROOT/log/com-staircase/$TAG.metrics.csv"
  if [ "$DRY_RUN" = "1" ]; then
    record "DRY_RUN $CONTRACT_CMD $metrics_csv > $CONTRACT_LOG"
  else
    if "$CONTRACT_CMD" "$metrics_csv" >"$CONTRACT_LOG" 2>&1; then
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
fi

run_or_record "$STATUS_REPORT_CMD" "${TAG}_handoff" || true

record "DONE status=$status swd_status=$swd_status log=$LOG"
if [ "$status" -ne 0 ] && [ "$FAIL_ON_ERROR" = "1" ]; then
  exit "$status"
fi
