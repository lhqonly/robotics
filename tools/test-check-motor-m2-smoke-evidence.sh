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

create_raw_manifest() {
  local dir="$1"
  (
    cd "$dir"
    sha256sum \
      topics.txt \
      info.motor_target.txt \
      info.motor_state.txt \
      info.motor_health.txt \
      info.com_status.txt \
      state.before_seq42.yaml \
      state.after_seq42.yaml \
      health.before_reject.yaml \
      state.after_reject_seq43.yaml \
      health.after_reject_seq43.yaml \
      state.after_seq44.yaml \
      state.after_clamp_seq45.yaml \
      health.before_ttl.yaml \
      state.after_ttl.yaml \
      health.after_ttl.yaml \
      health.before_enabled_soak.yaml \
      enabled_soak.summary.txt \
      health.mid_enabled_soak.yaml \
      state.mid_enabled_soak.yaml \
      rate.motor_state.txt \
      rate.motor_health.txt \
      rate.com_status.txt \
      com_cmd.rate.log \
      rate.com_status.soak.txt \
      com_cmd.soak.log \
      state.after_enabled_soak.yaml \
      health.after_enabled_soak.yaml \
      stack-hwm.txt \
      agent.log >raw.sha256
  )
}

python3 -m py_compile "$ROOT/tools/check-motor-m2-smoke-evidence.py"

template="$TMPDIR/template.env"
"$ROOT/tools/check-motor-m2-smoke-evidence.py" --template >"$template"
assert_contains "$(cat "$template")" "topic_motor_target=present" \
  "template includes motor target topic"
assert_contains "$(cat "$template")" "evidence_source=template" \
  "template marks evidence source"
assert_contains "$(cat "$template")" "template_generated=true" \
  "template marks generated evidence"
assert_contains "$(cat "$template")" "evidence_capture_id=template" \
  "template marks capture id"
assert_contains "$(cat "$template")" "state_after_ttl_fault_bits=2" \
  "template includes TTL stale evidence"
assert_contains "$(cat "$template")" "enabled_soak_duration_s=2.0" \
  "template includes enabled soak duration evidence"
assert_contains "$(cat "$template")" "newlib_heap_free_before_msp_reserve_bytes=1024" \
  "template includes newlib heap MSP margin"
assert_contains "$(cat "$template")" "agent_session_loss_events=0" \
  "template includes agent session loss evidence"

out="$(run_expect_fail "unfilled sample template" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$template")"
assert_contains "$out" "BLOCKED_MISSING_EVIDENCE motor_m2_smoke" \
  "unfilled template is blocked"
assert_contains "$out" "sample_template_not_filled" \
  "unfilled template reason"

sed -i 's/^sample_only=.*/sample_only=false/' "$template"
out="$(run_expect_fail "template source without provenance" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$template")"
assert_contains "$out" "sample_template_not_filled" \
  "template source still blocked after sample_only flip"

sed -i 's/^evidence_source=.*/evidence_source=manual_raw_capture/' "$template"
out="$(run_expect_fail "template capture id without provenance" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$template")"
assert_contains "$out" "sample_template_not_filled" \
  "template capture id still blocked after source flip"

sed -i 's/^evidence_capture_id=.*/evidence_capture_id=test_manual_capture/' "$template"
out="$(run_expect_fail "template-derived single-file evidence" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$template")"
assert_contains "$out" "file_evidence_not_raw_capture_use_directory" \
  "single-file evidence cannot pass"
assert_contains "$out" "template_generated_evidence_not_raw_capture" \
  "template-derived evidence cannot pass"

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
out="$(run_expect_fail "single-file applied natural evidence" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$applied_natural")"
assert_contains "$out" "file_evidence_not_raw_capture_use_directory" \
  "single-file applied natural evidence cannot pass"

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

health_rate="$TMPDIR/health-rate.env"
cp "$template" "$health_rate"
sed -i 's/^motor_health_hz=.*/motor_health_hz=1.0/' "$health_rate"
out="$(run_expect_fail "motor health rate low" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$health_rate")"
assert_contains "$out" "motor_health_hz_out_of_range_4.5_5.5_got_1" \
  "motor health rate reason"

enabled_rate="$TMPDIR/enabled-rate.env"
cp "$template" "$enabled_rate"
sed -i 's/^enabled_soak_target_hz=.*/enabled_soak_target_hz=100.0/' "$enabled_rate"
out="$(run_expect_fail "enabled soak target rate low" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$enabled_rate")"
assert_contains "$out" "enabled_soak_target_hz_out_of_range_180_220_got_100" \
  "enabled soak target rate reason"

