/* stm32f1xx_it.c — 中断服务程序 (T4 骨架)
 *
 * 本卡相关的中断(2026-06-19 改到 USART1/Ch5/Ch4,见 main.c 架构变更说明):
 *   - USART1_IRQHandler        : 处理 IDLE line(收完变长帧后线路空闲)→ 收集 RX
 *   - DMA1_Channel5_IRQHandler : USART1_RX DMA 传输完成(circular 绕回)→ 收集 RX
 *   - DMA1_Channel4_IRQHandler : USART1_TX DMA 传输完成 → 清标志、关通道(标记空闲)
 *
 * SysTick/PendSV/SVC 由 FreeRTOS port 提供(经 FreeRTOSConfig.h 的宏映射到 CMSIS 名),
 * 此处不实现。Reset/NMI/HardFault 等由 CMSIS startup 提供默认弱实现。
 *
 * 注:本卡未在 ISR 内调用 FreeRTOS FromISR API(只搬字节进无锁 SPSC 环形缓冲),
 *     故无需 portYIELD_FROM_ISR。中断优先级数值=6 >= MAX_SYSCALL(5),已为将来用 API 留余地。
 */

#include "stm32f1xx.h"

/* 在 main.c 中定义:把 DMA RX 缓冲里的新字节搬进应用环形缓冲。 */
extern void rx_dma_collect(void);

void USART1_IRQHandler(void)
{
    uint32_t sr = USART1->SR;   /* 先快照 SR(读 SR 是 F1 清 IDLE/ORE 序列的第一步) */

    /* IDLE line 检测:收完一帧后线路空闲 → 收变长帧。
     * F1 清 IDLE 序列 = 读 SR 再读 DR。注意:DMA RX 模式下,触发 IDLE 时这一帧的最后
     * 一个字节早已被 DMA 搬入缓冲(RXNE 由 DMA 清),此处读 DR 仅用于清标志,不会吞数据。 */
    if (sr & USART_SR_IDLE) {
        volatile uint32_t tmp = USART1->DR;   /* 读 DR → 清 IDLE(顺带清 ORE) */
        (void)tmp;
        rx_dma_collect();   /* 收完一帧,搬进环形缓冲 */
    }
    /* 溢出错误(ORE):DMA 在高波特率下若被瞬时抢占可能触发 ORE。F1 的 ORE 一旦置位会
     * 停止后续 RXNE/DMA 请求,直到「读 SR 再读 DR」清除——否则 RX 会彻底卡死(表现为缓冲
     * 不再更新)。这里显式清掉,保证 RX 链路自恢复;不静默,可由 T5 再加计数监控。
     * (若 IDLE 分支已读过 DR 则 ORE 已清,此处不会重复吞字节。) */
    else if (sr & USART_SR_ORE) {
        volatile uint32_t tmp = USART1->DR;
        (void)tmp;
    }
}

void DMA1_Channel5_IRQHandler(void)
{
    /* RX circular 传输完成(写到缓冲尾绕回)。先收集再清标志,避免丢字节。 */
    if (DMA1->ISR & DMA_ISR_TCIF5) {
        rx_dma_collect();
        DMA1->IFCR = DMA_IFCR_CTCIF5;
    }
    /* 传输错误:清掉以免反复进中断(circular 下罕见)。 */
    if (DMA1->ISR & DMA_ISR_TEIF5) {
        DMA1->IFCR = DMA_IFCR_CTEIF5;
    }
}

void DMA1_Channel4_IRQHandler(void)
{
    /* TX 传输完成:清标志并关通道,uart_tx_dma 用 CCR.EN 位判断空闲。 */
    if (DMA1->ISR & DMA_ISR_TCIF4) {
        DMA1_Channel4->CCR &= ~DMA_CCR_EN;
        DMA1->IFCR = DMA_IFCR_CTCIF4;
    }
    if (DMA1->ISR & DMA_ISR_TEIF4) {
        DMA1_Channel4->CCR &= ~DMA_CCR_EN;
        DMA1->IFCR = DMA_IFCR_CTEIF4;
    }
}
