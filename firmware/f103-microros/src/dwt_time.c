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

/* ===== 64 位回绕扩展状态(全部 .bss 静态,无动态分配) ===== */
/* g_dwt_cyccnt_hi:CYCCNT 已回绕的次数(= 64 位 cycle 计数的高 32 位)。
 *   仅由 tick 钩子(单写者)写;dwt_now_ns 读。volatile 防优化,跨上下文(ISR/任务)可见。 */
static volatile uint32_t g_dwt_cyccnt_hi = 0u;

/* g_dwt_last_cyccnt:上一个 tick 采样到的 CYCCNT 低 32 位。
 *   tick 钩子用它检测「本次 tick < 上次 tick ⇒ 回绕」;
 *   dwt_now_ns 也读它,作为「自上次 tick 以来是否已回绕」的读取点补偿基准
 *   (见 dwt_now_ns 内的滞后窗口补偿)。tick 钩子是唯一写者。 */
static volatile uint32_t g_dwt_last_cyccnt = 0u;

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

    g_dwt_cyccnt_hi   = 0u;
    g_dwt_last_cyccnt = DWT->CYCCNT;

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
     * g_dwt_cyccnt_hi / g_dwt_last_cyccnt 的**唯一写者**——单写者免锁。
     *
     * 回绕检测:1ms 内 CYCCNT 至多走 72000 cycle,绝无可能回绕(回绕需 2^32≈4.29e9 cycle)。
     * 故相邻两 tick 间「本次 < 上次」当且仅当恰好跨过一次 32 位回绕 → 高位 +1。
     * 因 tick 周期(1ms)<< 回绕周期(59.65s),两 tick 间最多回绕一次,绝不漏检(这正是 H3 要点)。 */
    if (!g_dwt_ready) {
        return;
    }
    /* 写入顺序(关键,dwt_now_ns 的读取点补偿依赖它):先把回绕计入 hi,再更新
     * 基准 last_cyccnt。这样在 ISR 执行到「hi 已 ++、last 未更新」的中间瞬间,
     * (hi, last) 短暂处于「hi 是回绕后的新值、last 仍是回绕前的旧大值」组合——
     * dwt_now_ns 若此刻读到它,会在「low(回绕后小值) < last(旧大值)」上再补一次 +1,
     * 造成 hi 多加一圈、stamp 大跳变。本顺序配合 dwt_now_ns 的 hi1==hi2 重读循环
     * (重读会发现 hi 已变、重来)消除该跳变;详细论证见 dwt_now_ns 注释 ④。 */
    uint32_t now = DWT->CYCCNT;
    if (now < g_dwt_last_cyccnt) {
        g_dwt_cyccnt_hi++;       /* 跨过一次 32 位回绕,先记 hi */
    }
    g_dwt_last_cyccnt = now;     /* 再更新基准 */
}

