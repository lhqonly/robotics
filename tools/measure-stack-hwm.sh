#!/usr/bin/env bash
# Measure FreeRTOS static task stack high-water marks over SWD.
#
# Usage:
#   tools/measure-stack-hwm.sh [elf] [gdb_port]
#
# Cortex-M stacks grow downward. FreeRTOS fills unused stack bytes with 0xA5, so
# the high-water mark is the contiguous 0xA5 region from the low address of each
# static stack array, reported in 32-bit stack words.
set -euo pipefail

ELF="${1:-firmware/f103-microros/build/f103-microros.elf}"
PORT="${2:-4242}"
STLINK_PREFLIGHT="${STLINK_PREFLIGHT:-1}"
STLINK_TIMEOUT_SECONDS="${STLINK_TIMEOUT_SECONDS:-30}"

if ! command -v arm-none-eabi-nm >/dev/null; then
  echo "ERROR: arm-none-eabi-nm not found" >&2
  exit 1
fi
if ! command -v gdb-multiarch >/dev/null; then
  echo "ERROR: gdb-multiarch not found" >&2
  exit 1
fi
if ! command -v st-util >/dev/null; then
  echo "ERROR: st-util not found" >&2
  exit 1
fi
if [ "$STLINK_PREFLIGHT" = "1" ] && ! command -v st-info >/dev/null; then
  echo "ERROR: st-info not found" >&2
  exit 1
fi
if [ ! -f "$ELF" ]; then
  echo "ERROR: ELF not found: $ELF" >&2
  exit 1
fi

check_stlink_ready() {
  local out
  if ! out="$(timeout "$STLINK_TIMEOUT_SECONDS" st-info --probe 2>&1)"; then
    echo "$out" >&2
    echo "ERROR: ST-LINK preflight failed; cannot measure stack watermarks" >&2
    return 1
  fi
  if printf '%s\n' "$out" |
      grep -Eq 'Found[[:space:]]+0 stlink programmers|dev-type:[[:space:]]+unknown|chipid:[[:space:]]+0x000'; then
    echo "$out" >&2
    echo "ERROR: ST-LINK/SWD preflight is invalid; cannot measure stack watermarks" >&2
    return 1
  fi
}

STACK_SYMBOLS=(
  microros_task_stack
  control_task_stack
  led_task_stack
  idle_task_stack
)

if [ "$STLINK_PREFLIGHT" = "1" ]; then
  check_stlink_ready
fi

OWN_STUTIL=0
if ! ss -ltn "sport = :$PORT" | grep -q ":$PORT"; then
  st-util --multi --no-reset --listen_port "$PORT" >/tmp/measure-stack-hwm.stutil.log 2>&1 &
  STUTIL_PID=$!
  OWN_STUTIL=1
  sleep 1
fi

cleanup() {
  if [ "$OWN_STUTIL" = "1" ]; then
    kill "$STUTIL_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

count_a5_prefix_words() {
  local file="$1"
  od -An -tx1 -v "$file" |
    awk '
      BEGIN { count = 0; done = 0 }
      {
        for (i = 1; i <= NF; i++) {
          if (done) {
            next
          }
          if (tolower($i) == "a5") {
            count++
          } else {
            done = 1
          }
        }
      }
      END { printf "%d", int(count / 4) }
    '
}

symbol_addr() {
  local symbol="$1"
  arm-none-eabi-nm -S "$ELF" |
    awk -v s="$symbol" '$4 == s && found == 0 { print $1; found = 1 }'
}

symbol_value() {
  local symbol="$1"
  arm-none-eabi-nm -a "$ELF" |
    awk -v s="$symbol" '$3 == s && found == 0 { print $1; found = 1 }'
}

dump_memory() {
  local addr_hex="$1"
  local end_hex="$2"
  local out="$3"
  timeout "$STLINK_TIMEOUT_SECONDS" gdb-multiarch -q "$ELF" \
    -ex 'set pagination off' \
    -ex "target extended-remote :$PORT" \
    -ex "dump binary memory $out 0x$addr_hex 0x$end_hex" \
    -ex 'disconnect' \
    -ex 'quit' >/tmp/measure-stack-hwm.gdb.log 2>/tmp/measure-stack-hwm.gdb.err
}

read_u32_le() {
  local file="$1"
  od -An -tu4 -N4 "$file" | awk '{print $1; exit}'
}

echo "elf=$ELF"
for sym in "${STACK_SYMBOLS[@]}"; do
  addr_hex="$(symbol_addr "$sym")"
  if [ -z "$addr_hex" ]; then
    echo "$sym missing"
    continue
  fi

  size_hex="$(arm-none-eabi-nm -S "$ELF" |
    awk -v s="$sym" '$4 == s && found == 0 { print $2; found = 1 }')"
  addr=$((16#$addr_hex))
  size=$((16#$size_hex))
  end=$((addr + size))
  out="/tmp/measure-stack-hwm.${sym}.bin"

  dump_memory "$(printf '%x' "$addr")" "$(printf '%x' "$end")" "$out"

  hwm_words="$(count_a5_prefix_words "$out")"
  total_words=$((size / 4))
  used_words=$((total_words - hwm_words))
  printf '%s addr=0x%s bytes=%d total_words=%d hwm_free_words=%d used_words=%d\n' \
    "$sym" "$addr_hex" "$size" "$total_words" "$hwm_words" "$used_words"
done

heap_end_addr_hex="$(symbol_addr g_newlib_heap_end)"
reserve_addr_hex="$(symbol_addr g_newlib_heap_msp_reserve_bytes)"
end_hex="$(symbol_value end)"
estack_hex="$(symbol_value _estack)"
if [ -n "$heap_end_addr_hex" ] && [ -n "$reserve_addr_hex" ] &&
    [ -n "$end_hex" ] && [ -n "$estack_hex" ]; then
  heap_ptr_out="/tmp/measure-stack-hwm.g_newlib_heap_end.bin"
  reserve_out="/tmp/measure-stack-hwm.g_newlib_heap_msp_reserve_bytes.bin"
  heap_end_addr=$((16#$heap_end_addr_hex))
  reserve_addr=$((16#$reserve_addr_hex))
  dump_memory "$heap_end_addr_hex" "$(printf '%x' $((heap_end_addr + 4)))" "$heap_ptr_out"
  dump_memory "$reserve_addr_hex" "$(printf '%x' $((reserve_addr + 4)))" "$reserve_out"
  heap_end_value="$(read_u32_le "$heap_ptr_out")"
  reserve_bytes="$(read_u32_le "$reserve_out")"
  estack_value=$((16#$estack_hex))
  end_value=$((16#$end_hex))
  heap_limit=$((estack_value - reserve_bytes))
  free_before_reserve=$((heap_limit - heap_end_value))
  if [ "$free_before_reserve" -lt 0 ]; then
    free_before_reserve=0
  fi
  bytes_to_estack=$((estack_value - heap_end_value))
  if [ "$bytes_to_estack" -lt 0 ]; then
    bytes_to_estack=0
  fi
  printf 'newlib_heap heap_end=0x%08x end=0x%08x estack=0x%08x msp_reserved_bytes=%d free_before_msp_reserve_bytes=%d bytes_to_estack=%d\n' \
    "$heap_end_value" "$end_value" "$estack_value" "$reserve_bytes" \
    "$free_before_reserve" "$bytes_to_estack"
else
  echo "newlib_heap missing"
fi
