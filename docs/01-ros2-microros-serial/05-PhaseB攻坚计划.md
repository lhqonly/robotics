# Phase B 攻坚计划：WSL ↔ STM32F103 真机 pub/sub 打通

> 作者：elon（设计），主 agent 代笔落盘（2026-06-19）。目标：**今天把 WSL(ROS2 Jazzy) ↔ Nucleo-F103RB(micro-ROS) 真机双向 pub/sub 完全打通**。任务卡 T3/T4/T5/T8 见 B 节，本文为 Phase B 的权威执行计划（`02-任务卡-Tom.md` 的 T3~T8 以此为准）。

## A. 关键路径与最快可行路线

### A.0 核心判断
T8（20KB spike）不是独立于 T4 的东西——它就是「T4 骨架 + libmicroros 链接 + 最小 1-pub 应用」第一次合体烧板。真正的关键路径是一条线，中间插三个**增量验收里程碑**，任一里程碑亮红灯就地停、不憋大招。

### A.1 关键路径（串行主链）+ 可并行项
```
   [并行线 1: WSL 侧]                    [并行线 2: 固件侧]
M0  T3 装 micro_ros_agent(源码/docker)    T4 F103 裸机骨架(点灯/串口自检)
    产出 run-agent.sh          ┐         + generate_lib 产出 libmicroros.a
                               │         (两步互不依赖，真并行)
                               └────┬───────────────┘
                                    ▼
M1 ★里程碑①  T8: 骨架+libmicroros+最小1-pub → 烧板 → agent 看到 client/session created
              (这一刻回答"20KB 跑不跑得下"的 go/no-go 大头)
                                    ▼
M2 ★里程碑②  T5a 单向: MCU pub /exo/mcu_status，WSL `ros2 topic echo` 收到稳定计数
                                    ▼
M3 ★里程碑③  T5b 双向: WSL pub /exo/cmd_heartbeat → MCU sub → 原样回填 pub → WSL 配对成功
                                    ▼
M4 收尾  .map 量 RAM/Flash + uxTaskGetStackHighWaterMark 栈水位 → 最终 go/no-go(T8 验收)
```
**关键路径 = T4(骨架) → T8(合体起 session) → T5a(单向) → T5b(双向) → M4(量化)**。T3 完全并行，不在关键路径上（但 M1 需要它就绪）。

### A.2 里程碑红绿灯
| 里程碑 | 产物 | 验收信号（绿） | 红灯处置 |
|---|---|---|---|
| M0-A T3 | `tools/run-agent.sh` | `micro_ros_agent --help` 有输出；脚本能开 `/dev/ttyACM0` 不报 busy/permission | docker fallback |
| M0-B T4 | 可烧 `.elf/.bin`；LED 闪 + USART2 自检串 | `cat /dev/ttyACM0` 看到上电自检；`readelf -A` 为 M3 无 VFP | 时钟/BRR 排障(见 C) |
| **M1 ★** T8 | 骨架+libmicroros+1pub 烧板 | agent `-v6` 打印 session established / create participant | 链接溢出/起不来 → C 的降级判定 |
| **M2 ★** T5a | MCU 单向 pub | `ros2 topic echo /exo/mcu_status` 单调递增 Int32 | transport read/write 回调打桩排查 |
| **M3 ★** T5b | 双向回环 | WSL `exo_cmd` 配对成功、值回环一致(§2)；监控无异常驱逐 | sub 路径单独验，先确认 cmd 到 MCU |
| M4 | RAM/Flash/栈水位实测 | `.map` RAM<20KB 有裕度；HWM_min ≥ 安全余量；N 分钟无 hardfault | 见 C 降级预案 |

### A.3 「今天」时间盒（诚实版）
- T3 + T4 并行，各约 1–3h（T4 裸机骨架是今天最大纯手工活）。
- **M1 起 session 是今天首要目标**——M1 绿，"20KB 能跑 micro-ROS"基本证实，今天就赢了大半。
- M2 单向、M3 双向能赶到就赶，赶不到明天。不为凑双向跳过 M1 量化观察。
- **硬纪律：先单向(write)再双向(加 read)**，把排障空间砍半。

## B. 任务卡（T3/T4/T5/T8）

### T3：micro_ros_agent（WSL/Jazzy）
**结论（联网核实 2026-06-19）**：❌ 不存在 apt 包 `ros-jazzy-micro-ros-agent`（apt 里 micro-ros 只有 diagnostic-bridge/msgs，无 agent）→ 走【方案 A 源码 build】(首选) 或【方案 B docker】(兜底)。

