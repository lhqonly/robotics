# F103RB / 20KB SRAM 专用 micro-ROS 裁剪配置

本目录提供 **STM32 Nucleo-F103RB(STM32F103, 仅 20KB SRAM / 128KB Flash)** 专用的
micro-ROS firmware 静态库构建裁剪配置 `colcon.meta`,以及配套的内存预算与栈调优说明。

> 产出归属:任务卡 **T-meta**(开发 Tom 设计、主 agent 代笔落盘,2026-06-19)。键名已对 4 个官方源核实,来源见文末。

## 这是什么 / 为什么需要

micro-ROS 官方推荐最低 32KB RAM,F103RB 只有 20KB,**低于官方下限**(详见
`docs/01-ros2-microros-serial/04-变更-F103换芯与硬件到位.md` A.2)。能否在 20KB 内跑起
来,取决于把 rmw_microxrcedds + Micro-XRCE-DDS-Client 中间件裁到多窄。本 colcon.meta
就是把它裁到本项目最小闭环实际所需的最窄配置。

## 对应的接口契约决策(v1.2)

- 本闭环只有 **1 个 publisher**(`/com/tp_mcu_status`)+ **1 个 subscription**
  (`/com/tp_cmd_heartbeat`),无 service / client,wire = `exo_msgs`。
- 契约 v1.2 已用户拍板:**F103(micro-ROS client)侧 QoS History Depth = 1**
  (`RMW_UXRCE_MAX_HISTORY=1`),WSL(ROS2)侧维持 Depth=10,RELIABLE 两端不变。
  这是 20KB 省 RAM 的契约级取舍,代价(MCU 侧缓存浅、抖动更易丢)由契约第 7 节
  监控如实暴露,不掩盖。
- 串口物理层:USART2 (PA2/PA3) 经 ST-Link VCP,921600 8N1,custom USART+DMA transport。

## 文件

- `colcon.meta`            —— 纯 JSON,真正用于构建(JSON 不支持注释,勿加注释)。
- `colcon.meta.annotated`  —— 带逐键注释的说明版,**仅供阅读**,勿用于构建。
- `colcon.motor.meta`      —— M3 `/motor` topic 接入候选配置，3 pub + 2 sub，不覆盖当前 `/com` 稳定基线。
- `colcon.motor.meta.annotated` —— motor 候选配置说明版，记录资源池扩大的理由。
- `src/motor_control.*`    —— M2 MCU 侧 motor latest-target / TTL / 限幅 / safe-state 核心。

## M2 motor core 自测

`motor_control` 是 MCU 内部控制核心，可在 PC 上用 gcc 做无硬件自测：

```bash
cd ~/robotics
gcc -std=c11 -Wall -Wextra -Werror \
  -I firmware/f103-microros/src \
  firmware/f103-microros/src/motor_control.c \
  firmware/f103-microros/tests/motor_control_host_test.c \
  -o /tmp/motor_control_host_test
/tmp/motor_control_host_test
```

STM32 固件构建：

```bash
cd ~/robotics
cmake -S firmware/f103-microros -B firmware/f103-microros/build \
  -DCMAKE_TOOLCHAIN_FILE=$(pwd)/firmware/f103-microros/toolchain-arm-m3.cmake \
  -DCMAKE_BUILD_TYPE=MinSizeRel
cmake --build firmware/f103-microros/build
```

M2 `/motor` micro-ROS 实体当前已作为实验 profile 接入，默认构建仍保持
`EXO_MOTOR_ROS_ENTITIES=OFF`，用于保护 `/com` 稳定基线。要构建 motor profile：

```bash
cd ~/robotics
cmake -S firmware/f103-microros -B firmware/f103-microros/build-motor \
  -DCMAKE_TOOLCHAIN_FILE=$(pwd)/firmware/f103-microros/toolchain-arm-m3.cmake \
  -DCMAKE_BUILD_TYPE=MinSizeRel \
  -DEXO_MOTOR_ROS_ENTITIES=ON \
  -DEXO_CONTROL_LOOP_HZ=10000 \
  -DEXO_MOTOR_TELEMETRY_QOS_BEST_EFFORT=ON
cmake --build firmware/f103-microros/build-motor
tools/firmware-size-report.sh firmware/f103-microros/build-motor/f103-microros.elf
```

