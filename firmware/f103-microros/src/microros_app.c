/* microros_app.c — micro-ROS rclc 双向应用(节点 node_com_mcu) (M-B / exo_msgs 迁移)
 *
 * 契约 §1 双向闭环(01-接口契约.md v1.7,exo_msgs 载体;原 v1.5 std_msgs/Int32 已迁移):
 *   sub /com/tp_cmd_heartbeat (exo_msgs/ExoCmd, RELIABLE, KEEP_LAST, F103 侧 depth=1)
 *     → ON_NEW_DATA 回调里解包 ExoCmd → 回填 ExoStatus → pub /com/tp_mcu_status(同 QoS)。
 *   节点名 node_com_mcu(§5),响应式回发(每收一条回一条,§1.2)。
 *
 * 【M-B 回填语义(契约 §1.2 / 11 之 H1)】每收一条 ExoCmd:
 *   - header.seq           = 原样回填 cmd.header.seq(§7.6 seq 配对,精确相等)
 *   - payload              = bit-exact 原样回填 cmd.payload(H1:固件不做任何变换——
 *                            不缩放/不饱和/不翻字节序/不重解释,否则回环校验自身变伪故障源)
 *   - header.stamp_mono_ns = MCU 自己 DWT 单调时钟重盖(不回填 cmd 的 stamp;两端时钟不可比 §D4)
 *   - header.crc           = crc_enabled 时按 §7.9 对**回填后**(seq,MCU-stamp,payload)三元组
 *                            重算(crc 置 0 后),否则 0
 *   - (crc_enabled 且收到 cmd 带 crc 时)先校验 cmd.crc,mismatch → g_crc_mismatch_count++,
 *                            **不阻断**,仍回填回发(与 WSL §7.9 不阻断语义对齐)。
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
#include "dwt_time.h"   /* M-B 任务 3:DWT CYCCNT 单调时钟,stamp_mono_ns 来源 */
#include "exo_crc.h"    /* M-B 任务 4:应用级 CRC-32(§7.9),与 WSL zlib.crc32 逐字节对齐 */
#include "motor_control.h"  /* M2:latest target / safety core, vendor independent */

#include "stm32f1xx.h"
#include "FreeRTOS.h"
#include "task.h"

#include <stddef.h>
#include <stdint.h>

/* ===== CRC 自检开关(契约 §7.9,默认关,不阻断主链路) =====
 * 默认 0:发送侧 header.crc 置 0、收侧不校验。联调时改 1 端到端验字节序(WSL 侧
 * crc_mismatch_count 应恒 0)。这是编译期开关——改这里重新编译固件即可切换。
 * (任务卡 4:默认关,CRC 一致性作为联调时单独开启验证的独立项,不卡主链路。) */
#ifndef EXO_CRC_ENABLED
#  define EXO_CRC_ENABLED 0
#endif

#ifndef EXO_QOS_BEST_EFFORT
#  define EXO_QOS_BEST_EFFORT 0
#endif

#ifndef EXO_MOTOR_ROS_ENTITIES
#  define EXO_MOTOR_ROS_ENTITIES 0
#endif

#ifndef EXO_CONTROL_LOOP_HZ
#  define EXO_CONTROL_LOOP_HZ 1000u
#endif

#ifndef EXO_STATUS_EVERY_N
#  define EXO_STATUS_EVERY_N 1u
#endif

#ifndef EXO_EXECUTOR_SPIN_TIMEOUT_US
#  define EXO_EXECUTOR_SPIN_TIMEOUT_US 1000u
#endif

#ifndef EXO_MOTOR_STATE_PERIOD_MS
#  define EXO_MOTOR_STATE_PERIOD_MS 20u
#endif

#ifndef EXO_MOTOR_HEALTH_PERIOD_MS
#  define EXO_MOTOR_HEALTH_PERIOD_MS 200u
#endif

#if EXO_STATUS_EVERY_N < 1u
#  error "EXO_STATUS_EVERY_N must be >= 1"
#endif

