#!/usr/bin/env bash
# Host-side model test for the firmware latest-target double buffer.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

cc -std=c11 -Wall -Wextra -Werror \
  "$ROOT/tools/control-target-model-test.c" \
  -o "$TMPDIR/control-target-model-test"

"$TMPDIR/control-target-model-test"
