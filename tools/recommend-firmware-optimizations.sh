#!/usr/bin/env bash
# Summarize static firmware optimization candidates and their runtime gates.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIZE_MATRIX_LOGDIR="$ROOT/log/firmware-size-matrix"
STACK_LOGDIR="$ROOT/log/firmware-stack-sweep"
SPIN_LOGDIR="$ROOT/log/firmware-spin-timeout-sweep"
LINKER_LOGDIR="$ROOT/log/firmware-linker-reserve-sweep"
COMBINED_LOGDIR="$ROOT/log/firmware-combined-memory-sweep"
SIZE_MATRIX_CSV="${SIZE_MATRIX_CSV:-}"
STACK_CSV="${STACK_CSV:-}"
SPIN_CSV="${SPIN_CSV:-}"
LINKER_CSV="${LINKER_CSV:-}"
COMBINED_CSV="${COMBINED_CSV:-}"
FIRMWARE_ELF="${FIRMWARE_ELF:-$ROOT/firmware/f103-microros/build/f103-microros.elf}"
FIRMWARE_SIZE_REPORT="${FIRMWARE_SIZE_REPORT:-}"

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

SIZE_MATRIX_CSV="${SIZE_MATRIX_CSV:-$(latest_file "$SIZE_MATRIX_LOGDIR" '*.csv')}"
STACK_CSV="${STACK_CSV:-$(latest_file "$STACK_LOGDIR" '*.csv')}"
SPIN_CSV="${SPIN_CSV:-$(latest_file "$SPIN_LOGDIR" '*.csv')}"
LINKER_CSV="${LINKER_CSV:-$(latest_file "$LINKER_LOGDIR" '*.csv')}"
COMBINED_CSV="${COMBINED_CSV:-$(latest_file "$COMBINED_LOGDIR" '*.csv')}"

csv_value() {
  local file="$1"
  local match_col="$2"
  local match_value="$3"
  local value_col="$4"
  if [ ! -f "$file" ]; then
    return 0
  fi
  awk -F, -v match_col="$match_col" -v match_value="$match_value" \
    -v value_col="$value_col" '
    NR == 1 {
      for (i = 1; i <= NF; i++) {
        col[$i] = i
      }
      next
    }
    col[match_col] && col[value_col] &&
        $col[match_col] == match_value {
      print $col[value_col]
      exit
    }
  ' "$file"
}

csv_min_row() {
  local file="$1"
  local value_col="$2"
  local keep_col="${3:-}"
  local keep_value="${4:-}"
  if [ ! -f "$file" ]; then
    return 0
  fi
  awk -F, -v value_col="$value_col" -v keep_col="$keep_col" \
    -v keep_value="$keep_value" '
    NR == 1 {
      header = $0
      for (i = 1; i <= NF; i++) {
        col[$i] = i
      }
      next
    }
    col[value_col] && (keep_col == "" ||
        (col[keep_col] && $col[keep_col] == keep_value)) {
      value = $col[value_col] + 0
      if (!seen || value < best) {
        seen = 1
        best = value
        best_row = $0
      }
    }
    END {
      if (seen) {
        print header
        print best_row
      }
    }
  ' "$file"
}

csv_unique_values() {
  local file="$1"
  local value_col="$2"
  if [ ! -f "$file" ]; then
    return 0
  fi
  awk -F, -v value_col="$value_col" '
    NR == 1 {
      for (i = 1; i <= NF; i++) {
        col[$i] = i
      }
      next
    }
    col[value_col] {
      seen[$col[value_col]] = 1
    }
    END {
      first = 1
      for (value in seen) {
        if (!first) printf " "
        printf "%s", value
        first = 0
      }
    }
  ' "$file"
}

row_field() {
  local two_line_csv="$1"
  local field="$2"
  printf '%s\n' "$two_line_csv" |
    awk -F, -v field="$field" '
      NR == 1 {
        for (i = 1; i <= NF; i++) {
          col[$i] = i
        }
        next
      }
      NR == 2 && col[field] {
        print $col[field]
      }
    '
}

num_or_zero() {
  local value="${1:-}"
  if [ -n "$value" ]; then
    printf '%s' "$value"
  else
    printf '0'
  fi
}

firmware_size_report() {
  if [ -n "$FIRMWARE_SIZE_REPORT" ] && [ -f "$FIRMWARE_SIZE_REPORT" ]; then
    cat "$FIRMWARE_SIZE_REPORT"
    return 0
  fi
  if [ -f "$FIRMWARE_ELF" ] && [ -x "$ROOT/tools/firmware-size-report.sh" ]; then
    "$ROOT/tools/firmware-size-report.sh" "$FIRMWARE_ELF" 2>/dev/null || true
  fi
}

