#!/usr/bin/env bash
# Compare PC-side scheduling cases for the 200Hz latest-target control profile.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export CMD_RATE_HZ="${CMD_RATE_HZ:-200}"
export CMD_CATCHUP_MAX="${CMD_CATCHUP_MAX:-0}"
export QOS_RELIABILITY="${QOS_RELIABILITY:-best_effort}"
export QOS_DEPTH="${QOS_DEPTH:-1}"
export TRACKING_MODE="${TRACKING_MODE:-sampled}"
export STATUS_EVERY_N="${STATUS_EVERY_N:-40}"
export SUMMARY_PERIOD_S="${SUMMARY_PERIOD_S:-5.0}"
export LINK_HEALTH_PERIOD_S="${LINK_HEALTH_PERIOD_S:-5.0}"
export STARTUP_GRACE_S="${STARTUP_GRACE_S:-3.0}"
export REQUIRE_CORE_METRICS="${REQUIRE_CORE_METRICS:-0}"
export REQUIRE_HEALTH_PASS="${REQUIRE_HEALTH_PASS:-0}"
export MAX_CATCHUP_EVENTS="${MAX_CATCHUP_EVENTS:-0}"
export MAX_CATCHUP_EXTRA="${MAX_CATCHUP_EXTRA:-0}"
export RUN_SECONDS="${RUN_SECONDS:-30}"
export WARMUP_SECONDS="${WARMUP_SECONDS:-5}"
export HZ_SECONDS="${HZ_SECONDS:-20}"

if [ -z "${PC_SCHEDULER_CASES:-}" ]; then
  export PC_SCHEDULER_CASES=$'default|\nthreads2||2\nthreads4||4'
fi

exec "$ROOT/tools/run-pc-scheduler-sweep.sh" "$@"
