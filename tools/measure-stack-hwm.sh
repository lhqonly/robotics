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
if [ ! -f "$ELF" ]; then
  echo "ERROR: ELF not found: $ELF" >&2
  exit 1
fi

STACK_SYMBOLS=(
  microros_task_stack
  control_task_stack
  led_task_stack
  idle_task_stack
)

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

echo "elf=$ELF"
for sym in "${STACK_SYMBOLS[@]}"; do
  line="$(arm-none-eabi-nm -S "$ELF" |
    awk -v s="$sym" '$4 == s && found == 0 { print; found = 1 }')"
  if [ -z "$line" ]; then
    echo "$sym missing"
    continue
  fi

  addr_hex="$(awk '{print $1}' <<<"$line")"
  size_hex="$(awk '{print $2}' <<<"$line")"
  addr=$((16#$addr_hex))
  size=$((16#$size_hex))
  end=$((addr + size))
  out="/tmp/measure-stack-hwm.${sym}.bin"

  gdb-multiarch -q "$ELF" \
    -ex 'set pagination off' \
    -ex "target extended-remote :$PORT" \
    -ex "dump binary memory $out 0x$(printf '%x' "$addr") 0x$(printf '%x' "$end")" \
    -ex 'disconnect' \
    -ex 'quit' >/tmp/measure-stack-hwm.gdb.log 2>/tmp/measure-stack-hwm.gdb.err

  hwm_words="$(count_a5_prefix_words "$out")"
  total_words=$((size / 4))
  used_words=$((total_words - hwm_words))
  printf '%s addr=0x%s bytes=%d total_words=%d hwm_free_words=%d used_words=%d\n' \
    "$sym" "$addr_hex" "$size" "$total_words" "$hwm_words" "$used_words"
done
