/* dwt_time.h — DWT CYCCNT 单调时钟源对外接口 (M-B / 任务 3,H3 硬约束)
 *
 * 【这是什么】
 *   ExoStatus.header.stamp_mono_ns 的唯一来源:基于 Cortex-M3 内核 DWT->CYCCNT(周期计数器)
 *   折算纳秒的单调时钟。F103 @72MHz,1 cycle = 1/72e6 s ≈ 13.888... ns。
 *   只要求**稳定单调**(绝对值跨端不可比,§D4 已接受),用于 MCU 侧相对时效地基。
 *
 * 【为什么不用 FreeRTOS tick(ms)直接做 stamp】
 *   main.c 的 clock_gettime 已用 FreeRTOS tick(1ms 粒度)喂 micro-ROS 保活,但 stamp_mono_ns
 *   要的是更细的时效地基(契约 §7.1:发送方单调纳秒)。DWT CYCCNT 是 13.9ns 粒度,精度最好
 *   (§D6),故 stamp 专用 DWT,与保活时钟分离。
 *
 * 【H3 硬约束:32 位 CYCCNT ~59.65s 回绕,64 位扩展必须由独立高频源维护】
 *   CYCCNT 是 32 位 @72MHz → 2^32/72e6 ≈ 59.65s 回绕。stamp_mono_ns 是 uint64,必须做
 *   64 位回绕扩展。**禁止**在读取点(dwt_now_ns)靠「本次 CYCCNT < 上次就 +2^32」判回绕——
 *   dwt_now_ns 只在收 cmd 的回调里被调用,链路断流 >59.65s 时两次调用间会整整回绕一圈,
 *   「本次 > 上次」假成立 → 漏一个回绕 → 64 位累加少加 2^32 → **stamp 倒退**(安全关键场景里
 *   最该暴露却被掩盖的失效:链路刚恢复时 stamp 反而倒退)。
 *
 *   正确做法(本模块):由 **FreeRTOS tick 钩子 vApplicationTickHook(1kHz=1ms,远 << 59.65s)**
 *   维护 64 位 cycle 累加——每 tick 读一次 CYCCNT,与上次 tick 比,检测回绕(本次 < 上次 ⇒ 高位 +1),
 *   把高 32 位累加进 g_dwt_cyccnt_hi。tick 周期(1ms)远小于回绕周期(59.65s),两次采样间最多
 *   回绕一次、绝不漏检。dwt_now_ns() 读「(hi<<32)|当前 CYCCNT 低位」并补偿「硬件已回绕、
 *   tick 尚未把 hi+1」的最长 1ms 滞后窗口(否则该窗口内会用旧 hi 配回绕后小低位 → stamp 倒退),
 *   全程无锁(单写者 tick 钩子 + 读者三读重读循环 + 单向补偿,详见 dwt_time.c)。
 *
 *   高频源选型:复用 FreeRTOS 已有的 1kHz SysTick(tick 钩子),不另起独立定时器中断——零额外
 *   中断成本、零额外外设占用。需在 FreeRTOSConfig.h 置 configUSE_TICK_HOOK=1(M-B 已改)。
 */
#ifndef DWT_TIME_H
#define DWT_TIME_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 开机初始化(一次):使能 DWT trace + 清零并启动 CYCCNT。
 * 必须在调度器启动前(tick 钩子开始跑前)调用,否则首个 tick 读到未使能的 CYCCNT。
 * 返回 1 = CYCCNT 已成功使能并在计数;0 = 该 part 不实现 CYCCNT(F103 标配可用,理论兜底)。 */
int dwt_init(void);

/* FreeRTOS tick 钩子内部调用的 64 位回绕扩展维护函数(每 tick / 1ms 调一次)。
 * 由 vApplicationTickHook 转调(见 main.c)。**只在 tick 钩子里调,别处勿调**——
 * 它假定调用间隔 = 1 tick(远 << 回绕周期),据此做「最多回绕一次」的无遗漏检测。 */
void dwt_tick_update(void);

/* 读当前单调时间(纳秒)。组合 64 位 cycle 累加(tick 钩子维护的高位)+ 当前 CYCCNT 低位,
 * 无锁双读夹逼防撕裂,再折纳秒 ns = cycles64 * 1e9 / 72e6(64 位中间量防溢出)。
 * 这是 stamp_mono_ns 的唯一来源;单调不倒退(含 >60s 静默后恢复),禁用任何 wall clock。
 *
 * 【🔒 调用上下文硬契约(gill+Codex 重审,安全关键,务必遵守)】
 *   只能从优先级数值 >= configMAX_SYSCALL_INTERRUPT_PRIORITY(=5)的上下文调用——即
 *   FreeRTOS 任务,或被 FreeRTOS 临界区(BASEPRI=5)屏蔽的 ISR。**严禁从优先级数值 <5 的
 *   裸 ISR 调用**(如直配的高优编码器/急停 EXTI)。
 *   原因:tick 钩子(在 SysTick ISR 的 BASEPRI=5 临界区内跑)更新 (hi, last) 时有「hi++ 已做、
 *   last= 未做」的瞬态;若一个 prio<5 的 ISR 在此瞬态抢占并调 dwt_now_ns,会读到 hi 新/last 旧,
 *   触发一次误补偿 → 返回值 +2^32(≈59.65s)跳变,随后正常调用又倒退。无锁读序的原子性
 *   来自「读者优先级 >= SysTick 屏蔽级」这一外部配置,**不是代码自证**。当前固件满足
 *   (唯一调用点在 micro-ROS 任务上下文;USART/DMA 中断 = 优先级 6 >= 5,被屏蔽)。
 *   若未来移动调用点或改中断优先级,必须重新核对此契约,否则倒退 High 会无声复活。
 *   彻底消除该外部依赖的加固方向(非阻断,见 dwt_time.c TODO):tick 钩子改单次原子发布
 *   (64 位基准一次写 / seqlock 偶奇序号),使单调性内生于代码、与中断优先级配置无关。 */
uint64_t dwt_now_ns(void);

#ifdef __cplusplus
}
#endif

#endif /* DWT_TIME_H */
