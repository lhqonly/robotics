#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tests=(
  "tools/test-control-target-model.sh"
  "tools/test-control-loop-config.sh"
  "tools/test-dwt-snapshot-model.sh"
  "tools/test-microros-config.sh"
  "tools/test-com-wire-budget.sh"
  "tools/test-com-perf-contract.sh"
  "tools/test-com-summary-parsers.sh"
  "tools/test-com-staircase-dry-run.sh"
  "tools/test-com-status-report.sh"
  "tools/test-firmware-size-report.sh"
)

for test_script in "${tests[@]}"; do
  echo "[offline-contracts] $test_script"
  "$ROOT/$test_script"
done

echo "PASS: offline communication/firmware contract tests"
