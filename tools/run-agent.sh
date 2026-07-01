#!/usr/bin/env bash
# 启动 micro-ROS Agent（macOS 主机侧），serial 传输对接 F103 micro-ROS client。
# 通信口 = 独立 USB-TTL 上的 USART1，macOS 设备通常为 /dev/cu.usbserial*。
#
# 用法：tools/run-agent.sh [dev] [baud]
#   dev   默认自动探测 /dev/cu.usbserial*、/dev/cu.SLAB_USBtoUART*、/dev/cu.usbmodem*
#   baud  默认 921600
#
# 前置：① ROS2 与 micro_ros_agent 已在当前 shell 或 EXO_ROS_SETUP/EXO_UROS_WS 中可用；
#       ② USB-TTL 已直接接入 MacBook。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/host-common.sh"

DEV="${1:-${EXO_DEV:-}}"
if [ -z "$DEV" ]; then
  DEV="$(exo_detect_serial_dev || true)"
fi
BAUD="${2:-921600}"

if [ -z "$DEV" ] || [ ! -e "$DEV" ]; then
  echo "[run-agent] 错误：未找到 USB-TTL 串口设备。" >&2
  exo_print_serial_help
  exit 1
fi

exo_source_agent || exit 1

echo "[run-agent] micro_ros_agent serial --dev $DEV -b $BAUD -v6"
exec ros2 run micro_ros_agent micro_ros_agent serial --dev "$DEV" -b "$BAUD" -v6
