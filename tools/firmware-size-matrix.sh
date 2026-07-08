#!/usr/bin/env bash
# Build selected STM32 firmware profiles and summarize static Flash/RAM usage.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/firmware/f103-microros"
OUTDIR="${OUTDIR:-$ROOT/log/firmware-size-matrix}"
TAG="${1:-size_matrix}"
CSV="$OUTDIR/$TAG.csv"
MD="$OUTDIR/$TAG.md"
BUILD_ROOT="${BUILD_ROOT:-$SRC/build-size-matrix}"
TOOLCHAIN_FILE="${TOOLCHAIN_FILE:-$SRC/toolchain-arm-m3.cmake}"
JOBS="${JOBS:-}"
SRAM_BYTES="${SRAM_BYTES:-20480}"
FLASH_BYTES="${FLASH_BYTES:-131072}"
RAM_STATIC_WARN_BYTES="${RAM_STATIC_WARN_BYTES:-18432}"

mkdir -p "$OUTDIR" "$BUILD_ROOT"

cmake_build_args=()
if [ -n "$JOBS" ]; then
  cmake_build_args+=(--parallel "$JOBS")
fi

write_headers() {
  cat >"$CSV" <<'EOF'
profile,verdict,reason,control_loop_hz,control_tick_source,qos,status_every_n,executor_spin_timeout_us,flash_bytes,flash_margin_bytes,ram_static_bytes,ram_static_margin_bytes,data_bytes,bss_bytes,microros_stack_bytes,control_stack_bytes,led_stack_bytes,idle_stack_bytes
EOF
  cat >"$MD" <<'EOF'
| Profile | verdict | reason | loop Hz | tick source | QoS | status every | spin us | Flash B | Flash margin B | static RAM B | RAM margin B | data B | bss B | micro-ROS stack B | control stack B | led stack B | idle stack B |
|---|---|---|---:|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
EOF
}

static_budget_verdict() {
  local flash_bytes="$1"
  local ram_static_bytes="$2"
  local verdict="PASS"
  local reason="-"

  if [ "$flash_bytes" -gt "$FLASH_BYTES" ]; then
    verdict="FAIL"
    reason="flash_overflow"
  fi
  if [ "$ram_static_bytes" -gt "$SRAM_BYTES" ]; then
    verdict="FAIL"
    if [ "$reason" = "-" ]; then
      reason="sram_overflow"
    else
      reason="$reason;sram_overflow"
    fi
  elif [ "$ram_static_bytes" -gt "$RAM_STATIC_WARN_BYTES" ] &&
      [ "$verdict" != "FAIL" ]; then
    verdict="WARN"
    reason="static_ram_above_warn"
  fi

  printf '%s,%s' "$verdict" "$reason"
}

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

stack_bytes_from_report() {
  local report="$1"
  local symbol="$2"
  awk -v symbol="$symbol" '
    $1 == symbol {
      for (i = 1; i <= NF; i++) {
        if ($i == "bytes=") {
          print $(i + 1)
          found = 1
          exit
        }
        split($i, kv, "=")
        if (kv[1] == "bytes" && kv[2] != "") {
          print kv[2]
          found = 1
          exit
        }
      }
    }
    END {
      if (!found) {
        print 0
      }
    }
  ' "$report"
}

run_profile() {
  local profile="$1"
  local loop_hz="$2"
  local qos="$3"
  local status_every="$4"
  local spin_timeout_us="${5:-1000}"
  local qos_best_effort="OFF"
  local build_dir="$BUILD_ROOT/$profile"
  local report="$OUTDIR/$TAG.$profile.report.log"
  local flash_bytes ram_static_bytes data_bytes bss_bytes
  local flash_margin ram_static_margin verdict_csv verdict reason
  local microros_stack control_stack led_stack idle_stack
  local control_tick_source="freertos_task"

  case "$qos" in
    reliable) qos_best_effort="OFF" ;;
    best_effort) qos_best_effort="ON" ;;
    *)
      echo "ERROR: invalid qos '$qos'" >&2
      exit 1
      ;;
  esac
  if [ "$loop_hz" -gt 1000 ]; then
    control_tick_source="tim2_isr"
  fi

  if [ -f "$build_dir/CMakeCache.txt" ] &&
      ! grep -q 'arm-none-eabi-gcc-ar' "$build_dir/CMakeCache.txt"; then
    echo "[size-matrix] remove non-ARM cached build dir: $build_dir"
    rm -rf "$build_dir"
  fi

  echo "[size-matrix] build profile=$profile loop_hz=$loop_hz qos=$qos status_every=$status_every spin_timeout_us=$spin_timeout_us"
  cmake -S "$SRC" -B "$build_dir" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DEXO_CONTROL_LOOP_HZ="$loop_hz" \
    -DEXO_QOS_BEST_EFFORT="$qos_best_effort" \
    -DEXO_STATUS_EVERY_N="$status_every" \
    -DEXO_EXECUTOR_SPIN_TIMEOUT_US="$spin_timeout_us" \
    >"$OUTDIR/$TAG.$profile.cmake.log" 2>&1
  cmake --build "$build_dir" "${cmake_build_args[@]}" \
    >"$OUTDIR/$TAG.$profile.build.log" 2>&1
  "$ROOT/tools/firmware-size-report.sh" "$build_dir/f103-microros.elf" >"$report"

  flash_bytes="$(metric_from_report "$report" flash_bytes)"
  ram_static_bytes="$(metric_from_report "$report" ram_static_bytes)"
  data_bytes="$(metric_from_report "$report" data_bytes)"
  bss_bytes="$(metric_from_report "$report" bss_bytes)"
  microros_stack="$(stack_bytes_from_report "$report" microros_task_stack)"
  control_stack="$(stack_bytes_from_report "$report" control_task_stack)"
  led_stack="$(stack_bytes_from_report "$report" led_task_stack)"
  idle_stack="$(stack_bytes_from_report "$report" idle_task_stack)"
  flash_margin=$((FLASH_BYTES - flash_bytes))
  ram_static_margin=$((SRAM_BYTES - ram_static_bytes))
  verdict_csv="$(static_budget_verdict "$flash_bytes" "$ram_static_bytes")"
  verdict="${verdict_csv%%,*}"
  reason="${verdict_csv#*,}"

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$profile" "$verdict" "$reason" "$loop_hz" "$control_tick_source" \
    "$qos" "$status_every" "$spin_timeout_us" \
    "$flash_bytes" "$flash_margin" "$ram_static_bytes" "$ram_static_margin" \
    "$data_bytes" "$bss_bytes" \
    "$microros_stack" "$control_stack" "$led_stack" "$idle_stack" >>"$CSV"
  printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
    "$profile" "$verdict" "$reason" "$loop_hz" "$control_tick_source" \
    "$qos" "$status_every" "$spin_timeout_us" \
    "$flash_bytes" "$flash_margin" "$ram_static_bytes" "$ram_static_margin" \
    "$data_bytes" "$bss_bytes" \
    "$microros_stack" "$control_stack" "$led_stack" "$idle_stack" >>"$MD"
}

write_headers

run_profile default_reliable_1khz 1000 reliable 1

for hz in 1000 2000 5000 10000; do
  run_profile "reliable_${hz}hz_status1" "$hz" reliable 1
done

for hz in 1000 2000 5000 10000; do
  run_profile "besteffort_${hz}hz_status40" "$hz" best_effort 40
done

echo "[size-matrix] csv=$CSV"
echo "[size-matrix] markdown=$MD"