enabled_duration="$TMPDIR/enabled-duration.env"
cp "$template" "$enabled_duration"
sed -i 's/^enabled_soak_duration_s=.*/enabled_soak_duration_s=0.5/' "$enabled_duration"
out="$(run_expect_fail "enabled soak duration low" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$enabled_duration")"
assert_contains "$out" "enabled_soak_duration_s_low_0.5_lt_2" \
  "enabled soak duration reason"

enabled_hz_consistency="$TMPDIR/enabled-hz-consistency.env"
cp "$template" "$enabled_hz_consistency"
sed -i 's/^enabled_soak_duration_s=.*/enabled_soak_duration_s=3.0/' "$enabled_hz_consistency"
out="$(run_expect_fail "enabled soak hz inconsistent" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$enabled_hz_consistency")"
assert_contains "$out" "enabled_soak_hz_inconsistent_sent_over_duration_133.333_reported_200_gt_1" \
  "enabled soak hz consistency reason"

enabled_last_seq="$TMPDIR/enabled-last-seq.env"
cp "$template" "$enabled_last_seq"
sed -i 's/^enabled_soak_state_last_target_seq=.*/enabled_soak_state_last_target_seq=1398/' "$enabled_last_seq"
out="$(run_expect_fail "enabled soak last seq stale" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$enabled_last_seq")"
assert_contains "$out" "enabled_soak_state_last_target_seq_lag_1_gt_0" \
  "enabled soak last target seq reason"

enabled_applied="$TMPDIR/enabled-applied.env"
cp "$template" "$enabled_applied"
sed -i 's/^enabled_soak_targets_applied_after=.*/enabled_soak_targets_applied_after=400/' "$enabled_applied"
out="$(run_expect_fail "enabled soak applied too low" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$enabled_applied")"
assert_contains "$out" "enabled_soak_targets_applied_delta_low_400_lt_16000" \
  "enabled soak applied delta reason"

enabled_mid="$TMPDIR/enabled-mid.env"
cp "$template" "$enabled_mid"
sed -i 's/^enabled_soak_targets_applied_mid=.*/enabled_soak_targets_applied_mid=16000/' "$enabled_mid"
out="$(run_expect_fail "enabled soak applied not monotonic" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$enabled_mid")"
assert_contains "$out" "enabled_soak_targets_applied_not_monotonic_0_16000_16000" \
  "enabled soak applied monotonic reason"

enabled_fault="$TMPDIR/enabled-fault.env"
cp "$template" "$enabled_fault"
sed -i 's/^enabled_soak_state_fault_bits=.*/enabled_soak_state_fault_bits=2/' "$enabled_fault"
out="$(run_expect_fail "enabled soak has fault" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$enabled_fault")"
assert_contains "$out" "enabled_soak_state_fault_bits_expected_0_got_2" \
  "enabled soak fault reason"

enabled_com_rate="$TMPDIR/enabled-com-rate.env"
cp "$template" "$enabled_com_rate"
sed -i 's/^com_status_soak_hz=.*/com_status_soak_hz=1.0/' "$enabled_com_rate"
out="$(run_expect_fail "enabled soak com status rate low" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$enabled_com_rate")"
assert_contains "$out" "com_status_soak_hz_out_of_range_4.5_5.5_got_1" \
  "enabled soak com status rate reason"

missing_enabled="$TMPDIR/missing-enabled.env"
grep -v '^enabled_soak_target_hz=' "$template" >"$missing_enabled"
out="$(run_expect_fail "missing enabled soak evidence" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$missing_enabled")"
assert_contains "$out" "BLOCKED_MISSING_EVIDENCE motor_m2_smoke" \
  "missing enabled soak status"
assert_contains "$out" "missing_enabled_soak_target_hz" \
  "missing enabled soak reason"

stack="$TMPDIR/stack.env"
cp "$template" "$stack"
sed -i 's/^microros_stack_free_words=.*/microros_stack_free_words=64/' "$stack"
out="$(run_expect_fail "stack margin low" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$stack")"
assert_contains "$out" "microros_stack_free_words_low_64_lt_128" \
  "stack margin reason"

heap_margin="$TMPDIR/heap-margin.env"
cp "$template" "$heap_margin"
sed -i 's/^newlib_heap_free_before_msp_reserve_bytes=.*/newlib_heap_free_before_msp_reserve_bytes=-1/' "$heap_margin"
out="$(run_expect_fail "newlib heap margin low" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$heap_margin")"
assert_contains "$out" "newlib_heap_free_before_msp_reserve_bytes_low_-1_lt_0" \
  "negative heap margin parse reason"

msp_reserve="$TMPDIR/msp-reserve.env"
cp "$template" "$msp_reserve"
sed -i 's/^newlib_heap_msp_reserved_bytes=.*/newlib_heap_msp_reserved_bytes=128/' "$msp_reserve"
out="$(run_expect_fail "msp reserve too small" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$msp_reserve")"
assert_contains "$out" "newlib_heap_msp_reserved_bytes_low_128_lt_512" \
  "MSP reserve reason"

