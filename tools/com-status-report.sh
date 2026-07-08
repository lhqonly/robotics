#!/usr/bin/env bash
# Generate a communication validation handoff report from current logs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTDIR="${OUTDIR:-$ROOT/log/handoff}"
TAG="${1:-handoff_$(date +%Y%m%d_%H%M)}"
REPORT="$OUTDIR/$TAG.md"
COM_LOGDIR="$ROOT/log/com-perf"
SIZE_LOGDIR="$ROOT/log/firmware-size-matrix"
STACK_LOGDIR="$ROOT/log/firmware-stack-sweep"

mkdir -p "$OUTDIR"

latest_file() {
  local dir="$1"
  local pattern="$2"
  find "$dir" -maxdepth 1 -type f -name "$pattern" -printf '%T@ %p\n' 2>/dev/null |
    sort -nr |
    awk 'NR == 1 {sub(/^[^ ]+ /, ""); print; exit}' || true
}

relpath() {
  local path="${1:-}"
  if [ -z "$path" ]; then
    printf '-'
  else
    printf '%s' "${path#$ROOT/}"
  fi
}

metric_from_line() {
  local line="$1"
  local key="$2"
  printf '%s\n' "$line" |
    tr ' ' '\n' |
    awk -F= -v key="$key" '$1 == key {print $2}' |
    tail -1
}

first_table_rows() {
  local file="$1"
  local rows="${2:-12}"
  if [ -f "$file" ]; then
    sed -n "1,${rows}p" "$file"
  else
    echo "-"
  fi
}

probe_stlink() {
  if ! command -v st-info >/dev/null; then
    echo "status=unknown reason=st-info-not-found"
    return 0
  fi

  local out rc
  set +e
  out="$(timeout 15 st-info --probe 2>&1)"
  rc=$?
  set -e

  if [ "$rc" -ne 0 ]; then
    echo "status=bad rc=$rc"
    printf '%s\n' "$out"
    return 0
  fi

  if printf '%s\n' "$out" | grep -Eq 'dev-type:[[:space:]]+unknown|chipid:[[:space:]]+0x000'; then
    echo "status=bad_unknown_target"
  else
    echo "status=ok"
  fi
  printf '%s\n' "$out"
}

serial_presence() {
  local dev
  for dev in /dev/ttyUSB0 /dev/ttyACM0; do
    if [ -e "$dev" ]; then
      printf '%s=present ' "$dev"
    else
      printf '%s=missing ' "$dev"
    fi
  done
  echo
}

usb_snapshot() {
  if command -v lsusb >/dev/null; then
    lsusb 2>&1 || true
  else
    echo "lsusb not found"
  fi
}

serial_lsof() {
  if command -v lsof >/dev/null; then
    lsof /dev/ttyUSB0 /dev/ttyACM0 2>/dev/null || echo "no ttyUSB0/ttyACM0 lsof users"
  else
    echo "lsof not found"
  fi
}

git_branch="$(git -C "$ROOT" branch --show-current 2>/dev/null || echo unknown)"
git_rev="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
git_status="$(git -C "$ROOT" status --short 2>/dev/null || true)"
if [ -z "$git_status" ]; then
  git_status="clean"
fi

latest_sampler="$(latest_file "$COM_LOGDIR" '*.sampler.log')"
latest_hz="$(latest_file "$COM_LOGDIR" '*.hz.log')"
latest_cmd="$(latest_file "$COM_LOGDIR" '*.cmd.log')"
latest_wire="$(latest_file "$COM_LOGDIR" '*.wire.log')"
latest_size_md="$(latest_file "$SIZE_LOGDIR" '*.md')"
latest_stack_md="$(latest_file "$STACK_LOGDIR" '*.md')"

sampler_summary=""
if [ -f "$latest_sampler" ]; then
  sampler_summary="$(grep 'status_sampler:' "$latest_sampler" | tail -1 || true)"
