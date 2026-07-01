#!/usr/bin/env bash
# Shared host helpers for the macOS branch.
#
# This branch targets a MacBook connected directly to the F103 board:
#   MacBook ROS2/micro-ROS Agent <-> USB serial <-> STM32F103 micro-ROS client

EXO_HOST_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXO_REPO_ROOT="$(cd "$EXO_HOST_COMMON_DIR/.." && pwd)"
EXO_ROS_WS="${EXO_ROS_WS:-$EXO_REPO_ROOT/ros2_ws}"
EXO_LOGDIR="${EXO_LOGDIR:-$EXO_REPO_ROOT/log}"
EXO_UROS_WS="${EXO_UROS_WS:-$HOME/uros_ws}"
EXO_ROS_DISTRO="${ROS_DISTRO:-jazzy}"

exo_source_if_exists() {
  local file="$1"
  if [ -f "$file" ]; then
    # ROS setup files read unset variables on some installs; keep callers free
    # to use `set -u`.
    set +u
    # shellcheck disable=SC1090
    source "$file"
    set -u
    return 0
  fi
  return 1
}

exo_source_ros() {
  if [ -n "${EXO_ROS_SETUP:-}" ]; then
    exo_source_if_exists "$EXO_ROS_SETUP" || {
      echo "[host] EXO_ROS_SETUP does not exist: $EXO_ROS_SETUP" >&2
      return 1
    }
  elif command -v ros2 >/dev/null 2>&1; then
    :
  else
    exo_source_if_exists "/opt/ros/$EXO_ROS_DISTRO/setup.bash" ||
      exo_source_if_exists "/opt/ros/$EXO_ROS_DISTRO/setup.zsh" ||
      exo_source_if_exists "$HOME/ros2_$EXO_ROS_DISTRO/install/setup.bash" ||
      exo_source_if_exists "$HOME/ros2_$EXO_ROS_DISTRO/install/setup.zsh" || {
        echo "[host] ROS2 is not on PATH and no setup file was found." >&2
        echo "[host] Set EXO_ROS_SETUP=/path/to/setup.bash or source ROS2 first." >&2
        return 1
      }
  fi

  exo_source_if_exists "$EXO_ROS_WS/install/setup.bash" ||
    exo_source_if_exists "$EXO_ROS_WS/install/local_setup.bash" || true
}

exo_source_agent() {
  exo_source_ros || return 1
  exo_source_if_exists "$EXO_UROS_WS/install/local_setup.bash" ||
    exo_source_if_exists "$EXO_UROS_WS/install/setup.bash" || true
}

exo_detect_serial_dev() {
  local candidates=(
    /dev/cu.usbserial*
    /dev/cu.SLAB_USBtoUART*
    /dev/cu.wchusbserial*
    /dev/cu.usbmodem*
    /dev/tty.usbserial*
    /dev/tty.SLAB_USBtoUART*
    /dev/tty.wchusbserial*
    /dev/tty.usbmodem*
    /dev/ttyUSB0
    /dev/ttyACM0
  )
  local dev
  for dev in "${candidates[@]}"; do
    [ -e "$dev" ] && { printf '%s\n' "$dev"; return 0; }
  done
  return 1
}

exo_print_serial_help() {
  echo "可用串口候选：" >&2
  ls /dev/cu.* /dev/tty.* 2>/dev/null | sed 's/^/  /' >&2 || true
  echo "请把 USB-TTL 接到 MacBook 后重试，或显式传入设备：" >&2
  echo "  EXO_DEV=/dev/cu.usbserial-xxxx $0" >&2
}

exo_kill_tree_signal() {
  local sig="$1" pid="$2"
  [ -n "$pid" ] || return 0
  kill -0 "$pid" 2>/dev/null || return 0

  local child
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    exo_kill_tree_signal "$sig" "$child"
  done
  kill "-$sig" "$pid" 2>/dev/null || true
}

exo_kill_tree() {
  local pid="$1"
  exo_kill_tree_signal TERM "$pid"
  sleep 1
  exo_kill_tree_signal KILL "$pid"
}
