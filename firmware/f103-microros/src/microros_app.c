/* microros_app.c — micro-ROS rclc 双向应用(节点 exo_mcu) (T5b / 里程碑 M3)
 *
 * 契约 §1 最小双向闭环(01-接口契约.md v1.5):
 *   sub /exo/cmd_heartbeat (std_msgs/Int32, RELIABLE, KEEP_LAST, F103 侧 depth=1)
 *     → ON_NEW_DATA 回调里 status.data = cmd.data → pub /exo/mcu_status(同 QoS)。
 *   节点名 exo_mcu(§5),响应式回发(每收一条回一条,§1.2)。
 *
 * 【内存哲学(F103 仅 20KB SRAM,项目最大风险 R1)】
 *   - 全部 rclc/rcl 句柄、support、allocator、executor 句柄、消息体均为 .bss 静态对象,
 *     无动态分配(rclc 句柄结构体本身静态;rcl 内部对象由 libmicroros 的静态池分配,
 *     由 colcon.meta 的 RMW_UXRCE_MAX_* / UCLIENT_MAX_* = 1 限定上界)。
 *   - executor handle 数 = 1(只有 1 个 subscription),静态数组,见 EXECUTOR_HANDLES。
 *   - 消息体:1 个 sub 消息 + 1 个 pub 消息,各 std_msgs__msg__Int32(= 1×int32 = 4B)。
 *   - 句柄/内存预算估算见本文件末尾大注释与最终交付说明。
 *
 * 【gill 发现 #1(settled_window / 重传区分)定位说明】
 *   05 文档 T5b 提到的「settled_window 区分 never-sent 真错 vs stale-retransmit 超窗重传」
 *   是 **WSL 侧 exo_cmd 监控逻辑**(7.5 重复 echo 语义、7.8 A5/A6),用来在 RELIABLE 重传
 *   导致同值 echo 多次到达时不误报 UNMATCHED。**固件侧不参与该判定**:固件只需
 *   ① 用 RELIABLE QoS(保证重传机制本身在),② 原样回填(值正确)。重传是 DDS/Agent
 *   层行为,MCU 应用对此无感。故本文件不实现 settled_window,只确保 QoS=RELIABLE
 *   且回填精确,把「重传区分」的全部责任留在 WSL 侧——这是契约的正确分层。
 *
 * 【依赖 libmicroros —— include/link 占位,见文件末尾与 CMakeLists [MICROROS-*] 标记】
 *   用 __has_include 守卫:lib 未就位时编译占位(任务停在自检失败,暴露而非静默),
 *   主 agent 把 include 接好后真实实现自动生效。与 microros_transport.c 同策略。
 */

#include "microros_app.h"
#include "microros_transport.h"

#include "FreeRTOS.h"
#include "task.h"

/* ===== 是否拿到 micro-ROS 头(lib 已生成) ===== */
#if defined(__has_include)
#  if __has_include(<rclc/rclc.h>) && \
      __has_include(<rclc/executor.h>) && \
      __has_include(<std_msgs/msg/int32.h>)
#    define MICROROS_HEADERS_AVAILABLE 1
#  endif
#endif

#ifdef MICROROS_HEADERS_AVAILABLE
/* ====================== 真实实现(lib 就位后编译) ====================== */

#include <rcl/rcl.h>
#include <rcl/error_handling.h>
#include <rclc/rclc.h>
#include <rclc/executor.h>
#include <rmw_microros/rmw_microros.h>
#include <std_msgs/msg/int32.h>

/* 主 agent 用 USART1 自检串观察 micro-ROS 进度;复用 main.c 的阻塞 puts。
 * 注:micro-ROS 建链后,该串口同时被 XRCE 占用——自检串只在「未建链/建链失败」
 * 阶段打,建链成功后交给 micro-ROS,避免与 XRCE 帧交织。见各 RCCHECK 用法。 */
extern void uart_puts(const char *s);