#if EXO_EXECUTOR_SPIN_TIMEOUT_US < 1u
#  error "EXO_EXECUTOR_SPIN_TIMEOUT_US must be >= 1"
#endif

/* ===== MCU 本地控制基线 =====
 * 通信回调更新 latest target,本地控制 tick 读取最新目标。这里不驱动电机,只验证
 * "本地闭环频率"与"ROS 通信频率"解耦。>1kHz 时 TIM2 ISR 可设为高于 FreeRTOS
 * syscall critical section 的优先级,因此 target 用双缓冲+原子 active index 提交:
 * ISR 永远读 active buffer;任务只写 inactive buffer 后再切 active,避免半更新 seq/payload。 */
typedef struct {
    uint32_t seq;
    int32_t payload;
} control_target_t;

static volatile control_target_t g_control_targets[2];
static volatile uint32_t g_control_target_active = 0u;
static volatile uint32_t g_control_latest_seq = 0u;       /* SWD/debug mirror */
static volatile int32_t  g_control_latest_payload = 0;    /* SWD/debug mirror */
static volatile uint32_t g_control_tick_count = 0u;

static void com_control_update_target(uint32_t seq, int32_t payload)
{
    uint32_t next = (g_control_target_active ^ 1u) & 1u;

    g_control_targets[next].payload = payload;
    g_control_targets[next].seq = seq;
    g_control_target_active = next;

    /* Mirrors are for coarse SWD/debug observation only. The control ISR reads
     * the double-buffered active target above. */
    g_control_latest_seq = seq;
    g_control_latest_payload = payload;
}

void com_control_task(void *arg)
{
    (void)arg;
    TickType_t last = xTaskGetTickCount();
    const TickType_t period = pdMS_TO_TICKS(
        (1000u + EXO_CONTROL_LOOP_HZ - 1u) / EXO_CONTROL_LOOP_HZ);

    for (;;) {
        vTaskDelayUntil(&last, period);
        com_control_tick_isr();
    }
}

void com_control_tick_isr(void)
{
    uint32_t active = g_control_target_active & 1u;
    uint32_t seq = g_control_targets[active].seq;
    int32_t payload = g_control_targets[active].payload;

    /* Phase baseline: consume latest target without motor output. */
    (void)seq;
    (void)payload;
    g_control_tick_count++;
    motor_control_tick();
}

uint32_t com_control_tick_count(void)
{
    return g_control_tick_count;
}

uint32_t com_control_latest_seq(void)
{
    uint32_t active = g_control_target_active & 1u;
    return g_control_targets[active].seq;
}

/* ===== 是否拿到 micro-ROS 头(lib 已生成) ===== */
/* M-B:守卫从 std_msgs/Int32 换成 exo_msgs 生成头(保留「lib 未就位编占位」策略)。
 * 生成头名以任务 1 重建 libmicroros 产物为准,rosidl 约定 = 蛇形:exo_msgs/msg/exo_cmd.h。 */
#if defined(__has_include)
#  if __has_include(<rclc/rclc.h>) && \
      __has_include(<rclc/executor.h>) && \
      __has_include(<exo_msgs/msg/exo_cmd.h>) && \
      __has_include(<exo_msgs/msg/exo_status.h>)
#    define MICROROS_HEADERS_AVAILABLE 1
#  endif
#endif

#ifdef MICROROS_HEADERS_AVAILABLE
#if EXO_MOTOR_ROS_ENTITIES
#  if defined(__has_include)
#    if !__has_include(<exo_motor_msgs/msg/joint_target.h>) || \
        !__has_include(<exo_motor_msgs/msg/joint_state.h>) || \
        !__has_include(<exo_motor_msgs/msg/motor_health.h>)
#      error "EXO_MOTOR_ROS_ENTITIES requires generated exo_motor_msgs headers"
#    endif
#  endif
#endif
/* ====================== 真实实现(lib 就位后编译) ====================== */

