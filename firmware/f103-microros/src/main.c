/* main.c — STM32F103RB 固件主文件 (T5 / 里程碑 M2/M3)
 *
 * 目标:时钟树 72MHz + LED(PA5) 心跳 + USART1(PA9/PA10) @EXO_UART_BAUD 8N1 +
 *       DMA1 Ch5 RX circular + USART1 IDLE 中断收变长帧 + DMA1 Ch4 TX 发送。
 *       底层收发(DMA/IDLE/app_ring,RX bug 已修见 git 573a226)沿用 T4,不改动。
 *
 * 【T5 变更 2026-06-20】在 T4 物理层之上接入 micro-ROS:
 *   - 新增 uart_ll_write_blocking / uart_ll_read(本文件,见 uart_ll.h):
 *     transport 层(src/microros_transport.c)的 write/read 回调底座。
 *   - 任务模型:T4 的「echo + 临时 DBG 探针」AppTask 已删除,改为
 *       microros_app_task(src/microros_app.c):rclc 双向闭环 node_com_mcu 节点;
 *       com_control_task/TIM2(src/microros_app.c):本地控制基线(消费最新目标,暂不驱动电机);
 *       + 一个极小 LedTask 做 liveness 心跳。
 *   - 串口归 micro-ROS(XRCE-DDS over serial);仅上电横幅/建链失败用明文自检串。
 *
 * 【架构变更 2026-06-19】通信口从 USART2(PA2/PA3,经 ST-Link VCP)改到独立的
 *   USART1(PA9=TX/PA10=RX),外接独立 USB-TTL 适配器。原因:ST-Link VCP 与 SWD
 *   烧录共用同一 USB,经 usbip 转发 + 老 ST-Link 固件导致 host→MCU 的 RX 收不到真实
 *   数据(真机实测:TX 完美、RX 收不到)。独立 UART 把烧录(ST-Link SWD)与通信彻底隔离。
 *   ST-Link 今后只做 SWD 烧录,固件不再碰 PA2/PA3。
 *
 * 实现层级:寄存器级(CMSIS Device 头提供外设结构体),不用 HAL/LL。
 *   理由:F103 寄存器简单、可观测性最好(每行都看得见写哪个寄存器),
 *         vendor 面最小(只需 CMSIS Core + Device)。
 *
 * 硬约束(见任务卡 T4):
 *   - 时钟:HSE 8MHz → PLL×9 = 72MHz SYSCLK;AHB/1=72M;APB1/2=36M;APB2/1=72M(USART1 挂这);Flash 2WS。
 *   - F103 DMA 固定映射:USART1_TX=DMA1 Ch4,USART1_RX=DMA1 Ch5。
 *   - 禁浮点。
 *
 * 串口内存预算(见 README,buffer 全静态 .bss,128B 对齐):
 *   RX circular 2×128B、TX 单缓冲 128B、MTU=128。
 *
 * 假设(显式标注,供 Gill / 后续同事核对):
 *   - 板载 8MHz HSE 晶振存在且可起振(Nucleo-F103RB 默认通过 ST-Link MCO 提供 8MHz,
 *     SB54/SB55 默认配置 = HSE 来自 ST-Link 8MHz)。若 HSE 起振失败,Clock_Init 会卡在
 *     等待 HSERDY —— 这是有意暴露而非静默降级到 HSI。
 *   - USART1(PA9/PA10) 经独立 USB-TTL 适配器透传到 /dev/ttyUSB0,无硬件流控。
 *   - 中断优先级数值 >= configLIBRARY_MAX_SYSCALL_INTERRUPT_PRIORITY(=5),以便 ISR 内安全
 *     使用(本卡未用 FromISR API,但留余地;故设为 6)。
 */

#include "stm32f1xx.h"
#include "FreeRTOS.h"
#include "task.h"

#include <errno.h>
#include <stddef.h>
#include <stdint.h>

/* ===== 有界 _sbrk(覆盖 nosys 的无界版本)—— 永久保留的健壮性改进 =====
 * nosys.specs 的 _sbrk 不做任何边界检查:newlib heap 从 `end` 一路上涨,耗尽时越过 RAM 顶
 * (_estack)写非法地址 → HardFault。这里改成有界:超过 [end, _estack-RESERVE] 即返回 -1,
 * 让 newlib malloc 得到 NULL → rcl 干净失败而不是踩飞。
 * RESERVE 给 MSP/ISR 栈留余量(调度器启动后 MSP 仅 ISR 用)。 */
extern char end;        /* 链接脚本:.bss 之后 = newlib heap 起点 */
extern char _estack;    /* 链接脚本:RAM 顶(MSP 初值) */
#define NEWLIB_HEAP_MSP_RESERVE  512u

