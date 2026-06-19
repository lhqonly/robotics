#!/usr/bin/env bash
# 工具链一键安装 —— T1 步骤的可复现脚本
#
# 作用：在干净的 Ubuntu 24.04 (Noble) 上装齐外骨骼项目所需工具链：
#   1) ROS2 Jazzy (ros-base + dev-tools) + 写入 ~/.bashrc 的 source
#   2) micro_ros_setup 依赖 (rosdep / vcstool / colcon / pip 等，由 ros-dev-tools 覆盖)
#   3) arm-none-eabi-gcc 工具链 + cmake + ninja + make
#   4) stlink-tools (st-flash) + OpenOCD（烧录/调试，Phase B 用）
#   5) codex CLI（评审，见脚本末尾——非 apt 源，单独说明）
#
# 为什么单独成脚本而不是直接跑：
#   - 这些步骤需要 sudo，且在非交互 agent 会话里无法输入密码。
#   - 因此把"确切命令"固化下来，由人在交互终端执行，保证可复现、可审计。
#
# 用法（在交互终端、有 sudo 密码的环境下）：
#   bash tools/install-toolchain.sh            # 全装（ROS2 用 ros-base，体积小）
#   ROS_PKG=ros-jazzy-desktop bash tools/install-toolchain.sh   # 改装 desktop(含 rviz 等)
#
# 安全：本脚本只调用官方 apt 源与 ROS2 官方 ros2-apt-source 包；不下载来路不明二进制。
# 参考：https://docs.ros.org/en/jazzy/Installation/Ubuntu-Install-Debs.html
set -euo pipefail

ROS_DISTRO="${ROS_DISTRO:-jazzy}"
ROS_PKG="${ROS_PKG:-ros-${ROS_DISTRO}-ros-base}"   # 默认 ros-base；可覆盖为 ros-jazzy-desktop
BASHRC="${HOME}/.bashrc"

log() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# 0. 前置检查
# ---------------------------------------------------------------------------
if [[ "$(. /etc/os-release && echo "$VERSION_ID")" != "24.04" ]]; then
  echo "警告: 本脚本针对 Ubuntu 24.04 (ROS2 Jazzy)。当前系统非 24.04，继续需自行确认。" >&2
fi

# ---------------------------------------------------------------------------
# 1. ROS2 Jazzy
# ---------------------------------------------------------------------------
log "1/5 配置 locale (UTF-8)"
sudo apt-get update
sudo apt-get install -y locales
sudo locale-gen en_US en_US.UTF-8
sudo update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
export LANG=en_US.UTF-8

log "1/5 添加 ROS2 apt 源 (ros2-apt-source)"
sudo apt-get install -y software-properties-common curl
sudo add-apt-repository -y universe
# 用 ros-apt-source 官方包提供 GPG key + source 列表（取最新 release，避免版本漂移）
ROS_APT_VERSION="$(curl -fsSL https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest \
  | grep -F '"tag_name"' | awk -F'"' '{print $4}')"
curl -fsSL -o /tmp/ros2-apt-source.deb \
  "https://github.com/ros-infrastructure/ros-apt-source/releases/download/${ROS_APT_VERSION}/ros2-apt-source_${ROS_APT_VERSION}.$(. /etc/os-release && echo "$VERSION_CODENAME")_all.deb"
sudo dpkg -i /tmp/ros2-apt-source.deb

log "1/5 安装 ROS2 (${ROS_PKG}) + dev-tools"
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install -y "${ROS_PKG}" ros-dev-tools
# ros-dev-tools 已含: colcon-common-extensions, rosdep, vcstool, python3-* 构建依赖 -> 覆盖步骤 2

log "1/5 把 source 写入 ${BASHRC}"
SRC_LINE="source /opt/ros/${ROS_DISTRO}/setup.bash"
if ! grep -qxF "$SRC_LINE" "$BASHRC" 2>/dev/null; then
  printf '\n# ROS2 %s (added by install-toolchain.sh)\n%s\n' "$ROS_DISTRO" "$SRC_LINE" >> "$BASHRC"
  echo "已追加: $SRC_LINE"
else
  echo "已存在，跳过: $SRC_LINE"
fi

log "1/5 初始化 rosdep (供 micro_ros_setup / 后续 build 解析依赖)"
sudo rosdep init || echo "rosdep 已初始化，跳过"
rosdep update

# ---------------------------------------------------------------------------
# 2. micro_ros_setup 依赖
#    说明: micro_ros_setup 本身是个 colcon 包，T3 时再 git clone 进 ros2_ws 并 build。
#    它依赖的 colcon/rosdep/vcstool/pip 已由上面的 ros-dev-tools 安装齐。这里补 pip。
# ---------------------------------------------------------------------------
log "2/5 micro_ros_setup 构建依赖 (pip / git)"
sudo apt-get install -y git python3-pip

# ---------------------------------------------------------------------------
# 3. 固件工具链: arm-none-eabi-gcc + cmake + ninja + make
# ---------------------------------------------------------------------------
log "3/5 安装 arm-none-eabi 工具链 + cmake + ninja + make"
sudo apt-get install -y \
  gcc-arm-none-eabi binutils-arm-none-eabi gdb-multiarch \
  libnewlib-arm-none-eabi \
  cmake ninja-build make build-essential

# ---------------------------------------------------------------------------
# 4. 烧录 / 调试: stlink-tools + OpenOCD (Phase B 用)
# ---------------------------------------------------------------------------
log "4/5 安装 stlink-tools (st-flash) + OpenOCD"
sudo apt-get install -y stlink-tools openocd

# ---------------------------------------------------------------------------
# 5. codex CLI —— 非 apt 源，需单独装（说明，不在本脚本自动执行二进制下载）
# ---------------------------------------------------------------------------
log "5/5 codex CLI"
cat <<'EOF'
codex CLI 不在 apt 源中。登录态已随 ~/.codex 迁移，只需装二进制，二选一：

  方案 A (npm，推荐，自动随 npm 更新):
     sudo apt-get install -y nodejs npm
     sudo npm install -g @openai/codex
     codex --version

  方案 B (官方 release 二进制):
     从 https://github.com/openai/codex/releases 下载对应 x86_64-linux 包，
     解压后把 codex 放进 ~/.local/bin (确保该目录在 PATH 中)。

装完后运行 tools/env-check.sh 应能看到 codex 一行 [ OK ]。
EOF

log "完成。运行 'source ~/.bashrc' 或重开终端，再执行 tools/env-check.sh 验收。"