#include <rcl/rcl.h>
#include <rcl/error_handling.h>
#include <rclc/rclc.h>
#include <rclc/executor.h>
#include <rmw_microros/rmw_microros.h>
#include <exo_msgs/msg/exo_cmd.h>
#include <exo_msgs/msg/exo_status.h>
#if EXO_MOTOR_ROS_ENTITIES
#include <rmw_microxrcedds_c/config.h>
#include <exo_motor_msgs/msg/joint_target.h>
#include <exo_motor_msgs/msg/joint_state.h>
#include <exo_motor_msgs/msg/motor_health.h>
#endif

/* 主 agent 用 USART1 自检串观察 micro-ROS 进度;复用 main.c 的阻塞 puts。
 * 注:micro-ROS 建链后,该串口同时被 XRCE 占用——自检串只在「未建链/建链失败」
 * 阶段打,建链成功后交给 micro-ROS,避免与 XRCE 帧交织。见各 RCCHECK 用法。 */
extern void uart_puts(const char *s);

/* ===== 静态句柄(全部 .bss,无动态分配) ===== */
static rcl_allocator_t      g_allocator;          /* micro-ROS 默认 allocator(内部走静态池) */
static rclc_support_t       g_support;            /* support(含 rcl context / init options) */
static rcl_node_t           g_node;               /* 节点 node_com_mcu */
static rcl_publisher_t      g_pub_status;         /* /com/tp_mcu_status */
#if EXO_MOTOR_ROS_ENTITIES
static rcl_publisher_t      g_pub_joint_state;    /* /motor/tp_joint_state */
static rcl_publisher_t      g_pub_motor_health;   /* /motor/tp_motor_health */
#endif
static rcl_subscription_t   g_sub_cmd;            /* /com/tp_cmd_heartbeat */
#if EXO_MOTOR_ROS_ENTITIES
static rcl_subscription_t   g_sub_joint_target;   /* /motor/tp_joint_target */
#endif
static rclc_executor_t      g_executor;           /* 单线程 executor */

/* 消息体:sub 收的 ExoCmd、pub 发的 ExoStatus,各一个(header 16B + payload 4B = 20B)。静态。 */
static exo_msgs__msg__ExoCmd    g_msg_cmd;         /* 订阅回调写入 */
static exo_msgs__msg__ExoStatus g_msg_status;      /* 回填后发布 */
#if EXO_MOTOR_ROS_ENTITIES
static exo_motor_msgs__msg__JointTarget g_msg_joint_target;
static exo_motor_msgs__msg__JointState  g_msg_joint_state;
static exo_motor_msgs__msg__MotorHealth g_msg_motor_health;
#endif
static uint32_t g_cmd_rx_count = 0u;                /* 收到的 PC 命令计数,用于状态降频 */

#if EXO_MOTOR_ROS_ENTITIES
#  ifndef EXO_MOTOR_FRAME_ID_RX_CAPACITY
#    define EXO_MOTOR_FRAME_ID_RX_CAPACITY RMW_UXRCE_MAX_INPUT_BUFFER_SIZE
#  endif
#  if EXO_MOTOR_FRAME_ID_RX_CAPACITY < 1u
#    error "EXO_MOTOR_FRAME_ID_RX_CAPACITY must be >= 1"
#  endif
static char g_joint_target_frame_id[EXO_MOTOR_FRAME_ID_RX_CAPACITY] = "";
static char g_joint_state_frame_id[1] = "";
static char g_motor_health_frame_id[1] = "";
#endif

/* CRC 自检失败计数(§7.9,crc_enabled 时收到 cmd 的 crc 与重算不符则 +1,不阻断)。
 * volatile + used:保留为可观测探针(调试器/将来诊断 topic 可读),不让编译器优化掉。 */
static volatile uint32_t g_crc_mismatch_count __attribute__((used)) = 0u;