void *_sbrk(ptrdiff_t incr)
{
    static char *heap_end = 0;
    char *prev;
    uintptr_t stack_top = (uintptr_t)&_estack;
    char *limit = (char *)(stack_top - NEWLIB_HEAP_MSP_RESERVE);
    if (heap_end == 0) {
        heap_end = &end;
    }
    if (heap_end + incr > limit) {
        errno = ENOMEM;
        return (void *)-1;   /* 超界:malloc 得 NULL,rcl 据此干净失败 */
    }
    prev = heap_end;
    heap_end += incr;
    return (void *)prev;
}

#include "microros_app.h"   /* T5:micro-ROS 应用任务(替代 T4 的 echo AppTask) */
#include "uart_ll.h"        /* T5:本文件实现 uart_ll_write_blocking / uart_ll_read 供 transport 用 */
#include "dwt_time.h"       /* M-B 任务 3:DWT CYCCNT 单调时钟(stamp_mono_ns)+ tick 钩子回绕扩展 */

#include <time.h>           /* T5:clock_gettime 实现(libmicroros 的 rcutils/xrce 取时依赖) */

/* ===== T5:clock_gettime —— libmicroros 取时后端 =====
 * libmicroros 的 rcutils(time_unix.c)与 microxrcedds_client(time.c)在裸机下仍走 POSIX
 * clock_gettime(库构建期用 -DCLOCK_MONOTONIC 让其编过,运行实现由固件提供)。
 * 这里基于 FreeRTOS tick 提供单调时钟:精度 = 1/configTICK_RATE_HZ(ms 级),足够 XRCE
 * 会话保活/超时与 rcl 时间戳。CLOCK_MONOTONIC/REALTIME 都返回同一单调 tick(裸机无 RTC,
 * 不区分;micro-ROS 只需单调递增 + 合理速率)。
 * 注:64 位运算为软件实现(不涉硬浮点);tick(32 位)×1e6 用 64 位中转不溢出。 */
int clock_gettime(clockid_t clk_id, struct timespec *tp)
{
    (void)clk_id;
    if (tp == 0) return -1;
    TickType_t ticks = xTaskGetTickCount();
    uint64_t ms = (uint64_t)ticks * 1000u / (uint64_t)configTICK_RATE_HZ;
    tp->tv_sec  = (time_t)(ms / 1000u);
    tp->tv_nsec = (long)((ms % 1000u) * 1000000u);
    return 0;
}

/* ===== 串口缓冲(静态 .bss,128B 对齐) ===== */
#define UART_MTU            128u
#define RX_DMA_BUF_SIZE     (2u * UART_MTU)   /* circular 双半区 = 256B */
#define TX_DMA_BUF_SIZE     UART_MTU          /* 单缓冲 128B */

#ifndef EXO_UART_BAUD
#  define EXO_UART_BAUD 921600u
#endif
#define USART1_BRR_VALUE    ((uint32_t)((72000000u + (EXO_UART_BAUD / 2u)) / EXO_UART_BAUD))

#ifndef EXO_CONTROL_LOOP_HZ
#  define EXO_CONTROL_LOOP_HZ 1000u
#endif

static volatile uint8_t rx_dma_buf[RX_DMA_BUF_SIZE] __attribute__((aligned(4)));
static          uint8_t tx_dma_buf[TX_DMA_BUF_SIZE] __attribute__((aligned(4)));

/* 软件环形缓冲:IDLE/DMA 中断把收到的字节搬进来,task 取出回显。
 * 容量取 256(2 的幂,&掩码取模)。单生产者(ISR)单消费者(task),volatile 即可。 */
#define APP_RING_SIZE       256u
#define APP_RING_MASK       (APP_RING_SIZE - 1u)
static volatile uint8_t app_ring[APP_RING_SIZE];
static volatile uint16_t app_ring_head;   /* ISR 写 */
static volatile uint16_t app_ring_tail;   /* task 写 */

/* DMA RX 上一次处理到的位置(在 rx_dma_buf 中),用于计算本次新到了多少字节。 */
static volatile uint16_t rx_last_pos;

/* 诊断计数:每次 IDLE 中断本次搬进 app_ring 的字节数。
 * volatile + used:保留为可观测探针(调试器/将来诊断 topic 可读),不让编译器优化掉。
 * (T4 的临时 DBG 串口打印探针 rx_last_byte/rx_total 已随 T5 删除。) */
static volatile uint16_t rx_last_idle_count __attribute__((used));

/* ===== 供 stm32f1xx_it.c 调用的 RX 处理入口 ===== */
/* DMA RX 是 circular,当前写入位置 = RX_DMA_BUF_SIZE - CNDTR。
 * IDLE 中断(收完一帧线路空闲)和 TC 中断(写到缓冲尾绕回)都调用本函数,
 * 把 rx_last_pos..cur 之间的新字节搬进 app_ring(单生产者:ISR)。
 * 处理变长帧 + circular 绕回两种情况。 */