uint64_t dwt_now_ns(void)
{
    if (!g_dwt_ready) {
        return 0u;   /* 未初始化/CYCCNT 不可用:返回 0,不假装有时间(暴露) */
    }

    /* 无锁三读 + 读取点滞后补偿。读三个共享量:hi(tick 钩子维护的回绕计数)、
     * last(tick 钩子上次采样的 CYCCNT)、low(当前硬件 CYCCNT)。tick 钩子(SysTick ISR)
     * 是 (hi, last) 的唯一写者,可在任意指令边界抢占本函数。
     *
     * 两类要防的失效:
     *  (a) 撕裂:读 hi 与读 low 之间发生 tick 更新,组合出 hi/low 不一致的值;
     *  (b) 滞后窗口倒退(本次修复的 High):CYCCNT 硬件已回绕、但下一个 tick 还没把 hi+1
     *      的 <1ms 窗口内,直接 (hi<<32)|low 会用「旧 hi + 回绕后小 low」→ 比上次调用
     *      (旧 hi + 回绕前大 low)小约 2^32 cycle(~59.65s)→ stamp 倒退,违反 V5 严格单调。
     *
     * 读取序列(顺序固定):hi1 → last → low → hi2,要求 hi1==hi2 否则重读。
     *
     * 【load-bearing 前提(gill+Codex 重审,务必落档)】上面"hi1!=hi2 重读"能拦住一切
     * 改 hi 的 tick 抢占——这只在【读者不能抢占 SysTick tick 钩子】时成立。tick 钩子在
     * BASEPRI=5 临界区内更新 (hi,last),写序固定「先 hi++(仅回绕)、后 last=now」。若本函数
     * 被一个优先级数值 <5 的裸 ISR 调用,它能抢占到「hi 已++、last 未更新」瞬态:读到
     * hi1==hi2(新)但 last 旧大 → low<last 误补一圈 → +2^32 跳变后倒退。**故 dwt_now_ns
     * 只能从 prio>=configMAX_SYSCALL_INTERRUPT_PRIORITY(=5)的上下文调用**(契约见 dwt_time.h)。
     * 当前满足:唯一调用点在 micro-ROS 任务上下文,USART/DMA 中断=prio6>=5 被屏蔽。
     * 原子性来自该屏蔽级、非代码自证。
     * TODO(加固,非阻断):把 (hi,last) 改 seqlock(偶/奇序号)或 64 位基准单次原子发布,
     * 使读者无论优先级都不读半更新态,消除对中断优先级配置的隐式依赖。 */
    uint32_t hi1, last, low, hi2;
    do {
        hi1  = g_dwt_cyccnt_hi;    /* 1. 先读回绕计数 */
        last = g_dwt_last_cyccnt;  /* 2. 读 tick 基准(补偿用) */
        low  = DWT->CYCCNT;        /* 3. 读硬件低位 */
        hi2  = g_dwt_cyccnt_hi;    /* 4. 重读回绕计数 */
    } while (hi1 != hi2);

    /* 滞后窗口补偿:hi1==hi2 成立后,(hi1, last) 对应的是「截至某个 tick 的状态」。
     * 若 low < last,说明自那个 tick 采样后 CYCCNT 已越过一次 32 位回绕(low 归小)、
     * 而该回绕尚未被任何 tick 计入 hi → 本地补一圈。前提「两 tick 间最多回绕一次」
     * (1ms << 59.65s)保证最多补 1,不会漏补也不会多补。 */
    if (low < last) {
        hi1++;
    }
    uint64_t cycles64 = ((uint64_t)hi1 << 32) | (uint64_t)low;

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
 *    额外读 tick 钩子暴露的基准 g_dwt_last_cyccnt,若当前 low < last 即判定「自上次 tick 后
 *    已回绕但 hi 未记」,本地把 hi+1 再合成。前提「1ms << 59.65s ⇒ 两 tick 间最多回绕一次」
 *    保证补偿量恒为 +1。
 *
 * ③ 并发正确性论证(ISR 在任意点抢占都不产生倒退/跳变,交 gill 重审):
 *    设定:tick 钩子是 (hi,last) 唯一写者,写顺序固定为「先 hi++(仅回绕时)、后 last=now」;
 *    读者序列固定为 hi1 → last → low → hi2,hi1!=hi2 则整体重读。
 *
 *    先看 tick 钩子的一次执行对 (hi,last) 的影响,分两类:
 *      - 非回绕 tick:只写 last(now>=旧 last),hi 不变。last 单调增向 now 靠拢。
 *      - 回绕 tick:hi++ 然后 last 被写成回绕后的小值 now。两步之间存在「hi 已新、last 仍旧大」
 *        的瞬态。
 *
 *    对读者,把「重读循环采纳的那一遍」记为有效读,该遍内 hi 自始至终 == hi1(=hi2)。
 *    要证:补偿后的 cyc = ((hi1 + [low<last]) << 32) | low 不小于上一次调用的结果,且无 +2^32 跳变。
 *
 *    (i) 有效读期间无 tick 抢占:则 (hi1,last,low) 是某一时刻的真实快照。
 *        若期间未回绕 → low>=last,不补偿,cyc 正确。
 *        若 hi1 对应的最后一次 tick 之后 CYCCNT 已回绕 → low<last → 补 +1,恰好补上「硬件已绕、
 *        hi 未记」的那一圈 → cyc 等于真实 64 位 cycle。两种都精确,无偏小、无倒退。
 *
 *    (ii) 有效读期间发生了 tick 抢占:抢占改了 hi 或 last,可能撕裂 (hi1,last,low) 的自洽性。
 *        关键不变量:任何改变 hi 的 tick(回绕 tick)都会令 hi2 != hi1 → 该遍被丢弃重读。
 *        所以被采纳的有效读里,期间发生的 tick 只可能是「非回绕 tick(仅更新 last,不动 hi)」,
 *        且 hi1 自始 == 那遍里 g_dwt_cyccnt_hi 的全程值。于是读到的 last 必是某个「非回绕 tick
 *        写下的、与 hi1 同属一段未回绕区间内」的 CYCCNT 采样(旧 last 或抢占后的新 last 皆然)。
 *        判据 low<last 的语义因此化简为:「从该 last 基准时刻起、到读 low 的时刻,CYCCNT 是否越过
 *        一次回绕」——
 *          · 若期间硬件已回绕(low 归到比 last 小)→ 该回绕尚未被任何 tick 计入(否则 hi 会变、
 *            被 hi1!=hi2 拦掉)→ 补 +1 恰好补上,精确;
 *          · 若期间未回绕 → low>=last → 不补偿,精确。
 *        无论读到旧/新 last，判据都精确反映「自该基准以来是否回绕一次」，撕裂的 last 不诱发错补。
 *        唯一危险组合「last 是回绕 tick 写下的旧大值瞬态(hi 已 ++、last 未更新)」必伴随 hi 变化，
 *        被 hi1!=hi2 拦掉，不进入采纳遍。✓(此即 dwt_tick_update 必须「先 hi++、后写 last」的原因)
 *
 *    (iii) 跨调用单调:相邻两次 dwt_now_ns 调用,真实 64 位 cycle 只增;(i)(ii) 已证每次调用都
 *        返回「精确真值」或不补偿的精确真值(均等于真值,无 ±2^32 偏差)→ 后一次 >= 前一次。
 *        即:不再有「旧 hi+小 low」的滞后倒退,也不会因撕裂多补一圈而跳变 +59.65s。
 *
 *    结论:ISR 在读取序列任意指令边界抢占,采纳的结果要么精确、要么被重读循环丢弃,
 *    严格单调不倒退、无大跳变。无需关中断(单写者 + 重读 + 单向补偿)。
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
