#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ELF="${1:-$ROOT/firmware/f103-microros/build/f103-microros.elf}"
MOTOR_ELF="${MOTOR_ELF:-$ROOT/firmware/f103-microros/build-motor/f103-microros.elf}"
MOTOR_OPT_ELF="${MOTOR_OPT_ELF:-$ROOT/firmware/f103-microros/build-motor-opt/f103-microros.elf}"
STACK_LOGDIR="$ROOT/log/firmware-stack-sweep"
SPIN_LOGDIR="$ROOT/log/firmware-spin-timeout-sweep"
LINKER_LOGDIR="$ROOT/log/firmware-linker-reserve-sweep"
COMBINED_LOGDIR="$ROOT/log/firmware-combined-memory-sweep"
SIZE_MATRIX_LOGDIR="$ROOT/log/firmware-size-matrix"

latest_file() {
  local dir="$1"
  local pattern="$2"
  find "$dir" -maxdepth 1 -type f -name "$pattern" -printf '%T@ %p\n' 2>/dev/null |
    sort -nr |
    awk 'NR == 1 {sub(/^[^ ]+ /, ""); print; exit}' || true
}

relpath() {
  local path="${1:-}"
  if [ -z "$path" ]; then
    printf '-'
  else
    printf '%s' "${path#$ROOT/}"
  fi
}

first_table_rows() {
  local file="$1"
  local rows="${2:-10}"
  if [ -f "$file" ]; then
    sed -n "1,${rows}p" "$file"
  else
    echo "-"
  fi
}

ram_categories() {
  local elf="${1:-$ELF}"
  if [ ! -f "$elf" ]; then
    echo "missing_elf=$(relpath "$elf")"
    return 0
  fi
  "$ROOT/tools/firmware-size-report.sh" "$elf" |
    awk '
      /^ram_category_summary:/ {in_section = 1; print; next}
      /^static_task_stacks:/ {exit}
      in_section {print}
    '
}

rosidl_metadata_breakdown() {
  local elf="${1:-$ELF}"
  if [ ! -f "$elf" ]; then
    echo "missing_elf=$(relpath "$elf")"
    return 0
  fi
  "$ROOT/tools/firmware-size-report.sh" "$elf" |
    awk '
      /^rosidl_type_metadata_breakdown:/ {in_section = 1; print; next}
      /^largest_ram_symbols_by_category:/ {exit}
      in_section {print}
    '
}

firmware_size_row() {
  local label="$1"
  local elf="$2"
  if [ ! -f "$elf" ]; then
    printf '| %s | %s | missing | - | - | - | - | - | - | - |\n' \
      "$label" "$(relpath "$elf")"
    return 0
  fi
  "$ROOT/tools/firmware-size-report.sh" "$elf" |
    awk -v label="$label" -v elf="$(relpath "$elf")" '
      /^flash_bytes=/ {
        for (i = 1; i <= NF; i++) {
          split($i, kv, "=")
          metric[kv[1]] = kv[2]
        }
        next
      }
      /^linker_user_heap_stack_bytes=/ {
        split($1, kv, "=")
        metric["linker_user_heap_stack_bytes"] = kv[2]
        next
      }
      /^ram_category_summary:/ {in_ram = 1; next}
      in_ram && NF == 0 {in_ram = 0}
      in_ram {cat[$1] = $3}
      END {
        printf "| %s | %s | present | %s | %s | %s | %s | %s | %s | %s |\n",
          label, elf,
          metric["flash_bytes"] ? metric["flash_bytes"] : "-",
          metric["ram_static_bytes"] ? metric["ram_static_bytes"] : "-",
          metric["linker_user_heap_stack_bytes"] ? metric["linker_user_heap_stack_bytes"] : "-",
          cat["task_stacks"] ? cat["task_stacks"] : "-",
          cat["rosidl_type_metadata"] ? cat["rosidl_type_metadata"] : "-",
          cat["microros_custom_pools"] ? cat["microros_custom_pools"] : "-",
          cat["app_ros_state"] ? cat["app_ros_state"] : "-"
      }
    '
}

size_metric() {
  local elf="$1"
  local key="$2"
  if [ ! -f "$elf" ]; then
    return 0
  fi
  "$ROOT/tools/firmware-size-report.sh" "$elf" |
    awk -v key="$key" '
      /^flash_bytes=/ {
        for (i = 1; i <= NF; i++) {
          split($i, kv, "=")
          if (kv[1] == key) {
            print kv[2]
            exit
          }
        }
      }
      /^linker_user_heap_stack_bytes=/ && key == "linker_user_heap_stack_bytes" {
        split($1, kv, "=")
        print kv[2]
        exit
      }
    '
}

ram_category_metric() {
  local elf="$1"
  local key="$2"
  if [ ! -f "$elf" ]; then
    return 0
  fi
  "$ROOT/tools/firmware-size-report.sh" "$elf" |
    awk -v key="$key" '
      /^ram_category_summary:/ {in_ram = 1; next}
      in_ram && NF == 0 {exit}
      in_ram && $1 == key {
        print $3
        exit
      }
    '
}

