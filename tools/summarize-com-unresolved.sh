#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INPUT="${1:-}"

if [ -n "$INPUT" ] && [ -f "$INPUT" ]; then
  report="$INPUT"
else
  tag="${INPUT:-unresolved_$(date +%Y%m%d_%H%M)}"
  report_line="$("$ROOT/tools/com-status-report.sh" "$tag")"
  report="${report_line#*=}"
fi

if [ ! -f "$report" ]; then
  echo "ERROR: report not found: $report" >&2
  exit 1
fi

awk '
  $0 == "## 未解决项" {in_section = 1; print; next}
  in_section && /^## / {exit}
  in_section {print}
' "$report"