void rx_dma_collect(void)
{
    /* 当前 DMA 写到的位置(下一个将写入的下标)。
     * ★ &(SIZE-1) 掩码必须有:circular 绕回瞬间 CNDTR 可读到 0 → 256-0=256,而 rx_last_pos
     *   被掩在 [0,255] 永不等于 256 → while 死循环。掩码后 256&255=0,与 CNDTR=256(=0)一致。 */
    uint16_t cur = (uint16_t)((RX_DMA_BUF_SIZE - DMA1_Channel5->CNDTR) & (RX_DMA_BUF_SIZE - 1u));
    uint16_t n = 0;

    while (rx_last_pos != cur) {
        uint8_t b = rx_dma_buf[rx_last_pos];
        uint16_t next_head = (uint16_t)((app_ring_head + 1u) & APP_RING_MASK);
        if (next_head != app_ring_tail) {        /* 满则丢弃最新字节(溢出可观测留给 T5;T4 不静默扩容) */
            app_ring[app_ring_head] = b;
            app_ring_head = next_head;
        }
        rx_last_pos = (uint16_t)((rx_last_pos + 1u) & (RX_DMA_BUF_SIZE - 1u));
        /* 注:RX_DMA_BUF_SIZE=256 是 2 的幂,&掩码取模成立。 */
        n++;
    }
    rx_last_idle_count = n;   /* 诊断:本次搬运字节数 */
}

/* ===== 时钟树 72MHz(寄存器级) ===== */
static void Clock_Init(void)
{
    /* 1. 开 HSE,等就绪。
     *    ⚠️ Nucleo-F103RB 出厂默认:8MHz 由 ST-Link 经 MCO 走线送进 OSC_IN(外部时钟源,
     *    非晶振,X3 默认不焊;SB54/SB55 OFF + SB16/SB50 ON)。外部方波时钟必须用 HSE BYPASS 模式,
     *    否则晶振振荡器电路接方波可能不稳/起不来。故先置 HSEBYP 再 HSEON。
     *    若实际板子改成了焊晶振配置(SB54 ON),把 HSEBYP 这行去掉即可。 */
    RCC->CR |= RCC_CR_HSEBYP;   /* 外部时钟旁路(ST-Link MCO 8MHz),默认板配置 */
    RCC->CR |= RCC_CR_HSEON;
    while ((RCC->CR & RCC_CR_HSERDY) == 0) { /* 有意死等:HSE 不起就别往下跑,暴露问题 */ }

    /* 2. Flash:72MHz 需 2 等待周期 + 开预取缓冲。必须在切到 PLL 之前配好。 */
    FLASH->ACR &= ~FLASH_ACR_LATENCY;
    FLASH->ACR |= FLASH_ACR_LATENCY_2 | FLASH_ACR_PRFTBE;

    /* 3. 总线分频:AHB/1=72M;APB1/2=36M(USART2/TIM 等挂这);APB2/1=72M。 */
    RCC->CFGR &= ~(RCC_CFGR_HPRE | RCC_CFGR_PPRE1 | RCC_CFGR_PPRE2);
    RCC->CFGR |= RCC_CFGR_HPRE_DIV1;   /* AHB  = SYSCLK / 1  = 72M */
    RCC->CFGR |= RCC_CFGR_PPRE1_DIV2;  /* APB1 = HCLK   / 2  = 36M */
    RCC->CFGR |= RCC_CFGR_PPRE2_DIV1;  /* APB2 = HCLK   / 1  = 72M */

    /* 4. PLL:源 = HSE(不分频),倍频 ×9 → 8M × 9 = 72M。 */
    RCC->CFGR &= ~(RCC_CFGR_PLLSRC | RCC_CFGR_PLLXTPRE | RCC_CFGR_PLLMULL);
    RCC->CFGR |= RCC_CFGR_PLLSRC;        /* PLL 源 = HSE */
    RCC->CFGR |= RCC_CFGR_PLLMULL9;      /* ×9 */

    /* 5. 开 PLL,等就绪。 */
    RCC->CR |= RCC_CR_PLLON;
    while ((RCC->CR & RCC_CR_PLLRDY) == 0) { }

    /* 6. 切 SYSCLK 到 PLL,等切换确认。 */
    RCC->CFGR &= ~RCC_CFGR_SW;
    RCC->CFGR |= RCC_CFGR_SW_PLL;
    while ((RCC->CFGR & RCC_CFGR_SWS) != RCC_CFGR_SWS_PLL) { }

    /* 7. 更新 CMSIS 的 SystemCoreClock(FreeRTOS configCPU_CLOCK_HZ 依赖它)。 */
    SystemCoreClockUpdate();   /* 由 system_stm32f1xx.c 提供,按寄存器反算,得 72000000 */
}

