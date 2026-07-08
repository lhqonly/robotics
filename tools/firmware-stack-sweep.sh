#!/usr/bin/env bash
# Build selected micro-ROS stack-size candidates and summarize static RAM.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/firmware/f103-microros"
OUTDIR="${OUTDIR:-$ROOT/log/firmware-stack-sweep}"
TAG="${1:-stack_sweep}"
BUILD_ROOT="${BUILD_ROOT:-$SRC/build-stack-sweep}"
TOOLCHAIN_FILE="${TOOLCHAIN_FILE:-$SRC/toolchain-arm-m3.cmake}"
STACK_WORDS="${STACK_WORDS:-768 704 640}"
CONTROL_LOOP_HZ="${CONTROL_LOOP_HZ:-10000}"
QOS_BEST_EFFORT="${QOS_BEST_EFFORT:-ON}"
STATUS_EVERY_N="${STATUS_EVERY_N:-40}"
UART_BAUD="${UART_BAUD:-921600}"
JOBS="${JOBS:-}"
CSV="$OUTDIR/$TAG.csv"
MD="$OUTDIR/$TAG.md"

mkdir -p "$OUTDIR" "$BUILD_ROOT"

cmake_build_args=()
if [ -n "$JOBS" ]; then
  cmake_build_args+=(--parallel "$JOBS")
fi

cat >"$CSV" <<'EOF'
microros_stack_words,microros_stack_bytes,control_loop_hz,qos_best_effort,status_every_n,uart_baud,flash_bytes,ram_static_bytes,data_bytes,bss_bytes
EOF
cat >"$MD" <<'EOF'
| micro-ROS stack words | stack B | loop Hz | QoS best-effort | status every | baud | Flash B | static RAM B | data B | bss B |
|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|
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

for stack_words in $STACK_WORDS; do
  build_dir="$BUILD_ROOT/${stack_words}w"
  report="$OUTDIR/$TAG.${stack_words}w.report.log"
  echo "[stack-sweep] build stack_words=$stack_words loop_hz=$CONTROL_LOOP_HZ qos_best_effort=$QOS_BEST_EFFORT status_every=$STATUS_EVERY_N baud=$UART_BAUD"

  cmake -S "$SRC" -B "$build_dir" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DEXO_MICROROS_TASK_STACK_WORDS="$stack_words" \
    -DEXO_CONTROL_LOOP_HZ="$CONTROL_LOOP_HZ" \
    -DEXO_QOS_BEST_EFFORT="$QOS_BEST_EFFORT" \
    -DEXO_STATUS_EVERY_N="$STATUS_EVERY_N" \
    -DEXO_UART_BAUD="$UART_BAUD" \
    >"$OUTDIR/$TAG.${stack_words}w.cmake.log" 2>&1
  cmake --build "$build_dir" "${cmake_build_args[@]}" \
    >"$OUTDIR/$TAG.${stack_words}w.build.log" 2>&1
  "$ROOT/tools/firmware-size-report.sh" "$build_dir/f103-microros.elf" >"$report"

  flash_bytes="$(metric_from_report "$report" flash_bytes)"
  ram_static_bytes="$(metric_from_report "$report" ram_static_bytes)"
  data_bytes="$(metric_from_report "$report" data_bytes)"
  bss_bytes="$(metric_from_report "$report" bss_bytes)"
  stack_bytes=$((stack_words * 4))

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$stack_words" "$stack_bytes" "$CONTROL_LOOP_HZ" "$QOS_BEST_EFFORT" \
    "$STATUS_EVERY_N" "$UART_BAUD" "$flash_bytes" "$ram_static_bytes" \
    "$data_bytes" "$bss_bytes" >>"$CSV"
  printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
    "$stack_words" "$stack_bytes" "$CONTROL_LOOP_HZ" "$QOS_BEST_EFFORT" \
    "$STATUS_EVERY_N" "$UART_BAUD" "$flash_bytes" "$ram_static_bytes" \
    "$data_bytes" "$bss_bytes" >>"$MD"
done

echo "[stack-sweep] csv=$CSV"
echo "[stack-sweep] markdown=$MD"