/* ===== 静态句柄(全部 .bss,无动态分配) ===== */
static rcl_allocator_t      g_allocator;          /* micro-ROS 默认 allocator(内部走静态池) */
static rclc_support_t       g_support;            /* support(含 rcl context / init options) */
static rcl_node_t           g_node;               /* 节点 exo_mcu */
static rcl_publisher_t      g_pub_status;         /* /exo/mcu_status */
static rcl_subscription_t   g_sub_cmd;            /* /exo/cmd_heartbeat */
static rclc_executor_t      g_executor;           /* 单线程 executor */

/* 消息体:sub 收的 cmd、pub 发的 status,各一个 int32(4B)。静态。 */
static std_msgs__msg__Int32 g_msg_cmd;            /* 订阅回调写入 */
static std_msgs__msg__Int32 g_msg_status;         /* 回填后发布 */

/* executor 句柄数 = 1(只有 1 个 subscription)。rclc_executor 需要这个上界。 */
#define EXECUTOR_HANDLES  1u

/* 自检/错误处理宏:出错就把当前任务停在死循环(暴露,不静默继续)。
 * 注:micro-ROS 在 20KB 上不宜做复杂错误恢复;最小闭环里「初始化失败」= 配置/内存问题,
 *     必须显式停住让主 agent 在 agent -v6 日志侧看到 client 未上线,据此排障。 */
#define RCCHECK(fn)            \
    do {                      \
        rcl_ret_t _rc = (fn); \
        if (_rc != RCL_RET_OK) { fail_stop(); } \
    } while (0)

/* 软失败:不死,返回让外层重连(用于 spin/建链这类可重试路径)。 */
#define RCSOFT(fn) ((fn) == RCL_RET_OK)

static void fail_stop(void)
{
    /* 初始化级硬错:停住。LED 可继续被其它机制翻转与否不重要,关键是 client 不上线
     * → agent 日志侧可见,暴露问题(符合「不静默掩盖」哲学)。 */
    for (;;) { vTaskDelay(pdMS_TO_TICKS(1000)); }
}

/* ===== 订阅回调:收到 cmd_heartbeat → 原样回填 → 发布 mcu_status ===== */
/* ON_NEW_DATA 触发:msgin 指向 g_msg_cmd。把值原样搬到 status 并立即 publish。
 * 这就是契约 §1.2 的「响应式回发 + 原样回填」回环语义。 */
static void cmd_heartbeat_callback(const void *msgin)
{
    const std_msgs__msg__Int32 *m = (const std_msgs__msg__Int32 *)msgin;

    g_msg_status.data = m->data;   /* ★原样回填:回环校验的核心(§1.2 语义) */

    /* 发布回 mcu_status。RELIABLE 下 rcl_publish 把消息交给 XRCE reliable stream;
     * 失败不致命(下一拍心跳还会来),故用软检查,不 fail_stop。 */
    (void)rcl_publish(&g_pub_status, &g_msg_status, NULL);
}