/* ===== GPIO:PA5=LED 推挽输出;PA9=USART1_TX 复用推挽;PA10=USART1_RX 上拉输入 =====
 * F103 GPIO 模型:每脚 4 位 = MODE[1:0]+CNF[1:0],分布在 CRL(pin0-7)/CRH(pin8-15)。
 *   ⚠️ PA9/PA10 在 CRH(不是 CRL),pin9 nibble 在 bits 4..7、pin10 nibble 在 bits 8..11
 *      (CRH 内下标 = pin - 8)。
 *   输出 50MHz = MODE=0b11;推挽通用 CNF=0b00;复用推挽 CNF=0b10;带上下拉输入 MODE=0b00,CNF=0b10。
 */
static void GPIO_Init(void)
{
    /* 开 GPIOA + AFIO 时钟(APB2)。USART1 不需 AFIO 重映射(默认 PA9/PA10),但开着无害。 */
    RCC->APB2ENR |= RCC_APB2ENR_IOPAEN | RCC_APB2ENR_AFIOEN;

    /* --- PA5 (LED, CRL bits 20..23) : 输出 50MHz 推挽 = MODE=11, CNF=00 --- */
    GPIOA->CRL &= ~(0xFu << (5 * 4));
    GPIOA->CRL |=  (0x3u << (5 * 4));            /* MODE=11(50MHz out), CNF=00(推挽) */

    /* --- PA9 (USART1_TX, CRH bits 4..7 = nibble (9-8)) : 复用推挽 50MHz = MODE=11,CNF=10 = 0b1011 --- */
    GPIOA->CRH &= ~(0xFu << ((9 - 8) * 4));
    GPIOA->CRH |=  (0xBu << ((9 - 8) * 4));      /* 0b1011 */

    /* --- PA10 (USART1_RX, CRH bits 8..11 = nibble (10-8)) : 上拉输入 = MODE=00,CNF=10 = 0b1000, ODR.10=1 选上拉 ---
     * 沿用原 PA3(USART2_RX) 的上拉做法:输入悬空会漂到低,被 USART 当成连续起始位+全 0
     *   数据帧(runaway 0x00)。本次外接独立 USB-TTL 适配器会主动驱动 RX 线,正常不会悬空;
     *   上拉作空闲兜底,把空闲电平钳高,消除适配器断开/上电瞬态时的伪零帧。
     *   F1 输入模式下上拉/下拉由 ODR 选择:ODR=1 → 上拉。 */
    GPIOA->CRH &= ~(0xFu << ((10 - 8) * 4));
    GPIOA->CRH |=  (0x8u << ((10 - 8) * 4));     /* MODE=00(输入), CNF=10(带上/下拉输入) */
    GPIOA->ODR |=  (1u << 10);                   /* ODR.10=1 → 选上拉(空闲线钳高) */
}

/* ===== DMA1 Ch5 (USART1_RX, circular) + Ch4 (USART1_TX) =====
 * F103 固定映射:USART1_TX=DMA1 Ch4,USART1_RX=DMA1 Ch5(区别于 USART2 的 Ch7/Ch6)。 */
static void DMA_Init(void)
{
    RCC->AHBENR |= RCC_AHBENR_DMA1EN;
    (void)RCC->AHBENR;   /* ★必须:回读做屏障,确保 DMA1 时钟真正使能后再写其寄存器。
                          * 否则开时钟后紧跟的头一两个外设写会被静默丢弃——本卡的真凶:
                          * Ch5 CPAR(开时钟后第一个只写一次的寄存器)被丢→CPAR=0→DMA 从地址0狂读
                          * →RXNE 永不清→0x00 风暴。Ch4(TX) CPAR 写得晚、时钟已稳,故 TX 一直正常。 */

    /* --- Ch5: USART1_RX, circular, periph->mem, 字节, MINC, circular, 开 TC 中断 --- */
    DMA1_Channel5->CCR = 0;                                  /* 先关 */
    DMA1_Channel5->CPAR  = (uint32_t)&USART1->DR;            /* 外设地址 = USART1 数据寄存器 */
    DMA1_Channel5->CMAR  = (uint32_t)rx_dma_buf;             /* 内存地址 */
    DMA1_Channel5->CNDTR = RX_DMA_BUF_SIZE;                  /* 传输个数 */
    DMA1_Channel5->CCR =
          DMA_CCR_MINC      /* 内存地址递增 */
        | DMA_CCR_CIRC      /* circular */
        | DMA_CCR_PL_1      /* 优先级 High(0b10);Very High 用 PL_1|PL_0,这里 High 足够 */
        | DMA_CCR_TCIE;     /* 传输完成中断(回到缓冲尾→开头时触发,配合 IDLE 兜变长帧) */
        /* 方向位 DIR=0 = periph->mem(读外设);数据宽度默认 8 位(PSIZE/MSIZE=00)。 */

    /* --- Ch4: USART1_TX, normal, mem->periph, 字节, MINC, 开 TC 中断 --- */
    DMA1_Channel4->CCR = 0;
    DMA1_Channel4->CPAR  = (uint32_t)&USART1->DR;
    DMA1_Channel4->CMAR  = (uint32_t)tx_dma_buf;
    DMA1_Channel4->CNDTR = 0;
    DMA1_Channel4->CCR =
          DMA_CCR_DIR       /* mem->periph */
        | DMA_CCR_MINC
        | DMA_CCR_PL_1      /* High */
        | DMA_CCR_TCIE;
        /* 不开 CIRC:每次发送重设 CNDTR + 使能。 */

    /* NVIC:DMA1_Ch4/Ch5 + USART1 中断,优先级数值 6(>= MAX_SYSCALL=5,安全)。 */
    NVIC_SetPriority(DMA1_Channel4_IRQn, 6);
    NVIC_EnableIRQ(DMA1_Channel4_IRQn);
    NVIC_SetPriority(DMA1_Channel5_IRQn, 6);
    NVIC_EnableIRQ(DMA1_Channel5_IRQn);

    /* 使能 RX 通道(circular,常驻接收)。 */
    DMA1_Channel5->CCR |= DMA_CCR_EN;
}

