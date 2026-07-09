#!/usr/bin/env bash
# Static contract checks for the staged local control-loop implementation.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN="$ROOT/firmware/f103-microros/src/main.c"
IT="$ROOT/firmware/f103-microros/src/stm32f1xx_it.c"
APP="$ROOT/firmware/f103-microros/src/microros_app.c"
FREERTOS_CFG="$ROOT/firmware/f103-microros/FreeRTOSConfig.h"
CMAKE="$ROOT/firmware/f103-microros/CMakeLists.txt"

assert_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if ! grep -Fq -- "$needle" "$file"; then
    echo "FAIL: $label missing '$needle' in $file" >&2
    exit 1
  fi
}

assert_regex() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if ! grep -Eq -- "$pattern" "$file"; then
    echo "FAIL: $label missing pattern '$pattern' in $file" >&2
    exit 1
  fi
}

assert_function_contains() {
  local file="$1"
  local function_name="$2"
  local needle="$3"
  local label="$4"
  if ! awk -v fn="$function_name" -v needle="$needle" '
      index($0, fn "(") { in_fn = 1 }
      in_fn && index($0, needle) { found = 1 }
      in_fn && $0 ~ /^}/ { in_fn = 0 }
      END { exit found ? 0 : 1 }
    ' "$file"; then
    echo "FAIL: $label missing '$needle' inside $function_name in $file" >&2
    exit 1
  fi
}

assert_contains "$FREERTOS_CFG" \
  "#define configTICK_RATE_HZ                      ( ( TickType_t ) 1000 )" \
  "FreeRTOS remains a 1kHz scheduler tick"

assert_contains "$CMAKE" \
  'set(EXO_CONTROL_LOOP_HZ "1000" CACHE STRING "Local MCU control-loop baseline frequency")' \
  "default local control frequency"
assert_contains "$CMAKE" \
  'set(EXO_CONTROL_TIMER_IRQ_PRIORITY "4" CACHE STRING "TIM2 control-loop IRQ priority for >1kHz local loop")' \
  "default high-rate TIM2 IRQ priority"
assert_contains "$CMAKE" \
  "add_compile_definitions(EXO_CONTROL_LOOP_HZ=\${EXO_CONTROL_LOOP_HZ})" \
  "control frequency compile definition"
assert_contains "$CMAKE" \
  "add_compile_definitions(EXO_CONTROL_TIMER_IRQ_PRIORITY=\${EXO_CONTROL_TIMER_IRQ_PRIORITY})" \
  "control timer priority compile definition"
assert_contains "$CMAKE" \
  'set(EXO_MOTOR_STATE_PERIOD_MS "20" CACHE STRING "M2 motor JointState publish period in milliseconds")' \
  "default motor state publish period"
assert_contains "$CMAKE" \
  'set(EXO_MOTOR_HEALTH_PERIOD_MS "200" CACHE STRING "M2 motor MotorHealth publish period in milliseconds")' \
  "default motor health publish period"
assert_contains "$CMAKE" \
  'set(EXO_MOTOR_FRAME_ID_RX_CAPACITY "16" CACHE STRING "M2 JointTarget frame_id RX storage bytes")' \
  "default motor frame_id RX capacity"
assert_contains "$CMAKE" \
  "add_compile_definitions(EXO_MOTOR_STATE_PERIOD_MS=\${EXO_MOTOR_STATE_PERIOD_MS})" \
  "motor state period compile definition"
assert_contains "$CMAKE" \
  "add_compile_definitions(EXO_MOTOR_HEALTH_PERIOD_MS=\${EXO_MOTOR_HEALTH_PERIOD_MS})" \
  "motor health period compile definition"
assert_contains "$CMAKE" \
  "add_compile_definitions(EXO_MOTOR_FRAME_ID_RX_CAPACITY=\${EXO_MOTOR_FRAME_ID_RX_CAPACITY})" \
  "motor frame_id RX capacity compile definition"
assert_contains "$APP" \
  "#if EXO_MOTOR_STATE_PERIOD_MS < 10u || EXO_MOTOR_STATE_PERIOD_MS > 1000u" \
  "motor state period range guard"
assert_contains "$APP" \
  "#if EXO_MOTOR_HEALTH_PERIOD_MS < 100u || EXO_MOTOR_HEALTH_PERIOD_MS > 5000u" \
  "motor health period range guard"
assert_contains "$APP" \
  "#if EXO_MOTOR_HEALTH_PERIOD_MS < EXO_MOTOR_STATE_PERIOD_MS" \
  "motor health period slower-than-state guard"
assert_contains "$APP" \
  "#    define EXO_MOTOR_FRAME_ID_RX_CAPACITY 16u" \
  "motor frame_id RX fallback capacity"
assert_contains "$APP" \
  "#  if EXO_MOTOR_FRAME_ID_RX_CAPACITY < 8u" \
  "motor frame_id RX capacity lower bound"

assert_contains "$MAIN" "#if EXO_CONTROL_LOOP_HZ <= 1000u" \
  "1kHz-and-below FreeRTOS task branch"
assert_contains "$MAIN" 'xTaskCreateStatic(com_control_task, "ctrl"' \
  "control task is used for <=1kHz"
assert_contains "$MAIN" "ControlTimer_Init();" \
  "TIM2 timer is used for >1kHz"
assert_contains "$MAIN" \
  "#if EXO_CONTROL_LOOP_HZ <= 1000u && ((1000u % EXO_CONTROL_LOOP_HZ) != 0u)" \
  "FreeRTOS 1kHz divisibility guard"
assert_contains "$MAIN" \
  "#if EXO_CONTROL_LOOP_HZ > 1000u && ((1000000u % EXO_CONTROL_LOOP_HZ) != 0u)" \
  "TIM2 1MHz divisibility guard"
assert_contains "$MAIN" "TIM2->PSC = 71u;" \
  "TIM2 prescaler creates a 1MHz timer tick"
assert_contains "$MAIN" \
  "TIM2->ARR = (uint16_t)((1000000u / EXO_CONTROL_LOOP_HZ) - 1u);" \
  "TIM2 auto-reload derives from EXO_CONTROL_LOOP_HZ"
assert_contains "$MAIN" \
  "NVIC_SetPriority(TIM2_IRQn, EXO_CONTROL_TIMER_IRQ_PRIORITY);" \
  "TIM2 priority is compile-time tunable"

assert_contains "$IT" "void TIM2_IRQHandler(void)" \
  "TIM2 interrupt handler exists"
assert_function_contains "$IT" "TIM2_IRQHandler" "com_control_tick_isr();" \
  "TIM2 IRQ calls the local control tick"

assert_contains "$APP" "static volatile control_target_t g_control_targets[2];" \
  "latest-target double buffer exists"
assert_contains "$APP" "g_control_target_active = next;" \
  "latest-target active index is switched after payload/seq writes"
assert_contains "$APP" "com_control_update_target(m->header.seq, m->payload);" \
  "ROS command callback updates latest target"

for hz in 1000 2000 5000 10000; do
  if [ "$hz" -le 1000 ] && [ $((1000 % hz)) -ne 0 ]; then
    echo "FAIL: staircase frequency $hz does not divide the 1kHz FreeRTOS tick" >&2
    exit 1
  fi
  if [ "$hz" -gt 1000 ] && [ $((1000000 % hz)) -ne 0 ]; then
    echo "FAIL: staircase frequency $hz does not divide the 1MHz TIM2 tick" >&2
    exit 1
  fi
done

echo "PASS: control-loop staircase config checks"
