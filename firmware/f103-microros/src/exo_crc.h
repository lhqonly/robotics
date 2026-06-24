/* exo_crc.h — exo_msgs 应用级 CRC-32(契约 §7.9)固件侧实现接口 (M-B / 任务 4)
 *
 * 【这是什么】
 *   契约 §7.9 的「应用级 CRC」自检开关在固件侧的字节级实现。它**不是防链路误码**
 *   (那是帧层 CRC-16 + RELIABLE QoS 的事),而是抓**应用打包/序列化 bug**(字段写错
 *   偏移、两端字节序不一致、payload 错位覆盖)的自检位。默认关(crc_enabled=False),
 *   开发期联调单独打开,WSL 侧 crc_mismatch_count 恒 0 即证明两端逐字节对齐。
 *
 * 【为什么独立成一个不依赖 STM32 的纯 .c/.h】
 *   CRC 字节序是 M-B「板子日」最易出 bug 的点(§3 风险登记)。本模块**只用 <stdint.h>
 *   + <stddef.h>,不碰任何 STM32 寄存器 / CMSIS / FreeRTOS**,目的就是让它能在 host
 *   (x86 Linux)上单独编译,直接对拍 WSL 规范:
 *       Python:  zlib.crc32(struct.pack('<IQi', seq, stamp_mono_ns, payload))
 *   两边输出必须逐字节相等。对拍方法见 exo_crc.c 文件尾的注释 / 主 agent 构建说明。
 *
 * 【算法参数(与 WSL 侧 zlib.crc32 / ros2_ws/src/exo_cmd/exo_cmd/crc.py 逐字节一致)】
 *   CRC-32 (IEEE 802.3 / zlib):
 *     - 反射多项式 0xEDB88320(= 0x04C11DB7 位反射),输入/输出均反射(refin=refout=true)
 *     - 初值 init   = 0xFFFFFFFF
 *     - 异或输出 xorout = 0xFFFFFFFF
 *   查表实现(256 项 × 4B ≈ 1KB ROM,见 §D6 预算)。
 *
 * 【覆盖范围(契约 §7.9 写死,启用时)】
 *   对 crc 字段置 0 后的三元组规范小端字节流:
 *       seq           -> uint32 (4B LE)
 *       stamp_mono_ns -> uint64 (8B LE)
 *       payload       -> int32  (4B LE, 补码)
 *   即 struct.pack('<IQi', seq, stamp_mono_ns, payload)。
 *   ★ ExoStatus 回填时用**回填后的**三元组(seq 原样、stamp = MCU DWT 重盖、payload 原样)
 *     重算(H1 / 11 之 H1)——不是 cmd 的三元组。
 *   ★ 不依赖 C struct 的内存布局/padding:本模块显式按 <IQi> 顺序把三个标量拷进紧凑
 *     16 字节缓冲再算 CRC,与 rosidl 生成的 ExoHeader 结构体的对齐/padding 解耦。
 */
#ifndef EXO_CRC_H
#define EXO_CRC_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 通用 CRC-32(zlib/IEEE 802.3):对任意字节缓冲计算。
 * 与 Python `zlib.crc32(data) & 0xFFFFFFFF` 逐字节等价(单次调用、完整缓冲)。
 * 用于 host 对拍 / 内部被 exo_crc_envelope 调用。 */
uint32_t exo_crc32(const uint8_t *data, size_t len);

/* 契约 §7.9 信封 CRC:对 (seq, stamp_mono_ns, payload) 三元组按 <IQi> 规范小端字节流
 * 计算 CRC-32(crc 字段置 0、不入流)。等价于 WSL 侧 compute_crc(seq, stamp, payload)。
 *   seq           : 回填后的 header.seq          (uint32)
 *   stamp_mono_ns : MCU DWT 重盖的 stamp          (uint64)
 *   payload       : bit-exact 回填的 payload      (int32,以 int32_t 传入,内部按补码 LE 拼)
 * 返回 uint32 CRC,直接填进 header.crc。 */
uint32_t exo_crc_envelope(uint32_t seq, uint64_t stamp_mono_ns, int32_t payload);

#ifdef __cplusplus
}
#endif

#endif /* EXO_CRC_H */