/* ===== USART1 @EXO_UART_BAUD 8N1,DMA TX/RX + IDLE 中断 ===== */
static void USART1_Init(void)
{
    RCC->APB2ENR |= RCC_APB2ENR_USART1EN;   /* USART1 在 APB2(72MHz),区别于 USART2 的 APB1(36MHz) */

    USART1->CR1 = 0;
    USART1->CR2 = 0;
    USART1->CR3 = 0;

    /* 波特率:oversampling by 16 时 BRR 等价整数式为 round(PCLK2 / baud)。
     * 默认 EXO_UART_BAUD=921600 -> BRR=78(0x4E),实际 923077,误差 +0.16%。
     * 2Mbps -> BRR=36(0x24),3Mbps -> BRR=24(0x18),均需 USB-TTL 实测确认。 */
    USART1->BRR = USART1_BRR_VALUE;

    /* CR3:开 DMA 收发。 */
    USART1->CR3 = USART_CR3_DMAT | USART_CR3_DMAR;

    /* CR1:开 USART、TX、RX、IDLE 中断(IDLE = 收到一帧后线路空闲→收变长帧靠它)。 */
    USART1->CR1 = USART_CR1_UE | USART_CR1_TE | USART_CR1_RE | USART_CR1_IDLEIE;

    /* USART1 中断(IDLE 在此 IRQ),优先级 6。 */
    NVIC_SetPriority(USART1_IRQn, 6);
    NVIC_EnableIRQ(USART1_IRQn);
}

#if EXO_CONTROL_LOOP_HZ > 1000u
/* ===== TIM2 高频本地控制 tick =====
 * FreeRTOS tick=1kHz,无法表达 2/5/10kHz。高频基线改用 TIM2 ISR;ISR 只调用
 * com_control_tick_isr() 做 latest-target 采样/计数,不调用 FreeRTOS API。 */
static void ControlTimer_Init(void)
{
    RCC->APB1ENR |= RCC_APB1ENR_TIM2EN;
    (void)RCC->APB1ENR;

    TIM2->CR1 = 0;
    TIM2->PSC = 71u;  /* APB1 prescaler=2 => TIM2CLK=72MHz,PSC 71 => 1MHz */
    TIM2->ARR = (uint16_t)((1000000u / EXO_CONTROL_LOOP_HZ) - 1u);
    TIM2->EGR = TIM_EGR_UG;
    TIM2->SR = 0;
    TIM2->DIER = TIM_DIER_UIE;

    NVIC_SetPriority(TIM2_IRQn, 5);  /* 最高可被 FreeRTOS critical section 屏蔽的优先级 */
    NVIC_EnableIRQ(TIM2_IRQn);
    TIM2->CR1 = TIM_CR1_CEN;
}
#endif

/* ===== TX:用 DMA 发送一段(<= TX_DMA_BUF_SIZE)。阻塞等待上一次发完。 =====
 * 本卡自检/回显数据量小,简单实现:拷进 tx_dma_buf,重设 Ch7,等 TC。
 * 注:这是 T4 骨架的发送原语;T5 的 transport write 回调会有自己的实现。 */