fi
status_hz=""
if [ -f "$latest_hz" ]; then
  status_hz="$(awk '/average rate:/ {rate=$3} END {print rate}' "$latest_hz")"
fi
link_summary=""
if [ -f "$latest_cmd" ]; then
  link_summary="$(grep 'link-health summary' "$latest_cmd" | tail -1 || true)"
fi
wire_metrics=""
if [ -f "$latest_wire" ]; then
  wire_metrics="$(grep '^METRICS ' "$latest_wire" | tail -1 || true)"
fi

recovery_sampler="$COM_LOGDIR/noflash_recovery_20hz_after_200hz.sampler.log"
recovery_hz="$COM_LOGDIR/noflash_recovery_20hz_after_200hz.hz.log"
recovery_cmd="$COM_LOGDIR/noflash_recovery_20hz_after_200hz.cmd.log"
stress_sampler="$COM_LOGDIR/noflash_200hz_reliable_v6.sampler.log"
stress_wire="$COM_LOGDIR/noflash_200hz_reliable_v6.wire.log"
stress_cmd="$COM_LOGDIR/noflash_200hz_reliable_v6.cmd.log"

recovery_sampler_summary=""
recovery_status_hz=""
recovery_link_summary=""
if [ -f "$recovery_sampler" ]; then
  recovery_sampler_summary="$(grep 'status_sampler:' "$recovery_sampler" | tail -1 || true)"
fi
if [ -f "$recovery_hz" ]; then
  recovery_status_hz="$(awk '/average rate:/ {rate=$3} END {print rate}' "$recovery_hz")"
fi
if [ -f "$recovery_cmd" ]; then
  recovery_link_summary="$(grep 'link-health summary' "$recovery_cmd" | tail -1 || true)"
fi

stress_sampler_summary=""
stress_wire_metrics=""
stress_link_summary=""
if [ -f "$stress_sampler" ]; then
  stress_sampler_summary="$(grep 'status_sampler:' "$stress_sampler" | tail -1 || true)"
fi
if [ -f "$stress_wire" ]; then
  stress_wire_metrics="$(grep '^METRICS ' "$stress_wire" | tail -1 || true)"
fi
if [ -f "$stress_cmd" ]; then
  stress_link_summary="$(grep 'link-health summary' "$stress_cmd" | tail -1 || true)"
fi

stlink_probe="$(probe_stlink)"
serial_status="$(serial_presence)"
usb_status="$(usb_snapshot)"
serial_users="$(serial_lsof)"

