# CMakeLists.txt — STM32F103RB 裸机骨架 (T4 / M0-B)
#
# 用法:
#   cmake -S . -B build \
#         -DCMAKE_TOOLCHAIN_FILE=$(pwd)/toolchain-arm-m3.cmake \
#         -DCMAKE_BUILD_TYPE=MinSizeRel
#   cmake --build build
# 产物:build/f103-microros.elf / .bin / .hex / output.map
#
# 第三方(vendor,见 README/返回里的清单)预期布局:
#   ThirdParty/CMSIS/Core/Include/                 (ARM CMSIS5 Core)
#   ThirdParty/CMSIS/Device/ST/STM32F1xx/Include/  (stm32f1xx.h / stm32f103xb.h / system_*.h)
#   ThirdParty/CMSIS/Device/ST/STM32F1xx/Source/Templates/
#         system_stm32f1xx.c
#         gcc/startup_stm32f103xb.s
#   ThirdParty/FreeRTOS-Kernel/                    (内核 + include/ + portable/GCC/ARM_CM3 + portable/MemMang/heap_4.c)

cmake_minimum_required(VERSION 3.16)

project(f103-microros C ASM)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# ---- 路径 ----
set(TP        ${CMAKE_SOURCE_DIR}/ThirdParty)
set(CMSIS     ${TP}/CMSIS)
set(CMSIS_DEV ${CMSIS}/Device/ST/STM32F1xx)
set(FREERTOS  ${TP}/FreeRTOS-Kernel)
set(LDSCRIPT  ${CMAKE_SOURCE_DIR}/STM32F103RB_FLASH.ld)

# ---- 编译宏 ----
# STM32F103xB : 选择 CMSIS device 头里的具体型号寄存器定义。
# USE_HAL_DRIVER 不定义(我们不用 HAL)。
add_compile_definitions(STM32F103xB)

# ---- 头文件 ----
include_directories(
    ${CMAKE_SOURCE_DIR}                          # FreeRTOSConfig.h 在工程根
    ${CMAKE_SOURCE_DIR}/src
    ${CMSIS}/Core/Include
    ${CMSIS_DEV}/Include
    ${FREERTOS}/include
    ${FREERTOS}/portable/GCC/ARM_CM3
)

# ---- 源文件 ----
set(SOURCES
    ${CMAKE_SOURCE_DIR}/src/main.c
    ${CMAKE_SOURCE_DIR}/src/stm32f1xx_it.c
    ${CMSIS_DEV}/Source/Templates/system_stm32f1xx.c
    ${CMSIS_DEV}/Source/Templates/gcc/startup_stm32f103xb.s
    # FreeRTOS core
    ${FREERTOS}/tasks.c
    ${FREERTOS}/list.c
    ${FREERTOS}/queue.c
    ${FREERTOS}/timers.c
    ${FREERTOS}/croutine.c
    ${FREERTOS}/portable/GCC/ARM_CM3/port.c
    ${FREERTOS}/portable/MemMang/heap_4.c
)

add_executable(${PROJECT_NAME}.elf ${SOURCES})

# ---- 编译选项(优化 + 警告;ABI flags 来自 toolchain) ----
target_compile_options(${PROJECT_NAME}.elf PRIVATE
    -Wall -Wextra
    $<$<CONFIG:Debug>:-Og -g3>
    $<$<NOT:$<CONFIG:Debug>>:-Os>
)

# ---- 链接选项 ----
target_link_options(${PROJECT_NAME}.elf PRIVATE
    -T${LDSCRIPT}
    -Wl,--gc-sections
    -Wl,-Map=${CMAKE_BINARY_DIR}/output.map
    -Wl,--print-memory-usage
    --specs=nano.specs            # newlib-nano,省 Flash/RAM
    --specs=nosys.specs           # 无 OS syscalls 桩(_sbrk 等弱实现)
    -Wl,--no-warn-rwx-segments
)

# ---- 产物:.bin / .hex + size ----
add_custom_command(TARGET ${PROJECT_NAME}.elf POST_BUILD
    COMMAND ${CMAKE_OBJCOPY} -O binary $<TARGET_FILE:${PROJECT_NAME}.elf> ${CMAKE_BINARY_DIR}/${PROJECT_NAME}.bin
    COMMAND ${CMAKE_OBJCOPY} -O ihex   $<TARGET_FILE:${PROJECT_NAME}.elf> ${CMAKE_BINARY_DIR}/${PROJECT_NAME}.hex
    COMMAND ${CMAKE_SIZE} $<TARGET_FILE:${PROJECT_NAME}.elf>
    COMMENT "Generating .bin/.hex and printing size"
)
