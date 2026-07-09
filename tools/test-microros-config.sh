#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="$ROOT/firmware/f103-microros/colcon.meta"
ANNOTATED="$ROOT/firmware/f103-microros/colcon.meta.annotated"
UXR_CONFIG="$ROOT/firmware/f103-microros/ThirdParty/microros/include/uxr/client/config.h"
RMW_CONFIG="$ROOT/firmware/f103-microros/ThirdParty/microros/include/rmw_microxrcedds_c/config.h"

assert_contains() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if ! grep -Fq -- "$pattern" "$file"; then
    echo "FAIL: $label missing pattern '$pattern' in $file" >&2
    exit 1
  fi
}

assert_contains "$META" "-DROSIDL_TYPESUPPORT_SINGLE_TYPESUPPORT=OFF" "single typesupport default"
assert_contains "$META" "-DUCLIENT_MAX_OUTPUT_BEST_EFFORT_STREAMS=1" "output best-effort stream"
assert_contains "$META" "-DUCLIENT_MAX_INPUT_BEST_EFFORT_STREAMS=1" "input best-effort stream"
assert_contains "$META" "-DUCLIENT_CUSTOM_TRANSPORT_MTU=128" "custom transport MTU"
assert_contains "$META" "-DRMW_UXRCE_STREAM_HISTORY=2" "XRCE stream history"
assert_contains "$META" "-DRMW_UXRCE_CREATION_MODE=bin" "creation mode"

assert_contains "$ANNOTATED" "-DROSIDL_TYPESUPPORT_SINGLE_TYPESUPPORT=OFF" "annotated single typesupport"
assert_contains "$ANNOTATED" "-DUCLIENT_MAX_OUTPUT_BEST_EFFORT_STREAMS=1" "annotated output best-effort stream"
assert_contains "$ANNOTATED" "-DUCLIENT_MAX_INPUT_BEST_EFFORT_STREAMS=1" "annotated input best-effort stream"
assert_contains "$ANNOTATED" "-DRMW_UXRCE_STREAM_HISTORY=2" "annotated stream history"
assert_contains "$ANNOTATED" "-DRMW_UXRCE_CREATION_MODE=bin" "annotated creation mode"

assert_contains "$UXR_CONFIG" "#define UXR_CONFIG_CUSTOM_TRANSPORT_MTU               128" "generated custom MTU"
assert_contains "$RMW_CONFIG" "#define RMW_UXRCE_STREAM_HISTORY_INPUT 2" "generated input stream history"
assert_contains "$RMW_CONFIG" "#define RMW_UXRCE_STREAM_HISTORY_OUTPUT 2" "generated output stream history"

echo "PASS: micro-ROS config contract"
