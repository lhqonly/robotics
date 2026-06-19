#!/usr/bin/env bash
# 环境自检 —— T1 产出物，供复现与 Gill(G1) 验收
#
# 作用：打印外骨骼项目所需各工具链的版本/路径，一眼看出哪些就绪、哪些缺失。
#       覆盖 ROS2 Jazzy / arm-none-eabi-gcc / cmake / ninja / make / colcon /
#       codex / st-flash(或 OpenOCD) / micro_ros_setup 依赖等。
#
# 用法：
#   tools/env-check.sh            # 人类可读报告
#   tools/env-check.sh && echo OK # 全部关键组件就绪时返回 0，否则返回非 0
#
# 设计说明：
#   - 不退出于第一个缺失项（不使用 set -e），逐项检查并汇总，便于一次看全。
#   - 关键组件(KEY)缺失 -> 退出码非 0，方便 CI/验收脚本判定；
#     可选组件(非 KEY)缺失只告警，不影响退出码。
#   - 故意先 source ROS2 setup（若存在），否则 ros2/colcon 在新 shell 里找不到。

set -uo pipefail

# ---- 可被环境变量覆盖的默认值 ----
ROS_DISTRO_DEFAULT="jazzy"
ROS_SETUP="/opt/ros/${ROS_DISTRO:-$ROS_DISTRO_DEFAULT}/setup.bash"

# 若 ROS2 已安装但当前 shell 未 source，则临时 source，让 ros2/colcon 可见。
# 注意：ROS 的 setup.bash 引用了未初始化的 AMENT_TRACE_SETUP_FILES 等变量，
# 与本脚本的 `set -u` 不兼容，故 source 前后临时关闭 -u。
if [[ -f "$ROS_SETUP" ]]; then
  set +u
  # shellcheck disable=SC1090
  source "$ROS_SETUP"
  set -u
fi

# ---- 颜色（仅在 TTY 下启用，避免污染日志/管道）----
if [[ -t 1 ]]; then
  C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_WARN=$'\033[33m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_OK=""; C_BAD=""; C_WARN=""; C_DIM=""; C_RST=""
fi

FAIL=0   # 关键组件缺失计数 -> 决定退出码

# check <KEY|OPT> <显示名> <可执行名> <取版本命令...>
# - KEY：关键组件，缺失则全局失败
# - OPT：可选组件，缺失只告警
check() {
  local level="$1" name="$2" bin="$3"; shift 3
  local path version status
  if path="$(command -v "$bin" 2>/dev/null)"; then
    version="$("$@" 2>&1 | head -n1)"
    printf "%b[ OK ]%b %-22s %s\n" "$C_OK" "$C_RST" "$name" "$version"
    printf "       %s%s%s\n" "$C_DIM" "$path" "$C_RST"
  else
    if [[ "$level" == "KEY" ]]; then
      status="${C_BAD}[FAIL]${C_RST}"; FAIL=$((FAIL+1))
    else
      status="${C_WARN}[MISS]${C_RST}"
    fi
    printf "%b %-22s %snot found%s\n" "$status" "$name" "$C_DIM" "$C_RST"
  fi
}

echo "================= 外骨骼项目 环境自检 (T1 / G1) ================="
echo "主机: $(uname -srm)    用户: $(whoami)    日期: $(date '+%F %T')"
echo "ROS setup: ${ROS_SETUP} $( [[ -f "$ROS_SETUP" ]] && echo '(已 source)' || echo '(不存在)')"
echo "----------------------------------------------------------------"

echo "[ROS2 / micro-ROS 侧]"
check KEY "ros2"            ros2              ros2 --version
check KEY "colcon"         colcon            colcon version-check
check OPT "rosdep"         rosdep            rosdep --version
check OPT "vcs (vcstool)"  vcs               vcs --version
# micro_ros_agent 是 colcon 包，运行期才有；这里只探测可执行入口是否已 build。
if [[ -n "${AMENT_PREFIX_PATH:-}" ]] && ros2 pkg list 2>/dev/null | grep -qx micro_ros_agent; then
  printf "%b[ OK ]%b %-22s %s\n" "$C_OK" "$C_RST" "micro_ros_agent" "已在 AMENT 路径中(可 ros2 run)"
else
  printf "%b[MISS]%b %-22s %s未 build(T3 再做)%s\n" "$C_WARN" "$C_RST" "micro_ros_agent" "$C_DIM" "$C_RST"
fi
echo

echo "[固件工具链]"
check KEY "arm gcc"        arm-none-eabi-gcc arm-none-eabi-gcc --version
check OPT "arm g++"        arm-none-eabi-g++ arm-none-eabi-g++ --version
check OPT "arm objcopy"    arm-none-eabi-objcopy arm-none-eabi-objcopy --version
# 24.04 已移除 gdb-arm-none-eabi，改用 gdb-multiarch（调试时 set architecture arm）
check OPT "arm gdb (multiarch)" gdb-multiarch gdb-multiarch --version
check KEY "cmake"          cmake             cmake --version
check KEY "ninja"          ninja             ninja --version
check OPT "make"           make              make --version
echo

echo "[烧录 / 调试]"
check OPT "st-flash"       st-flash          st-flash --version
check OPT "st-info"        st-info           st-info --version
check OPT "openocd"        openocd           openocd --version
echo

echo "[评审工具]"
check KEY "codex"          codex             codex --version
echo

echo "----------------------------------------------------------------"
if [[ "$FAIL" -eq 0 ]]; then
  echo "${C_OK}结果: 关键组件齐备。${C_RST}"
  exit 0
else
  echo "${C_BAD}结果: 有 ${FAIL} 个关键组件缺失。请运行 tools/install-toolchain.sh 或参考 T1 任务卡。${C_RST}"
  exit 1
fi
