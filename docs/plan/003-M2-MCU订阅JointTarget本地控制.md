# 任务卡 003:M2 MCU订阅JointTarget本地控制
- 负责开发:Tom
- 负责测试:Gill
- 依赖:任务卡 002、现有 STM32 F103 micro-ROS 工程、已验证的 `micro_ros_bridge` 串口链路、现有 10kHz 控制 tick 验证结论

## 目标

让 MCU 端 `/node_mcu` 订阅 `/motor/tp_joint_target`，在本地 10kHz 控制 tick 中消费 latest target，完成 seq 追踪、ttl 过期、安全限幅和状态发布。

## 接口契约

MCU 端最小 ROS 节点仍然可以只有：

```text
/node_mcu
```

订阅：

```text
/motor/tp_joint_target   exo_motor_msgs/msg/JointTarget
```

发布：

```text
/motor/tp_joint_state    exo_motor_msgs/msg/JointState
/motor/tp_motor_health   exo_motor_msgs/msg/MotorHealth
/com/tp_mcu_status       现有 com 状态消息
```

固件内部建议模块边界：

```text
com/             micro-ROS 收发、链路状态、心跳
motor/           JointTarget 缓存、JointState 生成、限幅、fault
control_loop/    1kHz-10kHz 本地控制 tick
vendor_driver/   mock / cybergear / cubemars backend
```

Motor HAL 最小接口：

```text
motor_backend_enable()
motor_backend_disable()
motor_backend_clear_fault()
motor_backend_set_zero()
motor_backend_send_target()
motor_backend_read_state()
motor_backend_get_capability()
```

## 实现要点 / 约束

- micro-ROS callback 只更新 latest target 缓存，不在 callback 内做耗时控制。
- 10kHz 控制 tick 只读取最新 target，完成 ttl、限幅、模式、安全状态判断后应用。
- first backend 可用 mock/empty backend，不要求本卡真实驱动 CyberGear。
- `target_seq -> received_seq -> applied_seq -> JointState.last_target_seq` 必须可追踪。
- `ttl_us` 过期时不得继续应用旧目标。
- 位置、速度、力矩必须先做本地全局限幅，再进入 backend。
- 上电默认 `DISABLED` 或 `ZERO_TORQUE`，不能默认 active control。
- 资源约束：F103 RAM/ROM 不能因消息和队列明显超预算；避免动态分配进入控制热路径。
- 保持现有 `/com/` 链路验证能力，不因 motor 消息破坏通信压测。

## 验收标准(给 Gill)

- 固件可编译，下载功能仍正常。
- `micro_ros_bridge` 启动后，ROS2 能看到 `/node_mcu`。
- ROS2 发布 `/motor/tp_joint_target` 后，MCU 能发布 `/motor/tp_joint_state`。
- `JointState.last_target_seq` 能对应最新有效 target。
- 200Hz target 输入下，10kHz tick 中 applied 计数持续增长。
- 停止发布 target 后，ttl 过期计数增长，状态降级到安全模式。
- 发送超过限幅的 target，MCU 状态中能体现 clamp 或 fault，不直接透传危险目标。
- `/com/tp_mcu_status` 仍能正常发布，通信健康不被 motor 模块吞掉。
- 没有真实电机时，mock/empty backend 也能完成上述验收。

## 不在本卡范围内

- 不实现 CyberGear CAN 协议。
- 不实现 CubeMars。
- 不做高层助力算法 `/ctrl/node_assist_ctrl`。
- 不做真实人体穿戴。
- 不要求完成所有 service/action，只要求 topic 闭环和本地控制骨架。