当前 M2 motor 生成物来自 `colcon.motor.notypedesc.meta`，而不是默认 `/com`
`colcon.meta`。它包含 `exo_motor_msgs` 生成头和 motor 版 `libmicroros.a`，资源池为
3 publisher + 2 subscription，`STREAM_HISTORY=4`，并关闭 C type-description raw
source 以压 SRAM。这里提交生成产物是 F103 20KB SRAM 下可复现实验 profile 的阶段性例外；
后续若重建 `ThirdParty/microros`，必须同步记录所用 meta、size report 和真机建链结果。

M2 运行期仍未完成真机验收：需要烧录 `EXO_MOTOR_ROS_ENTITIES=ON` 固件，启动
micro-ROS Agent，确认 `/motor/tp_joint_target`、`/motor/tp_joint_state`、
`/motor/tp_motor_health` 与 `/com/tp_mcu_status` 同时可见，并完成 target seq、TTL、
clamp/fault、非空 `header.frame_id` 拒绝和 `/com` 并存稳定性验证。
吞吐优化 profile 可打开 `EXO_MOTOR_TELEMETRY_QOS_BEST_EFFORT=ON`，让
`/motor/tp_joint_state` 和 `/motor/tp_motor_health` 走 best-effort telemetry，
避免 200Hz target + 10kHz local tick smoke 中 telemetry 反压 reliable stream。

## 内存模型(static memory pool / 关动态分配)

**1. 中间件层已在 colcon.meta 里关动态分配:**
- `RCUTILS_AVOID_DYNAMIC_ALLOCATION=ON` + `RCUTILS_NO_*` 系列:rcutils 不走 malloc。
- rmw_microxrcedds 的 `RMW_UXRCE_MAX_*` 系列本身就是**静态实体池**(entity pool)尺寸,
  设成精确的 1/1/0/0,池只占实际需要的几槽;`RMW_UXRCE_ALLOW_DYNAMIC_ALLOCATIONS`
  保持**默认 OFF**(池满即失败而非偷偷 malloc,符合"不掩盖"哲学)。**不要打开它。**

**2. 应用层(属 T5,这里只给约束):**
- 用静态 allocator(`microros_static_allocator` 一类)把 message/serialized buffer
  放到静态数组,而非默认 heap allocator。具体 API 名以 T5 用的 micro-ROS 版本头文件为准。
- FreeRTOS:`configSUPPORT_STATIC_ALLOCATION=1`;若仍用 dynamic,heap_4.c +
  一个**明确上界**的 `configTOTAL_HEAP_SIZE`(从小往上调,别给默认大块)。

**3. micro-ROS 任务栈 —— 不定死字节,用实测收敛(写进 T8 执行清单):**
1. 起测给偏大安全值(如 2500 words ≈ 10KB)先让它不溢出跑起来。
2. 完整跑一轮 pub/sub,并多跑几分钟覆盖重连/重传路径(重传栈用得更深)。
3. 周期读 `uxTaskGetStackHighWaterMark(handle)`(单位 words,历史最小剩余栈)。
4. 新栈 = 当前栈 − HWM_min + 安全余量(≥128 words/512B)。
5. 迭代 2–4 直到栈降到"实测峰值 + 固定余量",HWM_min 稳定 ≥ 余量。
6. 同时监控 `xPortGetMinimumEverFreeHeapSize()`,确认 heap 未触底。
> 数值故意不定死——"够不够"正是 T8 要回答的 go/no-go 客观依据;G-T8-a 须给出实测
> HWM_min 与最终栈值。

## 串口 transport 内存预算(当前目标 < 1.5KB)

| 项 | 建议值 | 理由 |
|---|---|---|
| XRCE custom transport MTU | **128 B**(`UCLIENT_CUSTOM_TRANSPORT_MTU=128`) | 单条 Int32 的 XRCE 载荷仅几十字节;128B 给足裕度且远小于默认 512B。MTU 是省流缓冲 RAM 的最大杠杆。 |
| XRCE reliable stream 缓冲(client 内部) | ≈ MTU×`STREAM_HISTORY`×可靠流数 = 128×2×2 ≈ **512 B** | 当前 `STREAM_HISTORY=2` 是 T5 后的兼容下限：bin create_topic 描述需要 2×128B，不能轻易压回 1。 |
| XRCE best-effort stream 缓冲(client 内部) | 约 **256 B** | 高频 latest-target profile 需要输入/输出 best-effort stream；T5 发现 stream 数为 0 会触发初始化期内存踩踏。 |
| USART2 DMA RX 双缓冲 | **2 × 128 B = 256 B** | DMA circular + IDLE 中断收变长帧;每半 128B 与 MTU 对齐。 |
| USART2 DMA TX 缓冲 | **1 × 128 B = 128 B** | 发送主动控时序,单缓冲足够。 |
| app RX ring / index | **约 260 B** | 当前 `app_ring` 256B，外加 head/tail。 |
| **合计** | **约 1.1-1.3 KB 量级** | 比早期 reliable-only/history=1 的 640B 预算更高，但换来 best-effort latest-target 与 vanilla agent/bin creation 稳定性。 |