size_report_breakdown_bytes() {
  local report="$1"
  local label="$2"
  printf '%s\n' "$report" |
    awk -v label="$label" '
      /^rosidl_type_metadata_breakdown:/ {in_section = 1; next}
      in_section && NF == 0 {exit}
      in_section && $1 == label {
        for (i = 1; i <= NF; i++) {
          if ($i == "bytes=" && (i + 1) <= NF) {
            print $(i + 1)
            exit
          } else if ($i ~ /^bytes=./) {
            sub(/^bytes=/, "", $i)
            print $i
            exit
          }
        }
      }
    '
}

size_report="$(firmware_size_report)"
default_ram="$(csv_value "$SIZE_MATRIX_CSV" profile default_reliable_1khz ram_static_bytes)"
best_10k_ram="$(csv_value "$SIZE_MATRIX_CSV" profile besteffort_10000hz_status40 ram_static_bytes)"
rosidl_metadata_bytes="$(csv_value "$SIZE_MATRIX_CSV" profile default_reliable_1khz ram_rosidl_type_metadata_bytes)"
rosidl_raw_source_bytes="$(
  csv_value "$SIZE_MATRIX_CSV" profile default_reliable_1khz ram_rosidl_raw_source_metadata_bytes)"
if [ -z "$rosidl_raw_source_bytes" ]; then
  rosidl_raw_source_bytes="$(size_report_breakdown_bytes "$size_report" toplevel_type_raw_source)"
fi
microros_pools_bytes="$(csv_value "$SIZE_MATRIX_CSV" profile default_reliable_1khz ram_microros_custom_pools_bytes)"
default_stack_ram="$(csv_value "$STACK_CSV" microros_stack_words 768 ram_static_bytes)"
stack_motor_entities="$(csv_unique_values "$STACK_CSV" motor_ros_entities)"
best_stack_row="$(csv_min_row "$STACK_CSV" ram_static_bytes verdict PASS_STATIC)"
best_stack_words="$(row_field "$best_stack_row" microros_stack_words)"
best_stack_ram="$(row_field "$best_stack_row" ram_static_bytes)"
best_stack_motor_entities="$(row_field "$best_stack_row" motor_ros_entities)"
default_linker_ram="$(csv_value "$LINKER_CSV" case default ram_static_bytes)"
linker_motor_entities="$(csv_unique_values "$LINKER_CSV" motor_ros_entities)"
best_linker_row="$(csv_min_row "$LINKER_CSV" ram_static_bytes verdict PASS_STATIC)"
best_linker_case="$(row_field "$best_linker_row" case)"
best_linker_ram="$(row_field "$best_linker_row" ram_static_bytes)"
best_linker_motor_entities="$(row_field "$best_linker_row" motor_ros_entities)"
baseline_combined_ram="$(csv_value "$COMBINED_CSV" case baseline ram_static_bytes)"
combined_motor_entities="$(csv_unique_values "$COMBINED_CSV" motor_ros_entities)"
best_combined_row="$(csv_min_row "$COMBINED_CSV" ram_static_bytes verdict PASS_STATIC)"
best_combined_case="$(row_field "$best_combined_row" case)"
best_combined_ram="$(row_field "$best_combined_row" ram_static_bytes)"
best_combined_motor_entities="$(row_field "$best_combined_row" motor_ros_entities)"
spin_values="$(csv_unique_values "$SPIN_CSV" executor_spin_timeout_us)"

default_ram_n="$(num_or_zero "$default_ram")"
best_10k_ram_n="$(num_or_zero "$best_10k_ram")"
default_stack_ram_n="$(num_or_zero "$default_stack_ram")"
best_stack_ram_n="$(num_or_zero "$best_stack_ram")"
default_linker_ram_n="$(num_or_zero "$default_linker_ram")"
best_linker_ram_n="$(num_or_zero "$best_linker_ram")"
baseline_combined_ram_n="$(num_or_zero "$baseline_combined_ram")"
best_combined_ram_n="$(num_or_zero "$best_combined_ram")"
tim2_static_saving=$((default_ram_n - best_10k_ram_n))
stack_static_saving=$((default_stack_ram_n - best_stack_ram_n))
linker_static_saving=$((default_linker_ram_n - best_linker_ram_n))
combined_static_saving=$((baseline_combined_ram_n - best_combined_ram_n))

