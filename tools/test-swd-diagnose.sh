#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"

  if ! grep -Fq -- "$needle" <<<"$haystack"; then
    echo "FAIL: $label missing '$needle'" >&2
    echo "output:" >&2
    printf '%s\n' "$haystack" >&2
    exit 1
  fi
}

write_fake_lsusb() {
  local path="$1"
  cat >"$path" <<'EOF'
#!/usr/bin/env bash
cat <<'OUT'
Bus 001 Device 002: ID 0403:6001 Future Technology Devices International, Ltd FT232 Serial (UART) IC
Bus 001 Device 003: ID 0483:374b STMicroelectronics ST-LINK/V2.1
OUT
EOF
  chmod +x "$path"
}

write_fake_stinfo() {
  local path="$1"
  local mode="$2"
  case "$mode" in
    ok)
      cat >"$path" <<'EOF'
#!/usr/bin/env bash
cat <<'OUT'
Found 1 stlink programmers
  flash:      131072 (pagesize: 1024)
  sram:       20480
  chipid:     0x410
  dev-type:   STM32F1xx_MD
OUT
EOF
      ;;
    unknown)
      cat >"$path" <<'EOF'
#!/usr/bin/env bash
cat <<'OUT'
Failed to enter SWD mode
Found 1 stlink programmers
  flash:      0 (pagesize: 0)
  sram:       0
  chipid:     0x000
  dev-type:   unknown
OUT
EOF
      ;;
    fail)
      cat >"$path" <<'EOF'
#!/usr/bin/env bash
echo "LIBUSB_ERROR_TIMEOUT" >&2
exit 7
EOF
      ;;
    *)
      echo "bad fake st-info mode: $mode" >&2
      exit 1
      ;;
  esac
  chmod +x "$path"
}

run_diag() {
  local stinfo="$1"
  local lsusb="$2"
  ST_INFO_CMD="$stinfo" \
    LSUSB_CMD="$lsusb" \
    LSOF_CMD="$TMPDIR/missing-lsof" \
    DMESG_CMD="$TMPDIR/missing-dmesg" \
    TIMEOUT_CMD="$TMPDIR/missing-timeout" \
    TTY_USB="$TMPDIR/ttyUSB0" \
    TTY_ACM="$TMPDIR/ttyACM0" \
    "$ROOT/tools/diagnose-swd.sh"
}

touch "$TMPDIR/ttyUSB0" "$TMPDIR/ttyACM0"
write_fake_lsusb "$TMPDIR/lsusb"

write_fake_stinfo "$TMPDIR/st-info-ok" ok
out="$(run_diag "$TMPDIR/st-info-ok" "$TMPDIR/lsusb")"
assert_contains "$out" "SWD_STATUS=ok" "ok probe status"
assert_contains "$out" "SWD_REASON=probe-ok" "ok probe reason"
assert_contains "$out" "USB_STLINK=present" "ST-LINK USB present"
assert_contains "$out" "TTY_USB=present" "USB-TTL tty present"
assert_contains "$out" "tools/recommend-staircase-command.sh" \
  "next recommended staircase command"
assert_contains "$out" "tools/check-com-staircase-contract.py" \
  "next staircase contract command guidance"
assert_contains "$out" "--max-wire-baud-util-pct 30" \
  "next staircase wire utilization contract guidance"

write_fake_stinfo "$TMPDIR/st-info-unknown" unknown
out="$(run_diag "$TMPDIR/st-info-unknown" "$TMPDIR/lsusb")"
assert_contains "$out" "SWD_STATUS=bad_unknown_target" \
  "unknown target status"
assert_contains "$out" "SWD_REASON=probe-visible-but-target-invalid" \
  "unknown target reason"

write_fake_stinfo "$TMPDIR/st-info-fail" fail
out="$(run_diag "$TMPDIR/st-info-fail" "$TMPDIR/lsusb")"
assert_contains "$out" "SWD_STATUS=bad_probe_failed" "failed probe status"
assert_contains "$out" "SWD_REASON=st-info-rc-7" "failed probe reason"

set +e
STRICT=1 run_diag "$TMPDIR/st-info-unknown" "$TMPDIR/lsusb" >/dev/null
strict_rc=$?
set -e
if [ "$strict_rc" -eq 0 ]; then
  echo "FAIL: STRICT=1 should fail when SWD is not ok" >&2
  exit 1
fi

echo "PASS: SWD diagnose tests"
