#!/usr/bin/env bash
# Regression tests for communication summary parsers.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/com-perf"

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"

  if ! grep -Fq -- "$needle" <<<"$haystack"; then
    echo "FAIL: $label" >&2
    echo "missing: $needle" >&2
    echo "output:" >&2
    printf '%s\n' "$haystack" >&2
    exit 1
  fi
}

write_perf_logs() {
  printf '%s\n' 'average rate: 19.997' >"$TMPDIR/com-perf/sample.hz.log"
  printf '%s\n' \
    'status_sampler: rate_hz=20.001 seq_rate_hz=20.001 seq_delta_avg=1 seq_delta_min=1 seq_delta_max=1 p95_gap_s=0.051 p99_gap_s=0.056 max_gap_s=0.061 zero_gap_count=0' \
    >"$TMPDIR/com-perf/sample.sampler.log"
  printf '%s\n' \
    '[node_com_cmd] link-health summary: wire_rate_hz=20.001 target_rate_hz=20.000 target_window_hz=20.000 wire_gap_p95_ms=5.1 wire_gap_p99_ms=6.2 wire_gap_max_ms=9.9 lost=0 duplicate=0 inflight=1' \
    >"$TMPDIR/com-perf/sample.cmd.log"
  printf '%s\n' \
    'METRICS total_serial_kbit_s=90.77 baud_util_pct=9.85' \
    >"$TMPDIR/com-perf/sample.wire.log"

  printf '%s\n' 'average rate: 20.000' >"$TMPDIR/com-perf/legacy.hz.log"
  printf '%s\n' \
    'status_sampler: rate_hz=20.000 seq_rate_hz=20.000 seq_delta_avg=1 seq_delta_min=1 seq_delta_max=1 p95_gap_s=0.050 p99_gap_s=0.055 max_gap_s=0.060 zero_gap_count=0' \
    >"$TMPDIR/com-perf/legacy.sampler.log"
  printf '%s\n' \
    '[node_com_cmd] link-health summary: wire_rate_hz=20.000 target_rate_hz=20.000 target_window_hz=20.000 lost=0 duplicate=0 inflight=1' \
    >"$TMPDIR/com-perf/legacy.cmd.log"

  printf '%s\n' 'average rate: 20.000' >"$TMPDIR/com-perf/badpc.hz.log"
  printf '%s\n' \
    'status_sampler: rate_hz=20.000 seq_rate_hz=20.000 seq_delta_avg=1 seq_delta_min=1 seq_delta_max=1 p95_gap_s=0.050 p99_gap_s=0.055 max_gap_s=0.060 zero_gap_count=0' \
    >"$TMPDIR/com-perf/badpc.sampler.log"
  printf '%s\n' \
    '[node_com_cmd] link-health summary: wire_rate_hz=20.000 target_rate_hz=20.000 target_window_hz=20.000 wire_gap_p95_ms=50.0 wire_gap_p99_ms=250.0 wire_gap_max_ms=600.0 lost=0 duplicate=0 inflight=1' \
    >"$TMPDIR/com-perf/badpc.cmd.log"

  printf '%s\n' 'average rate: 20.000' >"$TMPDIR/com-perf/lostcase.hz.log"
  printf '%s\n' \
    'status_sampler: rate_hz=20.000 seq_rate_hz=20.000 seq_delta_avg=1.005 seq_delta_min=1 seq_delta_max=2 p95_gap_s=0.050 p99_gap_s=0.060 max_gap_s=0.080 zero_gap_count=0' \
    >"$TMPDIR/com-perf/lostcase.sampler.log"
  printf '%s\n' \
    '[node_com_cmd] [ERROR] [123.456] [node_com_cmd]: LOST seq=42: deadline 120.0 ms exceeded (waited_ms=123.456, deadline_ms=120.0, lost_count=1)' \
    '[node_com_cmd] link-health summary: wire_rate_hz=20.000 target_rate_hz=20.000 target_window_hz=20.000 wire_gap_p95_ms=50.0 wire_gap_p99_ms=60.0 wire_gap_max_ms=80.0 lost=1 duplicate=0 inflight=1' \
    >"$TMPDIR/com-perf/lostcase.cmd.log"
}

