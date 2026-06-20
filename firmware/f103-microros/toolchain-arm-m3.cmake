# toolchain-arm-m3.cmake
# 交叉编译工具链:STM32F103RB (Cortex-M3, 无 FPU)。
# T4 骨架与 T5 的 micro-ROS libmicroros toolchain.cmake 的 M3 ABI flags 必须完全一致,
# 否则链接期 ABI 不匹配 / VFP 不匹配。改这里要同步改 T5 的 toolchain.cmake。

set(CMAKE_SYSTEM_NAME      Generic)        # 裸机,无 OS
set(CMAKE_SYSTEM_PROCESSOR arm)

# 交叉编译时 try_compile 默认生成可执行(需链接脚本)会失败;改成生成静态库即可探测编译器。
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

# 允许用 -DTOOLCHAIN_PREFIX=... 覆盖;默认走 PATH 里的 arm-none-eabi-*。
if(NOT DEFINED TOOLCHAIN_PREFIX)
  set(TOOLCHAIN_PREFIX arm-none-eabi-)
endif()

set(CMAKE_C_COMPILER   ${TOOLCHAIN_PREFIX}gcc)
set(CMAKE_CXX_COMPILER ${TOOLCHAIN_PREFIX}g++)
set(CMAKE_ASM_COMPILER ${TOOLCHAIN_PREFIX}gcc)
set(CMAKE_OBJCOPY      ${TOOLCHAIN_PREFIX}objcopy CACHE FILEPATH "objcopy")
set(CMAKE_SIZE         ${TOOLCHAIN_PREFIX}size    CACHE FILEPATH "size")

# === M3 ABI flags(硬约束:三件套一起,且禁浮点) ===
# -mcpu=cortex-m3 -mthumb : Cortex-M3 仅 Thumb-2,无 FPU。
# -mfloat-abi=soft        : 软浮点(库实现),不发 VFP 指令;不给 -mfpu。
set(CPU_FLAGS "-mcpu=cortex-m3 -mthumb -mfloat-abi=soft")

# -ffunction-sections/-fdata-sections + 链接期 --gc-sections : 死代码/数据回收,省 Flash/RAM。
set(COMMON_FLAGS "${CPU_FLAGS} -ffunction-sections -fdata-sections")

set(CMAKE_C_FLAGS_INIT   "${COMMON_FLAGS}")
set(CMAKE_CXX_FLAGS_INIT "${COMMON_FLAGS} -fno-exceptions -fno-rtti")
set(CMAKE_ASM_FLAGS_INIT "${CPU_FLAGS} -x assembler-with-cpp")

# 交叉环境:只在 sysroot 找头/库,不在 host 找程序。
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
