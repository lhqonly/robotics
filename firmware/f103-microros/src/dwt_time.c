/* dwt_time.c — DWT CYCCNT 单调时钟源实现 (M-B / 任务 3,H3 硬约束)
 *
 * 见 dwt_time.h 头注释。核心:32 位 CYCCNT(~59.65s 回绕)→ 64 位单调纳秒,
 * 回绕扩展由 1kHz FreeRTOS tick 钩子维护(独立高频源,绝不靠读取点比较)。
 */

#include "dwt_time.h"

#include "stm32f1xx.h"   /* CoreDebug / DWT 寄存器定义(CMSIS Core for Cortex-M3) */

/* ===== 时钟常数 ===== */
#define DWT_CPU_HZ   72000000ULL   /* F103 SYSCLK = 72MHz(main.c Clock_Init 钉死) */
#define NS_PER_SEC   1000000000ULL

/* ===== 64 位回绕扩展状态(全部 .bss 静态,无动态分配) =====
 *
 * tick hook 是单写者,但读者可能来自任务或 ISR。为避免读到「hi 已更新、last
 * 仍是旧值」这种半更新组合,这里不用会自旋等待写者的 seqlock,而用双缓冲快照:
 *   1. writer 从当前 generation 指向的 active slot 读稳定快照;
 *   2. writer 把新 (hi,last) 写入 inactive slot;
 *   3. writer 最后用 32-bit generation 一次发布新 slot。
 *
 * 若高优先级 ISR 抢占 writer,它仍会读旧 generation 对应的完整 active slot,不会
 * 读到正在写的 inactive slot,也不会自旋等待被自己抢占的 writer。 */
static volatile uint32_t g_dwt_snapshot_hi[2] = {0u, 0u};
static volatile uint32_t g_dwt_snapshot_last[2] = {0u, 0u};
static volatile uint32_t g_dwt_snapshot_gen = 0u;

/* 是否已成功初始化(CYCCNT 在计数)。未初始化时 dwt_now_ns 返回 0(不假装有时间)。 */
static volatile int g_dwt_ready = 0;

int dwt_init(void)
{
    /* 1. 使能 trace(DWT/ITM 总开关)。不开则 CYCCNT 写不进、不计数。 */
    CoreDebug->DEMCR |= CoreDebug_DEMCR_TRCENA_Msk;

    /* 2. 清零并使能 cycle counter。 */
    DWT->CYCCNT = 0u;
    DWT->CTRL  |= DWT_CTRL_CYCCNTENA_Msk;

    /* 3. 校验 CYCCNT 真的在走(F103/M3 标配存在;极少数裁剪 part 不实现 → 兜底)。
     *    使能后读两次,若递增则确认 OK。这里不做精确延时,靠两次读之间的几条指令推进。 */
    uint32_t a = DWT->CYCCNT;
    (void)DWT->CYCCNT;        /* 制造几个 cycle 的间隔 */
    (void)DWT->CYCCNT;
    uint32_t b = DWT->CYCCNT;

    uint32_t now = DWT->CYCCNT;
    g_dwt_snapshot_hi[0] = 0u;
    g_dwt_snapshot_hi[1] = 0u;
    g_dwt_snapshot_last[0] = now;
    g_dwt_snapshot_last[1] = now;
    g_dwt_snapshot_gen = 0u;

    if (b != a) {
        g_dwt_ready = 1;
        return 1;            /* CYCCNT 在计数 */
    }
    /* CYCCNT 没动:该 part 不实现 CYCCNT。stamp 将恒返回 0(暴露,不静默降级到别的时钟)。 */
    g_dwt_ready = 0;
    return 0;
}