/* executor 句柄数:默认只启用 /com heartbeat;M2 实体实验打开后再加 /motor target。 */
#if EXO_MOTOR_ROS_ENTITIES
#  define EXECUTOR_HANDLES  2u
#else
#  define EXECUTOR_HANDLES  1u
#endif

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

static void ignore_rcl_ret(rcl_ret_t rc)
{
    (void)rc;
}

static void fail_stop(void)
{
    /* 初始化级硬错:停住。LED 可继续被其它机制翻转与否不重要,关键是 client 不上线
     * → agent 日志侧可见,暴露问题(符合「不静默掩盖」哲学)。 */
    for (;;) { vTaskDelay(pdMS_TO_TICKS(1000)); }
}

#if EXO_MOTOR_ROS_ENTITIES
static void bind_frame_id_storage(rosidl_runtime_c__String *frame_id,
                                  char *storage,
                                  size_t capacity)
{
    storage[0] = '\0';
    frame_id->data = storage;
    frame_id->size = 0u;
    frame_id->capacity = capacity;
}

static bool double_to_milli(double value, int32_t *out)
{
    if (out == NULL || value != value) {
        return false;
    }

    double scaled = value * 1000.0;
    if (scaled > 2147483647.0) {
        *out = INT32_MAX;
        return true;
    }
    if (scaled < -2147483648.0) {
        *out = INT32_MIN;
        return true;
    }
    *out = (int32_t)scaled;
    return true;
}

static double milli_to_double(int32_t value)
{
    return ((double)value) / 1000.0;
}

static void set_header_stamp_from_ns(std_msgs__msg__Header *header, uint64_t stamp_ns)
{
    header->stamp.sec = (int32_t)(stamp_ns / 1000000000ull);
    header->stamp.nanosec = (uint32_t)(stamp_ns % 1000000000ull);
}

static void snapshot_motor_state(motor_control_state_t *state)
{
    uint32_t primask = __get_PRIMASK();
    __disable_irq();
    motor_control_get_state(state);
    __set_PRIMASK(primask);
}

static void snapshot_motor_health(motor_control_health_t *health)
{
    uint32_t primask = __get_PRIMASK();
    __disable_irq();
    motor_control_get_health(health);
    __set_PRIMASK(primask);
}

static void motor_joint_target_callback(const void *msgin)
{
    const exo_motor_msgs__msg__JointTarget *m =
        (const exo_motor_msgs__msg__JointTarget *)msgin;

    /* M2 keeps std_msgs/Header only as host-side metadata. On F103 we only
     * support empty frame_id. The receive buffer is sized to the XRCE input
     * stream so non-empty frame_id values that fit on the wire are visible
     * here and rejected instead of being silently skipped by generated code. */
    if (m->header.frame_id.size != 0u) {
        return;
    }

    int32_t position_mrad = 0;
    int32_t velocity_mrad_s = 0;
    int32_t torque_mnm = 0;
    int32_t kp_mnm_per_rad = 0;
    int32_t kd_mnm_s_per_rad = 0;
    int32_t max_torque_mnm = 0;
    int32_t max_velocity_mrad_s = 0;
    int32_t max_position_mrad = 0;
    int32_t min_position_mrad = 0;

    if (!double_to_milli(m->position_rad, &position_mrad) ||
        !double_to_milli(m->velocity_rad_s, &velocity_mrad_s) ||
        !double_to_milli(m->torque_nm, &torque_mnm) ||
        !double_to_milli(m->kp_nm_per_rad, &kp_mnm_per_rad) ||
        !double_to_milli(m->kd_nm_s_per_rad, &kd_mnm_s_per_rad) ||
        !double_to_milli(m->max_torque_nm, &max_torque_mnm) ||
        !double_to_milli(m->max_velocity_rad_s, &max_velocity_mrad_s) ||
        !double_to_milli(m->max_position_rad, &max_position_mrad) ||
        !double_to_milli(m->min_position_rad, &min_position_mrad)) {
        return;
    }

    motor_control_target_t target = {0};
    target.seq = m->seq;
    target.joint_id = m->joint_id;
    target.control_mode = m->control_mode;
    target.position_mrad = position_mrad;
    target.velocity_mrad_s = velocity_mrad_s;
    target.torque_mnm = torque_mnm;
    target.kp_mnm_per_rad = kp_mnm_per_rad;
    target.kd_mnm_s_per_rad = kd_mnm_s_per_rad;
    target.max_torque_mnm = max_torque_mnm;
    target.max_velocity_mrad_s = max_velocity_mrad_s;
    target.max_position_mrad = max_position_mrad;
    target.min_position_mrad = min_position_mrad;
    target.ttl_us = m->ttl_us;
    target.flags = m->flags;

    motor_control_submit_target(&target);
}

