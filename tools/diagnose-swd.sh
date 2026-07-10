#!/usr/bin/env bash
# Diagnose ST-LINK/SWD readiness without flashing or resetting the target.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ST_INFO_CMD="${ST_INFO_CMD:-st-info}"
LSUSB_CMD="${LSUSB_CMD:-lsusb}"
LSOF_CMD="${LSOF_CMD:-lsof}"
DMESG_CMD="${DMESG_CMD:-dmesg}"
TIMEOUT_CMD="${TIMEOUT_CMD:-timeout}"
POWERSHELL_CMD="${POWERSHELL_CMD:-powershell.exe}"
USBIPD_CMD="${USBIPD_CMD:-usbipd}"
STLINK_TIMEOUT_SECONDS="${STLINK_TIMEOUT_SECONDS:-15}"
STRICT="${STRICT:-0}"
TTY_USB="${TTY_USB:-/dev/ttyUSB0}"
TTY_ACM="${TTY_ACM:-/dev/ttyACM0}"

status="unknown"
reason="not-run"
stinfo_rc="NA"
stinfo_out=""
lsusb_out=""
lsof_out=""
dmesg_out=""
windows_usbipd_out=""

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

presence() {
  local path="$1"
  if [ -e "$path" ]; then
    printf 'present'
  else
    printf 'missing'
  fi
}

run_lsusb() {
  if have_cmd "$LSUSB_CMD"; then
    "$LSUSB_CMD" 2>&1 || true
  else
    echo "$LSUSB_CMD not found"
  fi
}

run_windows_usbipd_list() {
  if have_cmd "$POWERSHELL_CMD"; then
    local out
    out="$("$POWERSHELL_CMD" -NoProfile -Command "$USBIPD_CMD list" 2>&1 || true)"
    printf '%s\n' "$out" | tr -d '\r'
  else
    echo "$POWERSHELL_CMD not found; from Windows run: usbipd list"
  fi
}

run_lsof() {
  if have_cmd "$LSOF_CMD"; then
    local out
    out="$("$LSOF_CMD" "$TTY_USB" "$TTY_ACM" 2>/dev/null || true)"
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
    else
      echo "no tty lsof users"
    fi
  else
    echo "$LSOF_CMD not found"
  fi
}

run_dmesg_tail() {
  if have_cmd "$DMESG_CMD"; then
    "$DMESG_CMD" 2>/dev/null |
      grep -Ei 'usbip|vhci|st-link|stlink|ttyACM|ttyUSB|libusb|reset|disconnect' |
      tail -20 || true
  else
    echo "$DMESG_CMD not found"
  fi
}

probe_stlink() {
  if ! have_cmd "$ST_INFO_CMD"; then
    status="unknown"
    reason="st-info-not-found"
    stinfo_rc="NA"
    stinfo_out="$ST_INFO_CMD not found"
    return 0
  fi

  set +e
  if have_cmd "$TIMEOUT_CMD"; then
    stinfo_out="$("$TIMEOUT_CMD" "$STLINK_TIMEOUT_SECONDS" "$ST_INFO_CMD" --probe 2>&1)"
    stinfo_rc=$?
  else
    stinfo_out="$("$ST_INFO_CMD" --probe 2>&1)"
    stinfo_rc=$?
  fi
  set -e

  if [ "$stinfo_rc" -ne 0 ]; then
    status="bad_probe_failed"
    reason="st-info-rc-$stinfo_rc"
    return 0
  fi

  if printf '%s\n' "$stinfo_out" |
      grep -Eq 'Found[[:space:]]+0 stlink programmers'; then
    status="bad_no_stlink"
    reason="no-stlink-programmer"
    return 0
  fi

  if printf '%s\n' "$stinfo_out" |
      grep -Eq 'dev-type:[[:space:]]+unknown|chipid:[[:space:]]+0x000'; then
    status="bad_unknown_target"
    reason="probe-visible-but-target-invalid"
    return 0
  fi

  status="ok"
  reason="probe-ok"
}

usbipd_line_for_pattern() {
  local pattern="$1"
  printf '%s\n' "$windows_usbipd_out" |
    awk -v pat="$pattern" 'BEGIN { IGNORECASE = 1 } $0 ~ pat { print; exit }'
}

usbipd_presence_from_line() {
  local line="$1"
  if [ -n "$line" ]; then
    printf 'present'
  else
    printf 'missing'
  fi
}

usbipd_state_from_line() {
  local line="$1"
  if [ -n "$line" ]; then
    awk '{ print $NF }' <<<"$line"
  else
    printf 'missing'
  fi
}

windows_usbipd="available"
if ! have_cmd "$POWERSHELL_CMD"; then
  windows_usbipd="unavailable"
