#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

cat >"$TMPDIR/pass.csv" <<'EOF'
profile,verdict,reason,control_loop_hz,control_tick_source,control_timer_irq_priority,qos,status_every_n,executor_spin_timeout_us,flash_bytes,flash_margin_bytes,ram_static_bytes,ram_static_margin_bytes
default_reliable_1khz,PASS,-,1000,freertos_task,4,reliable,1,1000,82504,48568,14512,5968
besteffort_10000hz_status40,PASS,-,10000,tim2_isr,4,best_effort,40,1000,82328,48744,13912,6568
EOF

cat >"$TMPDIR/ram_fail.csv" <<'EOF'
profile,verdict,reason,control_loop_hz,control_tick_source,control_timer_irq_priority,qos,status_every_n,executor_spin_timeout_us,flash_bytes,flash_margin_bytes,ram_static_bytes,ram_static_margin_bytes
default_reliable_1khz,PASS,-,1000,freertos_task,4,reliable,1,1000,82504,48568,19000,1480
besteffort_10000hz_status40,PASS,-,10000,tim2_isr,4,best_effort,40,1000,82328,48744,13912,6568
EOF

cat >"$TMPDIR/missing.csv" <<'EOF'
profile,verdict,reason,control_loop_hz,control_tick_source,control_timer_irq_priority,qos,status_every_n,executor_spin_timeout_us,flash_bytes,flash_margin_bytes,ram_static_bytes,ram_static_margin_bytes
default_reliable_1khz,PASS,-,1000,freertos_task,4,reliable,1,1000,82504,48568,14512,5968
EOF

pass_out="$("$ROOT/tools/check-firmware-size-matrix-contract.sh" "$TMPDIR/pass.csv")"
printf '%s\n' "$pass_out" | grep -Fq 'PASS firmware_size_matrix_contract'
printf '%s\n' "$pass_out" | grep -Fq 'besteffort_10000hz_status40'

if "$ROOT/tools/check-firmware-size-matrix-contract.sh" "$TMPDIR/ram_fail.csv" \
    >"$TMPDIR/ram_fail.out" 2>&1; then
  echo "FAIL: expected ram_fail.csv to fail" >&2
  exit 1
fi
grep -Fq 'ram_static_bytes=19000' "$TMPDIR/ram_fail.out"

if "$ROOT/tools/check-firmware-size-matrix-contract.sh" "$TMPDIR/missing.csv" \
    >"$TMPDIR/missing.out" 2>&1; then
  echo "FAIL: expected missing.csv to fail" >&2
  exit 1
fi
grep -Fq 'missing_profile=besteffort_10000hz_status40' "$TMPDIR/missing.out"

echo "PASS: firmware size matrix contract tests"
