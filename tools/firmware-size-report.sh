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

user_heap_stack_bytes="$(
  arm-none-eabi-objdump -h "$ELF" |
    awk '$2 == "._user_heap_stack" {print strtonum("0x" $3)}'
)"
printf 'linker_user_heap_stack_bytes=%d\n' "${user_heap_stack_bytes:-0}"

echo
echo "ram_category_summary:"
arm-none-eabi-nm -S --size-sort "$ELF" |
  awk -v total_ram="$ram_bytes" -v linker_reserve="${user_heap_stack_bytes:-0}" '
    $3 !~ /^[BbDd]$/ {
      next
    }

    {
      size = strtonum("0x" $2)
      name = $4
      categorized += size
      is_rosidl = name ~ /toplevel_type_raw_source/ ||
        name ~ /type_description/ ||
        name ~ /typesupport/ ||
        name ~ /message_member/ ||
        name ~ /__FIELDS$/ ||
        name ~ /FIELD_NAME/ ||
        name ~ /TYPE_NAME/ ||
        name ~ /REFERENCED_TYPE_DESCRIPTIONS/
      is_pool = name ~ /custom_sessions/ ||
        name ~ /custom_nodes/ ||
        name ~ /custom_publishers/ ||
        name ~ /custom_subscriptions/ ||
        name ~ /custom_static_buffers/ ||
        name ~ /custom_init_options/
      is_uart = name ~ /rx_dma_buf/ ||
        name ~ /tx_dma_buf/ ||
        name ~ /^app_ring/
      is_newlib = name ~ /^__sf$/ ||
        name ~ /^__malloc_/ ||
        name ~ /^_impure_ptr$/ ||
        name ~ /^impure_data$/
      is_app_ros = name ~ /^g_msg_/ ||
        name ~ /^g_executor$/ ||
        name ~ /^g_pub_/ ||
        name ~ /^g_sub_/ ||
        name ~ /^g_node$/ ||
        name ~ /^g_support$/ ||
        name ~ /^g_allocator$/ ||
        name ~ /^g_control_/ ||
        name ~ /^g_crc_/

      if (name ~ /_task_stack$/) {
        cat["task_stacks"] += size
      } else if (is_rosidl) {
        cat["rosidl_type_metadata"] += size
      } else if (is_pool) {
        cat["microros_custom_pools"] += size
      } else if (is_uart) {
        cat["uart_buffers"] += size
      } else if (is_newlib) {
        cat["newlib_state"] += size
      } else if (is_app_ros) {
        cat["app_ros_state"] += size
      } else {
        cat["other_named_ram"] += size
      }
    }

    END {
      order[1] = "task_stacks"
      order[2] = "linker_user_heap_stack"
      order[3] = "rosidl_type_metadata"
      order[4] = "microros_custom_pools"
      order[5] = "uart_buffers"
      order[6] = "newlib_state"
      order[7] = "app_ros_state"
      order[8] = "other_named_ram"

      cat["linker_user_heap_stack"] = linker_reserve
      accounted = linker_reserve
      for (idx = 1; idx <= 8; idx++) {
        accounted += cat[order[idx]]
      }
      accounted -= linker_reserve
      remainder = total_ram - accounted
      if (remainder < 0) {
        remainder = 0
      }

      for (idx = 1; idx <= 8; idx++) {
        name = order[idx]
        bytes = cat[name] + 0
        pct = total_ram > 0 ? (100.0 * bytes / total_ram) : 0
        printf "%-24s bytes=%6d pct=%5.1f\n", name, bytes, pct
      }
      remainder_pct = total_ram > 0 ? (100.0 * remainder / total_ram) : 0
      printf "%-24s bytes=%6d pct=%5.1f\n",
        "unattributed_or_padding", remainder, remainder_pct
    }
  '

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
