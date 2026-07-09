#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="$ROOT/firmware/f103-microros/colcon.motor.meta"
ANNOTATED="$ROOT/firmware/f103-microros/colcon.motor.meta.annotated"

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

echo "PASS: motor micro-ROS config candidate"