**方案 A（首选）**（含 source 的命令主 agent 跑；`[SUDO]` 用户在交互终端手动跑）：
1. `[SUDO]` `sudo apt update && sudo apt install -y python3-rosdep`
2. `[SUDO]` （若没初始化过）`sudo rosdep init`（已 init 报已存在可忽略）
3. `[主agent]` `mkdir -p ~/uros_ws/src && git clone -b jazzy https://github.com/micro-ROS/micro_ros_setup.git ~/uros_ws/src/micro_ros_setup`
4. `[主agent]` `set +u; source /opt/ros/jazzy/setup.bash; cd ~/uros_ws; rosdep update; rosdep install --from-paths src --ignore-src -y`（缺包则 `[SUDO]` 用户补）
5. `[主agent]` `colcon build; set +u; source ~/uros_ws/install/local_setup.bash`
6. `[主agent]` `ros2 run micro_ros_setup create_agent_ws.sh; ros2 run micro_ros_setup build_agent.sh; source ~/uros_ws/install/local_setup.bash`
7. 自检：`ros2 run micro_ros_agent micro_ros_agent --help` 有输出即装好。

**方案 B（兜底）docker**：`[SUDO]` `sudo apt install -y docker.io && sudo usermod -aG docker $USER`（重开 shell）；`docker run -it --rm -v /dev:/dev --privileged --net=host microros/micro-ros-agent:jazzy serial --dev /dev/ttyACM0 -b 921600 -v6`

**产出 `tools/run-agent.sh`**（Tom 写，主 agent 跑）：source ROS + uros_ws，`exec ros2 run micro_ros_agent micro_ros_agent serial --dev ${1:-/dev/ttyACM0} -b ${2:-921600} -v6`。`-v6` 起 session 时能看到 client/participant 创建日志（M1 验收靠它）。

**验收（Gill，G-B-1 收口）**：`--help` 有输出；脚本能开 ttyACM0 不报 permission/busy；无板时 `-v6` 周期打印等待；记录方案 A/B + agent 版本。

### T4：F103 裸机骨架（里程碑 M0-B）
**目标**：能编译+烧+点灯+串口自检的最小裸机骨架，不碰 micro-ROS。

**工程结构**（放 `firmware/f103-microros/`，与 colcon.meta 同目录）：顶层 `CMakeLists.txt`（裸 CMake + arm toolchain）、`toolchain-arm-m3.cmake`、`STM32F103RB_FLASH.ld`（Flash 128K @0x08000000 / RAM 20K @0x20000000）、`startup_stm32f103xb.s`（CMSIS 官方）、`src/main.c`、`system_stm32f1xx.c`、`stm32f1xx_it.c`、CMSIS + stm32f1xx HAL 子集、`ThirdParty/FreeRTOS/`（内核 + portable/GCC/ARM_CM3 + heap_4 或 static）。

**工具链 flags（硬约束，三个一起改否则 ABI 不匹配）**：`-mcpu=cortex-m3 -mthumb`（无 `-mfpu`、无 hard-float → soft）；`-ffunction-sections -fdata-sections` + 链接 `-Wl,--gc-sections`；`-Wl,-Map=output.map`；`-Wl,--print-memory-usage`。固件路径禁浮点。

**时钟树（务必配对否则 BRR 错）**：HSE 8MHz → PLL×9 = 72MHz SYSCLK；AHB/1=72M；APB1/2=36M（USART2 挂这）；APB2/1=72M；Flash 2 等待周期。USART2 BRR 由 HAL 按 `HAL_RCC_GetPCLK1Freq()`=36MHz 自动算 921600（误差 +0.16%）。

**USART2+DMA（PA2=TX/PA3=RX 经 VCP）**：8N1/921600/无流控；DMA RX circular + USART IDLE 中断收变长帧、TX 单缓冲（本卡先搭通路做自检）；buffer 静态 .bss，按 128B 对齐。

**权衡（Tom 自决）**：建议 stm32f1xx HAL 子集（LL 也可），速度优先。⚠️ F1 的 GPIO/USART/DMA HAL 与 F4 模型不同（F1=输入输出模式+CNF+AFIO 重映射；F4=MODER/AFR per-pin AF），不能照抄 F4 的 `MX_USART2_UART_Init`。

**FreeRTOS**：port=GCC/ARM_CM3；`configSUPPORT_STATIC_ALLOCATION=1` 优先；用 dynamic 则 heap_4 + 明确上界 `configTOTAL_HEAP_SIZE`（从小往上调）。先起 1 个 task 做 LED + 串口自检。

