#!/usr/bin/env bash
# Summarize STM32 firmware flash/RAM usage and the largest static symbols.
set -euo pipefail

ELF="${1:-firmware/f103-microros/build/f103-microros.elf}"
LIMIT="${LIMIT:-20}"

if ! command -v arm-none-eabi-size >/dev/null; then
  echo "ERROR: arm-none-eabi-size not found" >&2
  exit 1
fi
if ! command -v arm-none-eabi-nm >/dev/null; then
  echo "ERROR: arm-none-eabi-nm not found" >&2
  exit 1
fi
if [ ! -f "$ELF" ]; then
  echo "ERROR: ELF not found: $ELF" >&2
  exit 1
fi

echo "elf=$ELF"
arm-none-eabi-size "$ELF"

read -r text data bss _dec _hex _file < <(
  arm-none-eabi-size "$ELF" | awk 'NR == 2 {print $1, $2, $3, $4, $5, $6}'
)
flash_bytes=$((text + data))
ram_bytes=$((data + bss))

printf 'flash_bytes=%d ram_static_bytes=%d data_bytes=%d bss_bytes=%d\n' \
  "$flash_bytes" "$ram_bytes" "$data" "$bss"

echo
echo "static_task_stacks:"
arm-none-eabi-nm -S --size-sort "$ELF" |
  awk '
    $4 ~ /_task_stack$/ {
      printf "%-24s bytes=%6d words=%5d addr=0x%s\n",
        $4, strtonum("0x" $2), strtonum("0x" $2) / 4, $1
    }
  '

echo
echo "largest_ram_symbols:"
arm-none-eabi-nm -S --size-sort "$ELF" |
  awk '$3 ~ /^[BbDd]$/ {
    printf "%8d %-2s 0x%s %s\n", strtonum("0x" $2), $3, $1, $4
  }' |
  tail -n "$LIMIT"

echo
echo "largest_flash_symbols:"
arm-none-eabi-nm -S --size-sort "$ELF" |
  awk '$3 ~ /^[TtRr]$/ {
    printf "%8d %-2s 0x%s %s\n", strtonum("0x" $2), $3, $1, $4
  }' |
  tail -n "$LIMIT"