{
  echo "# 通信验证交接报告"
  echo
  echo "- 生成时间：$(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "- 仓库版本：branch=$git_branch rev=$git_rev"
  echo "- 工作区状态：$git_status"
  echo "- 串口设备：$serial_status"
  echo
  echo "## USB/串口占用"
  echo
  echo '```text'
  printf '%s\n' "$usb_status"
  echo
  printf '%s\n' "$serial_users"
  echo '```'
  echo
  echo "## ST-LINK/SWD"
  echo
  echo '```text'
  printf '%s\n' "$stlink_probe"
  echo '```'
  echo
  echo "结论：如果出现 \`status=bad_unknown_target\`、\`chipid: 0x000\` 或 \`dev-type: unknown\`，说明 ST-LINK 本身可见，但 SWD 没读到 STM32 目标；此时不要阻塞 ROS/串口 no-flash 验证，但不能烧录新固件或复测运行期栈水位。"
  echo
  echo "## 最近日志"
  echo
  echo "- sampler：$(relpath "$latest_sampler")"
  echo "- topic hz：$(relpath "$latest_hz")"
  echo "- PC cmd：$(relpath "$latest_cmd")"
  echo "- wire stats：$(relpath "$latest_wire")"
  echo "- size matrix：$(relpath "$latest_size_md")"
  echo "- stack sweep：$(relpath "$latest_stack_md")"
  echo
  echo "## 最新通信指标"
  echo
  echo "- ros2 topic hz status_hz=${status_hz:-unknown}"
  echo "- sampler：${sampler_summary:-unknown}"
  echo "- LinkHealth：${link_summary:-unknown}"
  echo "- wire：${wire_metrics:-unknown}"
  echo
  echo "## 已知关键样本"
  echo
  echo "### no-flash 200Hz reliable/status_every_1 压力样本"
  echo
  echo "- sampler：${stress_sampler_summary:-missing}"
  echo "- LinkHealth：${stress_link_summary:-missing}"
  echo "- wire：${stress_wire_metrics:-missing}"
  if [ -n "$stress_wire_metrics" ]; then
    echo "- 线速占用：total_serial_kbit_s=$(metric_from_line "$stress_wire_metrics" total_serial_kbit_s) kbit/s，baud_util_pct=$(metric_from_line "$stress_wire_metrics" baud_util_pct)%"
  fi
  echo
  echo "解释：这个样本证明 PC 侧可以约 200Hz 下发，MCU status seq 也能快速前进，但 full-echo 状态回传跟不上；高频控制应采用 latest-target + 状态降频/采样，而不是要求每条 200Hz 命令 reliable 回显。"
  echo
  echo "### no-flash 20Hz 恢复样本"
  echo
  echo "- ros2 topic hz status_hz=${recovery_status_hz:-missing}"
  echo "- sampler：${recovery_sampler_summary:-missing}"
  echo "- LinkHealth：${recovery_link_summary:-missing}"
  echo
  echo "解释：用于确认 200Hz 压力后链路能回到稳定 20Hz 基线。"
  echo
  echo "## 固件静态内存矩阵"
  echo
  echo "来源：$(relpath "$latest_size_md")"
  echo
  echo '```markdown'
  first_table_rows "$latest_size_md" 12
  echo '```'
  echo
  echo "## micro-ROS 栈候选"
  echo
  echo "来源：$(relpath "$latest_stack_md")"
  echo
  echo '```markdown'
  first_table_rows "$latest_stack_md" 8
  echo '```'
  echo
  echo "## 未解决项"
  echo
  echo "- SWD 仍需恢复：当前无法 flash 新 profile，也无法读取高频运行期栈水位。"
  echo "- 10kHz/200Hz/best_effort/status_every_40 和 2Mbps profile 已能编译，但运行收益待 SWD 恢复后实测。"
  echo "- UART read polling 候选 \`EXO_UART_READ_POLL_YIELDS=4\` 仅完成编译/size 验证，是否改善 RTT/gap 长尾待上板实测。"
  echo "- idle stack 96 words、micro-ROS stack 704/640 words 目前是静态候选，必须上板用 \`tools/measure-stack-hwm.sh\` 复测后再设为默认。"
  echo "- \`cmd_catchup_max=1\` 只应用于 best-effort/status decimation/sampled 的 latest-target profile；不要用于 reliable/status_every_1/full-echo 默认诊断。"
  echo "- 200Hz reliable/status_every_1/full-echo 不适合作为控制链路目标；后续验收重点应转向 latest-target 接收率、状态采样频率、长尾 gap、lost/duplicate/inflight。"
  echo
  echo "## 下一步建议"
  echo
  echo "1. 先修 SWD：检查线缆、供电、BOOT/RESET、usbip 独占、ST-LINK 连接状态。"
  echo "2. SWD 恢复后跑：\`STAIRCASE_BAUDS=\"921600 2000000\" tools/run-com-staircase.sh staircase_\$(date +%Y%m%d_%H%M)\`。"
  echo "3. 高频 profile 跑通后读栈水位：\`tools/measure-stack-hwm.sh firmware/f103-microros/build/f103-microros.elf\`。"
  echo "4. 若 SWD 仍未恢复，继续 no-flash：\`BUILD_FIRMWARE=0 FLASH_FIRMWARE=0 tools/run-com-perf.sh noflash_\$(date +%H%M)\`。"
} >"$REPORT"

echo "[com-status-report] report=$REPORT"