agent_loss="$TMPDIR/agent-loss.env"
cp "$template" "$agent_loss"
sed -i 's/^agent_session_loss_events=.*/agent_session_loss_events=1/' "$agent_loss"
out="$(run_expect_fail "agent session loss" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$agent_loss")"
assert_contains "$out" "agent_session_loss_events_high_1_gt_0" \
  "agent session loss reason"

hardfault="$TMPDIR/hardfault.env"
cp "$template" "$hardfault"
sed -i 's/^hardfault_seen=.*/hardfault_seen=true/' "$hardfault"
out="$(run_expect_fail "hardfault seen" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$hardfault")"
assert_contains "$out" "hardfault_seen" \
  "hardfault reason"

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
cat >"$dir/health.before_enabled_soak.yaml" <<'EOF'
targets_received: 2
targets_applied: 0
EOF
cat >"$dir/enabled_soak.summary.txt" <<'EOF'
enabled_soak_target_hz=200.0
enabled_soak_duration_s=2.0
enabled_soak_targets_sent=400
enabled_soak_first_target_seq=1000
enabled_soak_last_target_seq=1399
EOF
cat >"$dir/health.mid_enabled_soak.yaml" <<'EOF'
targets_received: 202
targets_applied: 8000
EOF
cat >"$dir/state.mid_enabled_soak.yaml" <<'EOF'
last_target_seq: 1199
target_fresh: true
enabled: true
fault_bits: 0
EOF
cat >"$dir/state.after_enabled_soak.yaml" <<'EOF'
last_target_seq: 1399
target_fresh: true
enabled: true
fault_bits: 0
EOF
cat >"$dir/health.after_enabled_soak.yaml" <<'EOF'
targets_received: 402
targets_applied: 16000
EOF
cat >"$dir/rate.motor_state.txt" <<'EOF'
average rate: 50.000
min: 0.019s max: 0.021s std dev: 0.00100s window: 10
EOF
cat >"$dir/rate.motor_health.txt" <<'EOF'
average rate: 5.000
min: 0.190s max: 0.210s std dev: 0.00400s window: 10
EOF
cat >"$dir/rate.com_status.txt" <<'EOF'
status_sampler: count=11 rate_hz=5.000 min_gap_s=0.190 max_gap_s=0.210 p95_gap_s=0.210 p99_gap_s=0.210 std_gap_s=0.00400 zero_gap_count=0 duration_s=2.000 seq_rate_hz=5.000 seq_delta_avg=1.000 seq_delta_min=1 seq_delta_max=1
EOF
cat >"$dir/com_cmd.rate.log" <<'EOF'
[INFO] exo_cmd up: pub /com/tp_cmd_heartbeat @ 200 Hz, sub /com/tp_mcu_status
EOF
cat >"$dir/rate.com_status.soak.txt" <<'EOF'
status_sampler: count=11 rate_hz=5.000 min_gap_s=0.190 max_gap_s=0.210 p95_gap_s=0.210 p99_gap_s=0.210 std_gap_s=0.00400 zero_gap_count=0 duration_s=2.000 seq_rate_hz=5.000 seq_delta_avg=1.000 seq_delta_min=1 seq_delta_max=1
EOF
cat >"$dir/com_cmd.soak.log" <<'EOF'
[INFO] exo_cmd up: pub /com/tp_cmd_heartbeat @ 200 Hz, sub /com/tp_mcu_status
EOF
cat >"$dir/stack-hwm.txt" <<'EOF'
elf=firmware/f103-microros/build-motor/f103-microros.elf
microros_task_stack addr=0x20001150 bytes=3072 total_words=768 hwm_free_words=160 used_words=608
newlib_heap heap_end=0x20003ee0 end=0x20003ee0 estack=0x20005000 msp_reserved_bytes=1024 free_before_msp_reserve_bytes=3360 bytes_to_estack=4384
EOF
cat >"$dir/agent.log" <<'EOF'
[run-bridge] micro_ros_agent serial --dev /dev/ttyUSB0 -b 2000000 -v6
[INFO] session established
EOF
create_raw_manifest "$dir"

out="$("$ROOT/tools/check-motor-m2-smoke-evidence.py" "$dir")"
assert_contains "$out" "PASS motor_m2_smoke" \
  "passing directory evidence"
assert_contains "$out" "motor_state_hz_range=45..55" \
  "passing rate contract"
assert_contains "$out" "motor_health_hz_range=4.5..5.5" \
  "passing health rate contract"
assert_contains "$out" "enabled_soak_target_hz_range=180..220" \
  "passing enabled soak rate contract"
assert_contains "$out" "min_enabled_soak_duration_s=2" \
  "passing enabled soak duration contract"
