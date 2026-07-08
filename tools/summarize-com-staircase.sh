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

  function hz_value(value,    n) {
    n = value + 0
    if (value ~ /khz$/) {
      return n * 1000
    }
    if (value ~ /hz$/) {
      return n
    }
    return "NA"
  }

  function strip_prefix_number(value, prefix) {
    sub("^" prefix, "", value)
    return value + 0
  }

  function stage_metadata(stage, out,    parts, count) {
    out["loop_hz"] = "NA"
    out["baud"] = "NA"
    out["poll_yields"] = "NA"
    out["pc_cmd_hz"] = "NA"
    out["qos"] = "NA"
    out["status_every_n"] = "NA"

    count = split(stage, parts, "_")
    if (count >= 7 && parts[1] == "latest") {
      out["loop_hz"] = hz_value(parts[2])
      sub(/baud$/, "", parts[3])
      out["baud"] = parts[3]
      out["poll_yields"] = strip_prefix_number(parts[4], "poll")
      out["pc_cmd_hz"] = hz_value(parts[5])
      out["qos"] = (parts[6] == "be") ? "best_effort" : parts[6]
      out["status_every_n"] = strip_prefix_number(parts[7], "n")
    } else if (count >= 4 && parts[1] == "baseline") {
      out["loop_hz"] = hz_value(parts[2])
      out["pc_cmd_hz"] = hz_value(parts[3])
      out["qos"] = parts[4]
      out["status_every_n"] = 1
      out["poll_yields"] = 0
    }
  }

  function is_missing(value) {
    return value == "" || value == "NA"
  }

  function add_reason(reason) {
    if (reasons == "") reasons = reason
    else reasons = reasons ";" reason
  }

  function profile_verdict(stage, meta, target_rx_hz, seq_rate_hz,
      seq_delta_min, seq_delta_max, p99_gap_s, max_gap_s, lost, duplicate,
      inflight,    expected_hz, min_ratio, max_ratio, max_p99_gap,
      max_max_gap, observed_hz) {
    reasons = ""
    verdict = "PASS"

    if (meta["pc_cmd_hz"] == "NA") {
      return "INFO,no_profile_expectation"
    }

    expected_hz = meta["pc_cmd_hz"] + 0
    min_ratio = 0.90
    max_ratio = 1.10
    max_p99_gap = 0.50
    max_max_gap = 1.00

    if (expected_hz <= 20) {
      max_p99_gap = 0.10
      max_max_gap = 0.25
    }

    observed_hz = target_rx_hz
    if (is_missing(observed_hz) && !is_missing(seq_rate_hz)) {
      observed_hz = seq_rate_hz
    }

    if (is_missing(observed_hz)) {
      verdict = "WARN"
      add_reason("missing_rate")
    } else if (observed_hz + 0 < expected_hz * min_ratio ||
        observed_hz + 0 > expected_hz * max_ratio) {
      verdict = "WARN"
      add_reason("target_rate_out_of_band")
    }

    if (!is_missing(p99_gap_s) && p99_gap_s + 0 > max_p99_gap) {
      verdict = "WARN"
      add_reason("p99_gap_high")
    }
    if (!is_missing(max_gap_s) && max_gap_s + 0 > max_max_gap) {
      verdict = "WARN"
      add_reason("max_gap_high")
    }

    if (meta["status_every_n"] == 1 &&
        (!is_missing(seq_delta_min) || !is_missing(seq_delta_max)) &&
        (seq_delta_min + 0 != 1 || seq_delta_max + 0 != 1)) {
      verdict = "WARN"
      add_reason("seq_delta_not_1")
    }

    if (!is_missing(duplicate) && duplicate + 0 > 0) {
      verdict = "FAIL"
      add_reason("duplicate_nonzero")
    }
    if (!is_missing(lost) && lost + 0 > 0) {
      verdict = "FAIL"
      add_reason("lost_nonzero")
    }

    if (reasons == "") reasons = "-"
    return verdict "," reasons
  }

  BEGIN {
    if (format == "csv") {
      print "stage,verdict,reason,loop_hz,baud,uart_read_poll_yields,pc_cmd_hz,qos,status_every_n,status_hz,sampler_hz,target_rx_hz,p95_gap_s,p99_gap_s,max_gap_s,zero_gap_count,seq_rate_hz,seq_delta_avg,seq_delta_min,seq_delta_max,pc_target_rate_hz,pc_target_window_hz,wire_kbit_s,wire_baud_util_pct,tx_kbit_s,rx_kbit_s,lost,duplicate,inflight"
    } else {
      print "| Stage | verdict | reason | loop Hz | baud | poll yields | PC Hz | QoS | status N | status Hz | sampler Hz | target rx Hz | p95 gap s | p99 gap s | max gap s | zero gaps | seq Hz | seq delta avg/min/max | PC target Hz | wire kbit/s | baud util % | lost | duplicate | inflight |"
      print "|---|---|---|---:|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
    }
  }

  /^METRICS / {
    stage = $2
    delete meta
    stage_metadata(stage, meta)
    status_hz = metric("status_hz")
    sampler_hz = metric("sampler_hz")
    target_rx_hz = metric("sampler_target_rx_hz")
    p95_gap_s = metric("sampler_p95_gap_s")
    p99_gap_s = metric("sampler_p99_gap_s")
    max_gap_s = metric("sampler_max_gap_s")
    zero_gap_count = metric("sampler_zero_gap_count")
    seq_rate_hz = metric("sampler_seq_rate_hz")
    seq_delta_avg = metric("seq_delta_avg")
    seq_delta_min = metric("seq_delta_min")
    seq_delta_max = metric("seq_delta_max")
    pc_target_rate_hz = metric("pc_target_rate_hz")
    pc_target_window_hz = metric("pc_target_window_hz")
    wire_kbit_s = metric("wire_kbit_s")
    wire_baud_util_pct = metric("wire_baud_util_pct")
    tx_kbit_s = metric("tx_kbit_s")
    rx_kbit_s = metric("rx_kbit_s")
    lost = metric("lost")
    duplicate = metric("duplicate")
    inflight = metric("inflight")
    verdict_csv = profile_verdict(stage, meta, target_rx_hz, seq_rate_hz,
      seq_delta_min, seq_delta_max, p99_gap_s, max_gap_s, lost, duplicate,
      inflight)
    verdict = substr(verdict_csv, 1, index(verdict_csv, ",") - 1)
    reason = substr(verdict_csv, index(verdict_csv, ",") + 1)

    if (format == "csv") {
      printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n",
        stage, verdict, reason, meta["loop_hz"], meta["baud"], meta["poll_yields"],
        meta["pc_cmd_hz"], meta["qos"], meta["status_every_n"],
        status_hz, sampler_hz, target_rx_hz, p95_gap_s, p99_gap_s,
        max_gap_s, zero_gap_count, seq_rate_hz, seq_delta_avg, seq_delta_min,
        seq_delta_max, pc_target_rate_hz, pc_target_window_hz, wire_kbit_s,
        wire_baud_util_pct, tx_kbit_s, rx_kbit_s, lost, duplicate, inflight
    } else {
      printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s/%s/%s | %s / %s | %s | %s | %s | %s | %s |\n",
        stage, verdict, reason, meta["loop_hz"], meta["baud"], meta["poll_yields"],
        meta["pc_cmd_hz"], meta["qos"], meta["status_every_n"],
        status_hz, sampler_hz, target_rx_hz, p95_gap_s, p99_gap_s,
        max_gap_s, zero_gap_count, seq_rate_hz, seq_delta_avg, seq_delta_min,
        seq_delta_max, pc_target_rate_hz, pc_target_window_hz, wire_kbit_s,
        wire_baud_util_pct, lost, duplicate, inflight
    }
  }
' "$SUMMARY"
