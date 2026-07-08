#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/tools/run-com-perf.sh"

bash -n "$SCRIPT"

assert_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if ! grep -Fq -- "$needle" "$file"; then
    echo "FAIL: $label missing '$needle' in $file" >&2
    exit 1
  fi
}

assert_contains "$SCRIPT" 'SUMMARY_PERIOD_S_SET="${SUMMARY_PERIOD_S+x}"' \
  "summary period explicit override sentinel"
assert_contains "$SCRIPT" \
  'LINK_HEALTH_PERIOD_S_SET="${LINK_HEALTH_PERIOD_S+x}"' \
  "link health period explicit override sentinel"
assert_contains "$SCRIPT" '[ "$QOS_RELIABILITY" = "best_effort" ]' \
  "latest-target reliability condition"
assert_contains "$SCRIPT" '[ "$TRACKING_MODE" = "sampled" ]' \
  "latest-target tracking condition"
assert_contains "$SCRIPT" '[ "$STATUS_EVERY_N" -gt 1 ]' \
  "latest-target status decimation condition"
assert_contains "$SCRIPT" 'SUMMARY_PERIOD_S=5.0' \
  "latest-target summary period auto-default"
assert_contains "$SCRIPT" 'LINK_HEALTH_PERIOD_S=5.0' \
  "latest-target link health period auto-default"

latest_config="$(
  PRINT_CONFIG_ONLY=1 \
    QOS_RELIABILITY=best_effort \
    TRACKING_MODE=sampled \
    STATUS_EVERY_N=40 \
    "$SCRIPT" latest_config_test
)"
printf '%s\n' "$latest_config" | grep -Fq \
  'summary_period_s=5.0 link_health_period_s=5.0' || {
    echo "FAIL: latest-target print-config did not auto-default diagnostics" >&2
    printf '%s\n' "$latest_config" >&2
    exit 1
  }

override_config="$(
  PRINT_CONFIG_ONLY=1 \
    QOS_RELIABILITY=best_effort \
    TRACKING_MODE=sampled \
    STATUS_EVERY_N=40 \
    SUMMARY_PERIOD_S=2.0 \
    LINK_HEALTH_PERIOD_S=3.0 \
    "$SCRIPT" override_config_test
)"
printf '%s\n' "$override_config" | grep -Fq \
  'summary_period_s=2.0 link_health_period_s=3.0' || {
    echo "FAIL: print-config did not preserve explicit diagnostic periods" >&2
    printf '%s\n' "$override_config" >&2
    exit 1
  }

echo "PASS: run-com-perf config checks"