static void publish_motor_state(void)
{
    motor_control_state_t state;

    snapshot_motor_state(&state);

    uint64_t stamp_ns = dwt_now_ns();
    set_header_stamp_from_ns(&g_msg_joint_state.header, stamp_ns);
    bind_frame_id_storage(&g_msg_joint_state.header.frame_id,
                          g_joint_state_frame_id,
                          sizeof(g_joint_state_frame_id));
    g_msg_joint_state.seq = state.seq;
    g_msg_joint_state.joint_id = state.joint_id;
    g_msg_joint_state.control_mode = state.control_mode;
    g_msg_joint_state.position_rad = milli_to_double(state.position_mrad);
    g_msg_joint_state.velocity_rad_s = milli_to_double(state.velocity_mrad_s);
    g_msg_joint_state.torque_est_nm = milli_to_double(state.torque_mnm);
    g_msg_joint_state.current_a = 0.0;
    g_msg_joint_state.bus_voltage_v = 0.0;
    g_msg_joint_state.temperature_c = 0.0;
    g_msg_joint_state.fault_bits = state.fault_bits;
    g_msg_joint_state.vendor_fault_bits = 0u;
    g_msg_joint_state.last_target_seq = state.last_target_seq;
    g_msg_joint_state.sample_age_us = state.sample_age_us;
    g_msg_joint_state.target_fresh = state.target_fresh;
    g_msg_joint_state.enabled = state.enabled;

    ignore_rcl_ret(rcl_publish(&g_pub_joint_state, &g_msg_joint_state, NULL));
}

static void publish_motor_health(void)
{
    motor_control_health_t health;

    snapshot_motor_health(&health);

    uint64_t stamp_ns = dwt_now_ns();
    set_header_stamp_from_ns(&g_msg_motor_health.header, stamp_ns);
    bind_frame_id_storage(&g_msg_motor_health.header.frame_id,
                          g_motor_health_frame_id,
                          sizeof(g_motor_health_frame_id));
    g_msg_motor_health.bus_id = 0u;
    g_msg_motor_health.joint_count = 1u;
    g_msg_motor_health.targets_received = health.targets_received;
    g_msg_motor_health.targets_applied = health.targets_applied;
    g_msg_motor_health.stale_targets = health.stale_ticks;
    g_msg_motor_health.motor_tx = 0u;
    g_msg_motor_health.motor_rx = 0u;
    g_msg_motor_health.motor_timeout = 0u;
    g_msg_motor_health.motor_fault = 0u;
    g_msg_motor_health.target_apply_latency_p99_ms = 0.0;
    g_msg_motor_health.can_gap_p99_ms = 0.0;
    g_msg_motor_health.reconciles = health.reconciles;

    ignore_rcl_ret(rcl_publish(&g_pub_motor_health, &g_msg_motor_health, NULL));
}
#endif

/* ===== 订阅回调:收到 ExoCmd → 解包 → 回填 ExoStatus → 发布 mcu_status ===== */
/* ON_NEW_DATA 触发:msgin 指向 g_msg_cmd。解包 cmd、按 §1.2/H1 回填 status、立即 publish。
 * 这就是契约 §1.2 的「响应式回发 + 信封回填」回环语义(exo_msgs 升级版)。 */
