#!/usr/bin/env bash
# Build linker heap/MSP reserve candidates and summarize static Flash/RAM.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:-linker_reserve_sweep}"
LOGDIR="${LOGDIR:-$ROOT/log/firmware-linker-reserve-sweep}"
CSV="$LOGDIR/$TAG.csv"
MD="$LOGDIR/$TAG.md"
SRC="$ROOT/firmware/f103-microros"
TOOLCHAIN_FILE="${TOOLCHAIN_FILE:-$SRC/toolchain-arm-m3.cmake}"
BUILD_ROOT="${BUILD_ROOT:-$SRC/build-linker-reserve-sweep}"
BUILD_JOBS="${BUILD_JOBS:-}"

FLASH_BYTES="${FLASH_BYTES:-131072}"
SRAM_BYTES="${SRAM_BYTES:-20480}"
RAM_STATIC_WARN_BYTES="${RAM_STATIC_WARN_BYTES:-18432}"
CONTROL_LOOP_HZ="${CONTROL_LOOP_HZ:-10000}"
CONTROL_TIMER_IRQ_PRIORITY="${CONTROL_TIMER_IRQ_PRIORITY:-4}"
QOS_BEST_EFFORT="${QOS_BEST_EFFORT:-ON}"
STATUS_EVERY_N="${STATUS_EVERY_N:-40}"
UART_BAUD="${UART_BAUD:-921600}"
UART_READ_POLL_YIELDS="${UART_READ_POLL_YIELDS:-0}"
EXECUTOR_SPIN_TIMEOUT_US="${EXECUTOR_SPIN_TIMEOUT_US:-1000}"
RESERVE_CASES="${RESERVE_CASES:-default:512:1024 heap0_stack512:0:512 heap0_stack768:0:768 heap256_stack512:256:512}"

mkdir -p "$LOGDIR"
cmake_build_args=()
if [ -n "$BUILD_JOBS" ]; then
  cmake_build_args+=(--parallel "$BUILD_JOBS")
fi
echo "case,verdict,reason,newlib_heap_bytes,msp_stack_bytes,linker_user_heap_stack_bytes,control_loop_hz,control_timer_irq_priority,qos_best_effort,status_every_n,uart_baud,flash_bytes,flash_margin_bytes,ram_static_bytes,ram_static_margin_bytes,data_bytes,bss_bytes" >"$CSV"
{
  echo "| Case | verdict | reason | newlib heap B | MSP stack B | linker reserve B | loop Hz | timer IRQ prio | QoS best-effort | status every | baud | Flash B | Flash margin B | static RAM B | RAM margin B | data B | bss B |"
  echo "|---|---|---|---:|---:|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|"
} >"$MD"

metric_from_report() {
  local report="$1"
  local key="$2"
  tr ' ' '\n' <"$report" |
    awk -F= -v k="$key" '$1 == k {value=$2} END {print value}'
}

static_budget_verdict() {
  local flash_bytes="$1"
  local ram_static_bytes="$2"
  local verdict="PASS_STATIC"
  local reason="runtime_msp_heap_required"

  if [ "$flash_bytes" -gt "$FLASH_BYTES" ]; then
    verdict="FAIL_STATIC"
    reason="flash_overflow"
  fi
  if [ "$ram_static_bytes" -gt "$SRAM_BYTES" ]; then
    verdict="FAIL_STATIC"
    if [ "$reason" = "runtime_msp_heap_required" ]; then
      reason="sram_overflow"
    else
      reason="$reason;sram_overflow"
    fi
  elif [ "$ram_static_bytes" -gt "$RAM_STATIC_WARN_BYTES" ] &&
      [ "$verdict" = "PASS_STATIC" ]; then
    verdict="WARN_STATIC"
    reason="$reason;static_ram_above_warn"
  fi
  printf '%s,%s' "$verdict" "$reason"
}

for reserve_case in $RESERVE_CASES; do
  IFS=: read -r label heap_bytes stack_bytes <<EOF_CASE
