/* microros_transport.c — micro-ROS 自定义串口 transport 4 回调实现 (T5)
 *
 * 把 Micro XRCE-DDS client 的字节流收发接到 USART1@921600 + DMA(main.c 已调通)。
 * 注册:rmw_uros_set_custom_transport(framing=true, &args, open, close, write, read)。
 *
 * 【依赖 libmicroros —— 主 agent 集成时需确认的 include 占位】
 *   本文件用到的两个 micro-ROS 头(随 libmicroros.a 一起由 generate_lib 产出到
 *   firmware/build/include/,主 agent 拷进 ThirdParty/microros/include/ 后,
 *   CMakeLists 的 include 路径已预留——见 CMakeLists 注释 [MICROROS-INCLUDE]):
 *     #include <uxr/client/profile/transport/custom/custom_transport.h>  // uxrCustomTransport
 *     #include <rmw_microros/rmw_microros.h>                             // rmw_uros_set_custom_transport
 *   这两个头在 lib 生成前不存在,故本文件用 #if __has_include 守卫:
 *     - 有头:正常编译真实回调 + 注册。
 *     - 无头:编译一个「占位实现」(microros_transport_register 返回 false),让
 *       main.c 仍能在「lib 未就位」时单独编过(主 agent 增量集成用)。集成后 __has_include
 *       命中真实头,占位自动失效。这样 Tom 这边交付即可编,不卡主 agent 进度。
 *
 * 回调约定(签名已由 05 文档联网核实 verbatim):
 *   bool   open (uxrCustomTransport* t)
 *   bool   close(uxrCustomTransport* t)
 *   size_t write(uxrCustomTransport* t, const uint8_t* buf, size_t len, uint8_t* err)
 *   size_t read (uxrCustomTransport* t, uint8_t* buf, size_t len, int timeout, uint8_t* err)
 *   err:出错时置非 0(XRCE 据此判错);正常置 0。read 超时返 0 且 err=0,不算错。
 */

#include "microros_transport.h"
#include "uart_ll.h"      /* uart_ll_write_blocking / uart_ll_read —— main.c 实现 */

/* ===== 是否拿到 micro-ROS 头(lib 已生成) ===== */
#if defined(__has_include)
#  if __has_include(<uxr/client/profile/transport/custom/custom_transport.h>) && \
      __has_include(<rmw_microros/rmw_microros.h>)
#    define MICROROS_HEADERS_AVAILABLE 1
#  endif
#endif

#ifdef MICROROS_HEADERS_AVAILABLE
/* ====================== 真实实现(lib 就位后编译) ====================== */

#include <uxr/client/profile/transport/custom/custom_transport.h>
#include <rmw_microros/rmw_microros.h>

/* USART1 早在 main.c 的 USART1_Init()/DMA_Init() 里已使能并常驻。
 * 故 open/close 不重复初始化外设(底层属 main.c 职责),只做语义占位:
 *   - open:报告物理层已就绪(USART/DMA 一直开着)→ 直接 true。
 *   - close:不真正关 USART(关了 RX circular 会丢后续重连数据);仅返回 true。
 * 若将来要支持「transport 关停外设以省电」,在此调 main.c 暴露的 enable/disable 即可。 */

/* open:micro-ROS 建链/重连时调用一次。我们的串口常驻,无需做事。 */
static bool f103_transport_open(uxrCustomTransport *transport)
{
    (void)transport;
    return true;
}

/* close:session 关闭/重连前调用。串口常驻,不关。 */
static bool f103_transport_close(uxrCustomTransport *transport)
{
    (void)transport;
    return true;
}

/* write:把 XRCE 要发的 len 字节经 USART1 TX DMA 发出。
 *   - uart_ll_write_blocking 内部会等上一次 TX DMA 完成,保证按序、不覆盖缓冲。
 *   - 全部发出才返回(阻塞语义);返回实际写出字节数。
 *   - 正常路径不置错;只有底层拒发(理论上不会)才标 err。 */
static size_t f103_transport_write(uxrCustomTransport *transport,
                                   const uint8_t *buf, size_t len, uint8_t *err)
{
    (void)transport;
    size_t written = uart_ll_write_blocking(buf, len);
    if (err) {
        /* 没有把全部字节发出 → 视为传输错误,交给 XRCE 重试。正常 written==len。 */
        *err = (written == len) ? 0u : 1u;
    }
    return written;
}

/* read:从 app_ring(RX DMA 已搬入的字节)取最多 len 字节,带 timeout(毫秒)软超时。
 *   - 取到 >=1 字节即返回(不强求填满 len);取不到则等到 timeout 返回 0。
 *   - 返回 0 且 err=0 表示「本次没数据」,是 XRCE 轮询的正常结果,不算错。 */
static size_t f103_transport_read(uxrCustomTransport *transport,
                                  uint8_t *buf, size_t len, int timeout, uint8_t *err)
{
    (void)transport;
    size_t n = uart_ll_read(buf, len, timeout);
    if (err) {
        *err = 0u;   /* 串口读永不报硬错;无数据=返回 0,由 XRCE 自行处理超时 */
    }
    return n;
}

/* 自定义 transport args:本实现无需透传上下文(外设是全局的),传 NULL 即可。 */
bool microros_transport_register(void)
{
    /* framing=true:串口字节流无消息边界,启用 XRCE stream framing 自切帧
     * (对应 colcon.meta UCLIENT_PROFILE_STREAM_FRAMING=ON)。 */
    rmw_ret_t rc = rmw_uros_set_custom_transport(
        true,                       /* framing */
        (void *)0,                  /* args:无需上下文 */
        f103_transport_open,
        f103_transport_close,
        f103_transport_write,
        f103_transport_read);

    return (rc == RMW_RET_OK);
}

#else  /* !MICROROS_HEADERS_AVAILABLE */
/* ====================== 占位实现(lib 未就位时,让 main.c 仍可编) ====================== */
/* 这条分支只是为了「Tom 交付即可编、不阻塞主 agent」。一旦主 agent 把 libmicroros
 * 的 include 路径接好,__has_include 命中,上面的真实实现生效,本占位自动失效。 */

bool microros_transport_register(void)
{
    /* lib 未集成:不可能注册成功。返回 false,microros 任务会据此停在自检失败处
     * (暴露而非静默继续)。 */
    return false;
}

#endif /* MICROROS_HEADERS_AVAILABLE */