test_com_perf_summary() {
  local csv md

  csv="$(LOGDIR="$TMPDIR/com-perf" FORMAT=csv "$ROOT/tools/summarize-com-perf.sh" sample legacy)"
  assert_contains "$csv" \
    'pc_wire_gap_p95_ms,pc_wire_gap_p99_ms,pc_wire_gap_max_ms' \
    'com-perf csv header includes PC publish gap fields'
  assert_contains "$csv" \
    'sample,19.997,20.001,20.001,1,1,1,0.051,0.056,0.061,0,20.001,20.000,20.000,5.1,6.2,9.9,90.77,9.85,0,0,1' \
    'com-perf csv parses sample metrics'
  assert_contains "$csv" \
    'legacy,20.000,20.000,20.000,1,1,1,0.050,0.055,0.060,0,20.000,20.000,20.000,NA,NA,NA,NA,NA,0,0,1' \
    'com-perf csv keeps missing new fields as NA'

  md="$(LOGDIR="$TMPDIR/com-perf" "$ROOT/tools/summarize-com-perf.sh" sample)"
  assert_contains "$md" 'PC gap p95/p99/max ms' \
    'com-perf markdown header includes PC publish gap fields'
  assert_contains "$md" '| sample | 19.997 | 20.001 | 20.001 | 1/1/1 | 0.051 | 0.056 | 0.061 | 0 | 20.001 | 20.000 / 20.000 | 5.1/6.2/9.9 | 90.77 | 9.85 | 0 | 0 | 1 |' \
    'com-perf markdown parses sample metrics'

  csv="$(LOGDIR="$TMPDIR/com-perf" FORMAT=csv PERF_EXPECTED_RATE_HZ=20 \
    "$ROOT/tools/summarize-com-perf.sh" badpc)"
  assert_contains "$csv" \
    'badpc,WARN,pc_wire_gap_p99_high;pc_wire_gap_max_high,20.000,20.000,20.000,1,1,1,0.050,0.055,0.060,0,20.000,20.000,20.000,50.0,250.0,600.0,NA,NA,0,0,1' \
    'com-perf verdict flags PC publish gap contract'
}

test_staircase_summary() {
  local summary csv md

  summary="$TMPDIR/staircase.summary.log"
  printf '%s\n' \
    'mode build_firmware=1 flash_firmware=1 dry_run=0 staircase_bauds=921600 staircase_control_timer_irq_priorities=4 staircase_uart_read_poll_yields=0 staircase_executor_spin_timeout_us=100 pc_launch_prefix=taskset -c 2 staircase_pc_launch_case_count=2' \
    'METRICS latest_10khz_921600baud_irqp4_poll0_spin100_200hz_be_n40 status_hz=5 sampler_hz=5 sampler_target_rx_hz=200.0 sampler_p95_gap_s=0.051 sampler_p99_gap_s=0.056 sampler_max_gap_s=0.061 sampler_zero_gap_count=0 sampler_seq_rate_hz=5 seq_delta_avg=40 seq_delta_min=40 seq_delta_max=40 pc_target_rate_hz=199.9 pc_target_window_hz=200.1 pc_wire_gap_p95_ms=5.0 pc_wire_gap_p99_ms=6.0 pc_wire_gap_max_ms=8.0 wire_kbit_s=90.77 wire_baud_util_pct=9.85 tx_kbit_s=48 rx_kbit_s=42 lost=0 duplicate=0 inflight=0' \
    'METRICS latest_10khz_921600baud_irqp4_poll0_spin100_200hz_be_n40_badpc status_hz=5 sampler_hz=5 sampler_target_rx_hz=200.0 sampler_p95_gap_s=0.051 sampler_p99_gap_s=0.056 sampler_max_gap_s=0.061 sampler_zero_gap_count=0 sampler_seq_rate_hz=5 seq_delta_avg=40 seq_delta_min=40 seq_delta_max=40 pc_target_rate_hz=199.9 pc_target_window_hz=200.1 pc_wire_gap_p95_ms=5.0 pc_wire_gap_p99_ms=25.0 pc_wire_gap_max_ms=60.0 wire_kbit_s=90.77 wire_baud_util_pct=9.85 tx_kbit_s=48 rx_kbit_s=42 lost=0 duplicate=0 inflight=0' \
    >"$summary"

  csv="$(FORMAT=csv "$ROOT/tools/summarize-com-staircase.sh" "$summary")"
  assert_contains "$csv" \
    'baud,timer_irq_priority,uart_read_poll_yields,executor_spin_timeout_us,pc_cmd_hz,qos,status_every_n,pc_launch_prefix' \
    'staircase csv header includes timer IRQ priority and launch prefix fields'
  assert_contains "$csv" \
    'latest_10khz_921600baud_irqp4_poll0_spin100_200hz_be_n40,PASS,-,10000,921600,4,0,100,200,best_effort,40,taskset -c 2,5,5,200.0,0.051,0.056,0.061,0,5,40,40,40,199.9,200.1,5.0,6.0,8.0,90.77,9.85,48,42,0,0,0' \
    'staircase csv parses metadata and metrics'
  assert_contains "$csv" \
    'latest_10khz_921600baud_irqp4_poll0_spin100_200hz_be_n40_badpc,WARN,pc_wire_gap_p99_high;pc_wire_gap_max_high,10000,921600,4,0,100,200,best_effort,40,taskset -c 2,5,5,200.0,0.051,0.056,0.061,0,5,40,40,40,199.9,200.1,5.0,25.0,60.0,90.77,9.85,48,42,0,0,0' \
    'staircase csv flags PC publish gap contract'

  md="$("$ROOT/tools/summarize-com-staircase.sh" "$summary")"
  assert_contains "$md" 'timer IRQ prio' \
    'staircase markdown header includes timer IRQ priority field'
  assert_contains "$md" 'PC launch prefix' \
    'staircase markdown header includes PC launch prefix field'
  assert_contains "$md" '| latest_10khz_921600baud_irqp4_poll0_spin100_200hz_be_n40 | PASS | - | 10000 | 921600 | 4 | 0 | 100 | 200 | best_effort | 40 | taskset -c 2 | 5 | 5 | 200.0 | 0.051 | 0.056 | 0.061 | 0 | 5 | 40/40/40 | 199.9 / 200.1 | 5.0/6.0/8.0 | 90.77 | 9.85 | 0 | 0 | 0 |' \
    'staircase markdown parses metadata and metrics'
}

