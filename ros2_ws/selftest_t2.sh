#!/usr/bin/env bash
# T2 hardware-free loopback self-test.
# Sources ROS2 + this workspace, launches exo_cmd + loopback, then samples
# /exo/mcu_status and the QoS of both topics, and shuts everything down.
#
# Run:  ./selftest_t2.sh
#
# NOTE: deliberately NO `set -u`. ROS2 setup.bash references unbound vars
# (e.g. AMENT_TRACE_SETUP_FILES) and aborts under nounset. We also avoid
# `set -e` because expected timeouts on `ros2 topic echo` return non-zero.

WS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
. /opt/ros/jazzy/setup.bash
# shellcheck disable=SC1091
. "${WS_ROOT}/install/setup.bash"

echo "=== ROS_DISTRO=${ROS_DISTRO} ==="

# Start the full loopback (exo_cmd + exo_loopback) in the background.
ros2 launch exo_bringup loopback_test.launch.py > /tmp/t2_launch.log 2>&1 &
LAUNCH_PID=$!

# Let discovery + a few heartbeats happen.
sleep 4

echo "=== ros2 node list ==="
ros2 node list

echo "=== ros2 topic list (exo) ==="
ros2 topic list | grep exo

echo "=== sample /exo/mcu_status (3 msgs) ==="
timeout 3 ros2 topic echo --once /exo/mcu_status
timeout 3 ros2 topic echo --once /exo/mcu_status
timeout 3 ros2 topic echo --once /exo/mcu_status

echo "=== QoS: /exo/cmd_heartbeat ==="
ros2 topic info -v /exo/cmd_heartbeat

echo "=== QoS: /exo/mcu_status ==="
ros2 topic info -v /exo/mcu_status

echo "=== applied QoS (local ground truth, from node logs) ==="
echo "NOTE: 'ros2 topic info -v' shows History/Depth=UNKNOWN for REMOTE"
echo "endpoints by DDS design (History/depth are not propagated over"
echo "discovery). The lines below are the REAL local QoS each node set:"
grep -E "applied QoS" /tmp/t2_launch.log

echo "=== exo_cmd round-trip log (tail) ==="
grep -E "round-trip|UNMATCHED" /tmp/t2_launch.log | tail -10

# Tear down the launch process group.
kill -INT "${LAUNCH_PID}" 2>/dev/null
sleep 1
kill -TERM "${LAUNCH_PID}" 2>/dev/null
pkill -f exo_cmd_node 2>/dev/null
pkill -f loopback_node 2>/dev/null
echo "=== selftest done ==="
