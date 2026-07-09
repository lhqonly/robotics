# 任务卡 004:M3 CyberGear CAN Backend
- 负责开发:Tom
- 负责测试:Gill
- 依赖:任务卡 001、任务卡 002、任务卡 003、CyberGear 电机、24V 限流电源、CAN transceiver/USB-CAN、120Ω 终端电阻、急停/保险

## 目标

在 Motor HAL 下实现 CyberGear CAN backend，让 MCU 或 PC backend 可以通过统一 `JointTarget` 控制小米 CyberGear，并把电机状态映射成统一 `JointState` / `MotorHealth`。

## 接口契约

backend 对上只暴露 Motor HAL：

```text
motor_backend_probe()
motor_backend_enable()
motor_backend_disable()
motor_backend_clear_fault()
motor_backend_set_zero()
motor_backend_send_target()
motor_backend_read_state()
motor_backend_get_capability()
motor_backend_get_param()
motor_backend_set_param()
```

backend 对 ROS 只通过统一消息间接暴露：

```text
JointTarget -> motor_backend_send_target()
motor_backend_read_state() -> JointState
CAN/backend counters -> MotorHealth
```

CyberGear 厂商内容只能出现在：

```text
cybergear_backend.*
cybergear_frame_codec.*
cybergear_params.*
cybergear_fault_map.*
```

## 实现要点 / 约束

- CyberGear CAN 1Mbps，扩展帧，具体编码以资料和 M0 codec 实测为准。
- position、velocity、torque/current、kp、kd 的单位换算必须封装在 codec/backend。
- mode 映射必须从统一 `control_mode` 转换到 CyberGear 运行模式，不能让上层传厂商 mode id。
- fault 映射分两层：统一 `fault_bits` 和原始 `vendor_fault_bits`。
- enable 前必须确认电压、温度、fault、位置范围和急停状态。
- disable/stop 必须走最保守路径，不能继续保持上一条目标。
- set zero 只能在 calibration 或明确调试流程内执行。
- CAN timeout、bus-off/error-passive/error-warning 必须计数并上报到 MotorHealth。
- 第一版只要求单电机，joint_id -> motor_id 配置化，不写死。

## 验收标准(给 Gill)

- backend codec 离线单测通过。
- 真实 CyberGear 可 probe 到。
- enable/disable 可重复执行，disable 后电机不继续执行旧目标。
- clear fault 可执行并有结果反馈。
- set zero 只能在允许状态下执行，非法状态会拒绝。
- position 模式能小角度正反转。
- velocity 模式能小速度运行并停止。
- torque/current 模式能小力矩输出并停止。
- `JointState` 能读到 position、velocity、torque_est/current、temperature、fault。
- 断开 CAN 或关闭电机电源后，MotorHealth 的 timeout/fault 计数增长，并进入安全状态。
- grep 公共 ROS 消息和 joint controller，不存在 CyberGear 原始帧编码泄漏。

## 不在本卡范围内

- 不实现多电机同步控制。
- 不实现 CubeMars。
- 不做真实外骨骼负载。
- 不做完整轨迹 action。
- 不优化最终性能，只保证单电机安全 bring-up。

