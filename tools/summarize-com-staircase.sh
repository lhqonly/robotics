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
    out["timer_irq_priority"] = "NA"
    out["poll_yields"] = "NA"
    out["spin_timeout_us"] = "NA"
    out["pc_cmd_hz"] = "NA"
    out["qos"] = "NA"
    out["status_every_n"] = "NA"

    count = split(stage, parts, "_")
    if (count >= 9 && parts[1] == "latest" && parts[4] ~ /^irqp/ &&
        parts[6] ~ /^spin/) {
      out["loop_hz"] = hz_value(parts[2])
      sub(/baud$/, "", parts[3])
      out["baud"] = parts[3]
      out["timer_irq_priority"] = strip_prefix_number(parts[4], "irqp")
      out["poll_yields"] = strip_prefix_number(parts[5], "poll")
      out["spin_timeout_us"] = strip_prefix_number(parts[6], "spin")
      out["pc_cmd_hz"] = hz_value(parts[7])
      out["qos"] = (parts[8] == "be") ? "best_effort" : parts[8]
      out["status_every_n"] = strip_prefix_number(parts[9], "n")
    } else if (count >= 8 && parts[1] == "latest" && parts[5] ~ /^spin/) {
      out["loop_hz"] = hz_value(parts[2])
      sub(/baud$/, "", parts[3])
      out["baud"] = parts[3]
      out["timer_irq_priority"] = 4
      out["poll_yields"] = strip_prefix_number(parts[4], "poll")
      out["spin_timeout_us"] = strip_prefix_number(parts[5], "spin")
      out["pc_cmd_hz"] = hz_value(parts[6])
      out["qos"] = (parts[7] == "be") ? "best_effort" : parts[7]
      out["status_every_n"] = strip_prefix_number(parts[8], "n")
    } else if (count >= 7 && parts[1] == "latest") {
      out["loop_hz"] = hz_value(parts[2])
      sub(/baud$/, "", parts[3])
      out["baud"] = parts[3]
      out["timer_irq_priority"] = 4
      out["poll_yields"] = strip_prefix_number(parts[4], "poll")
      out["spin_timeout_us"] = 1000
      out["pc_cmd_hz"] = hz_value(parts[5])
      out["qos"] = (parts[6] == "be") ? "best_effort" : parts[6]
      out["status_every_n"] = strip_prefix_number(parts[7], "n")
    } else if (count >= 4 && parts[1] == "baseline") {
      out["loop_hz"] = hz_value(parts[2])
      out["pc_cmd_hz"] = hz_value(parts[3])
      out["qos"] = parts[4]
      out["status_every_n"] = 1
      out["timer_irq_priority"] = 4
      out["poll_yields"] = 0
      out["spin_timeout_us"] = 1000
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
      inflight, pc_target_window_hz, pc_wire_gap_p99_ms, pc_wire_gap_max_ms,
      expected_hz, min_ratio, max_ratio, max_p99_gap, max_max_gap,
      observed_hz, period_ms, pc_p99_limit_ms, pc_max_limit_ms) {
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
    period_ms = 1000.0 / expected_hz
    pc_p99_limit_ms = period_ms * 4.0
    pc_max_limit_ms = period_ms * 10.0

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
    if (!is_missing(pc_target_window_hz) &&
        (pc_target_window_hz + 0 < expected_hz * min_ratio ||
         pc_target_window_hz + 0 > expected_hz * max_ratio)) {
      verdict = "WARN"
      add_reason("pc_target_rate_out_of_band")
    }
    if (!is_missing(pc_wire_gap_p99_ms) &&
        pc_wire_gap_p99_ms + 0 > pc_p99_limit_ms) {
      verdict = "WARN"
      add_reason("pc_wire_gap_p99_high")
    }
    if (!is_missing(pc_wire_gap_max_ms) &&
        pc_wire_gap_max_ms + 0 > pc_max_limit_ms) {
      verdict = "WARN"
      add_reason("pc_wire_gap_max_high")
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
      print "stage,verdict,reason,loop_hz,baud,timer_irq_priority,uart_read_poll_yields,executor_spin_timeout_us,pc_cmd_hz,qos,status_every_n,status_hz,sampler_hz,target_rx_hz,p95_gap_s,p99_gap_s,max_gap_s,zero_gap_count,seq_rate_hz,seq_delta_avg,seq_delta_min,seq_delta_max,pc_target_rate_hz,pc_target_window_hz,pc_wire_gap_p95_ms,pc_wire_gap_p99_ms,pc_wire_gap_max_ms,wire_kbit_s,wire_baud_util_pct,tx_kbit_s,rx_kbit_s,lost,duplicate,inflight"
    } else {
      print "| Stage | verdict | reason | loop Hz | baud | timer IRQ prio | poll yields | spin us | PC Hz | QoS | status N | status Hz | sampler Hz | target rx Hz | p95 gap s | p99 gap s | max gap s | zero gaps | seq Hz | seq delta avg/min/max | PC target Hz | PC gap p95/p99/max ms | wire kbit/s | baud util % | lost | duplicate | inflight |"
      print "|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
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
    pc_wire_gap_p95_ms = metric("pc_wire_gap_p95_ms")
    pc_wire_gap_p99_ms = metric("pc_wire_gap_p99_ms")
    pc_wire_gap_max_ms = metric("pc_wire_gap_max_ms")
    wire_kbit_s = metric("wire_kbit_s")
    wire_baud_util_pct = metric("wire_baud_util_pct")
    tx_kbit_s = metric("tx_kbit_s")
    rx_kbit_s = metric("rx_kbit_s")
    lost = metric("lost")
    duplicate = metric("duplicate")
    inflight = metric("inflight")
    verdict_csv = profile_verdict(stage, meta, target_rx_hz, seq_rate_hz,
      seq_delta_min, seq_delta_max, p99_gap_s, max_gap_s, lost, duplicate,
      inflight, pc_target_window_hz, pc_wire_gap_p99_ms,
      pc_wire_gap_max_ms)
    verdict = substr(verdict_csv, 1, index(verdict_csv, ",") - 1)
    reason = substr(verdict_csv, index(verdict_csv, ",") + 1)

    if (format == "csv") {
      printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n",
        stage, verdict, reason, meta["loop_hz"], meta["baud"],
        meta["timer_irq_priority"], meta["poll_yields"],
        meta["spin_timeout_us"], meta["pc_cmd_hz"], meta["qos"], meta["status_every_n"],
        status_hz, sampler_hz, target_rx_hz, p95_gap_s, p99_gap_s,
        max_gap_s, zero_gap_count, seq_rate_hz, seq_delta_avg, seq_delta_min,
        seq_delta_max, pc_target_rate_hz, pc_target_window_hz,
        pc_wire_gap_p95_ms, pc_wire_gap_p99_ms, pc_wire_gap_max_ms,
        wire_kbit_s, wire_baud_util_pct, tx_kbit_s, rx_kbit_s, lost,
        duplicate, inflight
    } else {
      printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s/%s/%s | %s / %s | %s/%s/%s | %s | %s | %s | %s | %s |\n",
        stage, verdict, reason, meta["loop_hz"], meta["baud"],
        meta["timer_irq_priority"], meta["poll_yields"],
        meta["spin_timeout_us"], meta["pc_cmd_hz"], meta["qos"], meta["status_every_n"],
        status_hz, sampler_hz, target_rx_hz, p95_gap_s, p99_gap_s,
        max_gap_s, zero_gap_count, seq_rate_hz, seq_delta_avg, seq_delta_min,
        seq_delta_max, pc_target_rate_hz, pc_target_window_hz,
        pc_wire_gap_p95_ms, pc_wire_gap_p99_ms, pc_wire_gap_max_ms,
        wire_kbit_s, wire_baud_util_pct, lost, duplicate, inflight
    }
  }
' "$SUMMARY"
