#!/usr/bin/env bash
# Validate static Flash/RAM budget rows from tools/firmware-size-matrix.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSV="${1:-}"
REQUIRED_PROFILES="${REQUIRED_PROFILES:-default_reliable_1khz besteffort_10000hz_status40}"
MAX_FLASH_BYTES="${MAX_FLASH_BYTES:-131072}"
MAX_RAM_STATIC_BYTES="${MAX_RAM_STATIC_BYTES:-18432}"

latest_csv() {
  find "$ROOT/log/firmware-size-matrix" -maxdepth 1 -type f -name '*.csv' \
    -printf '%T@ %p\n' 2>/dev/null |
    sort -nr |
    awk 'NR == 1 {sub(/^[^ ]+ /, ""); print; exit}'
}

if [ -z "$CSV" ]; then
  CSV="$(latest_csv)"
fi

if [ -z "$CSV" ] || [ ! -f "$CSV" ]; then
  echo "FAIL firmware_size_matrix_contract missing_csv=${CSV:-none}" >&2
  exit 1
fi

awk \
  -v required_profiles="$REQUIRED_PROFILES" \
  -v max_flash="$MAX_FLASH_BYTES" \
  -v max_ram="$MAX_RAM_STATIC_BYTES" \
  -v csv="$CSV" '
  BEGIN {
    FS = ","
    split(required_profiles, required, /[[:space:]]+/)
    for (i in required) {
      if (required[i] != "") {
        need[required[i]] = 1
      }
    }
    failures = 0
  }

  NR == 1 {
    for (i = 1; i <= NF; i++) {
      col[$i] = i
    }
    required_cols = "profile verdict flash_bytes ram_static_bytes ram_rosidl_type_metadata_bytes ram_rosidl_raw_source_metadata_bytes ram_microros_custom_pools_bytes"
    split(required_cols, cols, / /)
    for (i in cols) {
      if (!(cols[i] in col)) {
        printf "FAIL firmware_size_matrix_contract csv=%s missing_column=%s\n",
          csv, cols[i] > "/dev/stderr"
        failures++
      }
    }
    next
  }

  failures > 0 {
    next
  }

  {
    profile = $col["profile"]
    if (!(profile in need)) {
      next
    }
    seen[profile] = 1
    verdict = $col["verdict"]
    flash = $col["flash_bytes"] + 0
    ram = $col["ram_static_bytes"] + 0
    rosidl = $col["ram_rosidl_type_metadata_bytes"] + 0
    raw_source = $col["ram_rosidl_raw_source_metadata_bytes"] + 0
    pools = $col["ram_microros_custom_pools_bytes"] + 0
    if (verdict != "PASS") {
      printf "FAIL firmware_size_matrix_contract profile=%s verdict=%s\n",
        profile, verdict > "/dev/stderr"
      failures++
    }
    if (flash > max_flash) {
      printf "FAIL firmware_size_matrix_contract profile=%s flash_bytes=%d max_flash_bytes=%d\n",
        profile, flash, max_flash > "/dev/stderr"
      failures++
    }
    if (ram > max_ram) {
      printf "FAIL firmware_size_matrix_contract profile=%s ram_static_bytes=%d max_ram_static_bytes=%d\n",
        profile, ram, max_ram > "/dev/stderr"
      failures++
    }
    if (rosidl <= 0) {
      printf "FAIL firmware_size_matrix_contract profile=%s ram_rosidl_type_metadata_bytes=%d\n",
        profile, rosidl > "/dev/stderr"
      failures++
    }
    if (raw_source <= 0) {
      printf "FAIL firmware_size_matrix_contract profile=%s ram_rosidl_raw_source_metadata_bytes=%d\n",
        profile, raw_source > "/dev/stderr"
      failures++
    }
    if (pools <= 0) {
      printf "FAIL firmware_size_matrix_contract profile=%s ram_microros_custom_pools_bytes=%d\n",
        profile, pools > "/dev/stderr"
      failures++
    }
  }

  END {
    for (profile in need) {
      if (!(profile in seen)) {
        printf "FAIL firmware_size_matrix_contract csv=%s missing_profile=%s\n",
          csv, profile > "/dev/stderr"
        failures++
      }
    }
    if (failures > 0) {
      exit 1
    }
    printf "PASS firmware_size_matrix_contract csv=%s required_profiles=\"%s\" max_flash_bytes=%d max_ram_static_bytes=%d\n",
      csv, required_profiles, max_flash, max_ram
  }
' "$CSV"