**验收（Gill）**：G-T4-a `readelf -A` 显示 Tag_CPU_arch=v7(M3) 无 VFP；G-T4-b `.map`/`size` 读出 RAM<20KB 有裕度、Flash<128KB，`--print-memory-usage` 留档；LED 闪；`cat /dev/ttyACM0` 看到上电自检串（证 USART1@921600+DMA 收发通）；复位重连稳定。

### T5：micro-ROS 集成（libmicroros + custom transport + 双向应用）
拆 **T5a（单向，M2）/ T5b（双向，M3）** 两步交付。

**第一步：生成 libmicroros.a（主 agent 跑，核实 2026-06-19）**：
1. `source /opt/ros/jazzy + ~/uros_ws/install/local_setup.bash`
2. `cd ~/uros_ws; ros2 run micro_ros_setup create_firmware_ws.sh generate_lib`
3. 写 `toolchain.cmake`（给 generate_lib 用，**M3 flags 必须与 T4 完全一致**）：含 `set(CMAKE_SYSTEM_NAME Generic)`、`set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)`（关键，否则 try_compile 失败）、`arm-none-eabi-gcc/g++`、`-mcpu=cortex-m3 -mthumb ...`。
4. **⚠️ 参数顺序：toolchain 在前，colcon.meta 在后**：`ros2 run micro_ros_setup build_firmware.sh $(pwd)/toolchain.cmake /home/lhq24/robotics/firmware/f103-microros/colcon.meta`
5. 产物：`firmware/build/libmicroros.a` + `firmware/build/include/` → 拷进 `firmware/f103-microros/` 供裸 CMake 链接。
6. **核实裁剪生效**（键名错会被静默忽略）：检查生成的 rmw `config.h`，`RMW_UXRCE_MAX_PUBLISHERS/SUBSCRIPTIONS/HISTORY/STREAM_HISTORY`=1/1/1/1、`UCLIENT_CUSTOM_TRANSPORT_MTU`=128。

**custom transport 4 回调（签名已联网核实，verbatim）**：注册 `rmw_uros_set_custom_transport(true /*framing*/, &uart_args, open, close, write, read)`。
- `bool f103_transport_open(uxrCustomTransport* t)` — 起 USART2+DMA，成功 true
- `bool f103_transport_close(uxrCustomTransport* t)` — 停外设
- `size_t f103_transport_write(uxrCustomTransport* t, const uint8_t* buf, size_t len, uint8_t* err)` — 返回实际写出字节数
- `size_t f103_transport_read(uxrCustomTransport* t, uint8_t* buf, size_t len, int timeout, uint8_t* err)` — timeout 毫秒，返回读到字节数（可 0，超时返 0 不算错）
buffer 全静态 .bss，一次收发/MTU 按 128B 对齐（串口预算 ≈640B，见 colcon.meta README）。

**rclc 应用骨架**：`rclc_support_init` → `rclc_node_init_default(&node,"exo_mcu",...)` → publisher `/exo/mcu_status`(Int32, **RELIABLE depth=1**) → subscription `/exo/cmd_heartbeat`(Int32, **RELIABLE depth=1**) → `rclc_executor` add subscription(ON_NEW_DATA) → 回调原样回填 `status.data=m->data; rcl_publish(...)` → FreeRTOS task 里 `rclc_executor_spin_some`。⚠️ micro-ROS 默认 best-effort，**必须显式设 reliable** 否则与 WSL 侧匹配失败。

**交付拆分**：T5a 先只做 publisher + write 路径（M2）；T5b 加 subscription + executor + read（M3），并并入 gill 发现 #1（settled_window 把 F103 depth=1 的 RELIABLE 重传误报 UNMATCHED — 区分 never-sent 真错 vs stale-retransmit 超窗重传）。

**验收（Gill）**：M1 前置 session created；M2 `topic echo /exo/mcu_status` 单调递增无大量帧错；M3 值回环一致(§2)、监控配对无静默驱逐误报；G-T7 A1–A8 真机复现（尤其 A2 延迟/A3 丢包、921600 无大量 CRC）；读回 config.h 确认裁剪生效。

**不在范围**：exo_msgs（时间戳/seq/CRC，演进阶段）；多线程 executor（当前单线程）。

### T8：去风险 / 集成验收（20KB go/no-go，M1+M4）
**目标**：T4 骨架 + libmicroros + 最小 1-pub 应用，真机编译+烧+起 session，以 `.map` + 栈水位回答"20KB 跑不跑得下"。产出 go/no-go，不是完整功能。