static void cmd_heartbeat_callback(const void *msgin)
{
    const exo_msgs__msg__ExoCmd *m = (const exo_msgs__msg__ExoCmd *)msgin;

#if EXO_CRC_ENABLED
    /* (可选)先校验收到的 cmd.header.crc(§7.9):置 0 重算比对,mismatch 计数但不阻断。
     * 校验覆盖 cmd 的 (seq, stamp, payload) 三元组——注意这是 cmd 自己的 stamp(发送方的),
     * 不是 MCU 的;校验时用收到的原值,避免 CRC 自指(用收到的 crc 与重算值比,不改 m)。 */
    {
        uint32_t calc = exo_crc_envelope(m->header.seq,
                                         m->header.stamp_mono_ns,
                                         m->payload);
        if (calc != m->header.crc) {
            g_crc_mismatch_count++;   /* 自检失败可观测,不丢帧、不阻断(§7.9) */
        }
    }
#endif

    /* ---- 回填 ExoStatus(§1.2 / H1)---- */
    g_cmd_rx_count++;
    g_msg_status.header.seq = m->header.seq;   /* 原样回填 seq(§7.6 配对,精确相等) */
    g_msg_status.payload    = m->payload;      /* ★bit-exact 原样回填 payload(H1:零变换) */
    com_control_update_target(m->header.seq, m->payload);

    /* stamp 用 MCU 自己的 DWT 单调时钟重盖(不回填 cmd 的 stamp;两端时钟不可比 §D4)。 */
    g_msg_status.header.stamp_mono_ns = dwt_now_ns();

#if EXO_CRC_ENABLED
    /* crc 按**回填后**的 (seq, MCU-stamp, payload) 三元组重算(H1:不是 cmd 的三元组,
     * 因为 stamp 已被 MCU 重盖)。exo_crc_envelope 内部按 §7.9 把 crc 视作 0、不入流。 */
    g_msg_status.header.crc = exo_crc_envelope(g_msg_status.header.seq,
                                               g_msg_status.header.stamp_mono_ns,
                                               g_msg_status.payload);
#else
    g_msg_status.header.crc = 0u;              /* crc 关:置 0,收侧不校验(§7.9) */
#endif

    /* 发布回 mcu_status。默认 EXO_STATUS_EVERY_N=1 保持每条命令回一次状态;
     * 压测/真实控制可设为 5/10:每条命令仍更新 latest target,但只按比例回状态,
     * 避免 PC 200Hz 目标下发被同频状态回传拖住串口 reliable stream。 */
    if ((g_cmd_rx_count % EXO_STATUS_EVERY_N) == 0u) {
        ignore_rcl_ret(rcl_publish(&g_pub_status, &g_msg_status, NULL));
    }
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

    /* 节点 node_com_mcu,默认命名空间。topic 名带 /com/ 前缀由下面 topic 字符串给全。
     * 注:契约 §5 节点名 = node_com_mcu;命名空间留空("")避免与 /com/ topic 前缀重复。 */
    if (!RCSOFT(rclc_node_init_default(&g_node, "node_com_mcu", "", &g_support))) {
        return false;
    }

    /* publisher /com/tp_mcu_status,RELIABLE QoS。
     * ⚠️ micro-ROS 默认 best-effort,契约 §1.2 要求 RELIABLE,必须显式用 _init
     *    传 qos_profile_default(rmw 默认 = RELIABLE/KEEP_LAST)。History depth 由
     *    colcon.meta 的 RMW_UXRCE_MAX_HISTORY=1 在 lib 层钉死为 1(契约 F103 侧 depth=1)。
     * 用 rosidl 的 exo_msgs/ExoStatus type support。 */
#if EXO_QOS_BEST_EFFORT
    if (!RCSOFT(rclc_publisher_init_best_effort(
            &g_pub_status,
            &g_node,
            ROSIDL_GET_MSG_TYPE_SUPPORT(exo_msgs, msg, ExoStatus),
            "com/tp_mcu_status"))) {
        return false;
    }
#else
    if (!RCSOFT(rclc_publisher_init_default(
            &g_pub_status,
            &g_node,
            ROSIDL_GET_MSG_TYPE_SUPPORT(exo_msgs, msg, ExoStatus),
            "com/tp_mcu_status"))) {   /* rclc 会补成 /com/tp_mcu_status(默认命名空间下绝对化) */
        return false;
    }
#endif

#if EXO_MOTOR_ROS_ENTITIES
    if (!RCSOFT(rclc_publisher_init_default(
            &g_pub_joint_state,
            &g_node,
            ROSIDL_GET_MSG_TYPE_SUPPORT(exo_motor_msgs, msg, JointState),
            "motor/tp_joint_state"))) {
        return false;
    }

    if (!RCSOFT(rclc_publisher_init_default(
            &g_pub_motor_health,
            &g_node,
            ROSIDL_GET_MSG_TYPE_SUPPORT(exo_motor_msgs, msg, MotorHealth),
            "motor/tp_motor_health"))) {
        return false;
    }
#endif

    /* subscription /com/tp_cmd_heartbeat,RELIABLE QoS(同上,_init_default = reliable)。
     * 用 rosidl 的 exo_msgs/ExoCmd type support。 */
#if EXO_QOS_BEST_EFFORT
    if (!RCSOFT(rclc_subscription_init_best_effort(
            &g_sub_cmd,
            &g_node,
            ROSIDL_GET_MSG_TYPE_SUPPORT(exo_msgs, msg, ExoCmd),
            "com/tp_cmd_heartbeat"))) {
        return false;
    }
#else
    if (!RCSOFT(rclc_subscription_init_default(
            &g_sub_cmd,
            &g_node,
            ROSIDL_GET_MSG_TYPE_SUPPORT(exo_msgs, msg, ExoCmd),
            "com/tp_cmd_heartbeat"))) {
        return false;
    }
#endif

#if EXO_MOTOR_ROS_ENTITIES
    /* /motor target 是 latest-target 输入:best-effort subscription 能兼容 reliable
     * publisher,也能兼容 PC high-rate best-effort publisher。 */
    if (!RCSOFT(rclc_subscription_init_best_effort(
            &g_sub_joint_target,
            &g_node,
            ROSIDL_GET_MSG_TYPE_SUPPORT(exo_motor_msgs, msg, JointTarget),
            "motor/tp_joint_target"))) {
        return false;
    }
#endif

    /* executor:2 个句柄(/com + /motor subscriptions)。 */
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

#if EXO_MOTOR_ROS_ENTITIES
    if (!RCSOFT(rclc_executor_add_subscription(
            &g_executor, &g_sub_joint_target, &g_msg_joint_target,
            &motor_joint_target_callback, ON_NEW_DATA))) {
        return false;
    }
#endif

    return true;
}

