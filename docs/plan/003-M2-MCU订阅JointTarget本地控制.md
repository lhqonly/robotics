# 任务卡 003:M2 MCU订阅JointTarget本地控制
- 负责开发:Tom
- 负责测试:Gill
- 依赖:任务卡 002、现有 STM32 F103 micro-ROS 工程、已验证的 `micro_ros_bridge` 串口链路、现有 10kHz 控制 tick 验证结论

## 目标

让 MCU 端 `/node_mcu` 订阅 `/motor/tp_joint_target`，在本地 10kHz 控制 tick 中消费 latest target，完成 seq 追踪、ttl 过期、安全限幅和状态发布。

## 当前进度

- 已完成 MCU 侧 `motor_control` 核心模块：不依赖 micro-ROS、不依赖 CyberGear/CubeMars、不依赖真实电机。
- 控制热路径使用固定点整数单位（mrad、mrad/s、mNm），避免 1kHz-10kHz tick 中跑浮点。
- 已实现 latest target 双缓冲、TTL 过期、安全 disabled、位置/速度/力矩本地限幅、fresh/enabled/fault 状态、health 计数。
- 已接入现有 `com_control_tick_isr()`：每个 MCU 本地控制 tick 都会推进 motor 控制核心；没有真实 `/motor` target 时默认保持 safe disabled。
- 已保留 `/com` 心跳链路，不把 `/com/tp_cmd_heartbeat` 误当作 motor 指令。
- 已通过 host C 测试和 STM32 固件构建验证。
- 已重建/提交 M2 专用 micro-ROS 资源：`colcon.motor.notypedesc.meta`、`exo_motor_msgs` 生成头、`libmicroros.a`、3 publisher / 2 subscription 静态池配置。
- 已在 `EXO_MOTOR_ROS_ENTITIES=ON` profile 下接入 `/motor/tp_joint_target` subscription、`/motor/tp_joint_state` publisher、`/motor/tp_motor_health` publisher，并保留 `/com/tp_cmd_heartbeat` / `/com/tp_mcu_status`。
- 已修复离线审查发现的两个 M2 安全边界：非空 `header.frame_id` 的反序列化前缓冲风险，以及高优先级 TIM2 下 telemetry snapshot 可能被打断的问题。
- 已新增 M2 motor 通信预算工具：`tools/com-wire-budget.py --profile motor-m2`，并把 M2 预算纳入 `tools/recommend-communication-optimizations.py` 和 `tools/com-status-report.sh`。
- 已新增 M2 telemetry period sweep：`tools/motor-m2-telemetry-sweep.py --min-margin-pct 1 --pass-only`，用于离线选择保守静态余量的 state/health 发布周期；它只给静态线速候选，不替代真机 smoke evidence。

当前尚未完成：

- 尚未在真机上烧录 `EXO_MOTOR_ROS_ENTITIES=ON` 固件并连接 micro-ROS Agent 验证 ROS graph 能看到 `/motor` 三个 topic。
- 尚未发布真实 `/motor/tp_joint_target` 验证 `JointState.last_target_seq`、TTL stale、clamp/fault 和 `/com/tp_mcu_status` 并存稳定性。
- 尚未做 200Hz target + configurable motor state/health 并发下的 runtime 对比；静态预算显示默认 200Hz target + 20ms state + 200ms health（50Hz/5Hz）在 921600 baud 超过 30% 预算，2Mbps 通过。应先跑 2Mbps first smoke；921600 low telemetry 只有 thin margin，只能作为 2Mbps PASS 后的 post-2Mbps comparison only，不能替代运行期证据。
- 尚未在 motor-enabled 固件上读取栈水位、MSP/heap 余量和 reconnect/soak 结果；`build-motor-opt` 只是候选，不能在无真机证据时改默认。
- 非空 `header.frame_id` 已做静态防护，但仍需运行期注入验证它会被干净拒绝，且不会破坏 executor/reconnect。

## 接口契约

当前 F103 固件沿用通信域节点名：

```text
/node_com_mcu
```

早期文档中的 `/node_mcu` 是 M2 领域化命名目标；在 `MAX_NODES=1` 的 F103 profile 下，
M2 不单独新增第二个节点，先把 `/com` 与 `/motor` 实体挂在现有 MCU 节点上。若后续要把
节点名改为 `/node_mcu`，需要同步更新 `/com` 验收脚本和 ROS graph 判据。

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
