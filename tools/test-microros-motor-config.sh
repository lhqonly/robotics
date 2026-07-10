#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="$ROOT/firmware/f103-microros/colcon.motor.meta"
ANNOTATED="$ROOT/firmware/f103-microros/colcon.motor.meta.annotated"
CMAKELISTS="$ROOT/firmware/f103-microros/CMakeLists.txt"
MICROROS_APP="$ROOT/firmware/f103-microros/src/microros_app.c"

assert_contains() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if ! grep -Fq -- "$pattern" "$file"; then
    echo "FAIL: $label missing pattern '$pattern' in $file" >&2
    exit 1
  fi
}

python3 -m json.tool "$META" >/dev/null

assert_contains "$META" "-DROSIDL_TYPESUPPORT_SINGLE_TYPESUPPORT=OFF" "single typesupport"
assert_contains "$META" "-DUCLIENT_CUSTOM_TRANSPORT_MTU=128" "custom transport MTU"
assert_contains "$META" "-DRMW_UXRCE_MAX_NODES=1" "node pool"
assert_contains "$META" "-DRMW_UXRCE_MAX_PUBLISHERS=3" "publisher pool"
assert_contains "$META" "-DRMW_UXRCE_MAX_SUBSCRIPTIONS=2" "subscription pool"
assert_contains "$META" "-DRMW_UXRCE_MAX_SERVICES=0" "service pool"
assert_contains "$META" "-DRMW_UXRCE_MAX_CLIENTS=0" "client pool"
assert_contains "$META" "-DRMW_UXRCE_MAX_HISTORY=1" "latest-only history"
assert_contains "$META" "-DRMW_UXRCE_STREAM_HISTORY=4" "motor stream history"
assert_contains "$META" "-DRMW_UXRCE_CREATION_MODE=bin" "creation mode"

assert_contains "$ANNOTATED" "/motor/tp_joint_state" "annotated joint_state publisher"
assert_contains "$ANNOTATED" "/motor/tp_motor_health" "annotated motor_health publisher"
assert_contains "$ANNOTATED" "/motor/tp_joint_target" "annotated joint_target subscription"
assert_contains "$ANNOTATED" "STREAM_HISTORY 先从 2 提到 4" "annotated stream history rationale"

assert_contains "$CMAKELISTS" "EXO_MOTOR_TELEMETRY_QOS_BEST_EFFORT" \
  "motor telemetry QoS compile option"
assert_contains "$MICROROS_APP" "#if EXO_MOTOR_TELEMETRY_QOS_BEST_EFFORT" \
  "motor telemetry best-effort branch"
assert_contains "$MICROROS_APP" "rclc_publisher_init_best_effort(" \
  "motor telemetry best-effort publisher init"
assert_contains "$MICROROS_APP" "rclc_publisher_init_default(" \
  "motor telemetry reliable/default publisher fallback"

python3 - "$MICROROS_APP" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
blocks = re.findall(
    r"#if EXO_MOTOR_TELEMETRY_QOS_BEST_EFFORT(.*?)#endif",
    text,
    flags=re.S,
)
if len(blocks) != 2:
    raise SystemExit(
        f"FAIL: expected exactly 2 motor telemetry QoS blocks, got {len(blocks)}"
    )

expected_topics = ["motor/tp_joint_state", "motor/tp_motor_health"]
for topic, block in zip(expected_topics, blocks):
    if topic not in block:
        raise SystemExit(f"FAIL: telemetry QoS block missing topic {topic}")
    if "rclc_publisher_init_best_effort" not in block:
        raise SystemExit(f"FAIL: telemetry QoS block for {topic} missing best-effort init")
    if "rclc_publisher_init_default" not in block:
        raise SystemExit(f"FAIL: telemetry QoS block for {topic} missing default fallback")

for forbidden in [
    "com/tp_mcu_status",
    "com/tp_cmd_heartbeat",
    "motor/tp_joint_target",
    "rclc_subscription_init",
]:
    if any(forbidden in block for block in blocks):
        raise SystemExit(f"FAIL: telemetry QoS macro unexpectedly wraps {forbidden}")
PY

echo "PASS: motor micro-ROS config candidate"
