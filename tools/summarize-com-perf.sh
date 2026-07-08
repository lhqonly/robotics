#!/usr/bin/env bash
# Summarize tools/run-com-perf.sh component logs for one or more tags.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGDIR="${LOGDIR:-$ROOT/log/com-perf}"
FORMAT="${FORMAT:-markdown}"
PERF_EXPECTED_RATE_HZ="${PERF_EXPECTED_RATE_HZ:-}"
PERF_MIN_RATE_RATIO="${PERF_MIN_RATE_RATIO:-0.90}"
PERF_MAX_RATE_RATIO="${PERF_MAX_RATE_RATIO:-1.10}"
PERF_MAX_LOST="${PERF_MAX_LOST:-0}"
PERF_MAX_DUPLICATE="${PERF_MAX_DUPLICATE:-0}"
PERF_MAX_P99_GAP_S="${PERF_MAX_P99_GAP_S:-0.10}"
PERF_MAX_MAX_GAP_S="${PERF_MAX_MAX_GAP_S:-0.25}"

case "$FORMAT" in
  markdown|md|csv) ;;
  *)
    echo "ERROR: FORMAT must be markdown or csv, got '$FORMAT'" >&2
    exit 1
    ;;
esac

if [ "$#" -lt 1 ]; then
  echo "Usage: FORMAT=markdown|csv tools/summarize-com-perf.sh <tag> [tag...]" >&2
  echo "       LOGDIR=log/com-perf tools/summarize-com-perf.sh no_flash_smoke" >&2
  exit 1
fi

metric_from_line() {
  local line="$1"
  local key="$2"
  local value
  value="$(printf '%s\n' "$line" |
    tr ' ' '\n' |
    awk -F= -v key="$key" '$1 == key {print $2}' |
    tail -1)"
  printf '%s' "${value:-NA}"
}

tag_from_arg() {
  local arg="$1"
  local base
  base="$(basename "$arg")"
  case "$base" in
    *.cmd.log) printf '%s' "${base%.cmd.log}" ;;
    *.sampler.log) printf '%s' "${base%.sampler.log}" ;;
    *.hz.log) printf '%s' "${base%.hz.log}" ;;
    *.wire.log) printf '%s' "${base%.wire.log}" ;;
    *) printf '%s' "$arg" ;;
  esac
}

print_header() {
  if [ "$FORMAT" = "csv" ]; then
    if [ -n "$PERF_EXPECTED_RATE_HZ" ]; then
      echo "tag,verdict,reason,status_hz,sampler_hz,seq_rate_hz,seq_delta_avg,seq_delta_min,seq_delta_max,p95_gap_s,p99_gap_s,max_gap_s,zero_gap_count,pc_wire_rate_hz,pc_target_rate_hz,pc_target_window_hz,wire_kbit_s,baud_util_pct,lost,duplicate,inflight"
    else
      echo "tag,status_hz,sampler_hz,seq_rate_hz,seq_delta_avg,seq_delta_min,seq_delta_max,p95_gap_s,p99_gap_s,max_gap_s,zero_gap_count,pc_wire_rate_hz,pc_target_rate_hz,pc_target_window_hz,wire_kbit_s,baud_util_pct,lost,duplicate,inflight"
    fi
  else
    if [ -n "$PERF_EXPECTED_RATE_HZ" ]; then
      echo "| Tag | verdict | reason | status Hz | sampler Hz | seq Hz | seq delta avg/min/max | p95 gap s | p99 gap s | max gap s | zero gaps | PC wire Hz | PC target Hz | wire kbit/s | baud util % | lost | duplicate | inflight |"
      echo "|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
    else
      echo "| Tag | status Hz | sampler Hz | seq Hz | seq delta avg/min/max | p95 gap s | p99 gap s | max gap s | zero gaps | PC wire Hz | PC target Hz | wire kbit/s | baud util % | lost | duplicate | inflight |"
      echo "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
    fi
  fi
}

