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

# ---- micro-ROS 静态库(T5)----
# [MICROROS-INCLUDE] / [MICROROS-LIB]:libmicroros.a + 其 include/ 由主 agent 用
#   micro_ros_setup 的 generate_lib 生成(产物在 firmware/build/{libmicroros.a,include/}),
#   再拷进本工程 ThirdParty/microros/ 下:
#       ThirdParty/microros/libmicroros.a
#       ThirdParty/microros/include/        (rclc/ rcl/ rmw_microros/ std_msgs/ uxr/ 等头)
# 在该目录就位前,src/microros_transport.c 与 src/microros_app.c 用 __has_include 守卫
#   编译成「占位实现」,故本工程在 lib 未就位时仍能 configure+build 出固件(只是 micro-ROS
#   功能未链接)。lib 就位后,下面 if(EXISTS ...) 自动接上真实 include + 链接,守卫命中真实头。
set(MICROROS_DIR     ${CMAKE_SOURCE_DIR}/ThirdParty/microros)
set(MICROROS_INC     ${MICROROS_DIR}/include)
set(MICROROS_LIB     ${MICROROS_DIR}/libmicroros.a)

# ---- 头文件 ----
include_directories(
    ${CMAKE_SOURCE_DIR}                          # FreeRTOSConfig.h 在工程根
    ${CMAKE_SOURCE_DIR}/src
    ${CMSIS}/Core/Include
    ${CMSIS_DEV}/Include
    ${FREERTOS}/include
    ${FREERTOS}/portable/GCC/ARM_CM3
)

# micro-ROS include 路径(存在才加;不存在时 __has_include 守卫走占位分支)。
if(EXISTS ${MICROROS_INC})
    include_directories(${MICROROS_INC})
    message(STATUS "[MICROROS] include found: ${MICROROS_INC}")
else()
    message(WARNING "[MICROROS] include NOT found at ${MICROROS_INC} -- building placeholder (micro-ROS disabled). 主 agent: 放好 libmicroros include 后重新 configure.")
endif()

# ---- 源文件 ----
set(SOURCES
    ${CMAKE_SOURCE_DIR}/src/main.c
    ${CMAKE_SOURCE_DIR}/src/stm32f1xx_it.c
    ${CMAKE_SOURCE_DIR}/src/microros_transport.c   # T5:自定义串口 transport 4 回调
    ${CMAKE_SOURCE_DIR}/src/microros_app.c         # T5/M-B:rclc 双向应用(exo_mcu,exo_msgs 载体)
    ${CMAKE_SOURCE_DIR}/src/dwt_time.c             # M-B 任务3:DWT CYCCNT 单调时钟(stamp_mono_ns)
    ${CMAKE_SOURCE_DIR}/src/exo_crc.c              # M-B 任务4:应用级 CRC-32(§7.9,host 可对拍)
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

# ---- [MICROROS-LIB] 链接 libmicroros.a(存在才链;否则占位构建) ----
# 注:libmicroros.a 与 newlib/specs 可能有交叉引用,用 --start-group/--end-group 容错。
#     micro-ROS 的 rcl/rmw/xrce 内部互相引用,顺序敏感,分组链接最稳。
if(EXISTS ${MICROROS_LIB})
    target_link_libraries(${PROJECT_NAME}.elf
        -Wl,--start-group
        ${MICROROS_LIB}
        -Wl,--end-group
    )
    message(STATUS "[MICROROS] linking ${MICROROS_LIB}")
else()
    message(WARNING "[MICROROS] libmicroros.a NOT found at ${MICROROS_LIB} -- placeholder build (no micro-ROS linked).")
endif()

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