fi
windows_usbipd_out="$(run_windows_usbipd_list)"
lsusb_out="$(run_lsusb)"
lsof_out="$(run_lsof)"
dmesg_out="$(run_dmesg_tail)"
probe_stlink

usb_stlink="unknown"
if printf '%s\n' "$lsusb_out" | grep -Eiq 'STMicroelectronics|ST-LINK|STLINK|0483:374'; then
  usb_stlink="present"
else
  usb_stlink="missing"
fi

usb_ttl="unknown"
if printf '%s\n' "$lsusb_out" | grep -Eiq 'FTDI|Future Technology|USB.*Serial|UART|0403:6001'; then
  usb_ttl="present"
else
  usb_ttl="missing"
fi

windows_stlink_line="$(usbipd_line_for_pattern 'STMicroelectronics|ST-LINK|STLINK|0483:374')"
windows_ttl_line="$(usbipd_line_for_pattern 'FTDI|Future Technology|USB.*Serial|UART|0403:6001')"
windows_stlink="$(usbipd_presence_from_line "$windows_stlink_line")"
windows_ttl="$(usbipd_presence_from_line "$windows_ttl_line")"
windows_stlink_state="$(usbipd_state_from_line "$windows_stlink_line")"
windows_ttl_state="$(usbipd_state_from_line "$windows_ttl_line")"

cat <<EOF
# SWD Diagnostic

SWD_STATUS=$status
SWD_REASON=$reason
STINFO_RC=$stinfo_rc
WINDOWS_USBIPD=$windows_usbipd
WINDOWS_STLINK=$windows_stlink
WINDOWS_STLINK_STATE=$windows_stlink_state
WINDOWS_TTL=$windows_ttl
WINDOWS_TTL_STATE=$windows_ttl_state
USB_STLINK=$usb_stlink
USB_TTL=$usb_ttl
TTY_USB=$(presence "$TTY_USB")
TTY_ACM=$(presence "$TTY_ACM")
TTY_USB_PATH=$TTY_USB
TTY_ACM_PATH=$TTY_ACM

## ST-LINK Probe

\`\`\`text
$stinfo_out
\`\`\`

## Windows usbipd Snapshot

\`\`\`text
$windows_usbipd_out
\`\`\`

## WSL USB Snapshot

\`\`\`text
$lsusb_out
\`\`\`

## Serial Users

\`\`\`text
$lsof_out
\`\`\`

## Kernel USB Tail

\`\`\`text
$dmesg_out
\`\`\`

## Recovery Checklist

1. First inspect Windows ownership: \`powershell.exe -NoProfile -Command "usbipd list"\`; confirm ST-LINK and USB-TTL are visible and note each BUSID/state.
2. If Windows shows a device as \`Shared\` but WSL does not show it in \`lsusb\`, attach it with \`powershell.exe -NoProfile -Command "usbipd attach --wsl --busid <BUSID>"\`; attach both ST-LINK and USB-TTL.
3. Then verify WSL visibility with \`lsusb\`, \`$TTY_ACM\`, \`$TTY_USB\`, and this diagnostic output.
4. Keep the independent USB-TTL on USART1 for communication; do not move ROS traffic back to ST-LINK VCP.
5. If the device is missing from Windows too, then check target power, cable, common ground, SWDIO, SWCLK, NRST, BOOT0=0, and whether another Windows tool owns ST-LINK.
6. Power-cycle the board and reattach usbip if the kernel log shows disconnect/reset/usbip/vhci errors.
7. If ST-LINK is visible but chipid is 0x000/dev-type unknown, try connect-under-reset flashing only after wiring/power/reset is fixed.

## Next Commands

When SWD_STATUS=ok:

\`\`\`bash
tools/recommend-staircase-command.sh
# Then run the recommended tools/run-com-staircase.sh command and the matching
# tools/check-com-staircase-contract.py command printed by the recommendation.
# To include UART utilization in acceptance:
STAIRCASE_CONTRACT_ARGS="--max-pc-catchup-events 0 --max-pc-catchup-extra 0 --max-wire-baud-util-pct 30" tools/recommend-staircase-command.sh
tools/measure-stack-hwm.sh firmware/f103-microros/build/f103-microros.elf
\`\`\`

When SWD_STATUS is not ok:

\`\`\`bash
BUILD_FIRMWARE=0 FLASH_FIRMWARE=0 tools/run-com-perf.sh noflash_\$(date +%H%M)
tools/com-status-report.sh handoff_\$(date +%Y%m%d_%H%M)
\`\`\`
EOF

if [ "$STRICT" = "1" ] && [ "$status" != "ok" ]; then
  exit 1
fi