/* ===== 销毁实体(断链重连时清理,避免句柄泄漏到下一次 init) ===== */
static void microros_entities_fini(void)
{
    /* 逆序销毁。fini 失败不致命(本就在清理重连路径),忽略返回值。 */
    ignore_rcl_ret(rclc_executor_fini(&g_executor));
#if EXO_MOTOR_ROS_ENTITIES
    ignore_rcl_ret(rcl_subscription_fini(&g_sub_joint_target, &g_node));
    ignore_rcl_ret(rcl_publisher_fini(&g_pub_motor_health, &g_node));
    ignore_rcl_ret(rcl_publisher_fini(&g_pub_joint_state, &g_node));
#endif
    ignore_rcl_ret(rcl_publisher_fini(&g_pub_status, &g_node));
    ignore_rcl_ret(rcl_subscription_fini(&g_sub_cmd, &g_node));
    ignore_rcl_ret(rcl_node_fini(&g_node));
    ignore_rcl_ret(rclc_support_fini(&g_support));
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

    /* 初值(§任务卡 2):payload=-1 作「未收到任何 cmd」哨兵,首次回填后变首条 cmd 值。
     * header 各字段清 0(seq/stamp/crc),cmd 侧同样清 0。 */
    g_msg_status.header.seq           = 0u;
    g_msg_status.header.stamp_mono_ns = 0u;
    g_msg_status.header.crc           = 0u;
    g_msg_status.payload              = -1;     /* 「未收到任何 cmd」哨兵 */
    g_msg_cmd.header.seq              = 0u;
    g_msg_cmd.header.stamp_mono_ns    = 0u;
    g_msg_cmd.header.crc              = 0u;
    g_msg_cmd.payload                 = 0;
#if EXO_MOTOR_ROS_ENTITIES
    bind_frame_id_storage(&g_msg_joint_target.header.frame_id,
                          g_joint_target_frame_id,
                          sizeof(g_joint_target_frame_id));
    bind_frame_id_storage(&g_msg_joint_state.header.frame_id,
                          g_joint_state_frame_id,
                          sizeof(g_joint_state_frame_id));
    bind_frame_id_storage(&g_msg_motor_health.header.frame_id,
                          g_motor_health_frame_id,
                          sizeof(g_motor_health_frame_id));
#endif
    motor_control_init();

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
        TickType_t last_ping = xTaskGetTickCount();
#if EXO_MOTOR_ROS_ENTITIES
        TickType_t last_motor_state = last_ping;
        TickType_t last_motor_health = last_ping;
#endif
        for (;;) {
            /* spin_some 超时默认 1000us,可编译期下调到 500/200/100us 做延迟阶梯。
             * ping 用 FreeRTOS tick 计时,不再假设"1000 次循环约等于 1s"。 */
            (void)rclc_executor_spin_some(
                &g_executor,
                ((uint64_t)EXO_EXECUTOR_SPIN_TIMEOUT_US) * 1000ull);

            TickType_t now = xTaskGetTickCount();
#if EXO_MOTOR_ROS_ENTITIES
            if ((now - last_motor_state) >= pdMS_TO_TICKS(EXO_MOTOR_STATE_PERIOD_MS)) {
                last_motor_state = now;
                publish_motor_state();
            }
            if ((now - last_motor_health) >= pdMS_TO_TICKS(EXO_MOTOR_HEALTH_PERIOD_MS)) {
                last_motor_health = now;
                publish_motor_health();
            }
#endif

            /* 每 ~1s ping 一次 agent;连续多次失败判定掉线,跳出去重连。 */
            if ((now - last_ping) >= pdMS_TO_TICKS(1000)) {
                last_ping = now;
                if (rmw_uros_ping_agent(50, 2) != RMW_RET_OK) {
                    break;            /* agent 掉线 → 清理重连 */
                }
            }
            taskYIELD();   /* 不额外睡 1 tick;高优先级控制 task 仍可抢占 */
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
 *   rclc_executor_t          g_executor    —— 含 handle 数组指针(EXECUTOR_HANDLES=1)
 *   exo_msgs__msg__ExoCmd    g_msg_cmd     —— 20B(header 16B + payload 4B)
 *   exo_msgs__msg__ExoStatus g_msg_status  —— 20B(同上;较 Int32 每实例 +16B)
 *   volatile uint32_t        g_crc_mismatch_count —— 4B(CRC 自检计数,可观测探针)
 *   本文件 .bss 直接占用:约 0.2–0.4 KB(句柄壳 + 2×20B 消息),真正大头在 libmicroros 静态池。
 *   M-B 增量:消息体 2×(20-4)=+32B;exo_crc.c CRC 表 ~1KB 进 .rodata(ROM,非 RAM);
 *            dwt_time.c 64 位回绕状态 ~12B .bss。详见任务 6(T8 量化,主 agent 编译后实测)。
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
