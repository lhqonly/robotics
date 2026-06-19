# robotics — 外骨骼机器人控制链路

一个个人学习项目：搭建外骨骼机器人的**实时控制链路**，并借此练习用 AI 编码工具协作开发。

## 这个项目要做什么

最终目标是**实时控制外骨骼的关节电机**。整条链路是：

```
上位机 (WSL / Ubuntu, ROS2 Jazzy)  <--- 串口 (UART, 921600, DMA, 双向) --->  STM32 (Nucleo-F103RB, micro-ROS + FreeRTOS)
```

- **上位机侧**：ROS2 负责指令下发与状态监控。
- **MCU 侧**：STM32 跑 micro-ROS，负责实时电机控制。
- **链路要求**：因为终局是实时控制环，**延迟与丢包是安全关键**——链路监控从一开始就按"逐帧测往返延迟、超限告警、丢包显式检出、绝不静默掩盖"的标准设计。

## 现在进展

分阶段推进，先打通最小闭环再上真实控制：

- **Phase A（已完成核心）**：ROS2 ↔ 本地回环节点的最小闭环（`std_msgs/Int32` 心跳回环）+ 链路健康监控（往返延迟 / 丢包 / 重复检测 / 对账恒等）。逻辑与对抗测试全绿。
- **Phase B（进行中）**：换到真实 STM32 Nucleo-F103RB 硬件，micro-ROS over serial 真机联调。当前在做 20KB SRAM 上的 micro-ROS 可行性验证。

## 目录结构

| 目录 | 内容 |
|------|------|
| `docs/` | 架构文档、接口契约、任务卡、变更设计 |
| `ros2_ws/` | ROS2 工作区（`exo_cmd` 心跳+链路监控、`exo_bringup` 启动） |
| `firmware/` | STM32 / micro-ROS 固件相关配置（F103 裁剪 colcon.meta 等） |
| `tools/` | 工具链安装、环境自检、实跑验证脚本 |

## 技术栈

ROS2 Jazzy · micro-ROS (XRCE-DDS over serial) · STM32F103 · FreeRTOS · 裸 CMake + arm-none-eabi-gcc

---

*开发过程用 Claude Code 的子 agent 模拟一个小型研发团队（架构 / 开发 / 测试分工）协作完成。*
