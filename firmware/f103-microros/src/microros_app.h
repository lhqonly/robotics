/* microros_app.h — micro-ROS rclc 双向应用任务对外接口 (T5)
 *
 * 实现契约 §1 的最小双向闭环:
 *   sub /com/tp_cmd_heartbeat (exo_msgs/ExoCmd, RELIABLE, KEEP_LAST depth=1)
 *     → 回调里原样回填 → pub /com/tp_mcu_status (exo_msgs/ExoStatus, RELIABLE, KEEP_LAST depth=1)
 *   节点名 node_com_mcu(契约 §5)。
 *
 * 用法:main.c 用 xTaskCreateStatic 起本任务(替代 T4 的 AppTask echo)。
 */
#ifndef MICROROS_APP_H
#define MICROROS_APP_H

/* micro-ROS 应用任务入口。死循环:建链 → spin executor → 断链重连。
 * arg 未用。 */
void microros_app_task(void *arg);

#endif /* MICROROS_APP_H */
