#!/usr/bin/env bash
# Convert tools/run-com-staircase.sh summary logs into CSV or Markdown tables.
set -euo pipefail

SUMMARY="${1:-}"
FORMAT="${FORMAT:-markdown}"

if [ -z "$SUMMARY" ] || [ ! -f "$SUMMARY" ]; then
  echo "Usage: FORMAT=markdown|csv tools/summarize-com-staircase.sh <summary.log>" >&2
  exit 1
fi

case "$FORMAT" in
  markdown|md|csv) ;;
  *)
    echo "ERROR: FORMAT must be markdown or csv, got '$FORMAT'" >&2
    exit 1
    ;;
esac

awk -v format="$FORMAT" '
  function metric(key,    i, prefix) {
    prefix = key "="
    for (i = 3; i <= NF; i++) {
      if (index($i, prefix) == 1) {
        return substr($i, length(prefix) + 1)
      }
    }
    return "NA"
  }

  BEGIN {
    if (format == "csv") {
      print "stage,status_hz,sampler_hz,target_rx_hz,p95_gap_s,p99_gap_s,max_gap_s,seq_rate_hz,seq_delta_avg,seq_delta_min,seq_delta_max,pc_target_rate_hz,pc_target_window_hz,lost,duplicate,inflight"
    } else {
      print "| Stage | status Hz | sampler Hz | target rx Hz | p95 gap s | p99 gap s | max gap s | seq Hz | seq delta avg/min/max | PC target Hz | lost | duplicate | inflight |"
      print "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
    }
  }

  /^METRICS / {
    stage = $2
    status_hz = metric("status_hz")
    sampler_hz = metric("sampler_hz")
    target_rx_hz = metric("sampler_target_rx_hz")
    p95_gap_s = metric("sampler_p95_gap_s")
    p99_gap_s = metric("sampler_p99_gap_s")
    max_gap_s = metric("sampler_max_gap_s")
    seq_rate_hz = metric("sampler_seq_rate_hz")
    seq_delta_avg = metric("seq_delta_avg")
    seq_delta_min = metric("seq_delta_min")
    seq_delta_max = metric("seq_delta_max")
    pc_target_rate_hz = metric("pc_target_rate_hz")
    pc_target_window_hz = metric("pc_target_window_hz")
    lost = metric("lost")
    duplicate = metric("duplicate")
    inflight = metric("inflight")

    if (format == "csv") {
      printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n",
        stage, status_hz, sampler_hz, target_rx_hz, p95_gap_s, p99_gap_s,
        max_gap_s, seq_rate_hz, seq_delta_avg, seq_delta_min, seq_delta_max,
        pc_target_rate_hz, pc_target_window_hz, lost, duplicate, inflight
    } else {
      printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s/%s/%s | %s / %s | %s | %s | %s |\n",
        stage, status_hz, sampler_hz, target_rx_hz, p95_gap_s, p99_gap_s,
        max_gap_s, seq_rate_hz, seq_delta_avg, seq_delta_min, seq_delta_max,
        pc_target_rate_hz, pc_target_window_hz, lost, duplicate, inflight
    }
  }
' "$SUMMARY"
