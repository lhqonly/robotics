#!/usr/bin/env bash
# Build and run the host-side DWT snapshot model test.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-/tmp/dwt-snapshot-model-test}"

gcc -std=c11 -Wall -Wextra -Werror -O2 \
  "$ROOT/tools/dwt-snapshot-model-test.c" -o "$OUT"
"$OUT"
