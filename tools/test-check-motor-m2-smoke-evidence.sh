#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if ! grep -Fq -- "$needle" <<<"$haystack"; then
    echo "FAIL: $label missing '$needle'" >&2
    echo "output:" >&2
    printf '%s\n' "$haystack" >&2
    exit 1
  fi
}

run_expect_fail() {
  local label="$1"
  shift
  local out rc
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "FAIL: $label should fail" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  printf '%s\n' "$out"
}

python3 -m py_compile "$ROOT/tools/check-motor-m2-smoke-evidence.py"

template="$TMPDIR/template.env"
"$ROOT/tools/check-motor-m2-smoke-evidence.py" --template >"$template"
assert_contains "$(cat "$template")" "topic_motor_target=present" \
  "template includes motor target topic"
assert_contains "$(cat "$template")" "state_after_ttl_fault_bits=2" \
  "template includes TTL stale evidence"

out="$(run_expect_fail "unfilled sample template" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$template")"
assert_contains "$out" "BLOCKED_MISSING_EVIDENCE motor_m2_smoke" \
  "unfilled template is blocked"
assert_contains "$out" "sample_template_not_filled" \
  "unfilled template reason"

sed -i 's/^sample_only=.*/sample_only=false/' "$template"
out="$("$ROOT/tools/check-motor-m2-smoke-evidence.py" "$template")"
assert_contains "$out" "PASS motor_m2_smoke" \
  "passing evidence"
assert_contains "$out" "motor_state_hz_range=45..55" \
  "passing rate contract"

offline="$TMPDIR/offline.env"
cp "$template" "$offline"
sed -i 's/^swd_status=.*/swd_status=bad_no_stlink/' "$offline"
out="$(run_expect_fail "offline hardware" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$offline")"
assert_contains "$out" "BLOCKED_HARDWARE_OFFLINE motor_m2_smoke" \
  "hardware offline status"
assert_contains "$out" "swd_status_bad_no_stlink" \
  "hardware offline reason"

missing_motor="$TMPDIR/missing-motor.env"
grep -v '^topic_motor_target=' "$template" >"$missing_motor"
out="$(run_expect_fail "missing motor topic" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$missing_motor")"
assert_contains "$out" "BLOCKED_MISSING_EVIDENCE motor_m2_smoke" \
  "missing evidence status"
assert_contains "$out" "missing_topic_motor_target" \
  "missing motor topic reason"

reject_seq="$TMPDIR/reject-seq.env"
cp "$template" "$reject_seq"
sed -i 's/^state_after_reject_last_target_seq=.*/state_after_reject_last_target_seq=43/' "$reject_seq"
out="$(run_expect_fail "rejected frame_id advanced seq" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$reject_seq")"
assert_contains "$out" "FAIL motor_m2_smoke" \
  "reject seq fail status"
assert_contains "$out" "state_after_reject_last_target_seq_expected_42_got_43" \
  "reject seq reason"

reject_received="$TMPDIR/reject-received.env"
cp "$template" "$reject_received"
sed -i 's/^health_after_reject_targets_received=.*/health_after_reject_targets_received=2/' "$reject_received"
out="$(run_expect_fail "rejected frame_id incremented received" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$reject_received")"
assert_contains "$out" "health_after_reject_targets_received_changed_from_1_to_2" \
  "reject received reason"

reject_applied="$TMPDIR/reject-applied.env"
cp "$template" "$reject_applied"
sed -i 's/^health_after_reject_targets_applied=.*/health_after_reject_targets_applied=1/' "$reject_applied"
out="$(run_expect_fail "rejected frame_id incremented applied" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$reject_applied")"
assert_contains "$out" "health_after_reject_targets_applied_changed_from_0_to_1" \
  "reject applied reason"