void dwt_tick_update(void)
{
    /* 由 vApplicationTickHook 每 1ms 调一次。tick 钩子在 SysTick ISR 上下文运行,是
     * DWT 扩展快照的**唯一写者**。
     *
     * 回绕检测:1ms 内 CYCCNT 至多走 72000 cycle,绝无可能回绕(回绕需 2^32≈4.29e9 cycle)。
     * 故相邻两 tick 间「本次 < 上次」当且仅当恰好跨过一次 32 位回绕 → 高位 +1。
     * 因 tick 周期(1ms)<< 回绕周期(59.65s),两 tick 间最多回绕一次,绝不漏检(这正是 H3 要点)。 */
    if (!g_dwt_ready) {
        return;
    }
    uint32_t gen = g_dwt_snapshot_gen;
    uint32_t active = gen & 1u;
    uint32_t hi = g_dwt_snapshot_hi[active];
    uint32_t last = g_dwt_snapshot_last[active];
    uint32_t now = DWT->CYCCNT;
    if (now < last) {
        hi++;       /* 跨过一次 32 位回绕 */
    }

    uint32_t next_gen = gen + 1u;
    uint32_t inactive = next_gen & 1u;
    g_dwt_snapshot_hi[inactive] = hi;
    g_dwt_snapshot_last[inactive] = now;
    __DMB();                    /* publish data before generation */
    g_dwt_snapshot_gen = next_gen;
}

uint64_t dwt_now_ns(void)
{
    if (!g_dwt_ready) {
        return 0u;   /* 未初始化/CYCCNT 不可用:返回 0,不假装有时间(暴露) */
    }

    /* 双缓冲快照 + 读取点滞后补偿。读三个量:hi(tick 钩子维护的回绕计数)、
     * last(tick 钩子上次采样的 CYCCNT)、low(当前硬件 CYCCNT)。tick 钩子(SysTick ISR)
     * 是 (hi,last) 快照的唯一写者,可在任意指令边界抢占本函数。
     *
     * 两类要防的失效:
     *  (a) 撕裂:读 hi/last 与读 low 之间发生 tick 更新,组合出不一致的值;
     *  (b) 滞后窗口倒退(本次修复的 High):CYCCNT 硬件已回绕、但下一个 tick 还没把 hi+1
     *      的 <1ms 窗口内,直接 (hi<<32)|low 会用「旧 hi + 回绕后小 low」→ 比上次调用
     *      (旧 hi + 回绕前大 low)小约 2^32 cycle(~59.65s)→ stamp 倒退,违反 V5 严格单调。
     *
     * 读取序列(顺序固定):gen1 → active snapshot → low → gen2,要求 gen1==gen2
     * 否则重读。writer 永远先写 inactive slot,最后发布 gen,所以读者即使抢占 writer
     * 也只会看到旧完整快照或新完整快照,不会看到半更新态。 */
    uint32_t gen1, gen2, slot, hi, last, low;
    do {
        gen1 = g_dwt_snapshot_gen;
        slot = gen1 & 1u;
        hi = g_dwt_snapshot_hi[slot];
        last = g_dwt_snapshot_last[slot];
        low = DWT->CYCCNT;
        __DMB();                  /* read data before confirming generation */
        gen2 = g_dwt_snapshot_gen;
    } while (gen1 != gen2);

    /* 滞后窗口补偿:gen1==gen2 成立后,(hi, last) 对应的是「截至某个 tick 的状态」。
     * 若 low < last,说明自那个 tick 采样后 CYCCNT 已越过一次 32 位回绕(low 归小)、
     * 而该回绕尚未被任何 tick 计入 hi → 本地补一圈。前提「两 tick 间最多回绕一次」
     * (1ms << 59.65s)保证最多补 1,不会漏补也不会多补。 */
    if (low < last) {
        hi++;
    }
    uint64_t cycles64 = ((uint64_t)hi << 32) | (uint64_t)low;

    /* 折纳秒:ns = cycles * 1e9 / 72e6。64 位中间量防溢出。
     * 注:cycles64 * 1e9 在极端大 cycles 下可能溢出 64 位(cycles > 1.8e10 即约 256s 后),
     * 故先约分:1e9/72e6 = 125/9(精确),ns = cycles * 125 / 9。
     *   cycles * 125 在 cycles < 2^64/125 ≈ 1.47e17(≈ 65 年 @72MHz)内不溢出 64 位 → 服役期安全。
     * 这比直接 *1e9 的溢出阈值(256s)大 8 个量级,是裸机长跑必须的约分。
     * 软件 64 位乘除(M3 无 FPU,但整数乘除是软件库,合规;无浮点)。 */
    return (cycles64 * 125ULL) / 9ULL;
}

