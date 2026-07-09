# 重要：ROS 命名空间与 SoC-MCU 边界澄清

> 状态：重要设计澄清。
> 日期：2026-07-09。
> 背景：避免把 `com`、`ctrl`、`motor` 误解成 SoC 和 MCU 之间必须存在的三套物理节点。

## 1. 最重要结论

`com`、`ctrl`、`motor` 首先是 **ROS namespace / 语义分区**，不是要求每一端都必须启动同名 node。

推荐理解：

```text
/com/    通信诊断 namespace
/ctrl/   控制算法 namespace
/motor/  电机/关节执行命令 namespace
```

真正运行的 ROS node 可以少很多。尤其在 MCU 上，为了省 RAM/ROM，完全可以只有一个 micro-ROS node。

## 2. `ctrl node -> motor topic -> MCU`，不是多绕一层

SoC 算出来“让 MCU 控制电机以多大力矩、速度或角度动作”的消息，确实可以口语上叫 control command。

但从系统契约看，它的执行对象是 motor/joint，所以建议放在：

```text
/motor/tp_joint_target
```

这不是额外多加一层 motor 消息，而是给同一条 SoC -> MCU 控制命令选一个更稳定的语义归属。

正确关系：

```text
/ctrl/node_assist_ctrl
        |
        | 发布“关节执行目标”
        v
/motor/tp_joint_target
        |
        v
MCU 收到后直接进入本地控制
        |
        v
PWM / CAN / CyberGear / CubeMars
```

不是：

```text
ctrl msg -> motor msg -> MCU
```

而是：

```text
ctrl node -> motor topic -> MCU
```

也就是说：

- `/ctrl/node_assist_ctrl` 表示“谁算出来的”。
- `/motor/tp_joint_target` 表示“这条消息要驱动什么”。

## 3. SoC 端最小结构

SoC 端最小闭环可以只有：

```text
SoC:
  /ctrl/node_assist_ctrl
  micro_ros_bridge
```

这里把常见的 `micro_ros_agent` 在项目文档中命名为：

```text
micro_ros_bridge
```

原因是这个名字更直观：它就是 PC/SoC ROS2 世界和 MCU micro-ROS 世界之间的桥。

`micro_ros_bridge` 只负责底层通信桥接：

- 打开串口或其他 transport。
- 让 MCU 的 micro-ROS node 接入 ROS2 DDS。
- 搬运 ROS topic/service 数据。

`micro_ros_bridge` 不应该理解业务语义：

- 不解析“这是 2Nm 力矩命令”。
- 不判断“这是膝关节还是髋关节”。
- 不做电机限幅、模式切换或故障处理。
- 不负责把 `/com/`、`/ctrl/`、`/motor/` 业务消息重新分发一遍。

## 4. MCU 端最小结构

MCU 端不需要真的拆成 `com node`、`ctrl node`、`motor node`。

推荐 MCU 端最小结构：

```text
MCU:
  /node_mcu
```

`/node_mcu` 可以同时：

```text
订阅：
  /motor/tp_joint_target

发布：
  /motor/tp_joint_state
  /motor/tp_motor_health
  /com/tp_mcu_status
```

在固件内部，建议把代码模块拆开：

```text
firmware:
  com/             micro-ROS 收发、链路状态、心跳
  motor/           关节目标、状态、限幅、故障
  control_loop/    1kHz-10kHz 本地控制 tick
  vendor_driver/   CyberGear / CubeMars / 其他电机协议
```

也就是说：

- **物理 node 可以只有一个**。
- **topic/service 的 namespace 仍然分开**。
- **固件代码结构也要分层**，避免后续电机厂商切换时牵动通信链路。

## 5. `/com/` 的边界

`/com/` 只负责通信诊断和 MCU 基础状态，不承载电机业务命令。

典型内容：

```text
/com/tp_mcu_status
/com/tp_link_health
```

它回答的问题是：

- SoC 和 MCU 有没有连上？
- 延迟多少？
- 是否丢包、重复、stale？
- MCU 基础状态是否正常？

它不回答：

- 当前目标力矩是多少？
- 哪个关节应该运动？
- 电机是否应该进入位置模式？

这些属于 `/motor/` 或 `/ctrl/`。

## 6. `/ctrl/` 的边界

`/ctrl/` 是控制算法域。

它负责：

- 人体意图识别。
- 步态/状态机。
- 助力策略。
- 生成关节目标。

典型 node：

```text
/ctrl/node_assist_ctrl
/ctrl/node_gait_ctrl
```

`/ctrl/` 可以订阅 `/motor/tp_joint_state` 和传感器状态，然后发布 `/motor/tp_joint_target`。

## 7. `/motor/` 的边界

`/motor/` 是电机/关节执行契约。

它负责表达：

- 哪个关节。
- 什么控制模式。
- 目标位置、速度、力矩。
- 阻抗参数。
- 限幅。
- 命令有效期。
- 电机/关节状态反馈。

典型 topic：

```text
/motor/tp_joint_target   SoC -> MCU
/motor/tp_joint_state    MCU -> SoC
/motor/tp_motor_health   MCU -> SoC
```

这条边界的好处是：未来从 CyberGear 换成 CubeMars，SoC 上层控制仍然发布同样的 `/motor/tp_joint_target`，只替换 MCU 或 adapter 里的厂商 backend。

## 8. 推荐最小闭环

第一阶段最小闭环建议按这个理解实现：

```text
SoC:
  /ctrl/node_assist_ctrl
  micro_ros_bridge

MCU:
  /node_mcu

Topic:
  /motor/tp_joint_target   SoC -> MCU
  /motor/tp_joint_state    MCU -> SoC
  /com/tp_mcu_status       MCU -> SoC
```

一句话：

```text
ctrl 负责算目标；
motor topic 承载关节执行契约；
MCU 直接执行；
com 只负责链路健康；
micro_ros_bridge 只负责把 SoC 和 MCU 的 ROS2/micro-ROS 世界接起来。
```
