#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ELF="${1:-$ROOT/firmware/f103-microros/build/f103-microros.elf}"
STACK_LOGDIR="$ROOT/log/firmware-stack-sweep"
SPIN_LOGDIR="$ROOT/log/firmware-spin-timeout-sweep"
LINKER_LOGDIR="$ROOT/log/firmware-linker-reserve-sweep"
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
  if [ ! -f "$ELF" ]; then
    echo "missing_elf=$(relpath "$ELF")"
    return 0
  fi
  "$ROOT/tools/firmware-size-report.sh" "$ELF" |
    awk '
      /^ram_category_summary:/ {in_section = 1; print; next}
      /^static_task_stacks:/ {exit}
      in_section {print}
    '
}

stack_md="$(latest_file "$STACK_LOGDIR" '*.md')"
spin_md="$(latest_file "$SPIN_LOGDIR" '*.md')"
linker_md="$(latest_file "$LINKER_LOGDIR" '*.md')"
size_matrix_csv="$(latest_file "$SIZE_MATRIX_LOGDIR" '*.csv')"

size_matrix_contract() {
  if [ -f "$size_matrix_csv" ]; then
    "$ROOT/tools/check-firmware-size-matrix-contract.sh" "$size_matrix_csv" 2>&1 ||
      true
  else
    echo "missing_size_matrix_csv"
  fi
}

cat <<EOF
# Firmware Memory Optimization Snapshot

- ELF: $(relpath "$ELF")
- stack sweep: $(relpath "$stack_md")
- spin-timeout sweep: $(relpath "$spin_md")
- linker reserve sweep: $(relpath "$linker_md")
- size matrix CSV: $(relpath "$size_matrix_csv")

## Current RAM Categories

\`\`\`text
$(ram_categories)
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

## Static Size Matrix Contract

\`\`\`text
$(size_matrix_contract)
\`\`\`

## Guardrails

- Do not change default micro-ROS task stack until high-rate HWM is measured on hardware.
- Do not shrink linker heap/MSP reserve until SWD is back and malloc/MSP/HardFault behavior is verified.
- Treat ROSIDL type metadata reduction as a libmicroros rebuild matrix, not a local firmware-only flag change.
EOF
