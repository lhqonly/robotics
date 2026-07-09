# 任务卡 006:M5 CubeMars后续分支准备
- 负责开发:Tom
- 负责测试:Gill
- 依赖:任务卡 002 的共同契约、任务卡 003 的 Motor HAL、任务卡 004 的 adapter 经验、CubeMars AK 系列资料，后续可选 CubeMars 硬件

## 目标

为后续 `feature/cubemars-motor-control` 分支准备 CubeMars adapter 接入计划，确保它复用 `exo_motor_msgs` 和 Motor HAL，不复制 CyberGear 私有设计。

## 接口契约

CubeMars 分支必须复用：

```text
/motor/tp_joint_target
/motor/tp_joint_state
/motor/tp_motor_health
Motor HAL backend interface
```

新增内容只能是：

```text
cubemars_ak_backend.*
cubemars_ak_frame_codec.*
cubemars_ak_params.*
cubemars_ak_fault_map.*
CubeMars joint config
CubeMars backend tests
```

不得修改：

```text
JointTarget.msg
JointState.msg
MotorHealth.msg
上层 /ctrl/ 控制算法接口
/com/ 通信诊断接口
```

除非能证明共同契约缺字段，并同步影响 CyberGear/mock。

## 实现要点 / 约束

- 本卡第一步只做资料归档和 contract gap analysis，不急着写 backend。
- 对比 CubeMars AK 的 current/velocity/position/position-velocity 等模式与统一 control_mode。
- 对比 CubeMars fault/status 与统一 fault_bits。
- 对比 CubeMars 单位、限幅、CAN ID 编码与 Motor HAL。
- 明确哪些能力 CyberGear 有、CubeMars 没有；哪些 CubeMars 有、CyberGear 没有。
- 如果需要扩展统一接口，必须写清为什么不是 vendor param。
- CubeMars 分支必须从包含共同契约的 `main` 开，不从 CyberGear 分支开。

## 验收标准(给 Gill)

- 输出一份 CubeMars gap analysis 文档，列出模式、单位、fault、参数、状态字段映射。
- 证明现有 `JointTarget` / `JointState` / `MotorHealth` 能覆盖 CubeMars 第一阶段单电机验证。
- 如果发现缺口，给出字段扩展建议和对 CyberGear/mock 的影响。
- CubeMars 计划中不依赖 CyberGear 私有类名、私有配置或私有 topic。
- 新分支策略清晰：`feature/cubemars-motor-control` 从 `main` 开。

## 不在本卡范围内

- 不在 CyberGear 分支直接实现 CubeMars。
- 不采购决策具体型号。
- 不做 CubeMars 真机动作验证。
- 不修改 `/motor/` 共同契约，除非先完成 gap analysis 并通过设计评审。