static void uart_tx_dma(const uint8_t *data, uint16_t len)
{
    if (len == 0) return;
    if (len > TX_DMA_BUF_SIZE) len = TX_DMA_BUF_SIZE;

    /* 等上一次 TX DMA 结束(通道被禁用 = 完成)。 */
    while (DMA1_Channel4->CCR & DMA_CCR_EN) { }

    for (uint16_t i = 0; i < len; i++) tx_dma_buf[i] = data[i];

    /* 清 Ch4 各标志(GIF/TCIF/HTIF/TEIF,位组 4 在 IFCR 的 bits 12..15)。 */
    DMA1->IFCR = DMA_IFCR_CGIF4;

    DMA1_Channel4->CCR  &= ~DMA_CCR_EN;
    DMA1_Channel4->CMAR  = (uint32_t)tx_dma_buf;
    DMA1_Channel4->CNDTR = len;
    DMA1_Channel4->CCR  |= DMA_CCR_EN;
}

/* 阻塞发字符串(自检横幅/micro-ROS 进度自检用)。
 * 非 static:microros_app.c 经 `extern void uart_puts(const char*)` 调用,打建链
 * 失败等自检信息(仅在未建链阶段;建链后串口交给 XRCE,见 microros_app.c 说明)。 */
void uart_puts(const char *s)
{
    uint16_t n = 0;
    while (s[n]) n++;
    uart_tx_dma((const uint8_t *)s, n);
}

/* ===== app_ring 取一个字节(task 侧消费),无数据返回 -1 ===== */
static int app_ring_get(uint8_t *out)
{
    if (app_ring_tail == app_ring_head) return -1;
    *out = app_ring[app_ring_tail];
    app_ring_tail = (uint16_t)((app_ring_tail + 1u) & APP_RING_MASK);
    return 0;
}

/* ===================== T5:transport 层用的 UART 收发原语 =====================
 * 声明在 uart_ll.h;microros_transport.c 的 write/read 回调调用它们。
 * 仍走 T4 已调通的 USART1+DMA(uart_tx_dma)与 app_ring,不重写底层。 */

/* write:把 len 字节全部发出(经 TX DMA)。len 可能 > MTU(XRCE 一帧最大 128,
 * 但稳妥起见分块),分多次 uart_tx_dma 直到发完。返回实际写出字节数。 */
size_t uart_ll_write_blocking(const uint8_t *data, size_t len)
{
    size_t sent = 0;
    while (sent < len) {
        size_t chunk = len - sent;
        if (chunk > TX_DMA_BUF_SIZE) chunk = TX_DMA_BUF_SIZE;
        uart_tx_dma(data + sent, (uint16_t)chunk);   /* 内部等上一次 TX 完成,阻塞 */
        sent += chunk;
    }
    /* 等最后一块 DMA 真正发完,保证返回时字节已上线(write 的阻塞语义)。 */
    while (DMA1_Channel4->CCR & DMA_CCR_EN) { }
    return sent;
}

/* read:从 app_ring 取最多 max 字节,带毫秒级软超时。
 *   - 先把当前可用字节尽量取走;不足 max 且未超时,则 vTaskDelay 让出后再取。
 *   - 取到 >=1 字节立即返回(不强求填满 max);全程无数据则等到超时返回 0。
 * 用 FreeRTOS tick 计超时;timeout_ms<=0 表示只取当前可用、不等待。 */
size_t uart_ll_read(uint8_t *out, size_t max, int timeout_ms)
{
    size_t got = 0;
    uint8_t c;

    /* 先一把取走当前可用字节。 */
    while (got < max && app_ring_get(&c) == 0) {
        out[got++] = c;
    }
    if (got > 0 || timeout_ms <= 0) {
        return got;   /* 已有数据 / 不等待 → 立即返回(XRCE 轮询常态) */
    }

    /* 当前为空且要求等待:在 timeout_ms 内轮询(1ms 粒度,降低 200Hz 基线 RTT)。 */
    TickType_t start    = xTaskGetTickCount();
    TickType_t deadline = pdMS_TO_TICKS((uint32_t)timeout_ms);
    while ((xTaskGetTickCount() - start) < deadline) {
        if (app_ring_get(&c) == 0) {
            out[got++] = c;
            /* 抓到第一个字节后,把当前已到的也顺手取走再返回,减少回调往返。 */
            while (got < max && app_ring_get(&c) == 0) {
                out[got++] = c;
            }
            return got;
        }
        vTaskDelay(pdMS_TO_TICKS(1));
    }
    return got;   /* 超时,got==0 */
}

/* ===== LED 心跳 task(liveness 信号,独立于 micro-ROS) =====
 * T4 的 echo + 临时 DBG 探针已删除(T5 不再回显/不再打 DBG 串,串口归 micro-ROS)。
 * 保留一个极小的 LED 翻转任务:即使 micro-ROS 卡在建链/重连,LED 仍闪 = 调度器活着,
 * 是裸眼可见的活性信号(与 agent 侧 -v6 日志互补)。栈极小(64 words=256B)。 */