assert_contains "$out" "max_enabled_soak_hz_consistency_error=1" \
  "passing enabled soak hz consistency contract"
assert_contains "$out" "min_enabled_soak_applied_per_received=40" \
  "passing enabled soak applied/received contract"
assert_contains "$out" "min_newlib_heap_msp_reserved_bytes=512" \
  "passing MSP reserve contract"
assert_contains "$out" "max_agent_session_loss_events=0" \
  "passing agent reconnect contract"

out="$(run_expect_fail "checker duration floor override" "$ROOT/tools/check-motor-m2-smoke-evidence.py" \
  "$dir" --min-enabled-soak-duration-s 0.5)"
assert_contains "$out" "--min-enabled-soak-duration-s must be >= 2" \
  "checker rejects weakened enabled soak duration floor"

missing_manifest_dir="$TMPDIR/missing-manifest-dir"
cp -a "$dir" "$missing_manifest_dir"
rm "$missing_manifest_dir/raw.sha256"
out="$(run_expect_fail "missing raw manifest" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$missing_manifest_dir")"
assert_contains "$out" "BLOCKED_MISSING_EVIDENCE motor_m2_smoke" \
  "missing raw manifest status"
assert_contains "$out" "missing_raw_manifest_sha256" \
  "missing raw manifest reason"

legacy_manifest_dir="$TMPDIR/legacy-manifest-dir"
cp -a "$dir" "$legacy_manifest_dir"
mv "$legacy_manifest_dir/raw.sha256" "$legacy_manifest_dir/manifest.sha256"
out="$(run_expect_fail "legacy manifest name only" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$legacy_manifest_dir")"
assert_contains "$out" "missing_raw_manifest_sha256" \
  "legacy manifest name is not accepted as raw evidence manifest"

tampered_raw_dir="$TMPDIR/tampered-raw-dir"
cp -a "$dir" "$tampered_raw_dir"
sed -i 's/^last_target_seq:.*/last_target_seq: 41/' \
  "$tampered_raw_dir/state.after_seq42.yaml"
out="$(run_expect_fail "tampered raw evidence" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$tampered_raw_dir")"
assert_contains "$out" "raw_hash_mismatch_state.after_seq42.yaml" \
  "tampered raw file reason"

bad_dir="$TMPDIR/bad-evidence-dir"
cp -a "$dir" "$bad_dir"
sed -i 's/^Subscription count:.*/Subscription count: 0/' "$bad_dir/info.motor_target.txt"
out="$(run_expect_fail "missing motor target subscriber" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$bad_dir")"
assert_contains "$out" "info_motor_target_not_ok" \
  "topic info subscription count reason"

substring_topic_dir="$TMPDIR/substring-topic-dir"
cp -a "$dir" "$substring_topic_dir"
sed -i 's#^/motor/tp_joint_target$#/motor/tp_joint_target_extra#' \
  "$substring_topic_dir/topics.txt"
out="$(run_expect_fail "substring motor target topic" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$substring_topic_dir")"
assert_contains "$out" "topic_motor_target_not_ok" \
  "topic list requires exact motor target match"

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

missing_health_rate_dir="$TMPDIR/missing-health-rate-dir"
cp -a "$dir" "$missing_health_rate_dir"
rm "$missing_health_rate_dir/rate.motor_health.txt"
out="$(run_expect_fail "missing motor health rate file" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$missing_health_rate_dir")"
assert_contains "$out" "missing_motor_health_hz" \
  "missing motor health rate reason"

bad_stack_dir="$TMPDIR/bad-stack-dir"
cp -a "$dir" "$bad_stack_dir"
cat >"$bad_stack_dir/stack-hwm.txt" <<'EOF'
led_task_stack addr=0x20000100 bytes=256 total_words=64 hwm_free_words=42 used_words=22
EOF
out="$(run_expect_fail "missing microros stack HWM" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$bad_stack_dir")"
assert_contains "$out" "missing_microros_stack_free_words" \
  "missing microros stack reason"
assert_contains "$out" "missing_newlib_heap_free_before_msp_reserve_bytes" \
  "missing newlib heap reason"

bad_agent_dir="$TMPDIR/bad-agent-dir"
cp -a "$dir" "$bad_agent_dir"
cat >"$bad_agent_dir/agent.log" <<'EOF'
[ERROR] session lost after disconnect
[WARN] reconnecting client
!!HARDFAULT!!
EOF
out="$(run_expect_fail "bad agent log" "$ROOT/tools/check-motor-m2-smoke-evidence.py" "$bad_agent_dir")"
assert_contains "$out" "agent_session_loss_events_high_2_gt_0" \
  "agent log session loss and reconnect reason"
assert_contains "$out" "hardfault_seen" \
  "agent log hardfault reason"

echo "PASS: M2 motor smoke evidence checker tests"
