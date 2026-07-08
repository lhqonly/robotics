#!/usr/bin/env bash
# 启动 micro-ROS Agent（WSL 侧），serial 传输对接 F103 micro-ROS client。
# 契约 v1.3：通信口 = 独立 USB-TTL 上的 USART1，WSL 设备 /dev/ttyUSB0（非 ST-Link 的 ttyACM0）。
#
# 用法：tools/run-bridge.sh [dev] [baud]
#   dev   默认 /dev/ttyUSB0（USB-TTL；以 `ls /dev/ttyUSB*` 实际为准）
#   baud  默认 921600
#   MICROROS_AGENT_VERBOSITY 默认 1；排障时可设为 6，性能测试建议 0/1
#
# 前置：① ~/uros_ws 已 build_agent（T3 完成）；② USB-TTL 已 usbipd attach 进 WSL。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV="${1:-/dev/ttyUSB0}"
BAUD="${2:-921600}"
VERBOSITY="${MICROROS_AGENT_VERBOSITY:-1}"
SERIAL_LOCK_WAIT_SECONDS="${SERIAL_LOCK_WAIT_SECONDS:-0}"
SERIAL_LOCK="${SERIAL_LOCK:-$ROOT/log/com-perf/.com-perf-$(basename "$DEV").lock}"
RUN_BRIDGE_LOCK_HELD="${RUN_BRIDGE_LOCK_HELD:-0}"

if [ ! -e "$DEV" ]; then
  echo "[run-bridge] 错误：$DEV 不存在。USB-TTL 透传进 WSL 了吗？(usbipd attach + ls /dev/ttyUSB*)" >&2
  exit 1
fi

if [ "$RUN_BRIDGE_LOCK_HELD" != "1" ]; then
  mkdir -p "$(dirname "$SERIAL_LOCK")"
  if command -v flock >/dev/null; then
    exec 9>"$SERIAL_LOCK"
    if ! flock -w "$SERIAL_LOCK_WAIT_SECONDS" 9; then
      echo "[run-bridge] 错误：通信串口忙：$DEV (lock=$SERIAL_LOCK)" >&2
      echo "[run-bridge] 如需等待，设置 SERIAL_LOCK_WAIT_SECONDS=<seconds>。" >&2
      exit 1
    fi
  else
    echo "[run-bridge] 警告：flock 不存在，串口并发保护关闭。" >&2
  fi
fi

set +u
source /opt/ros/jazzy/setup.bash
source "$HOME/uros_ws/install/local_setup.bash"
set -u

echo "[run-bridge] lock=$SERIAL_LOCK wait_s=$SERIAL_LOCK_WAIT_SECONDS held=$RUN_BRIDGE_LOCK_HELD"
echo "[run-bridge] micro_ros_agent serial --dev $DEV -b $BAUD -v$VERBOSITY"
exec ros2 run micro_ros_agent micro_ros_agent serial --dev "$DEV" -b "$BAUD" -v"$VERBOSITY"