static void LedTask(void *arg)
{
    (void)arg;
    for (;;) {
        GPIOA->ODR ^= (1u << 5);          /* PA5 翻转 */
        vTaskDelay(pdMS_TO_TICKS(500));   /* 1Hz 闪烁(亮灭各 500ms) */
    }
}

/* ===== 静态 task 资源(configSUPPORT_STATIC_ALLOCATION=1) =====
 * micro-ROS 任务栈:rcl→rmw→xrce 调用链较深。早期按 05 文档 T8 建议从 ~2500 words
 *   起测,现已基于 gdb 栈水位和硬件验收收敛到 1024 words。
 * 控制任务栈:128 words(=512B),<=1kHz latest-target 消费骨架。
 * LED 任务栈:64 words(=256B),只翻 GPIO + delay,够用。 */
#define MICROROS_TASK_STACK_WORDS  1024u   /* 4KB。gdb 实测 rcl_init+create_session 全程栈最深仅用 ~235 words
                                            * (早期 2048-word 栈 HWM 余 1813),4KB 仍保留约 3KB 栈余量;
                                            * 省下 2KB SRAM 给 newlib heap / micro-ROS 运行余量。
                                            * (注:建链 hang 与栈无关,真因是 best_effort 流配置见 colcon.meta;
                                            *  此前 10KB→6KB 的栈调整是误判方向,栈从来不是瓶颈。) */
#define CONTROL_TASK_STACK_WORDS   128u    /* = 512B,1kHz local control baseline */
#define LED_TASK_STACK_WORDS       64u     /* = 256B */

static StaticTask_t microros_task_tcb;
static StackType_t  microros_task_stack[MICROROS_TASK_STACK_WORDS];
#if EXO_CONTROL_LOOP_HZ <= 1000u
static StaticTask_t control_task_tcb;
static StackType_t  control_task_stack[CONTROL_TASK_STACK_WORDS];
#endif
static StaticTask_t led_task_tcb;
static StackType_t  led_task_stack[LED_TASK_STACK_WORDS];
static StaticTask_t idle_task_tcb;
static StackType_t  idle_task_stack[configMINIMAL_STACK_SIZE];
static volatile uint32_t t8_probe_anchor;

#if defined(__GNUC__)
#define T8_PROBE_NOINLINE __attribute__((noinline, used))
#else
#define T8_PROBE_NOINLINE
#endif

T8_PROBE_NOINLINE uint32_t t8_probe_microros_stack_hwm_words(void);
T8_PROBE_NOINLINE uint32_t t8_probe_control_stack_hwm_words(void);
T8_PROBE_NOINLINE uint32_t t8_probe_led_stack_hwm_words(void);
T8_PROBE_NOINLINE uint32_t t8_probe_idle_stack_hwm_words(void);

int main(void)
{
    Clock_Init();
    GPIO_Init();
    DMA_Init();
    USART1_Init();

    /* M-B 任务 3:初始化 DWT CYCCNT 单调时钟(stamp_mono_ns 来源)。
     * ★ 必须在 vTaskStartScheduler 之前:调度器一起跑,1kHz tick 钩子(vApplicationTickHook)
     *   就会调 dwt_tick_update() 维护 64 位回绕扩展——init 必须先把 CYCCNT 使能并把
     *   g_dwt_last_cyccnt 置好,否则首个 tick 读到未使能/未初始化的低位。
     * 返回 0(CYCCNT 不可用)在 F103 上不应发生;若发生,stamp 恒 0(暴露,不静默降级)。
     * 不死等/不 fail:stamp 不可用不该让整个 micro-ROS 链路停摆(回环值仍正确,只是 stamp=0
     * 可观测),与「值正确性 > 时效地基」的分层一致。 */
    (void)dwt_init();

    rx_last_pos   = 0;
    app_ring_head = 0;
    app_ring_tail = 0;

    /* 【T5 注意】USART1 = micro-ROS XRCE 串口,**禁止任何明文输出**(banner/DBG 都会
     * 污染 XRCE 帧流,agent 无法建链)。固件存活靠 LED 心跳(LedTask)观察,不靠串口文本。
     * 原 boot banner 已移除(2026-06-20:实测 banner 文本混进 XRCE 流导致 agent 收不到 session)。 */

    /* 控制基线高于通信任务:本地闭环不被 ROS 通信阻塞。
     * <=1kHz 用 FreeRTOS task;>1kHz 用 TIM2 ISR。micro-ROS 优先级 2;LED 优先级 1。 */
#if EXO_CONTROL_LOOP_HZ <= 1000u
    xTaskCreateStatic(com_control_task, "ctrl", CONTROL_TASK_STACK_WORDS, NULL,
                      3 /*prio*/, control_task_stack, &control_task_tcb);
#else
    ControlTimer_Init();
#endif
    xTaskCreateStatic(microros_app_task, "uros", MICROROS_TASK_STACK_WORDS, NULL,
                      2 /*prio*/, microros_task_stack, &microros_task_tcb);
    xTaskCreateStatic(LedTask, "led", LED_TASK_STACK_WORDS, NULL,
                      1 /*prio*/, led_task_stack, &led_task_tcb);

    /* GDB 可把 t8_probe_anchor 置成 magic 后单步调用;默认值为 0,正常启动不触发。
     * 这条 volatile 分支的主要作用是让 linker 保留 t8_probe_* 符号和 FreeRTOS 查询函数。 */
    if (t8_probe_anchor == 0x54385052u) {  /* "T8PR" */
        t8_probe_anchor += t8_probe_microros_stack_hwm_words();
        t8_probe_anchor += t8_probe_control_stack_hwm_words();
        t8_probe_anchor += t8_probe_led_stack_hwm_words();
        t8_probe_anchor += t8_probe_idle_stack_hwm_words();
    }

    vTaskStartScheduler();

    /* 调度器不应返回;若返回说明 heap/资源问题,死循环暴露。 */
    for (;;) { }
}

