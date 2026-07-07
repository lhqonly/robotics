#!/usr/bin/env bash
# =============================================================================
# T8 go/no-go evidence collector: "does micro-ROS fit in F103RB's 20KB SRAM?"
# (designed by Gill; run by 主 agent after T8 firmware is built+flashed)
#
# Splits into STATIC evidence (from the ELF, available right after build) and
# RUNTIME evidence (printed by firmware over the link / SWD). The script only
# AUTOMATES the static side; runtime numbers must be reported by the firmware
# and pasted/parsed here -- a bare "no hardfault" is NOT sufficient evidence.
#
# Usage: t8_gonogo_evidence.sh <path-to-firmware.elf>
# =============================================================================
set -uo pipefail
ELF="${1:?usage: t8_gonogo_evidence.sh <firmware.elf>}"
SIZE=arm-none-eabi-size
NM=arm-none-eabi-nm
SRAM_TOTAL=$((20*1024))   # F103RB = 20 KiB SRAM
FLASH_TOTAL=$((128*1024)) # F103RB = 128 KiB Flash

[ -f "$ELF" ] || { echo "ELF not found: $ELF"; exit 2; }

echo "=================================================================="
echo " T8 STATIC EVIDENCE  (ELF: $ELF)"
echo "=================================================================="
echo "--- arm-none-eabi-size -A (per-section) ---"
"$SIZE" -A "$ELF"
echo
echo "--- arm-none-eabi-size (Berkeley: text/data/bss) ---"
"$SIZE" "$ELF"

# Compute static RAM = data + bss. This is RAM consumed BEFORE any heap/stack
# growth. The .map's heap+stack reservation is on top.
read -r TEXT DATA BSS _ < <("$SIZE" "$ELF" | awk 'NR==2{print $1, $2, $3, $4}')
STATIC_RAM=$((DATA + BSS))
FLASH_USED=$((TEXT + DATA))   # data has an init-image copy in Flash
echo
echo "--- DERIVED ---"
printf "  Static RAM (data+bss)  = %6d B  (%.1f%% of 20KB)\n" "$STATIC_RAM" "$(awk "BEGIN{print $STATIC_RAM*100/$SRAM_TOTAL}")"
printf "  RAM headroom above static image = %6d B\n" "$((SRAM_TOTAL - STATIC_RAM))"
printf "  Flash used (text+data) = %6d B  (%.1f%% of 128KB)\n" "$FLASH_USED" "$(awk "BEGIN{print $FLASH_USED*100/$FLASH_TOTAL}")"
echo
echo "  GUARDRAIL: if static RAM is near the 20KB ceiling, runtime stack/newlib"
echo "             growth has nowhere to go. A green build is NOT go by itself."

echo
echo "--- largest .bss / .data symbols (where the RAM went) ---"
"$NM" --print-size --size-sort --radix=d "$ELF" 2>/dev/null \
  | awk '$3 ~ /[bBdD]/ {printf "%8d  %s  %s\n",$2,$3,$4}' | sort -rn | head -20

if "$NM" "$ELF" 2>/dev/null | grep -qE ' (ucHeap|xPortGetMinimumEverFreeHeapSize|pvPortMalloc|vPortFree)$'; then
  HAS_FREERTOS_HEAP=1
else
  HAS_FREERTOS_HEAP=0
fi

echo
echo "--- FreeRTOS heap evidence ---"
if [ "$HAS_FREERTOS_HEAP" -eq 1 ]; then
  echo "  FreeRTOS dynamic heap symbols present: runtime heap low-water is required."
else
  echo "  FreeRTOS dynamic heap symbols absent: configSUPPORT_DYNAMIC_ALLOCATION=0 path."
  echo "  Runtime heap evidence should focus on bounded newlib _sbrk + task stacks."
fi