**执行**：链接（undefined ref/multiple def 优先查 ABI flag 是否与 toolchain.cmake 一致）→ 最小 1-pub 应用（触发完整 client+rmw+xrce 内存路径）→ 起 agent + 烧板看 `-v6`（⚠️ ST-Link SWD 烧录与 VCP 共用 USB，烧录走 WSL st-flash，别让 Windows 抢；烧完 agent 再占串口）→ 量化：`size`/`.map` RAM(.data+.bss)/Flash 实际 KB+裕度；栈起测 ~2500 words 不溢出，周期读 `uxTaskGetStackHighWaterMark`，新栈=当前−HWM_min+余量(≥128 words)，迭代收敛；`xPortGetMinimumEverFreeHeapSize` 确认 heap 未触底；多跑几分钟覆盖重连/重传。

**go/no-go**：GO=session 稳定 + RAM 正裕度 + HWM_min≥余量 + N 分钟无 hardfault → 放行 T5。NO-GO=链接溢出/session 起不来/栈或 heap 触底反复 hardfault → **回来找用户拍板**（降功能/换协议/换芯，已确认流程）。灰区=能起 session 但裕度<余量 → 先降单向再评估，仍不行回用户。

## C. 对「今天打通」的最大风险 + 缓解

| # | 风险 | 缓解 / 降级 |
|---|---|---|
| **R1** | **20KB RAM 装不下**（项目级真风险，官方≥32KB，issue#35 同款踩溢出） | 已有最窄 colcon.meta + 砍浮点 + 串口预算 ≈640B；M1 先证起 session 别憋双向；灰区先降单向；真 no-go 回用户 |
| **R2** | **裸机 custom transport 从零写**（DMA circular+IDLE+4 回调，今天最大手工活） | 硬纪律先单向(write)再双向(read)；见 C.2 polling-first 建议 |
| **R3** | **micro_ros_setup 在 Jazzy 的坑**（rosdep/generate_lib try_compile） | toolchain.cmake 必含 `CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY`；rosdep 缺包 SUDO 补；整体卡死 → docker agent 兜底 |
| **R4** | **F1 HAL 与 F4 差异 + 时钟没配对 → BRR 错** | T4 按 F1 模型重写；锁 72/36/72 + Flash 2WS；M0-B 串口自检先证波特率对 |
| **R5** | **ST-Link SWD 烧录与 VCP 争用同一 USB** | 统一 WSL 内 st-flash 烧录+联调；烧录与起 agent 串行，别同占 |
| **R6** | **DMA 时序今天调不完**（半传输/完成/IDLE 三类中断协调） | 见 C.2 |

### C.2 ★ 一个建议放宽的次级决策（需用户拍板）
保留「裸 CMake + 自定义 USART2+DMA custom transport」的**接口与方向**（它是终极实时控制环延迟可控的根基，见 [[control-loop-latency-is-safety-critical]]）。但为「今天打通」，建议**临时降级 transport 的内部实现，不动接口**：

> **建议：T5a 的 custom transport 回调内部今天先用「阻塞/轮询式 USART 收发」（read 轮询+软件超时，write 轮询发完），把 DMA circular+IDLE 推迟到 M3 之后做优化。**
> - 接口契约完全不变（还是那 4 个回调、custom transport、921600），只是回调"肚子里"今天先不上 DMA。
> - 收益：把今天最易翻车的 R2/R6（DMA 环形+IDLE 时序）从关键路径摘掉，"今天起 session+单向通"概率大幅提升。
> - 代价：阻塞式占 CPU、吞吐/实时性差——但最小闭环只有 10Hz×Int32 完全够用；违背"DMA"物理层契约**这一条**，故需用户点头：今天先 polling 打通、**DMA 作为紧随其后的 Phase B 优化项（不丢）**。
> - 若坚持今天就要 DMA：可以，但接受"今天可能只到 M0-B/M1，M2/M3 顺延明天"。

其余锁定决策（F103/裸 CMake/FreeRTOS/micro-ROS over serial/921600/双向）均非今天致命阻塞，维持不变。唯一真正可能让今天"打不通"的是 R1(20KB)，它靠 M1 实测证实/证伪，故 M1 设为今日首要里程碑。

## 关键来源（联网核实 2026-06-19）
- micro_ros_setup jazzy README（create_agent_ws/build_agent/create_firmware_ws）
- 自定义静态库 generate_lib + build_firmware + toolchain.cmake + libmicroros.a：micro.ros.org create_custom_static_library
- custom transport 4 回调签名 + rmw_uros_set_custom_transport + framing：micro-ros create_custom_transports
- apt 实测：无 `ros-jazzy-micro-ros-agent`（只有 diagnostic-bridge/msgs）→ agent 必须源码或 docker
- micro-ROS Build System；STM32 cubemx_utils 回调命名参考