/* ===== 静态分配回调(FreeRTOS 要求,configSUPPORT_STATIC_ALLOCATION=1 时必须提供) =====
 * 给 idle task 提供静态内存。 */
void vApplicationGetIdleTaskMemory(StaticTask_t **ppxIdleTaskTCBBuffer,
                                   StackType_t **ppxIdleTaskStackBuffer,
                                   uint32_t *pulIdleTaskStackSize)
{
    *ppxIdleTaskTCBBuffer   = &idle_task_tcb;
    *ppxIdleTaskStackBuffer = idle_task_stack;
    *pulIdleTaskStackSize   = configMINIMAL_STACK_SIZE;
}

/* ===== T8 SWD/GDB-only probes =====
 * 这些函数只为调试器保留符号,正常运行路径不调用。它们避免把诊断塞进 ExoStatus
 * payload,也不增加 micro-ROS publisher。 */
T8_PROBE_NOINLINE uint32_t t8_probe_microros_stack_hwm_words(void)
{
    return (uint32_t)uxTaskGetStackHighWaterMark((TaskHandle_t)&microros_task_tcb);
}

T8_PROBE_NOINLINE uint32_t t8_probe_control_stack_hwm_words(void)
{
#if EXO_CONTROL_LOOP_HZ <= 1000u
    return (uint32_t)uxTaskGetStackHighWaterMark((TaskHandle_t)&control_task_tcb);
#else
    return 0u;  /* TIM2 ISR mode has no control task stack. */
#endif
}

T8_PROBE_NOINLINE uint32_t t8_probe_led_stack_hwm_words(void)
{
    return (uint32_t)uxTaskGetStackHighWaterMark((TaskHandle_t)&led_task_tcb);
}

T8_PROBE_NOINLINE uint32_t t8_probe_idle_stack_hwm_words(void)
{
    return (uint32_t)uxTaskGetStackHighWaterMark((TaskHandle_t)&idle_task_tcb);
}

#undef T8_PROBE_NOINLINE

/* configCHECK_FOR_STACK_OVERFLOW != 0 时需要;栈溢出 = 安全事件,死循环暴露给调试器。 */
void vApplicationStackOverflowHook(TaskHandle_t xTask, char *pcTaskName)
{
    (void)xTask; (void)pcTaskName;
    taskDISABLE_INTERRUPTS();
    for (;;) { }
}

/* configUSE_MALLOC_FAILED_HOOK=1 时需要;malloc 失败不静默。 */
void vApplicationMallocFailedHook(void)
{
    taskDISABLE_INTERRUPTS();
    for (;;) { }
}

/* ===== M-B 任务 3:FreeRTOS tick 钩子 —— DWT 64 位回绕扩展的独立高频源(H3) =====
 * configUSE_TICK_HOOK=1 时,FreeRTOS 每个 tick(1kHz = 1ms)在 SysTick ISR 上下文调本钩子。
 * 这里把它转给 dwt_tick_update():每 1ms 采样一次 CYCCNT、检测/累加 32 位回绕到 64 位高位。
 * 1ms << CYCCNT 回绕周期 59.65s → 两 tick 间至多走 72000 cycle,绝不可能跨整圈 2^32,
 *   故回绕检测无遗漏(H3 核心:不靠 dwt_now_ns 调用频率,链路断流 >59.65s 也不漏回绕)。
 * 钩子内只读一次寄存器 + 一次比较 + 至多一次自增,极轻(几十 ns),不拖累 tick。 */
void vApplicationTickHook(void)
{
    dwt_tick_update();
}
