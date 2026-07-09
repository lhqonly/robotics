#!/usr/bin/env bash
# Read-only preflight for the 1/2/5/10kHz communication staircase.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIAGNOSE_CMD="${DIAGNOSE_CMD:-$ROOT/tools/diagnose-swd.sh}"
RECOMMEND_CMD="${RECOMMEND_CMD:-$ROOT/tools/recommend-staircase-command.sh}"
WATCH_STATUS_CMD="${WATCH_STATUS_CMD:-$ROOT/tools/overnight-watch-status.sh}"
PROBE_SWD="${PROBE_SWD:-1}"
SWD_STATUS_OVERRIDE="${SWD_STATUS_OVERRIDE:-}"

extract_swd_status() {
  awk -F= '$1 == "SWD_STATUS" {print $2; exit}' "$1"
}

print_block() {
  local prefix="$1"
  sed "s/^/$prefix/"
}

echo "# Communication Staircase Preflight"
echo
echo "PREFLIGHT_PROFILE=pc_200hz_latest_target_mcu_status40_loops_1_2_5_10khz_bauds_921600_2000000"

swd_status="unknown"
if [ -n "$SWD_STATUS_OVERRIDE" ]; then
  swd_status="$SWD_STATUS_OVERRIDE"
  echo "PREFLIGHT_SWD_SOURCE=override"
elif [ "$PROBE_SWD" = "1" ]; then
  swd_tmp="$(mktemp)"
  trap 'rm -f "$swd_tmp"' EXIT
  if "$DIAGNOSE_CMD" >"$swd_tmp" 2>&1; then
    swd_status="$(extract_swd_status "$swd_tmp")"
    swd_status="${swd_status:-unknown}"
  else
    swd_status="$(extract_swd_status "$swd_tmp")"
    swd_status="${swd_status:-diagnose_failed}"
  fi
  echo "PREFLIGHT_SWD_SOURCE=diagnose"
else
  echo "PREFLIGHT_SWD_SOURCE=skipped"
fi
echo "PREFLIGHT_SWD_STATUS=$swd_status"

recommend_status="missing"
cases=""
contract_args=""
if [ -x "$RECOMMEND_CMD" ]; then
  if cases="$(FORMAT=cases "$RECOMMEND_CMD" 2>/dev/null)" &&
      contract_args="$(FORMAT=contract_args "$RECOMMEND_CMD" 2>/dev/null)"; then
    recommend_status="ok"
  else
    recommend_status="unavailable"
  fi
fi
echo "PREFLIGHT_RECOMMEND_STATUS=$recommend_status"
if [ -n "$cases" ]; then
  printf '%s\n' "$cases" | print_block "PREFLIGHT_STAIRCASE_CASE "
fi
echo "PREFLIGHT_CONTRACT_ARGS=${contract_args:-}"

watch_status="none"
if [ -x "$WATCH_STATUS_CMD" ]; then
  watch_status="$("$WATCH_STATUS_CMD" 2>/dev/null || true)"
  watch_status="${watch_status:-none}"
fi
printf '%s\n' "$watch_status" | print_block "PREFLIGHT_WATCH "

ready="no"
next_action=""
case "$swd_status" in
  ok)
    if [ "$recommend_status" = "ok" ]; then
      ready="yes"
      next_action="run_recommended_staircase_then_contract"
    else
      next_action="run_pc_scheduler_sweep_before_staircase"
    fi
    ;;
  skipped|unknown)
    next_action="run_tools_diagnose_swd"
    ;;
  *)
    next_action="recover_swd_keep_noflash_watch_running"
    ;;
esac

echo "PREFLIGHT_READY=$ready"
echo "PREFLIGHT_NEXT_ACTION=$next_action"

if [ "$ready" = "yes" ]; then
  echo
  echo "Next commands:"
  echo "tools/recommend-staircase-command.sh"
  echo "# Then run the printed tools/run-com-staircase.sh command."
  echo "# Then run the printed tools/check-com-staircase-contract.py command."
fi