smoke_verdict() {
  local sampler_hz="$1"
  local seq_delta_min="$2"
  local seq_delta_max="$3"
  local p99_gap_s="$4"
  local max_gap_s="$5"
  local lost="$6"
  local duplicate="$7"

  awk \
    -v expected="$PERF_EXPECTED_RATE_HZ" \
    -v min_ratio="$PERF_MIN_RATE_RATIO" \
    -v max_ratio="$PERF_MAX_RATE_RATIO" \
    -v max_lost="$PERF_MAX_LOST" \
    -v max_duplicate="$PERF_MAX_DUPLICATE" \
    -v max_p99_gap="$PERF_MAX_P99_GAP_S" \
    -v max_max_gap="$PERF_MAX_MAX_GAP_S" \
    -v sampler_hz="$sampler_hz" \
    -v seq_delta_min="$seq_delta_min" \
    -v seq_delta_max="$seq_delta_max" \
    -v p99_gap_s="$p99_gap_s" \
    -v max_gap_s="$max_gap_s" \
    -v lost="$lost" \
    -v duplicate="$duplicate" '
      function missing(v) { return v == "" || v == "NA" }
      function add_reason(reason) {
        if (reasons == "") reasons = reason
        else reasons = reasons ";" reason
      }
      BEGIN {
        verdict = "PASS"
        if (missing(sampler_hz) || missing(seq_delta_min) ||
            missing(seq_delta_max) || missing(lost) || missing(duplicate)) {
          verdict = "WARN"
          add_reason("missing_metrics")
        }
        if (!missing(sampler_hz) &&
            (sampler_hz + 0 < expected * min_ratio ||
             sampler_hz + 0 > expected * max_ratio)) {
          verdict = "WARN"
          add_reason("rate_out_of_band")
        }
        if (!missing(seq_delta_min) && !missing(seq_delta_max) &&
            (seq_delta_min + 0 != 1 || seq_delta_max + 0 != 1)) {
          verdict = "WARN"
          add_reason("seq_delta_not_1")
        }
        if (!missing(p99_gap_s) && p99_gap_s + 0 > max_p99_gap) {
          verdict = "WARN"
          add_reason("p99_gap_high")
        }
        if (!missing(max_gap_s) && max_gap_s + 0 > max_max_gap) {
          verdict = "WARN"
          add_reason("max_gap_high")
        }
        if (!missing(duplicate) && duplicate + 0 > max_duplicate) {
          verdict = "WARN"
          add_reason("duplicate_nonzero")
        }
        if (!missing(lost) && lost + 0 > max_lost) {
          verdict = "FAIL"
          add_reason("lost_nonzero")
        }
        if (reasons == "") reasons = "-"
        printf "%s,%s", verdict, reasons
      }
    '
}

