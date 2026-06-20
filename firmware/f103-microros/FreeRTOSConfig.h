/* FreeRTOSConfig.h — STM32F103RB (Cortex-M3, ARM_CM3 port)
 *
 * 20KB SRAM 极紧:
 *  - configSUPPORT_STATIC_ALLOCATION=1 优先(task/queue 控制块与栈走静态数组,不占 heap)。
 *  - 仍开 heap_4 + 一个明确上界的 configTOTAL_HEAP_SIZE 兜底(部分内部对象、未来 T5
 *    若用 dynamic 时用),刻意给小(2KB),从小往上调。20KB 经不起默认 heap 大块。
 *  - 本卡(T4)只起 1 个静态 task,几乎不碰 heap。
 *
 * 时钟:SYSCLK = 72MHz(配套 main.c 时钟树)。SysTick 由内核驱动。
 * 中断优先级:F103 只实现高 4 位优先级(__NVIC_PRIO_BITS=4)。
 */
#ifndef FREERTOS_CONFIG_H
#define FREERTOS_CONFIG_H

/* CMSIS device 头提供 __NVIC_PRIO_BITS 等;链接到 SystemCoreClock 由 system_stm32f1xx.c 维护。 */
#ifdef __cplusplus
extern "C" {
#endif
extern uint32_t SystemCoreClock;
#ifdef __cplusplus
}
#endif

#define configENABLE_FPU                        0   /* M3 无 FPU */
#define configENABLE_MPU                        0

#define configUSE_PREEMPTION                    1
#define configUSE_PORT_OPTIMISED_TASK_SELECTION 0   /* CM3 generic 用通用法即可 */
#define configUSE_TICKLESS_IDLE                 0
#define configCPU_CLOCK_HZ                      ( SystemCoreClock )
#define configTICK_RATE_HZ                      ( ( TickType_t ) 1000 )
#define configMAX_PRIORITIES                    ( 5 )
#define configMINIMAL_STACK_SIZE                ( ( uint16_t ) 128 )   /* words = 512B */
#define configMAX_TASK_NAME_LEN                 ( 12 )
#define configUSE_16_BIT_TICKS                  0
#define configIDLE_SHOULD_YIELD                 1
#define configUSE_MUTEXES                       1
#define configUSE_RECURSIVE_MUTEXES             0
#define configUSE_COUNTING_SEMAPHORES           1
#define configQUEUE_REGISTRY_SIZE               4
#define configUSE_QUEUE_SETS                    0
#define configUSE_TIME_SLICING                  1
#define configUSE_NEWLIB_REENTRANT              0
#define configENABLE_BACKWARD_COMPATIBILITY     0
#define configNUM_THREAD_LOCAL_STORAGE_POINTERS 0

/* 内存分配:静态优先;dynamic 兜底,heap 给小且明确上界。 */
#define configSUPPORT_STATIC_ALLOCATION         1
#define configSUPPORT_DYNAMIC_ALLOCATION        1
#define configTOTAL_HEAP_SIZE                   ( ( size_t ) ( 2 * 1024 ) )   /* 2KB 上界,从小往上调 */
#define configAPPLICATION_ALLOCATED_HEAP        0

/* 钩子 */
#define configUSE_IDLE_HOOK                     0
#define configUSE_TICK_HOOK                     0
#define configCHECK_FOR_STACK_OVERFLOW          2   /* 模式2:栈水位 + 模式覆盖检测,调试期开 */
#define configUSE_MALLOC_FAILED_HOOK            1   /* malloc 失败要暴露,不静默 */
#define configUSE_DAEMON_TASK_STARTUP_HOOK      0

/* 运行时统计 / 栈水位:T8 要用 uxTaskGetStackHighWaterMark,这里开 trace 工具支持。 */
#define configGENERATE_RUN_TIME_STATS           0
#define configUSE_TRACE_FACILITY                1
#define configUSE_STATS_FORMATTING_FUNCTIONS    0

/* 协程关闭 */
#define configUSE_CO_ROUTINES                   0
#define configMAX_CO_ROUTINE_PRIORITIES         1

/* 软件定时器(本卡不用,关掉省 RAM) */
#define configUSE_TIMERS                        0
#define configTIMER_TASK_PRIORITY               ( 2 )
#define configTIMER_QUEUE_LENGTH                4
#define configTIMER_TASK_STACK_DEPTH            ( configMINIMAL_STACK_SIZE )

/* 包含的 API */
#define INCLUDE_vTaskPrioritySet                1
#define INCLUDE_uxTaskPriorityGet               1
#define INCLUDE_vTaskDelete                     1
#define INCLUDE_vTaskSuspend                    1
#define INCLUDE_vTaskDelayUntil                 1
#define INCLUDE_vTaskDelay                      1
#define INCLUDE_xTaskGetSchedulerState          1
#define INCLUDE_xTaskGetCurrentTaskHandle       1
#define INCLUDE_uxTaskGetStackHighWaterMark     1   /* T8 栈水位收敛要用 */
#define INCLUDE_xTaskGetIdleTaskHandle          0
#define INCLUDE_eTaskGetState                   0
#define INCLUDE_xTimerPendFunctionCall          0
#define INCLUDE_xTaskAbortDelay                 0
#define INCLUDE_xQueueGetMutexHolder            0

/* === Cortex-M 中断优先级配置(F103: 4 位优先级位) === */
#ifdef __NVIC_PRIO_BITS
  #define configPRIO_BITS                       __NVIC_PRIO_BITS
#else
  #define configPRIO_BITS                       4
#endif

/* 最低优先级 = 2^4 - 1 = 15 */
#define configLIBRARY_LOWEST_INTERRUPT_PRIORITY        15
/* 允许调用 FreeRTOS API 的最高中断优先级(数值越大优先级越低)。
 * 优先级数值 < 此值(更高优先级)的中断不能调 FreeRTOS API,也不被 critical section 屏蔽。
 * 我们的 USART/DMA 中断必须 >= 5(数值),才能安全用 FromISR API。 */
#define configLIBRARY_MAX_SYSCALL_INTERRUPT_PRIORITY   5

#define configKERNEL_INTERRUPT_PRIORITY \
    ( configLIBRARY_LOWEST_INTERRUPT_PRIORITY << (8 - configPRIO_BITS) )
#define configMAX_SYSCALL_INTERRUPT_PRIORITY \
    ( configLIBRARY_MAX_SYSCALL_INTERRUPT_PRIORITY << (8 - configPRIO_BITS) )

/* 断言:调试期把错误暴露出来(死循环可被调试器捕获),不静默。 */
#define configASSERT( x ) if ( ( x ) == 0 ) { taskDISABLE_INTERRUPTS(); for( ;; ); }

/* CMSIS/startup 用通用名,FreeRTOS port 用自己的名,做映射: */
#define vPortSVCHandler        SVC_Handler
#define xPortPendSVHandler     PendSV_Handler
#define xPortSysTickHandler    SysTick_Handler

#endif /* FREERTOS_CONFIG_H */