motor_static_delta() {
  if [ ! -f "$MOTOR_ELF" ] || [ ! -f "$MOTOR_OPT_ELF" ]; then
    echo "- missing motor ELF or motor optimized ELF; cannot compute delta"
    return 0
  fi

  local motor_flash motor_opt_flash motor_ram motor_opt_ram
  local motor_linker motor_opt_linker motor_stack motor_opt_stack
  motor_flash="$(size_metric "$MOTOR_ELF" flash_bytes)"
  motor_opt_flash="$(size_metric "$MOTOR_OPT_ELF" flash_bytes)"
  motor_ram="$(size_metric "$MOTOR_ELF" ram_static_bytes)"
  motor_opt_ram="$(size_metric "$MOTOR_OPT_ELF" ram_static_bytes)"
  motor_linker="$(size_metric "$MOTOR_ELF" linker_user_heap_stack_bytes)"
  motor_opt_linker="$(size_metric "$MOTOR_OPT_ELF" linker_user_heap_stack_bytes)"
  motor_stack="$(ram_category_metric "$MOTOR_ELF" task_stacks)"
  motor_opt_stack="$(ram_category_metric "$MOTOR_OPT_ELF" task_stacks)"

  if [ -z "$motor_ram" ] || [ -z "$motor_opt_ram" ]; then
    echo "- motor delta unavailable: size metrics missing"
    return 0
  fi

  echo "- ram_static_saved_bytes=$((motor_ram - motor_opt_ram))"
  echo "- flash_delta_bytes=$((motor_opt_flash - motor_flash))"
  echo "- linker_reserve_saved_bytes=$((motor_linker - motor_opt_linker))"
  echo "- task_stack_saved_bytes=$((motor_stack - motor_opt_stack))"
  echo "- adoption=hold gate=motor_enabled_stack_hwm_msp_heap_reconnect_soak"
}

stack_md="$(latest_file "$STACK_LOGDIR" '*.md')"
spin_md="$(latest_file "$SPIN_LOGDIR" '*.md')"
linker_md="$(latest_file "$LINKER_LOGDIR" '*.md')"
combined_md="$(latest_file "$COMBINED_LOGDIR" '*.md')"
size_matrix_csv="$(latest_file "$SIZE_MATRIX_LOGDIR" '*.csv')"

size_matrix_contract() {
  if [ -f "$size_matrix_csv" ]; then
    "$ROOT/tools/check-firmware-size-matrix-contract.sh" "$size_matrix_csv" 2>&1 ||
      true
  else
    echo "missing_size_matrix_csv"
  fi
}

optimization_recommendations() {
  if [ -x "$ROOT/tools/recommend-firmware-optimizations.sh" ]; then
    "$ROOT/tools/recommend-firmware-optimizations.sh" 2>/dev/null |
      awk '
        /^RECOMMENDATION / {print; next}
        /^CANDIDATE / {print; next}
        /^SCOPE_NOTE / {print; next}
      '
  else
    echo "missing_recommend_firmware_optimizations"
  fi
}

cat <<EOF
# Firmware Memory Optimization Snapshot

- ELF: $(relpath "$ELF")
- motor ELF: $(relpath "$MOTOR_ELF")
- motor optimized ELF: $(relpath "$MOTOR_OPT_ELF")
- stack sweep: $(relpath "$stack_md")
- spin-timeout sweep: $(relpath "$spin_md")
- linker reserve sweep: $(relpath "$linker_md")
- combined memory sweep: $(relpath "$combined_md")
- size matrix CSV: $(relpath "$size_matrix_csv")

## Default/Non-Motor ELF RAM Categories

- source ELF: $(relpath "$ELF")
- scope note: default/non-motor ELF categories are not M2 motor memory conclusions.

\`\`\`text
$(ram_categories)
\`\`\`

## Motor-Enabled Static Delta

| profile | ELF | status | flash B | static RAM B | linker reserve B | task stacks B | ROSIDL metadata B | micro-ROS pools B | app ROS state B |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|
$(firmware_size_row "motor-default" "$MOTOR_ELF")
$(firmware_size_row "motor-opt" "$MOTOR_OPT_ELF")

\`\`\`text
$(motor_static_delta)
\`\`\`

## Motor-Enabled RAM Categories

\`\`\`text
$(ram_categories "$MOTOR_ELF")
\`\`\`

## Motor-Enabled ROSIDL Metadata

\`\`\`text
$(rosidl_metadata_breakdown "$MOTOR_ELF")
\`\`\`

## micro-ROS Stack Candidates

\`\`\`markdown
$(first_table_rows "$stack_md" 8)
\`\`\`

## Executor Spin Timeout Candidates

\`\`\`markdown
$(first_table_rows "$spin_md" 8)
\`\`\`

## Linker Heap/MSP Reserve Candidates

\`\`\`markdown
$(first_table_rows "$linker_md" 8)
\`\`\`

## Combined Stack/Linker Candidates

\`\`\`markdown
$(first_table_rows "$combined_md" 8)
\`\`\`

## Static Size Matrix Contract

\`\`\`text
$(size_matrix_contract)
\`\`\`

## Optimization Recommendations

\`\`\`text
$(optimization_recommendations)
\`\`\`

## Guardrails

- Do not change default micro-ROS task stack until high-rate HWM is measured on hardware.
- Do not shrink linker heap/MSP reserve until SWD is back and malloc/MSP/HardFault behavior is verified.
- Treat combined stack/linker savings as a single runtime gate; both HWM and MSP/heap evidence must pass together.
- Treat ROSIDL type metadata reduction as a libmicroros rebuild matrix, not a local firmware-only flag change.
EOF