要点(给 T4/T5):
- **MTU 三处一致**:`UCLIENT_CUSTOM_TRANSPORT_MTU`、custom transport 回调一次收/发字节数、
  DMA buffer 半区,都按 128B 对齐。
- DMA RX 用 **circular + USART IDLE line 中断**收变长 XRCE 帧(framing 由
  `UCLIENT_PROFILE_STREAM_FRAMING=ON` 处理),不要定长阻塞接收。
- 这些 buffer 都是**静态数组(.bss)**,不进 heap。

## 在 T8(20KB 去风险 spike)里怎么用

1. 用 micro_ros_setup(Jazzy)创建 firmware/static-library 工作区。
2. 把本 `colcon.meta` 放到 micro_ros_setup 期望位置(static library 生成时 `--meta`
   指向它,或覆盖默认 colcon.meta),让裁剪键进入 rmw/client 构建。
3. 编译 micro-ROS 静态库 + 最小 FreeRTOS + 最小应用(哪怕只 1 个 pub)。
4. `arm-none-eabi-size` / `.map` 读 RAM/Flash 占用(G-T4-b:RAM<20KB 且有裕度)。
5. 烧录真机,起 micro_ros_agent session;按"任务栈"步骤实测栈水位收敛(G-T8-a)。
6. **验证裁剪确实生效**(见下),否则键名错被静默忽略,RAM 不会真降。

## 验证裁剪是否真生效(重要)

错误的键名会被构建**静默忽略**,裁剪等于没做。构建后必须核对:
- 检查 rmw_microxrcedds 生成的 `config.h`,确认 `RMW_UXRCE_MAX_PUBLISHERS`/
  `SUBSCRIPTIONS`/`HISTORY`/`STREAM_HISTORY` 实际值 = 我们设的值(默认 NODES=4/PUB=4/
  HISTORY=8/STREAM_HISTORY=4)。
- 检查 Micro-XRCE-DDS-Client 生成头,确认 `UCLIENT_CUSTOM_TRANSPORT_MTU=128`、各 STREAM 数生效。
- 用 `.map` 对比裁剪前后 .bss/.data,确认 RAM 真降。

## 已知不确定点(T8 编译时必须确认)

1. **CREATION_MODE = bin 是当前默认**:T5 后已从 `refs` 回到 `bin`，这样 vanilla
   micro-ROS agent 开箱即用，不需要 agent 侧 XML/ref profile。`refs` 仍可作为未来内存实验，
   但它会改变建链路径，必须重跑 T5 级建链验证。
2. 个别键在所用 micro_ros_setup 分支的暴露方式可能不同——以上面"验证裁剪是否生效"
   的实测为准,不要假设设了就生效。
3. 任务栈/heap 的具体字节数由 T8 用栈水位实测收敛,不在本配置定死。

## 键名核实来源
- rmw_microxrcedds CMakeLists (jazzy):https://raw.githubusercontent.com/micro-ROS/rmw_microxrcedds/jazzy/rmw_microxrcedds_c/CMakeLists.txt
  （确认 RMW_UXRCE_* 全部选项与默认值:MAX_HISTORY=8、STREAM_HISTORY=4[须 2 的幂]、
  MAX_NODES/PUB/SUB/SERVICES/CLIENTS=4、TRANSPORT∈{udp,tcp,serial,custom}、
  CREATION_MODE∈{bin,refs}、ALLOW_DYNAMIC_ALLOCATIONS 默认 OFF;确认 XML_BUFFER_LENGTH 不在表中）
- Micro-XRCE-DDS-Client CMakeLists:https://raw.githubusercontent.com/eProsima/Micro-XRCE-DDS-Client/master/CMakeLists.txt
  （确认 UCLIENT_* 选项与默认值:MTU 默认 512、STREAM_FRAMING 默认 ON、MAX_*_STREAMS 默认 1）
- micro-ROS rmw configuration 教程:https://github.com/micro-ROS/micro-ros.github.io/blob/master/_docs/tutorials/advanced/microxrcedds_rmw_configuration/index.md
- micro_ros_mbed 与 micro_ros_stm32cubemx_utils 的 colcon.meta(jazzy 分支)