/* ============================================================================
 * 【交付给 Gill 的实现说明(对应 09 任务 3 / 11 之 H3 / 10 卡 V5)】
 *
 * ① 回绕扩展高频源:复用 FreeRTOS 已有的 **1kHz SysTick**,经 vApplicationTickHook
 *    (main.c)每 1ms 调 dwt_tick_update()。周期 1ms 远 << CYCCNT 回绕周期 59.65s
 *    → 两 tick 间 CYCCNT 至多走 72000 cycle,绝无可能跨过一整圈 2^32,故「本次 < 上次」
 *    判回绕在 tick 粒度下无遗漏。**不依赖 dwt_now_ns 的调用频率**——即使链路断流、几分钟
 *    不收 cmd(不调 dwt_now_ns),tick 钩子仍每 1ms 推进 hi,回绕被如实累加,恢复后 stamp
 *    单调不倒退(H3 要根除的失效)。
 *
 * ② 读取点滞后窗口补偿(本轮修复的 High):tick 钩子维护 hi 的粒度是 1ms,故存在
 *    「CYCCNT 硬件已回绕、下一 tick 还没把 hi+1」的最长 1ms 窗口。窗口内若只用 (hi<<32)|low,
 *    会用旧 hi 配回绕后的小 low,得到比回绕前小约 2^32 cycle(~59.65s)的值 → stamp 倒退。
 *    10Hz 发包每个回绕点约 1% 命中,长跑跨多次回绕统计上必中。修复:dwt_now_ns 读取点
 *    额外读 tick 钩子发布快照里的 last 基准,若当前 low < last 即判定「自上次 tick 后
 *    已回绕但 hi 未记」,本地把 hi+1 再合成。前提「1ms << 59.65s ⇒ 两 tick 间最多回绕一次」
 *    保证补偿量恒为 +1。
 *
 * ③ 并发正确性论证(ISR 在任意点抢占都不产生倒退/跳变,交 gill 重审):
 *    设定:tick 钩子是快照唯一写者。writer 从当前 generation 指向的 active slot
 *    读取 (hi,last),计算新值,写入 inactive slot,最后发布 generation+1。读者序列固定为
 *    gen1 → snapshot[gen1&1] → low → gen2,gen1!=gen2 则整体重读。
 *
 *    (i) 读者抢占 writer 写 inactive slot 期间:published generation 尚未变化,读者仍从
 *        old active slot 读取完整旧快照。writer 的半更新数据位于 inactive slot,不可见。
 *
 *    (ii) writer 在读者读取期间完成发布:读者末尾 gen2 != gen1,丢弃本遍并重读。
 *
 *    (iii) 读者在 writer 发布后运行:gen 指向新 active slot,读到完整新快照。
 *
 *    因此采纳遍必定使用一份完整 (hi,last) 快照。若当前 low < last,只表示自该完整
 *    tick 快照后硬件 CYCCNT 已回绕、但尚未被后续 tick 发布进 hi,本地补 +1 恰好补上。
 *    若 low >= last,未跨回绕,不补偿。前提「1ms << 59.65s」保证两 tick 间最多补一圈。
 *
 *    结论:读者不再依赖“不能抢占 SysTick hook”的外部优先级契约;即使高优先级 ISR
 *    抢占 writer,也只会读旧完整快照或新完整快照,不会读到 hi/last 半更新组合。
 *
 * ④ Gill 验收建议(对应 10 卡 V5):
 *    - 长跑:连续发包,echo 的 stamp_mono_ns 严格单调递增。
 *    - >60s 静默对抗:发几条 cmd → 停发 >60s(跨过一次 59.65s 回绕)→ 恢复发包,
 *      恢复后首条 stamp 必须 > 静默前最后一条 stamp(不倒退)。这条 bug 只有断流 >60s
 *      再恢复才暴露,持续发包长跑抓不到。
 *
 * ⑤ 假设/限制:① F103 @72MHz CYCCNT 标配可用(dwt_init 校验,不可用则 stamp 恒 0 暴露);
 *    ② 折算用整数约分 125/9(= 1e9/72e6 精确),无浮点,服役期(~65 年)内不溢出;
 *    ③ 绝对值跨端不可比(§D4 已接受),仅 MCU 侧相对时效。
 * ============================================================================ */