echo
echo "=================================================================="
echo " T8 RUNTIME EVIDENCE  (firmware must EMIT these; do not assume)"
echo "=================================================================="
if [ "$HAS_FREERTOS_HEAP" -eq 1 ]; then
cat <<'EOF'
Required runtime numbers (firmware prints over VCP/UART or read via SWD/gdb).
A go decision needs ALL of these, not just "it ran":

  1. xPortGetMinimumEverFreeHeapSize()   -> FreeRTOS heap low-water (bytes)
       PASS guideline: stays > ~512 B with margin; if it touches 0 => no-go.
  2. uxTaskGetStackHighWaterMark(task)    -> per-task min free stack (words)
       For EVERY task (microros task, app task, idle, timer).
       PASS guideline: > ~64 words (256 B) free for each; near 0 => stack
       overflow imminent => no-go.
  3. configCHECK_FOR_STACK_OVERFLOW = 2 enabled, and the hook NEVER fired
       over the full soak. (Must be compiled in for this to be evidence.)
  4. No HardFault / no MemManage / no BusFault over N minutes.
       Evidence = a fault handler that latches a flag + the flag is clear,
       AND the link stayed up (cross-check hw_acceptance.sh BIDI ran clean
       for the same N minutes). A silent reset also counts as FAIL -- check
       agent log for repeated "create_client" (board re-sessioning = resets).

Suggested soak: run hw_acceptance.sh endurance 600 (10 min) WHILE the board
periodically reports heap/stack water marks (e.g. once/sec on a debug topic
or UART). Capture the WORST (minimum) values seen across the whole soak,
not a one-shot reading at boot.

Decision matrix:
  GO     : link bidi-green for full soak AND heap low-water > ~512B margin
           AND every task stack high-water > ~256B AND zero faults/resets.
  NO-GO  : any task stack high-water near 0, heap low-water near 0, any
           fault/overflow hook, or repeated re-sessioning in agent log.
           -> per 04-doc A.2, escalate to user (degrade / change protocol /
              change chip). Tom does NOT self-decide.
EOF
else
cat <<'EOF'
Required runtime numbers (firmware prints over VCP/UART or read via SWD/gdb).
A go decision needs ALL of these, not just "it ran":

  1. FreeRTOS dynamic heap is compiled out.
       PASS evidence: ucHeap / pvPortMalloc / vPortFree / heap_*.c symbols are
       absent from the ELF, and configSUPPORT_DYNAMIC_ALLOCATION=0.
  2. newlib heap is still bounded by _sbrk().
       PASS evidence: no malloc failure / HardFault over the full soak; any
       _sbrk exhaustion must fail visibly rather than corrupting stacks.
  3. uxTaskGetStackHighWaterMark(task) -> per-task min free stack (words).
       For EVERY task (microros task, LED task, idle).
       PASS guideline: > ~64 words (256 B) free for each; near 0 => stack
       overflow imminent => no-go.
  4. configCHECK_FOR_STACK_OVERFLOW = 2 enabled, and the hook NEVER fired
       over the full soak. (Must be compiled in for this to be evidence.)
  5. No HardFault / no MemManage / no BusFault over N minutes.
       Evidence = a fault handler that latches a flag + the flag is clear,
       AND the link stayed up (cross-check hw_acceptance.sh BIDI ran clean
       for the same N minutes). A silent reset also counts as FAIL -- check
       agent log for repeated "create_client" (board re-sessioning = resets).

Suggested soak: run hw_acceptance.sh endurance 600 (10 min) and read the stack
water marks via SWD/gdb after the run. Capture the WORST (minimum) values seen
across the whole soak, not a one-shot reading at boot.

Decision matrix:
  GO     : link bidi-green for full soak AND every task stack high-water
           > ~256B AND zero faults/resets AND no malloc/_sbrk exhaustion.
  NO-GO  : any task stack high-water near 0, any fault/overflow hook, malloc
           exhaustion, or repeated re-sessioning in agent log.
           -> per 04-doc A.2, escalate to user (degrade / change protocol /
              change chip). Tom does NOT self-decide.
EOF
fi
echo
echo "=== T8 static-evidence collection done. Paste runtime numbers below. ==="
