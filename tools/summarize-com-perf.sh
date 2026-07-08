#!/usr/bin/env bash
# Summarize tools/run-com-perf.sh component logs for one or more tags.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGDIR="${LOGDIR:-$ROOT/log/com-perf}"
FORMAT="${FORMAT:-markdown}"

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
    echo "tag,status_hz,sampler_hz,seq_rate_hz,seq_delta_avg,seq_delta_min,seq_delta_max,p95_gap_s,p99_gap_s,max_gap_s,zero_gap_count,pc_wire_rate_hz,pc_target_rate_hz,pc_target_window_hz,wire_kbit_s,baud_util_pct,lost,duplicate,inflight"
  else
    echo "| Tag | status Hz | sampler Hz | seq Hz | seq delta avg/min/max | p95 gap s | p99 gap s | max gap s | zero gaps | PC wire Hz | PC target Hz | wire kbit/s | baud util % | lost | duplicate | inflight |"
    echo "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
  fi
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

  if [ "$FORMAT" = "csv" ]; then
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$tag" "$status_hz" "$sampler_hz" "$seq_rate_hz" \
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
}

print_header
for arg in "$@"; do
  summarize_tag "$(tag_from_arg "$arg")"
done
