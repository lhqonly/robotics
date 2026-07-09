#!/usr/bin/env bash
# Build executor spin-timeout candidates and summarize static Flash/RAM usage.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/firmware/f103-microros"
OUTDIR="${OUTDIR:-$ROOT/log/firmware-spin-timeout-sweep}"
TAG="${1:-spin_timeout_sweep}"
BUILD_ROOT="${BUILD_ROOT:-$SRC/build-spin-timeout-sweep}"
TOOLCHAIN_FILE="${TOOLCHAIN_FILE:-$SRC/toolchain-arm-m3.cmake}"
SPIN_TIMEOUT_US="${SPIN_TIMEOUT_US:-1000 500 200 100}"
CONTROL_LOOP_HZ="${CONTROL_LOOP_HZ:-10000}"
CONTROL_TIMER_IRQ_PRIORITY="${CONTROL_TIMER_IRQ_PRIORITY:-4}"
QOS_BEST_EFFORT="${QOS_BEST_EFFORT:-ON}"
STATUS_EVERY_N="${STATUS_EVERY_N:-40}"
UART_BAUD="${UART_BAUD:-921600}"
UART_READ_POLL_YIELDS="${UART_READ_POLL_YIELDS:-0}"
JOBS="${JOBS:-}"
SRAM_BYTES="${SRAM_BYTES:-20480}"
FLASH_BYTES="${FLASH_BYTES:-131072}"
RAM_STATIC_WARN_BYTES="${RAM_STATIC_WARN_BYTES:-18432}"
CSV="$OUTDIR/$TAG.csv"
MD="$OUTDIR/$TAG.md"

mkdir -p "$OUTDIR" "$BUILD_ROOT"

cmake_build_args=()
if [ -n "$JOBS" ]; then
  cmake_build_args+=(--parallel "$JOBS")
fi

cat >"$CSV" <<'EOF'
executor_spin_timeout_us,verdict,reason,control_loop_hz,control_timer_irq_priority,qos_best_effort,status_every_n,uart_baud,uart_read_poll_yields,flash_bytes,flash_margin_bytes,ram_static_bytes,ram_static_margin_bytes,data_bytes,bss_bytes
EOF
cat >"$MD" <<'EOF'
| spin timeout us | verdict | reason | loop Hz | timer IRQ prio | QoS best-effort | status every | baud | poll yields | Flash B | Flash margin B | static RAM B | RAM margin B | data B | bss B |
|---:|---|---|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
EOF

metric_from_report() {
  local report="$1"
  local key="$2"
  awk -v key="$key" '
    {
      for (i = 1; i <= NF; i++) {
        split($i, kv, "=")
        if (kv[1] == key) {
          print kv[2]
          exit
        }
      }
    }
  ' "$report"
}

static_budget_verdict() {
  local flash_bytes="$1"
  local ram_static_bytes="$2"
  local verdict="PASS_STATIC"
  local reason="runtime_latency_required"

  if [ "$flash_bytes" -gt "$FLASH_BYTES" ]; then
    verdict="FAIL"
    reason="$reason;flash_overflow"
  fi
  if [ "$ram_static_bytes" -gt "$SRAM_BYTES" ]; then
    verdict="FAIL"
    reason="$reason;sram_overflow"
  elif [ "$ram_static_bytes" -gt "$RAM_STATIC_WARN_BYTES" ] &&
      [ "$verdict" != "FAIL" ]; then
    verdict="WARN_STATIC"
    reason="$reason;static_ram_above_warn"
  fi

  printf '%s,%s' "$verdict" "$reason"
}

for spin_timeout_us in $SPIN_TIMEOUT_US; do
  build_dir="$BUILD_ROOT/${spin_timeout_us}us"
  report="$OUTDIR/$TAG.${spin_timeout_us}us.report.log"
  echo "[spin-timeout-sweep] build spin_timeout_us=$spin_timeout_us loop_hz=$CONTROL_LOOP_HZ timer_irq_prio=$CONTROL_TIMER_IRQ_PRIORITY qos_best_effort=$QOS_BEST_EFFORT status_every=$STATUS_EVERY_N baud=$UART_BAUD poll_yields=$UART_READ_POLL_YIELDS"

  cmake -S "$SRC" -B "$build_dir" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DEXO_EXECUTOR_SPIN_TIMEOUT_US="$spin_timeout_us" \
    -DEXO_CONTROL_LOOP_HZ="$CONTROL_LOOP_HZ" \
    -DEXO_CONTROL_TIMER_IRQ_PRIORITY="$CONTROL_TIMER_IRQ_PRIORITY" \
    -DEXO_QOS_BEST_EFFORT="$QOS_BEST_EFFORT" \
    -DEXO_STATUS_EVERY_N="$STATUS_EVERY_N" \
    -DEXO_UART_BAUD="$UART_BAUD" \
    -DEXO_UART_READ_POLL_YIELDS="$UART_READ_POLL_YIELDS" \
    >"$OUTDIR/$TAG.${spin_timeout_us}us.cmake.log" 2>&1
  cmake --build "$build_dir" "${cmake_build_args[@]}" \
    >"$OUTDIR/$TAG.${spin_timeout_us}us.build.log" 2>&1
  "$ROOT/tools/firmware-size-report.sh" "$build_dir/f103-microros.elf" >"$report"

  flash_bytes="$(metric_from_report "$report" flash_bytes)"
  ram_static_bytes="$(metric_from_report "$report" ram_static_bytes)"
  data_bytes="$(metric_from_report "$report" data_bytes)"
  bss_bytes="$(metric_from_report "$report" bss_bytes)"
  flash_margin=$((FLASH_BYTES - flash_bytes))
  ram_static_margin=$((SRAM_BYTES - ram_static_bytes))
  verdict_csv="$(static_budget_verdict "$flash_bytes" "$ram_static_bytes")"
  verdict="${verdict_csv%%,*}"
  reason="${verdict_csv#*,}"

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$spin_timeout_us" "$verdict" "$reason" \
    "$CONTROL_LOOP_HZ" "$CONTROL_TIMER_IRQ_PRIORITY" "$QOS_BEST_EFFORT" \
    "$STATUS_EVERY_N" "$UART_BAUD" "$UART_READ_POLL_YIELDS" \
    "$flash_bytes" "$flash_margin" \
    "$ram_static_bytes" "$ram_static_margin" "$data_bytes" "$bss_bytes" >>"$CSV"
  printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
    "$spin_timeout_us" "$verdict" "$reason" \
    "$CONTROL_LOOP_HZ" "$CONTROL_TIMER_IRQ_PRIORITY" "$QOS_BEST_EFFORT" \
    "$STATUS_EVERY_N" "$UART_BAUD" "$UART_READ_POLL_YIELDS" \
    "$flash_bytes" "$flash_margin" \
    "$ram_static_bytes" "$ram_static_margin" "$data_bytes" "$bss_bytes" >>"$MD"
done

echo "[spin-timeout-sweep] csv=$CSV"
echo "[spin-timeout-sweep] markdown=$MD"
