#!/usr/bin/env bash
# Offline regression checks for firmware size/RAM category reports.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ELF="${ELF:-$ROOT/firmware/f103-microros/build/f103-microros.elf}"

if [ ! -f "$ELF" ]; then
  echo "SKIP: firmware ELF not found: $ELF" >&2
  exit 0
fi

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"

  if ! grep -Fq -- "$needle" <<<"$haystack"; then
    echo "FAIL: $label" >&2
    echo "missing: $needle" >&2
    echo "output:" >&2
    printf '%s\n' "$haystack" >&2
    exit 1
  fi
}

report="$(CATEGORY_LIMIT=5 "$ROOT/tools/firmware-size-report.sh" "$ELF")"

assert_contains "$report" "ram_category_summary:" \
  "size report emits RAM category summary"
assert_contains "$report" "rosidl_type_metadata" \
  "size report classifies rosidl type metadata"
assert_contains "$report" "microros_custom_pools" \
  "size report classifies micro-ROS custom pools"
assert_contains "$report" "largest_ram_symbols_by_category:" \
  "size report emits per-category symbol details"
assert_contains "$report" "rosidl_type_metadata_breakdown:" \
  "size report emits rosidl metadata breakdown"
assert_contains "$report" "ExoStatus" \
  "size report includes ExoStatus metadata breakdown row"
assert_contains "$report" "toplevel_type_raw_source" \
  "size report includes raw source metadata breakdown row"
assert_contains "$report" "[rosidl_type_metadata]" \
  "size report emits rosidl category detail header"
assert_contains "$report" "toplevel_type_raw_source" \
  "size report includes type raw source symbol"
assert_contains "$report" "custom_sessions" \
  "size report includes custom session pool symbol"

matrix_tag="test_size_report_categories"
OUTDIR="$(mktemp -d)"
BUILD_ROOT="$ROOT/firmware/f103-microros/build-size-test"
trap 'rm -rf "$OUTDIR"' EXIT

OUTDIR="$OUTDIR" BUILD_ROOT="$BUILD_ROOT" \
  "$ROOT/tools/firmware-size-matrix.sh" "$matrix_tag" >/dev/null
csv="$OUTDIR/$matrix_tag.csv"

assert_contains "$(head -1 "$csv")" "ram_rosidl_type_metadata_bytes" \
  "size matrix CSV header includes rosidl category column"
assert_contains "$(head -1 "$csv")" "ram_rosidl_raw_source_metadata_bytes" \
  "size matrix CSV header includes rosidl raw source column"
assert_contains "$(head -1 "$csv")" "ram_microros_custom_pools_bytes" \
  "size matrix CSV header includes micro-ROS pool category column"
if ! awk -F, 'NR > 1 && $22 + 0 > 0 && $23 + 0 > 0 && $24 + 0 > 0 {found = 1} END {exit !found}' "$csv"; then
  echo "FAIL: size matrix did not report non-zero rosidl/raw-source/pool category bytes" >&2
  cat "$csv" >&2
  exit 1
fi

echo "PASS: firmware size report tests"
