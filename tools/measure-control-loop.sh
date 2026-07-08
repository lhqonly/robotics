#!/usr/bin/env bash
# Measure the firmware-local control tick counter over SWD without using UART.
#
# Usage:
#   tools/measure-control-loop.sh [seconds] [elf] [gdb_port]
#
# The firmware must export the static symbol g_control_tick_count. The script
# hot-plugs with st-util --no-reset, reads the uint32 counter twice, and reports
# delta / elapsed. It does not require the micro-ROS serial bridge to stop.
set -euo pipefail

SECS="${1:-2}"
ELF="${2:-firmware/f103-microros/build/f103-microros.elf}"
PORT="${3:-4242}"

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

ADDR_HEX="$(arm-none-eabi-nm -n "$ELF" | awk '/ g_control_tick_count$/ {print $1; exit}')"
if [ -z "$ADDR_HEX" ]; then
  echo "ERROR: symbol g_control_tick_count not found in $ELF" >&2
  exit 1
fi
ADDR="0x$ADDR_HEX"

OWN_STUTIL=0
if ! ss -ltn "sport = :$PORT" | grep -q ":$PORT"; then
  st-util --multi --no-reset --listen_port "$PORT" >/tmp/measure-control-loop.stutil.log 2>&1 &
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

read_tick() {
  gdb-multiarch -q "$ELF" \
    -ex 'set pagination off' \
    -ex "target extended-remote :$PORT" \
    -ex "p/d *(unsigned int*)$ADDR" \
    -ex 'disconnect' \
    -ex 'quit' 2>/tmp/measure-control-loop.gdb.err |
    sed -nE 's/^\$[0-9]+ = ([0-9]+)/\1/p' | tail -1
}

A="$(read_tick)"
sleep "$SECS"
B="$(read_tick)"

if [ -z "$A" ] || [ -z "$B" ]; then
  echo "ERROR: failed to read tick counter" >&2
  cat /tmp/measure-control-loop.gdb.err >&2 || true
  exit 1
fi

DELTA=$((B - A))
if [ "$DELTA" -lt 0 ]; then
  DELTA=$((DELTA + 4294967296))
fi

HZ="$(awk -v d="$DELTA" -v s="$SECS" 'BEGIN { printf "%.2f", d / s }')"
ELAPSED_S="$(awk -v s="$SECS" 'BEGIN { printf "%.3f", s }')"

echo "symbol=g_control_tick_count addr=$ADDR"
echo "tick_a=$A tick_b=$B delta=$DELTA elapsed_s=$ELAPSED_S measured_hz=$HZ"