cat <<EOF
# Firmware Optimization Recommendations

- size matrix: $(relpath "$SIZE_MATRIX_CSV")
- stack sweep: $(relpath "$STACK_CSV")
- stack sweep motor entities: ${stack_motor_entities:-NA}
- spin-timeout sweep: $(relpath "$SPIN_CSV")
- linker reserve sweep: $(relpath "$LINKER_CSV")
- linker reserve motor entities: ${linker_motor_entities:-NA}
- combined memory sweep: $(relpath "$COMBINED_CSV")
- combined memory motor entities: ${combined_motor_entities:-NA}
- firmware ELF: $(relpath "$FIRMWARE_ELF")

## Current Safe Recommendation

RECOMMENDATION default_policy=keep_defaults_until_runtime_evidence

The static sweeps show useful SRAM headroom candidates, but the risky ones all
need SWD/runtime evidence before changing defaults. Keep current defaults until
the high-rate staircase and stack/MSP/heap checks pass on hardware.

## Candidates

SCOPE_NOTE default_non_motor_candidates_are_not_motor_memory_conclusions

CANDIDATE tim2_high_loop_static_saving saved_bytes=$tim2_static_saving default_profile_ram=${default_ram:-NA} best_effort_10khz_ram=${best_10k_ram:-NA} profile_scope=default_non_motor source_csv=$(relpath "$SIZE_MATRIX_CSV") adoption=already_profiled gate=run_staircase_after_swd

CANDIDATE control_loop_staircase_order loops=1000,2000,5000,10000 pc_cmd_hz=200 status_every_n=40 bauds=921600,2000000 profile_scope=runtime_sequence adoption=runtime_sequence gate=advance_next_loop_only_after_contract_pass

CANDIDATE microros_stack_min_static words=${best_stack_words:-NA} saved_bytes=$stack_static_saving ram_static_bytes=${best_stack_ram:-NA} motor_ros_entities=${best_stack_motor_entities:-NA} profile_scope=motor_enabled_candidate source_csv=$(relpath "$STACK_CSV") adoption=hold gate=measure_stack_hwm_after_high_rate margin_rule="min_free_words>=128"

CANDIDATE linker_reserve_min_static case=${best_linker_case:-NA} saved_bytes=$linker_static_saving ram_static_bytes=${best_linker_ram:-NA} motor_ros_entities=${best_linker_motor_entities:-NA} profile_scope=motor_enabled_candidate source_csv=$(relpath "$LINKER_CSV") adoption=hold gate=verify_msp_heap_malloc_hardfault

CANDIDATE combined_stack_linker_min_static case=${best_combined_case:-NA} saved_bytes=$combined_static_saving baseline_ram=${baseline_combined_ram:-NA} ram_static_bytes=${best_combined_ram:-NA} motor_ros_entities=${best_combined_motor_entities:-NA} profile_scope=motor_enabled_candidate source_csv=$(relpath "$COMBINED_CSV") adoption=hold gate=verify_stack_hwm_msp_heap_together

CANDIDATE executor_spin_timeout values="${spin_values:-NA}" saved_bytes=0 adoption=runtime_latency_only gate=compare_staircase_gap_and_cpu

CANDIDATE rosidl_type_metadata bytes=${rosidl_metadata_bytes:-NA} profile_scope=default_non_motor source_csv=$(relpath "$SIZE_MATRIX_CSV") adoption=hold gate=libmicroros_rebuild_compatibility_matrix

CANDIDATE rosidl_raw_source_metadata bytes=${rosidl_raw_source_bytes:-NA} parent_bytes=${rosidl_metadata_bytes:-NA} profile_scope=default_non_motor source_csv=$(relpath "$SIZE_MATRIX_CSV") adoption=hold gate=libmicroros_rebuild_strip_type_description_matrix

CANDIDATE microros_custom_pools bytes=${microros_pools_bytes:-NA} profile_scope=default_non_motor source_csv=$(relpath "$SIZE_MATRIX_CSV") adoption=hold gate=libmicroros_rebuild_and_agent_compatibility

## Next Runtime Gates

1. Restore SWD until \`tools/diagnose-swd.sh\` reports \`SWD_STATUS=ok\`.
2. Run \`STAIRCASE_BAUDS="921600 2000000" tools/run-com-staircase.sh staircase_\$(date +%Y%m%d_%H%M)\`.
3. After the highest passing profile, run \`tools/measure-stack-hwm.sh firmware/f103-microros/build/f103-microros.elf\`.
4. Only then consider stack/linker reserve default changes.
EOF
