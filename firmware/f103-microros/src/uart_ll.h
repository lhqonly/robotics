/* uart_ll.h — main.c 暴露给 transport 层的 USART1+DMA 底层收发原语 (T5)
 *
 * 这些函数/原语在 main.c 里实现(T4 已调通,RX DMA bug 已修,见 git 573a226)。
 * transport.c(micro-ROS 自定义 transport 的 write/read 回调)通过本头调用它们,
 * 不直接碰寄存器,也不重复实现收发逻辑。
 *
 * 线程/中断模型(沿用 T4):
 *   - app_ring 是单生产者(RX ISR)单消费者(本任务上下文)的 SPSC 环形缓冲;
 *     transport read 在 micro-ROS 任务上下文调用 uart_ll_read(),是唯一消费者,安全。
 *   - uart_ll_write_blocking() 在同一任务上下文调用,内部等上一次 TX DMA 完成,
 *     不与中断争用 tx_dma_buf。micro-ROS 单线程 executor,无并发 write。
 */
#ifndef UART_LL_H
#define UART_LL_H

#include <stdint.h>
#include <stddef.h>

/* 阻塞发送 len 字节(经 DMA1 Ch4)。len > MTU(128) 会分多次发完,全部发出才返回。
 * 返回实际发出的字节数(正常 == len)。供 transport write 回调使用。 */
size_t uart_ll_write_blocking(const uint8_t *data, size_t len);

/* 从 app_ring 取最多 max 字节到 out,带毫秒级软件超时。
 *   - 立即把当前可用字节取走;不足 max 时,在 timeout_ms 内轮询等待更多字节。
 *   - 返回实际取到的字节数(可能 0;超时返 0 不算错,符合 XRCE custom transport read 约定)。
 * 供 transport read 回调使用。timeout_ms==0 表示只取当前可用、不等待。 */
size_t uart_ll_read(uint8_t *out, size_t max, int timeout_ms);

#endif /* UART_LL_H */
