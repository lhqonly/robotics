#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

assert_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if ! grep -Fq -- "$needle" "$file"; then
    echo "FAIL: $label missing '$needle' in $file" >&2
    echo "output:" >&2
    cat "$file" >&2
    exit 1
  fi
}

actual_out="$TMPDIR/actual.md"
"$ROOT/tools/recommend-firmware-optimizations.sh" >"$actual_out"
assert_contains "$actual_out" "# Firmware Optimization Recommendations" \
  "recommendation title"
assert_contains "$actual_out" \
  "RECOMMENDATION default_policy=keep_defaults_until_runtime_evidence" \
  "default keep policy"
assert_contains "$actual_out" "CANDIDATE microros_stack_min_static" \
  "stack recommendation"
assert_contains "$actual_out" \
  "SCOPE_NOTE default_non_motor_candidates_are_not_motor_memory_conclusions" \
  "profile scope warning"
assert_contains "$actual_out" "stack sweep motor entities:" \
  "stack profile marker"
assert_contains "$actual_out" \
  "CANDIDATE tim2_high_loop_static_saving saved_bytes=" \
  "TIM2 recommendation row"
assert_contains "$actual_out" \
  "profile_scope=default_non_motor" \
  "default/non-motor profile scope marker"
assert_contains "$actual_out" \
  "profile_scope=motor_enabled_candidate" \
  "motor-enabled candidate profile scope marker"
assert_contains "$actual_out" \
  "CANDIDATE control_loop_staircase_order loops=1000,2000,5000,10000 pc_cmd_hz=200 status_every_n=40 bauds=921600,2000000" \
  "control-loop staircase order recommendation"
assert_contains "$actual_out" "CANDIDATE linker_reserve_min_static" \
  "linker recommendation"
assert_contains "$actual_out" "CANDIDATE combined_stack_linker_min_static" \
  "combined stack/linker recommendation"
assert_contains "$actual_out" "CANDIDATE rosidl_type_metadata" \
  "ROSIDL metadata recommendation"
assert_contains "$actual_out" "CANDIDATE rosidl_raw_source_metadata" \
  "ROSIDL raw source metadata recommendation"
assert_contains "$actual_out" "SWD_STATUS=ok" \
  "runtime SWD gate"

cat >"$TMPDIR/size.csv" <<'EOF'
profile,ram_static_bytes,ram_rosidl_type_metadata_bytes,ram_rosidl_raw_source_metadata_bytes,ram_microros_custom_pools_bytes
default_reliable_1khz,15000,3000,1555,2000
besteffort_10000hz_status40,14000,3000,1555,2000
EOF
cat >"$TMPDIR/stack.csv" <<'EOF'
microros_stack_words,verdict,ram_static_bytes,motor_ros_entities
768,PASS_STATIC,14000,ON
704,PASS_STATIC,13744,ON
640,PASS_STATIC,13488,ON
EOF
cat >"$TMPDIR/spin.csv" <<'EOF'
executor_spin_timeout_us,verdict,ram_static_bytes
1000,PASS_STATIC,14000
200,PASS_STATIC,14000
EOF
cat >"$TMPDIR/linker.csv" <<'EOF'
case,verdict,ram_static_bytes,motor_ros_entities
default,PASS_STATIC,14000,ON
heap0_stack512,PASS_STATIC,13000,ON
EOF
cat >"$TMPDIR/combined.csv" <<'EOF'
case,verdict,ram_static_bytes,motor_ros_entities
baseline,PASS_STATIC,14000,ON
stack640_heap0_stack512,PASS_STATIC,12488,ON
EOF
cat >"$TMPDIR/size-report.txt" <<'EOF'
rosidl_type_metadata_breakdown:
ExoHeader                bytes=   511
ExoCmd                   bytes=   347
ExoStatus                bytes=   350
toplevel_type_raw_source bytes=  1555
other_rosidl_metadata    bytes=    72
EOF

synthetic_out="$TMPDIR/synthetic.md"
SIZE_MATRIX_CSV="$TMPDIR/size.csv" \
  STACK_CSV="$TMPDIR/stack.csv" \
  SPIN_CSV="$TMPDIR/spin.csv" \
  LINKER_CSV="$TMPDIR/linker.csv" \
  COMBINED_CSV="$TMPDIR/combined.csv" \
  FIRMWARE_SIZE_REPORT="$TMPDIR/size-report.txt" \
  "$ROOT/tools/recommend-firmware-optimizations.sh" >"$synthetic_out"

assert_contains "$synthetic_out" \
  "CANDIDATE tim2_high_loop_static_saving saved_bytes=1000" \
  "synthetic TIM2/static profile saving"
assert_contains "$synthetic_out" \
  "CANDIDATE tim2_high_loop_static_saving saved_bytes=1000 default_profile_ram=15000 best_effort_10khz_ram=14000 profile_scope=default_non_motor" \
  "synthetic TIM2 default/non-motor scope"
assert_contains "$synthetic_out" \
  "CANDIDATE microros_stack_min_static words=640 saved_bytes=512" \
  "synthetic stack saving"
assert_contains "$synthetic_out" \
  "CANDIDATE microros_stack_min_static words=640 saved_bytes=512 ram_static_bytes=13488 motor_ros_entities=ON profile_scope=motor_enabled_candidate" \
  "synthetic stack motor scope"
assert_contains "$synthetic_out" \
  "stack sweep motor entities: ON" \
  "synthetic stack motor marker"
assert_contains "$synthetic_out" \
  "CANDIDATE linker_reserve_min_static case=heap0_stack512 saved_bytes=1000" \
  "synthetic linker reserve saving"
assert_contains "$synthetic_out" \
  "CANDIDATE linker_reserve_min_static case=heap0_stack512 saved_bytes=1000 ram_static_bytes=13000 motor_ros_entities=ON" \
  "synthetic linker motor marker"
assert_contains "$synthetic_out" \
  "CANDIDATE linker_reserve_min_static case=heap0_stack512 saved_bytes=1000 ram_static_bytes=13000 motor_ros_entities=ON profile_scope=motor_enabled_candidate" \
  "synthetic linker motor scope"
assert_contains "$synthetic_out" \
  "CANDIDATE combined_stack_linker_min_static case=stack640_heap0_stack512 saved_bytes=1512" \
  "synthetic combined stack/linker saving"
assert_contains "$synthetic_out" \
  "CANDIDATE combined_stack_linker_min_static case=stack640_heap0_stack512 saved_bytes=1512 baseline_ram=14000 ram_static_bytes=12488 motor_ros_entities=ON" \
  "synthetic combined motor marker"
assert_contains "$synthetic_out" \
  "CANDIDATE combined_stack_linker_min_static case=stack640_heap0_stack512 saved_bytes=1512 baseline_ram=14000 ram_static_bytes=12488 motor_ros_entities=ON profile_scope=motor_enabled_candidate" \
  "synthetic combined motor scope"
assert_contains "$synthetic_out" \
  "CANDIDATE rosidl_type_metadata bytes=3000" \
  "synthetic ROSIDL metadata bytes"
assert_contains "$synthetic_out" \
  "CANDIDATE rosidl_raw_source_metadata bytes=1555 parent_bytes=3000" \
  "synthetic ROSIDL raw source metadata bytes"
assert_contains "$synthetic_out" \
  "CANDIDATE rosidl_raw_source_metadata bytes=1555 parent_bytes=3000 profile_scope=default_non_motor" \
  "synthetic ROSIDL default/non-motor scope"

echo "PASS: firmware optimization recommendation tests"