applied_natural="$TMPDIR/applied-natural.env"
cp "$reject_applied" "$applied_natural"
sed -i 's/^reject_baseline_target_enabled=.*/reject_baseline_target_enabled=true/' "$applied_natural"
out="$("$ROOT/tools/check-motor-m2-smoke-evidence.py" "$applied_natural")"
assert_contains "$out" "PASS motor_m2_smoke" \
  "enabled baseline allows natural applied growth"

clamp="$TMPDIR/clamp.env"
cp "$template" "$clamp"
sed -i 's/^state_after_clamp_fault_bits=.*/state_after_clamp_fault_bits=0/' "$clamp"
out="$(run_expect_fail "missing clamp fault" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$clamp")"
assert_contains "$out" "state_after_clamp_fault_bits_missing_bit_4" \
  "clamp fault reason"

ttl="$TMPDIR/ttl.env"
cp "$template" "$ttl"
sed -i 's/^state_after_ttl_target_fresh=.*/state_after_ttl_target_fresh=true/' "$ttl"
out="$(run_expect_fail "target still fresh after ttl" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$ttl")"
assert_contains "$out" "state_after_ttl_target_still_fresh" \
  "TTL fresh reason"

rate="$TMPDIR/rate.env"
cp "$template" "$rate"
sed -i 's/^motor_state_hz=.*/motor_state_hz=20.0/' "$rate"
out="$(run_expect_fail "motor state rate low" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$rate")"
assert_contains "$out" "motor_state_hz_out_of_range_45_55_got_20" \
  "motor state rate reason"

stack="$TMPDIR/stack.env"
cp "$template" "$stack"
sed -i 's/^microros_stack_free_words=.*/microros_stack_free_words=64/' "$stack"
out="$(run_expect_fail "stack margin low" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$stack")"
assert_contains "$out" "microros_stack_free_words_low_64_lt_128" \
  "stack margin reason"

duplicate="$TMPDIR/duplicate.env"
cp "$template" "$duplicate"
printf '%s\n' 'state_after_accept_last_target_seq=42' >>"$duplicate"
out="$(run_expect_fail "duplicate key" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$duplicate")"
assert_contains "$out" "evidence_parse_failed:line" \
  "duplicate key parse failure"

old_echo="$TMPDIR/old-echo.env"
cp "$template" "$old_echo"
sed -i 's/^state_after_accept_seq=.*/state_after_accept_seq=0/' "$old_echo"
out="$(run_expect_fail "old echo sample" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$old_echo")"
assert_contains "$out" "state_after_accept_seq_not_after_state_before_accept_seq_0_le_0" \
  "old echo sequence reason"

