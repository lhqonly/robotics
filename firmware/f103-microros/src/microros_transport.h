/* microros_transport.h — micro-ROS 自定义串口 transport(4 回调)对外接口 (T5)
 *
 * 作用:把 micro-ROS(Micro XRCE-DDS client)的字节流收发,接到 main.c 里已经
 *   调通的 USART1@921600 + DMA1 Ch4(TX)/Ch5(RX) 物理层上。
 *
 * 设计原则(延续 main.c 风格):
 *   - 不重写底层收发/DMA/时钟。transport 只是「适配层」,write 调 main.c 暴露的
 *     发送原语,read 从 main.c 的 app_ring(RX 已搬入的字节)取。
 *   - 全静态,无动态分配。本文件不声明任何 buffer(字节缓冲都在 main.c 的 .bss)。
 *
 * 依赖 libmicroros 的类型 uxrCustomTransport —— 该类型来自 micro-ROS 头
 *   <uxr/client/profile/transport/custom/custom_transport.h>。主 agent 拿到
 *   libmicroros.a + include/ 后,本文件的 transport.c 才能编译(见 .c 顶部占位说明)。
 *   为了让本头不强依赖那套 include 也能被 main.c 引用(注册函数签名稳定),这里
 *   只暴露一个「注册入口」,把 uxrCustomTransport 细节封在 .c 内。
 */
#ifndef MICROROS_TRANSPORT_H
#define MICROROS_TRANSPORT_H

#include <stdbool.h>

/* 注册自定义 transport 到 micro-ROS RMW。
 *   内部调用 rmw_uros_set_custom_transport(framing=true, ...),绑定本文件的
 *   open/close/write/read 4 个回调。
 * 返回:true = 注册成功(rmw 返回 RMW_RET_OK)。
 *
 * 注:framing=true —— 串口是字节流、无消息边界,必须让 XRCE 用 stream framing
 *   协议自己切帧(契约 §3「XRCE-DDS over serial」+ colcon.meta
 *   UCLIENT_PROFILE_STREAM_FRAMING=ON 对应)。 */
bool microros_transport_register(void);

#endif /* MICROROS_TRANSPORT_H */
