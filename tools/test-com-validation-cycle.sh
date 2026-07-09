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
    echo "FAIL: $label unexpectedly found '$needle' in $file" >&2
    exit 1
  fi
}

run_cycle() {
  local tag="$1"
  shift
  env LOGDIR="$TMPDIR/logs" HANDOFF_DIR="$TMPDIR/handoff" DRY_RUN=1 "$@" \
    "$ROOT/tools/run-com-validation-cycle.sh" "$tag" >/dev/null
}

fake_recommend="$TMPDIR/fake-recommend-staircase-command.sh"
cat >"$fake_recommend" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${FORMAT:-markdown}" in
  cases)
    printf '%s\n' 'default|' 'threads2||2'
    ;;
  contract_args)
    printf '%s\n' '--max-pc-catchup-events 0 --max-pc-catchup-extra 0'
    ;;
  *)
    echo "fake recommendation"
    ;;
esac
EOF
chmod +x "$fake_recommend"

run_cycle dry_ok SWD_STATUS_OVERRIDE=ok RECOMMEND_STAIRCASE_CMD="$fake_recommend"
ok_log="$TMPDIR/logs/dry_ok.log"
assert_contains "$ok_log" "SWD_STATUS=ok" \
  "SWD OK status is recorded"
assert_contains "$ok_log" "PATH full_staircase" \
  "SWD OK selects full staircase"
assert_contains "$ok_log" "STAIRCASE_PC_LAUNCH_PREFIX_CASES_SOURCE=recommended" \
  "SWD OK uses recommended PC cases"
assert_contains "$ok_log" "STAIRCASE_PC_CASE default|" \
  "recommended default PC case is recorded"
assert_contains "$ok_log" "STAIRCASE_PC_CASE threads2||2" \
  "recommended executor thread PC case is recorded"
assert_contains "$ok_log" "STAIRCASE_CONTRACT_ARGS_SOURCE=recommended" \
  "recommended contract args source is recorded"
assert_contains "$ok_log" \
  "STAIRCASE_CONTRACT_ARGS=--max-pc-catchup-events 0 --max-pc-catchup-extra 0" \
  "recommended contract args are recorded"
assert_contains "$ok_log" \
  "DRY_RUN STAIRCASE_PC_LAUNCH_PREFIX_CASES=recommended $ROOT/tools/run-com-staircase.sh dry_ok" \
  "full staircase command with recommended cases is recorded"
assert_contains "$ok_log" \
  "DRY_RUN $ROOT/tools/check-com-staircase-contract.py $ROOT/log/com-staircase/dry_ok.metrics.csv --max-pc-catchup-events 0 --max-pc-catchup-extra 0" \
  "staircase contract command with recommended args is recorded"
assert_contains "$ok_log" "DRY_RUN $ROOT/tools/com-status-report.sh dry_ok_handoff" \
  "handoff report command is recorded on OK path"
assert_not_contains "$ok_log" "run-com-perf.sh dry_ok_noflash_smoke" \
  "OK path does not run no-flash fallback"

run_cycle dry_ok_env SWD_STATUS_OVERRIDE=ok RECOMMEND_STAIRCASE_CMD="$fake_recommend" \
  STAIRCASE_CONTRACT_ARGS="--max-wire-baud-util-pct 30"
ok_env_log="$TMPDIR/logs/dry_ok_env.log"
assert_contains "$ok_env_log" "STAIRCASE_CONTRACT_ARGS_SOURCE=env" \
  "env contract args source is recorded"
assert_contains "$ok_env_log" \
  "DRY_RUN $ROOT/tools/check-com-staircase-contract.py $ROOT/log/com-staircase/dry_ok_env.metrics.csv --max-wire-baud-util-pct 30" \
  "staircase contract command with extra args is recorded"

run_cycle dry_bad SWD_STATUS_OVERRIDE=bad_unknown_target
bad_log="$TMPDIR/logs/dry_bad.log"
assert_contains "$bad_log" "SWD_STATUS=bad_unknown_target" \
  "SWD failure status is recorded"
assert_contains "$bad_log" "PATH no_flash_fallback" \
  "SWD failure selects no-flash fallback"
assert_contains "$bad_log" "DRY_RUN $ROOT/tools/run-com-perf.sh dry_bad_noflash_smoke" \
  "no-flash smoke command is recorded"
assert_contains "$bad_log" "DRY_RUN $ROOT/tools/com-status-report.sh dry_bad_handoff" \
  "handoff report command is recorded on fallback path"
assert_contains "$bad_log" "SKIP overnight_watch START_OVERNIGHT_WATCH_ON_SWD_FAIL=0" \
  "fallback does not start overnight watcher by default"
assert_not_contains "$bad_log" "run-com-staircase.sh dry_bad" \
  "fallback path does not run full staircase"

run_cycle dry_watch SWD_STATUS_OVERRIDE=bad_unknown_target START_OVERNIGHT_WATCH_ON_SWD_FAIL=1
watch_log="$TMPDIR/logs/dry_watch.log"
assert_contains "$watch_log" "DRY_RUN $ROOT/tools/start-overnight-com-watch.sh dry_watch_watch" \
  "fallback can start detached overnight watcher"

run_cycle dry_skip SWD_STATUS_OVERRIDE=bad_probe_failed RUN_NO_FLASH_ON_SWD_FAIL=0
skip_log="$TMPDIR/logs/dry_skip.log"
assert_contains "$skip_log" "SKIP no_flash_fallback RUN_NO_FLASH_ON_SWD_FAIL=0" \
  "fallback can be explicitly skipped"
assert_not_contains "$skip_log" "run-com-perf.sh dry_skip_noflash_smoke" \
  "skip path does not run no-flash smoke"

echo "PASS: communication validation cycle dry-run checks"