/* ===== 建立 micro-ROS 实体(节点/pub/sub/executor),RELIABLE QoS ===== */
/* 返回 true 表示全部实体创建成功、executor 就绪。任何一步失败 → false,外层重连。 */
static bool microros_entities_init(void)
{
    g_allocator = rcl_get_default_allocator();

    /* support:建立 rcl context(含与 agent 的 session)。
     * 注:此处依赖 transport 已注册(microros_app_task 里先注册再 init)。 */
    if (!RCSOFT(rclc_support_init(&g_support, 0, (const char *const *)0, &g_allocator))) {
        return false;
    }

    /* 节点 exo_mcu,默认命名空间。topic 名带 /exo/ 前缀由下面 topic 字符串给全。
     * 注:契约 §5 节点名 = exo_mcu;命名空间留空("")避免与 /exo/ topic 前缀重复。 */
    if (!RCSOFT(rclc_node_init_default(&g_node, "exo_mcu", "", &g_support))) {
        return false;
    }

    /* publisher /exo/mcu_status,RELIABLE QoS。
     * ⚠️ micro-ROS 默认 best-effort,契约 §1.2 要求 RELIABLE,必须显式用 _init
     *    传 qos_profile_default(rmw 默认 = RELIABLE/KEEP_LAST)。History depth 由
     *    colcon.meta 的 RMW_UXRCE_MAX_HISTORY=1 在 lib 层钉死为 1(契约 F103 侧 depth=1)。
     * 用 rosidl 的 Int32 type support。 */
    if (!RCSOFT(rclc_publisher_init_default(
            &g_pub_status,
            &g_node,
            ROSIDL_GET_MSG_TYPE_SUPPORT(std_msgs, msg, Int32),
            "exo/mcu_status"))) {   /* rclc 会补成 /exo/mcu_status(默认命名空间下绝对化) */
        return false;
    }

    /* subscription /exo/cmd_heartbeat,RELIABLE QoS(同上,_init_default = reliable)。 */
    if (!RCSOFT(rclc_subscription_init_default(
            &g_sub_cmd,
            &g_node,
            ROSIDL_GET_MSG_TYPE_SUPPORT(std_msgs, msg, Int32),
            "exo/cmd_heartbeat"))) {
        return false;
    }

    /* executor:1 个句柄(只挂 1 个 subscription)。 */
    g_executor = rclc_executor_get_zero_initialized_executor();
    if (!RCSOFT(rclc_executor_init(&g_executor, &g_support.context,
                                   EXECUTOR_HANDLES, &g_allocator))) {
        return false;
    }

    /* 把 subscription 加进 executor,ON_NEW_DATA 触发回调,回调读到 g_msg_cmd。 */
    if (!RCSOFT(rclc_executor_add_subscription(
            &g_executor, &g_sub_cmd, &g_msg_cmd,
            &cmd_heartbeat_callback, ON_NEW_DATA))) {
        return false;
    }

    return true;
}

/* ===== 销毁实体(断链重连时清理,避免句柄泄漏到下一次 init) ===== */
static void microros_entities_fini(void)
{
    /* 逆序销毁。fini 失败不致命(本就在清理重连路径),忽略返回值。 */
    rcl_publisher_fini(&g_pub_status, &g_node);
    rcl_subscription_fini(&g_sub_cmd, &g_node);
    rclc_executor_fini(&g_executor);
    rcl_node_fini(&g_node);
    rclc_support_fini(&g_support);
}

/* ===== micro-ROS 应用任务主体 ===== */
void microros_app_task(void *arg)
{
    (void)arg;

    /* 1. 注册自定义串口 transport(USART1+DMA)。注册失败 = 配置错,硬停暴露。 */
    if (!microros_transport_register()) {
        uart_puts("\r\n[F103-T5] FATAL: custom transport register failed\r\n");
        fail_stop();
    }

    /* 自检初值:status 从 -1 起,首次回填后变成首条 cmd 值,便于区分「未收到任何 cmd」。 */
    g_msg_status.data = -1;
    g_msg_cmd.data    = 0;

    /* 2. 外层重连循环:等 agent 在线 → 建实体 → spin → 断链则清理重连。 */
    for (;;) {
        /* 等待与 agent 建链(ping)。超时则重试,不卡死。
         * rmw_uros_ping_agent(timeout_ms, attempts):每次 100ms,1 次。 */
        if (rmw_uros_ping_agent(100, 1) != RMW_RET_OK) {
            vTaskDelay(pdMS_TO_TICKS(200));   /* agent 未上线,200ms 后再 ping */
            continue;
        }

        /* agent 在线 → 建立全部实体。失败则清理后重来。 */
        if (!microros_entities_init()) {
            microros_entities_fini();
            vTaskDelay(pdMS_TO_TICKS(500));
            continue;
        }

        /* 3. spin:周期性处理 executor(收 cmd → 触发回调 → 回填 publish)。
         *    每轮 spin_some 处理已到数据,期间定期 ping 检测 agent 是否掉线。 */
        uint32_t miss = 0;
        for (;;) {
            /* spin_some 超时 10ms:足够覆盖 10Hz 心跳(周期 100ms),CPU 占用低。 */
            (void)rclc_executor_spin_some(&g_executor, RCL_MS_TO_NS(10));

            /* 每 ~1s ping 一次 agent;连续多次失败判定掉线,跳出去重连。 */
            if (++miss >= 100u) {     /* 100 × ~10ms ≈ 1s */
                miss = 0;
                if (rmw_uros_ping_agent(50, 2) != RMW_RET_OK) {
                    break;            /* agent 掉线 → 清理重连 */
                }
            }
            vTaskDelay(pdMS_TO_TICKS(2));   /* 让出 CPU 给 LED/其它任务 */
        }

        /* 断链:清理实体,回到外层重新等 agent。 */
        microros_entities_fini();
    }
}

