# toolchain-arm-m3-libmicroros.cmake
# T5:专门给 micro_ros_setup `build_firmware.sh`(generate_lib)生成 libmicroros.a 用的 toolchain。
#
# = 固件 toolchain(toolchain-arm-m3.cmake,M3 ABI flags 唯一真源)+ 裸机移植补丁。
#   固件可执行与 libmicroros 的 M3 ABI flags 必须完全一致(否则链接期 ABI/VFP 不匹配),
#   故这里 include 固件 toolchain 复用其 flags,只追加 micro-ROS 裸机编译所需的宏,不碰 ABI。
include(${CMAKE_CURRENT_LIST_DIR}/toolchain-arm-m3.cmake)

# --- 裸机移植补丁:POSIX 时钟宏 ---
# rcutils 的 src/time_unix.c 在非 WIN32 平台无条件走 POSIX 路径,引用 CLOCK_MONOTONIC/
# CLOCK_REALTIME。arm-none-eabi 的 newlib 默认不开 _POSIX_TIMERS,这些宏未定义 → 编译报
# "CLOCK_MONOTONIC undeclared"。这里仅补宏定义让其能编过;真正的取时实现(clock_gettime)
# 由固件侧基于 FreeRTOS tick 提供(见 microros_app/transport 集成,T8 链接期补)。
string(APPEND CMAKE_C_FLAGS_INIT   " -DCLOCK_MONOTONIC=1 -DCLOCK_REALTIME=0")
string(APPEND CMAKE_CXX_FLAGS_INIT " -DCLOCK_MONOTONIC=1 -DCLOCK_REALTIME=0")