$reserve_case
EOF_CASE
  if [ -z "${label:-}" ] || [ -z "${heap_bytes:-}" ] ||
      [ -z "${stack_bytes:-}" ]; then
    echo "ERROR: invalid RESERVE_CASE '$reserve_case'; expected label:heap_bytes:stack_bytes" >&2
    exit 1
  fi

  build_dir="$BUILD_ROOT/$label"
  report="$LOGDIR/$TAG.$label.report.log"
  if [ -f "$build_dir/CMakeCache.txt" ] &&
      ! grep -q 'arm-none-eabi-gcc-ar' "$build_dir/CMakeCache.txt"; then
    echo "[linker-reserve-sweep] remove non-ARM cached build dir: $build_dir"
    rm -rf "$build_dir"
  fi
  echo "[linker-reserve-sweep] build case=$label heap=$heap_bytes stack=$stack_bytes loop_hz=$CONTROL_LOOP_HZ"
  cmake -S "$SRC" -B "$build_dir" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DEXO_NEWLIB_HEAP_BYTES="$heap_bytes" \
    -DEXO_MSP_STACK_BYTES="$stack_bytes" \
    -DEXO_CONTROL_LOOP_HZ="$CONTROL_LOOP_HZ" \
    -DEXO_CONTROL_TIMER_IRQ_PRIORITY="$CONTROL_TIMER_IRQ_PRIORITY" \
    -DEXO_QOS_BEST_EFFORT="$QOS_BEST_EFFORT" \
    -DEXO_STATUS_EVERY_N="$STATUS_EVERY_N" \
    -DEXO_UART_BAUD="$UART_BAUD" \
    -DEXO_UART_READ_POLL_YIELDS="$UART_READ_POLL_YIELDS" \
    -DEXO_EXECUTOR_SPIN_TIMEOUT_US="$EXECUTOR_SPIN_TIMEOUT_US" \
    >"$LOGDIR/$TAG.$label.cmake.log" 2>&1
  cmake --build "$build_dir" "${cmake_build_args[@]}" \
    >"$LOGDIR/$TAG.$label.build.log" 2>&1
  "$ROOT/tools/firmware-size-report.sh" "$build_dir/f103-microros.elf" \
    >"$report"

  flash_bytes="$(metric_from_report "$report" flash_bytes)"
  ram_static_bytes="$(metric_from_report "$report" ram_static_bytes)"
  data_bytes="$(metric_from_report "$report" data_bytes)"
  bss_bytes="$(metric_from_report "$report" bss_bytes)"
  linker_reserve_bytes="$(metric_from_report "$report" linker_user_heap_stack_bytes)"
  flash_margin=$((FLASH_BYTES - flash_bytes))
  ram_static_margin=$((SRAM_BYTES - ram_static_bytes))
  verdict_csv="$(static_budget_verdict "$flash_bytes" "$ram_static_bytes")"
  verdict="${verdict_csv%%,*}"
  reason="${verdict_csv#*,}"

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$label" "$verdict" "$reason" "$heap_bytes" "$stack_bytes" \
    "$linker_reserve_bytes" "$CONTROL_LOOP_HZ" "$CONTROL_TIMER_IRQ_PRIORITY" \
    "$QOS_BEST_EFFORT" "$STATUS_EVERY_N" "$UART_BAUD" "$flash_bytes" \
    "$flash_margin" "$ram_static_bytes" "$ram_static_margin" \
    "$data_bytes" "$bss_bytes" >>"$CSV"
  printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
    "$label" "$verdict" "$reason" "$heap_bytes" "$stack_bytes" \
    "$linker_reserve_bytes" "$CONTROL_LOOP_HZ" "$CONTROL_TIMER_IRQ_PRIORITY" \
    "$QOS_BEST_EFFORT" "$STATUS_EVERY_N" "$UART_BAUD" "$flash_bytes" \
    "$flash_margin" "$ram_static_bytes" "$ram_static_margin" \
    "$data_bytes" "$bss_bytes" >>"$MD"
done

echo "[linker-reserve-sweep] markdown=$MD"
echo "[linker-reserve-sweep] csv=$CSV"