#else  /* !MICROROS_HEADERS_AVAILABLE */
/* ====================== 占位实现(lib 未就位时,让 main.c 仍可编) ====================== */

#include "uart_ll.h"   /* 仅占位分支用不到,但保持与真实分支同样可链接 */

extern void uart_puts(const char *s);

/* lib 未集成:任务起来就报缺 lib 并停住(暴露,不静默继续)。
 * 主 agent 接好 include 后,__has_include 命中,上面真实实现生效。 */
void microros_app_task(void *arg)
{
    (void)arg;
    for (;;) {
        uart_puts("\r\n[F103-T5] micro-ROS lib NOT linked (placeholder build)\r\n");
        vTaskDelay(pdMS_TO_TICKS(2000));
    }
}

#endif /* MICROROS_HEADERS_AVAILABLE */

/* ============================================================================
 * 【内存 / 句柄预算(交付说明,供主 agent T8 量化对照)】
 *
 * rclc/rcl 静态句柄(.bss,本文件持有):
 *   rcl_allocator_t       g_allocator      —— 几个函数指针,~16–32B
 *   rclc_support_t        g_support        —— 含 rcl context / init options 指针,~数十 B
 *   rcl_node_t            g_node           —— 句柄壳,内部 impl 指针指向 libmicroros 静态池
 *   rcl_publisher_t       g_pub_status     —— 同上
 *   rcl_subscription_t    g_sub_cmd        —— 同上
 *   rclc_executor_t       g_executor       —— 含 handle 数组指针(EXECUTOR_HANDLES=1)
 *   std_msgs__msg__Int32  g_msg_cmd        —— 4B
 *   std_msgs__msg__Int32  g_msg_status     —— 4B
 *   本文件 .bss 直接占用:约 0.2–0.4 KB(句柄壳),真正大头在 libmicroros 的静态池。
 *
 * libmicroros 静态池(由 colcon.meta 钉死上界,非本文件分配):
 *   RMW_UXRCE_MAX_NODES/PUBLISHERS/SUBSCRIPTIONS = 1/1/1,MAX_HISTORY=1,
 *   MAX_SESSIONS=1,UCLIENT 输入/输出各 1 条 reliable stream,MTU=128。
 *   → 这些决定了 rmw/xrce 的 RAM 占用上界,是 20KB go/no-go 的真正变量,由 T8 用 .map 实测。
 *
 * 串口 transport buffer(在 main.c .bss,非本文件):
 *   RX circular 256B + TX 单缓冲 128B + app_ring 256B ≈ 640B(契约 §3 / README 预算)。
 *
 * 任务栈(main.c 给 microros 任务分配):micro-ROS 调用栈较深(rcl→rmw→xrce),
 *   05 文档 T8 建议起测 ~2500 words,用 uxTaskGetStackHighWaterMark 收敛。见 main.c。
 * ============================================================================ */
