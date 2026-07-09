# 任务卡 001:M0 PC直连CyberGear与Mock
- 负责开发:Tom
- 负责测试:Gill
- 依赖:`docs/01-ros2-microros-serial/17-电机控制接口抽象设计.md`、`docs/01-ros2-microros-serial/18-重要-ROS命名空间与SoC-MCU边界.md`、Python `python-can`、CyberGear 资料、可选 USB-CAN/CyberGear 硬件

## 目标

建立第一条 PC 侧 motor bring-up 路线：无硬件时用 mock backend 验证统一接口；CyberGear 到货后用 PC USB-CAN 直连验证电机能安全动作和读状态。

## 接口契约

本卡先实现 PC 工具和 mock，不定义最终 ROS 消息包；但命名和字段必须对齐后续 M1：

```text
/motor/tp_joint_target
/motor/tp_joint_state
/motor/tp_motor_health
```

统一目标字段至少覆盖：

```text
seq
joint_id
control_mode
position_rad
velocity_rad_s
torque_nm
kp_nm_per_rad
kd_nm_s_per_rad
max_torque_nm
max_velocity_rad_s
min_position_rad
max_position_rad
ttl_us
flags
```

统一状态字段至少覆盖：

```text
seq
joint_id
control_mode
position_rad
velocity_rad_s
torque_est_nm
current_a
bus_voltage_v
temperature_c
fault_bits
vendor_fault_bits
last_target_seq
sample_age_us
enabled
target_fresh
```

CyberGear 原始 CAN 帧不得暴露到上层 topic/service；只能存在于 CyberGear codec/backend 内。

建议工具入口：

```text
ros2_ws/src/motor_tools/motor_cybergear_probe.py
ros2_ws/src/motor_tools/motor_cybergear_benchtop.py
ros2_ws/src/motor_tools/cybergear_frame_codec.py
ros2_ws/src/motor_tools/mock_motor_backend.py
```

命令行参数建议：

```text
--interface pcan|socketcan
--channel PCAN_USBBUS1|can0
--bitrate 1000000
--motor-id <id>
--joint-id <id>
--mode probe|mock|position|velocity|torque
--max-torque-nm <value>
--max-velocity-rad-s <value>
```

## 实现要点 / 约束

- 先实现 mock backend：输入 JointTarget，输出 JointState，模拟 seq 回填、ttl 过期、限幅、fault。
- CyberGear frame codec 必须是纯函数，可离线单测，不依赖真实电机和 CAN 设备。
- PC 直连 CyberGear 路线优先支持 `python-can`，接口兼容 PCAN 和 SocketCAN。
- 所有动作默认低速、低力矩，必须显式传入限幅。
- `enable` 前必须有 preflight：CAN 打开、电机可读、无 fault、限幅参数存在。
- `disable` 必须可随时执行，且不依赖 ROS topic 正常。
- 初始力矩建议不超过电机能力的 10%-20%，真实数值放配置，不写死在控制逻辑。
- Tony607/Cybergear 只能作为协议和 PCAN 使用参考，不能直接把它的类名/API 作为本项目长期接口。

## 验收标准(给 Gill)

- mock 模式无需硬件即可运行，能发布连续 JointState，并能模拟 ttl 过期和 fault。
- codec 单测覆盖 CyberGear enable、disable、stop、set zero、position、velocity、current/torque、状态解析、fault 解析。
- `ros2 run` 或等效工具可执行 probe，硬件不存在时错误清晰，不假装成功。
- CyberGear 硬件存在时，能扫描/读取电机基本信息。
- CyberGear 硬件存在时，能执行 enable -> 低速 position 小角度正反转 -> disable。
- CyberGear 硬件存在时，能执行 velocity 小速度运行并停止。
- CyberGear 硬件存在时，能执行小力矩/电流输出并停止。
- 能读取 position、velocity、current/torque、temperature、fault。
- Gill 能看到每次目标的 seq、last_target_seq、target_fresh、fault_bits。
- 上层接口和日志中不出现必须由 `/ctrl/` 知道的 CyberGear 原始通信类型或 CAN 扩展帧编码。

## 不在本卡范围内

- 不实现 `exo_motor_msgs` 正式消息包，字段以 M1 为准。
- 不实现 STM32 CAN backend。
- 不实现 MCU 10kHz 控制环。
- 不实现 CubeMars。
- 不做人体穿戴验证。
- 不做高力矩、高速度、大行程动作。