summarize_tag() {
  local tag="$1"
  local hz_log="$LOGDIR/$tag.hz.log"
  local sampler_log="$LOGDIR/$tag.sampler.log"
  local cmd_log="$LOGDIR/$tag.cmd.log"
  local wire_log="$LOGDIR/$tag.wire.log"
  local status_hz sampler_line cmd_line wire_line
  local sampler_hz seq_rate_hz seq_delta_avg seq_delta_min seq_delta_max
  local p95_gap_s p99_gap_s max_gap_s zero_gap_count
  local pc_wire_rate_hz pc_target_rate_hz pc_target_window_hz
  local wire_kbit_s baud_util_pct lost duplicate inflight
  local verdict reason verdict_csv

  status_hz="NA"
  if [ -f "$hz_log" ]; then
    status_hz="$(awk '/average rate:/ {rate=$3} END {print rate}' "$hz_log")"
    status_hz="${status_hz:-NA}"
  fi

  sampler_line=""
  if [ -f "$sampler_log" ]; then
    sampler_line="$(grep 'status_sampler:' "$sampler_log" | tail -1 || true)"
  fi
  sampler_hz="$(metric_from_line "$sampler_line" rate_hz)"
  seq_rate_hz="$(metric_from_line "$sampler_line" seq_rate_hz)"
  seq_delta_avg="$(metric_from_line "$sampler_line" seq_delta_avg)"
  seq_delta_min="$(metric_from_line "$sampler_line" seq_delta_min)"
  seq_delta_max="$(metric_from_line "$sampler_line" seq_delta_max)"
  p95_gap_s="$(metric_from_line "$sampler_line" p95_gap_s)"
  p99_gap_s="$(metric_from_line "$sampler_line" p99_gap_s)"
  max_gap_s="$(metric_from_line "$sampler_line" max_gap_s)"
  zero_gap_count="$(metric_from_line "$sampler_line" zero_gap_count)"

  cmd_line=""
  if [ -f "$cmd_log" ]; then
    cmd_line="$(grep 'link-health summary' "$cmd_log" | tail -1 || true)"
  fi
  pc_wire_rate_hz="$(metric_from_line "$cmd_line" wire_rate_hz)"
  pc_target_rate_hz="$(metric_from_line "$cmd_line" target_rate_hz)"
  pc_target_window_hz="$(metric_from_line "$cmd_line" target_window_hz)"
  lost="$(metric_from_line "$cmd_line" lost)"
  duplicate="$(metric_from_line "$cmd_line" duplicate)"
  inflight="$(metric_from_line "$cmd_line" inflight)"

  wire_line=""
  if [ -f "$wire_log" ]; then
    wire_line="$(grep '^METRICS ' "$wire_log" | tail -1 || true)"
  fi
  wire_kbit_s="$(metric_from_line "$wire_line" total_serial_kbit_s)"
  baud_util_pct="$(metric_from_line "$wire_line" baud_util_pct)"

  verdict=""
  reason=""
  if [ -n "$PERF_EXPECTED_RATE_HZ" ]; then
    verdict_csv="$(smoke_verdict "$sampler_hz" "$seq_delta_min" \
      "$seq_delta_max" "$p99_gap_s" "$max_gap_s" "$lost" "$duplicate")"
    verdict="${verdict_csv%%,*}"
    reason="${verdict_csv#*,}"
  fi

  if [ "$FORMAT" = "csv" ]; then
    if [ -n "$PERF_EXPECTED_RATE_HZ" ]; then
      printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$tag" "$verdict" "$reason" "$status_hz" "$sampler_hz" "$seq_rate_hz" \
        "$seq_delta_avg" "$seq_delta_min" "$seq_delta_max" \
        "$p95_gap_s" "$p99_gap_s" "$max_gap_s" "$zero_gap_count" \
        "$pc_wire_rate_hz" "$pc_target_rate_hz" "$pc_target_window_hz" \
        "$wire_kbit_s" "$baud_util_pct" "$lost" "$duplicate" "$inflight"
    else
      printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$tag" "$status_hz" "$sampler_hz" "$seq_rate_hz" \
        "$seq_delta_avg" "$seq_delta_min" "$seq_delta_max" \
        "$p95_gap_s" "$p99_gap_s" "$max_gap_s" "$zero_gap_count" \
        "$pc_wire_rate_hz" "$pc_target_rate_hz" "$pc_target_window_hz" \
        "$wire_kbit_s" "$baud_util_pct" "$lost" "$duplicate" "$inflight"
    fi
  else
    if [ -n "$PERF_EXPECTED_RATE_HZ" ]; then
      printf '| %s | %s | %s | %s | %s | %s | %s/%s/%s | %s | %s | %s | %s | %s | %s / %s | %s | %s | %s | %s | %s |\n' \
        "$tag" "$verdict" "$reason" "$status_hz" "$sampler_hz" "$seq_rate_hz" \
        "$seq_delta_avg" "$seq_delta_min" "$seq_delta_max" \
        "$p95_gap_s" "$p99_gap_s" "$max_gap_s" "$zero_gap_count" \
        "$pc_wire_rate_hz" "$pc_target_rate_hz" "$pc_target_window_hz" \
        "$wire_kbit_s" "$baud_util_pct" "$lost" "$duplicate" "$inflight"
    else
      printf '| %s | %s | %s | %s | %s/%s/%s | %s | %s | %s | %s | %s | %s / %s | %s | %s | %s | %s | %s |\n' \
        "$tag" "$status_hz" "$sampler_hz" "$seq_rate_hz" \
        "$seq_delta_avg" "$seq_delta_min" "$seq_delta_max" \
        "$p95_gap_s" "$p99_gap_s" "$max_gap_s" "$zero_gap_count" \
        "$pc_wire_rate_hz" "$pc_target_rate_hz" "$pc_target_window_hz" \
        "$wire_kbit_s" "$baud_util_pct" "$lost" "$duplicate" "$inflight"
    fi
  fi
}

print_header
for arg in "$@"; do
  summarize_tag "$(tag_from_arg "$arg")"
done