test_overnight_summary() {
  local watch_log csv md

  watch_log="$TMPDIR/overnight.log"
  printf '%s\n' \
    '[2026-07-08 23:00:00] start tag_prefix=overnight_test interval_s=1' \
    '[2026-07-08 23:00:01] iteration=1 smoke tag=sample' \
    '[2026-07-08 23:00:02] iteration=2 smoke tag=legacy' \
    '[2026-07-08 23:00:02] iteration=3 smoke tag=lostcase' \
    '[2026-07-08 23:00:03] done failures=0' \
    >"$watch_log"

  csv="$(LOGDIR="$TMPDIR/com-perf" FORMAT=csv "$ROOT/tools/summarize-overnight-com-watch.sh" "$watch_log")"
  assert_contains "$csv" 'sample,PASS,-,19.997,20.001' \
    'overnight csv delegates sample metrics'
  assert_contains "$csv" 'legacy,PASS,-,20.000,20.000' \
    'overnight csv delegates legacy metrics'

  md="$(LOGDIR="$TMPDIR/com-perf" "$ROOT/tools/summarize-overnight-com-watch.sh" "$watch_log")"
  assert_contains "$md" '- smoke samples: 3' \
    'overnight markdown counts smoke samples'
  assert_contains "$md" '- PASS/WARN/FAIL/INFO: 2/0/1/0' \
    'overnight markdown includes verdict summary'
  assert_contains "$md" 'lost_nonzero=1' \
    'overnight markdown includes lost reason summary'
  assert_contains "$md" 'seq_delta_not_1=1' \
    'overnight markdown includes seq-delta reason summary'
  assert_contains "$md" '## Failure Events' \
    'overnight markdown includes failure events section'
  assert_contains "$md" '- lostcase: LOST seq=42: deadline 120.0 ms exceeded (waited_ms=123.456, deadline_ms=120.0, lost_count=1)' \
    'overnight markdown summarizes lost event detail'
  assert_contains "$md" '| sample | PASS | - | 19.997 | 20.001' \
    'overnight markdown includes summarized sample row'
}

write_perf_logs
test_com_perf_summary
test_staircase_summary
test_overnight_summary

echo "PASS: communication summary parser tests"