dir="$TMPDIR/evidence-dir"
mkdir -p "$dir"
cat >"$dir/evidence.env" <<'EOF'
swd_status=ok
firmware_build=ok
firmware_flash=ok
agent_connected=ok
reject_baseline_target_enabled=false
clamp_target_ttl_us=100000
EOF
cat >"$dir/topics.txt" <<'EOF'
/com/tp_mcu_status
/motor/tp_joint_target
/motor/tp_joint_state
/motor/tp_motor_health
EOF
cat >"$dir/info.motor_target.txt" <<'EOF'
Type: exo_motor_msgs/msg/JointTarget
Publisher count: 1
Subscription count: 1
EOF
cat >"$dir/info.motor_state.txt" <<'EOF'
Type: exo_motor_msgs/msg/JointState
Publisher count: 1
Subscription count: 0
EOF
cat >"$dir/info.motor_health.txt" <<'EOF'
Type: exo_motor_msgs/msg/MotorHealth
Publisher count: 1
Subscription count: 0
EOF
cat >"$dir/info.com_status.txt" <<'EOF'
Type: exo_msgs/msg/McuStatus
Publisher count: 1
Subscription count: 1
EOF
cat >"$dir/state.before_seq42.yaml" <<'EOF'
seq: 0
EOF
cat >"$dir/state.after_seq42.yaml" <<'EOF'
seq: 1
last_target_seq: 42
EOF
cat >"$dir/health.before_reject.yaml" <<'EOF'
targets_received: 1
targets_applied: 0
EOF
cat >"$dir/state.after_reject_seq43.yaml" <<'EOF'
seq: 2
last_target_seq: 42
EOF
cat >"$dir/health.after_reject_seq43.yaml" <<'EOF'
targets_received: 1
targets_applied: 0
EOF
cat >"$dir/state.after_seq44.yaml" <<'EOF'
seq: 3
last_target_seq: 44
EOF
cat >"$dir/state.after_clamp_seq45.yaml" <<'EOF'
seq: 4
last_target_seq: 45
fault_bits: 4
sample_age_us: 1000
EOF
cat >"$dir/health.before_ttl.yaml" <<'EOF'
stale_targets: 0
EOF
cat >"$dir/state.after_ttl.yaml" <<'EOF'
seq: 5
last_target_seq: 45
target_fresh: false
enabled: false
fault_bits: 2
EOF
cat >"$dir/health.after_ttl.yaml" <<'EOF'
stale_targets: 1
EOF
cat >"$dir/rate.motor_state.txt" <<'EOF'
average rate: 50.000
min: 0.019s max: 0.021s std dev: 0.00100s window: 10
EOF
cat >"$dir/rate.com_status.txt" <<'EOF'
average rate: 5.000
min: 0.190s max: 0.210s std dev: 0.00400s window: 10
EOF
cat >"$dir/stack-hwm.txt" <<'EOF'
elf=firmware/f103-microros/build-motor/f103-microros.elf
microros_task_stack addr=0x20001150 bytes=3072 total_words=768 hwm_free_words=160 used_words=608
EOF

out="$("$ROOT/tools/check-motor-m2-smoke-evidence.py" "$dir")"
assert_contains "$out" "PASS motor_m2_smoke" \
  "passing directory evidence"

bad_dir="$TMPDIR/bad-evidence-dir"
cp -a "$dir" "$bad_dir"
sed -i 's/^Subscription count:.*/Subscription count: 0/' "$bad_dir/info.motor_target.txt"
out="$(run_expect_fail "missing motor target subscriber" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$bad_dir")"
assert_contains "$out" "info_motor_target_not_ok" \
  "topic info subscription count reason"

template_dir="$TMPDIR/template-dir"
mkdir -p "$template_dir"
"$ROOT/tools/check-motor-m2-smoke-evidence.py" --template >"$template_dir/evidence.env"
sed -i 's/^sample_only=.*/sample_only=false/' "$template_dir/evidence.env"
out="$(run_expect_fail "directory template without raw files" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$template_dir")"
assert_contains "$out" "BLOCKED_MISSING_EVIDENCE motor_m2_smoke" \
  "directory raw evidence required"
assert_contains "$out" "topic_motor_target_not_ok" \
  "directory ignores template topic defaults"
assert_contains "$out" "missing_state_after_accept_last_target_seq" \
  "directory ignores template state defaults"

missing_rate_dir="$TMPDIR/missing-rate-dir"
cp -a "$dir" "$missing_rate_dir"
rm "$missing_rate_dir/rate.motor_state.txt"
out="$(run_expect_fail "missing motor state rate file" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$missing_rate_dir")"
assert_contains "$out" "missing_motor_state_hz" \
  "missing motor state rate reason"

bad_stack_dir="$TMPDIR/bad-stack-dir"
cp -a "$dir" "$bad_stack_dir"
cat >"$bad_stack_dir/stack-hwm.txt" <<'EOF'
led_task_stack addr=0x20000100 bytes=256 total_words=64 hwm_free_words=42 used_words=22
EOF
out="$(run_expect_fail "missing microros stack HWM" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$bad_stack_dir")"
assert_contains "$out" "missing_microros_stack_free_words" \
  "missing microros stack reason"

echo "PASS: M2 motor smoke evidence checker tests"
