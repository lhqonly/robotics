# 任务卡 002:M1 exo_motor_msgs与ROS接口
- 负责开发:Tom
- 负责测试:Gill
- 依赖:任务卡 001 的字段验证经验、现有 `ros2_ws`、现有 `/com/` 命名规范、ROS2 Jazzy

## 目标

创建厂商无关的 `exo_motor_msgs` ROS 接口包，固定 `/motor/` topic/service 契约，让 CyberGear、CubeMars、mock、MCU 都复用同一套消息。

## 接口契约

新增接口包：

```text
ros2_ws/src/exo_motor_msgs/
```

必须包含：

```text
msg/JointTarget.msg
msg/JointState.msg
msg/MotorHealth.msg
srv/EnableJoint.srv
srv/DisableJoint.srv
srv/ClearMotorFault.srv
srv/SetJointZero.srv
srv/SetJointMode.srv
srv/GetMotorParam.srv
srv/SetMotorParam.srv
```

topic 契约：

```text
/motor/tp_joint_target   exo_motor_msgs/msg/JointTarget   SoC/PC -> MCU 或 PC mock
/motor/tp_joint_state    exo_motor_msgs/msg/JointState    MCU/mock -> SoC/PC
/motor/tp_motor_health   exo_motor_msgs/msg/MotorHealth   MCU/mock -> SoC/PC
```

`JointTarget` 必须包含：

```text
std_msgs/Header header
uint32 seq
uint8 joint_id
uint8 control_mode
float64 position_rad
float64 velocity_rad_s
float64 torque_nm
float64 kp_nm_per_rad
float64 kd_nm_s_per_rad
float64 max_torque_nm
float64 max_velocity_rad_s
float64 max_position_rad
float64 min_position_rad
uint32 ttl_us
uint32 flags
```

`JointState` 必须包含：

```text
std_msgs/Header header
uint32 seq
uint8 joint_id
uint8 control_mode
float64 position_rad
float64 velocity_rad_s
float64 torque_est_nm
float64 current_a
float64 bus_voltage_v
float64 temperature_c
uint32 fault_bits
uint32 vendor_fault_bits
uint32 last_target_seq
uint32 sample_age_us
bool target_fresh
bool enabled
```

`MotorHealth` 必须包含：

```text
std_msgs/Header header
uint8 bus_id
uint8 joint_count
uint64 targets_received
uint64 targets_applied
uint64 stale_targets
uint64 motor_tx
uint64 motor_rx
uint64 motor_timeout
uint64 motor_fault
float64 target_apply_latency_p99_ms
float64 can_gap_p99_ms
bool reconciles
```

枚举值必须用注释写在 msg 文件中，至少覆盖：

```text
DISABLED
ZERO_TORQUE
TORQUE
VELOCITY
POSITION
IMPEDANCE
TRAJECTORY
CALIBRATION
RAW_VENDOR
```

## 实现要点 / 约束

- `exo_motor_msgs` 是独立包，不要继续塞进现有 `exo_msgs`。`exo_msgs` 继续服务 `/com/` 通信验证。
- 消息包不包含 CyberGear/CubeMars 原始协议字段。
- `vendor_fault_bits` 可以保留厂商原始故障，但不影响统一 `fault_bits` 判断。
- `ttl_us` 是硬字段，后续 MCU 必须用它判断目标过期。
- `seq` 是控制闭环追踪字段，Gill 要能用它做目标 received/applied/state 对账。
- 新增最小 mock ROS node 或测试节点，证明接口可以被 publish/subscribe。
- README 或文档必须写清 source 顺序和自测命令。

## 验收标准(给 Gill)

- `colcon build` 成功。
- `colcon test` 成功。
- `ros2 interface show exo_motor_msgs/msg/JointTarget` 能看到字段。
- `ros2 interface show exo_motor_msgs/msg/JointState` 能看到字段。
- `ros2 interface show exo_motor_msgs/msg/MotorHealth` 能看到字段。
- `ros2 topic pub /motor/tp_joint_target ...` 可以被测试节点收到。
- 测试节点能发布 `/motor/tp_joint_state` 和 `/motor/tp_motor_health`。
- topic 名符合 `/motor/tp_*`，node 名符合 `node_*`。
- 包内 grep 不出现 CyberGear/CubeMars 厂商命令 ID 作为公共字段。
- 文档中明确 `micro_ros_bridge` 只是桥，不解析 `/motor/` 业务。

## 不在本卡范围内

- 不实现 CyberGear 真实 CAN 控制。
- 不实现 MCU 订阅。
- 不做安全状态机完整实现。
- 不新增 CubeMars backend。
- 不做动作接口 action，第一版只做 msg/srv。

