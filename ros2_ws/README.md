# ros2_ws — ROS2 communication workspace (Jazzy)

WSL-side ROS2 packages for the ROS2 ↔ micro-ROS minimal serial loopback.
Interface contract: `docs/01-ros2-microros-serial/01-接口契约.md` (v1.16).

## Packages

- **exo_cmd** (ament_python) — WSL command node + local MCU simulator.
  - `exo_cmd_node`: pub `/com/tp_cmd_heartbeat` (`exo_msgs/msg/ExoCmd`,
    configurable rate), sub `/com/tp_mcu_status`, verifies round-trip values.
  - `loopback_node`: Phase-A MCU stand-in. Sub `/com/tp_cmd_heartbeat`, echoes the
    same value to `/com/tp_mcu_status`.
- **com_bringup** (ament_python) — communication launch files.
  - `loopback_test.launch.py`: exo_cmd + loopback (hardware-free self-test).
  - `pc_cmd.launch.py`: exo_cmd only (for the real MCU / agent).

QoS for all `/com/*` topics (contract): RELIABLE / KEEP_LAST. Historical
self-tests use depth 10; high-rate real-hardware runs use depth 1 to avoid stale
command queueing. Defined once in `exo_cmd/exo_cmd/qos.py`.

## Source Rule

每开一个新终端，都要重新 `source`。可以先记这两类：

- 只用 PC 侧 ROS2 包：source ROS2 + 本工作区。
- 启动 micro-ROS bridge：脚本 `tools/run-bridge.sh` 会自己 source ROS2 和 `~/uros_ws`。

```bash
# 在 ~/robotics 目录执行
source /opt/ros/jazzy/setup.bash
source ros2_ws/install/setup.bash
```

如果刚改过 `ros2_ws/src/*` 里的代码，先重新 build：

```bash
cd ~/robotics/ros2_ws
source /opt/ros/jazzy/setup.bash
colcon build --packages-select exo_msgs exo_cmd com_bringup
source install/setup.bash
```

## Common Self-Tests

### 1. 无硬件回环自测

一条命令会启动 `/node_com_cmd` 和本地模拟 MCU 的 `/node_com_loopback`，并采样 topic：

```bash
cd ~/robotics/ros2_ws
./selftest_t2.sh
```

### 2. 无硬件手动启动

终端 1：

```bash
cd ~/robotics
source /opt/ros/jazzy/setup.bash
source ros2_ws/install/setup.bash
ros2 launch com_bringup loopback_test.launch.py
```

终端 2：

```bash
cd ~/robotics
source /opt/ros/jazzy/setup.bash
source ros2_ws/install/setup.bash
ros2 node list
ros2 topic list | grep /com
ros2 topic echo /com/tp_mcu_status exo_msgs/msg/ExoStatus --once
ros2 topic echo /com/tp_link_health exo_msgs/msg/LinkHealth --once
```

### 3. 真机联调

终端 1：启动 PC 串口 bridge，连接 STM32 micro-ROS。

```bash
cd ~/robotics
tools/run-bridge.sh /dev/ttyUSB0 921600
```

性能排障时可以临时开详细日志；延迟测试建议保持默认 `-v1`：

```bash
MICROROS_AGENT_VERBOSITY=6 tools/run-bridge.sh /dev/ttyUSB0 921600
```

终端 2：启动 PC 侧命令节点。

```bash
cd ~/robotics
source /opt/ros/jazzy/setup.bash
source ros2_ws/install/setup.bash
ros2 launch com_bringup pc_cmd.launch.py
```

`pc_cmd.launch.py` 默认按当前已验证稳定基线启动：20 Hz、QoS depth 2、
`rtt_warn_ms=10`、`rtt_deadline_ms=120`、`startup_grace_s=3.0`。`rtt_warn_ms`
用来提示“已经有滞后感风险”，`rtt_deadline_ms` 用来判定真正超时；
depth 2 用于 reliable/full-echo 诊断，避免 depth 1 偶发漏掉单个回显。需要退回历史
10 Hz 时：

```bash
ros2 launch com_bringup pc_cmd.launch.py cmd_rate_hz:=10 qos_depth:=10
```

200 Hz 是目标压力测试，不是当前稳定默认值：

```bash
ros2 launch com_bringup pc_cmd.launch.py cmd_rate_hz:=200 qos_depth:=1
```

实验性的 best-effort 压测需要 PC 和固件两边同时切换：

```bash
# PC 侧
ros2 launch com_bringup pc_cmd.launch.py \
  cmd_rate_hz:=200 cmd_catchup_max:=1 qos_depth:=1 qos_reliability:=best_effort

# 固件侧重新 configure/build 时使用
cmake -S firmware/f103-microros -B firmware/f103-microros/build \
  -DEXO_QOS_BEST_EFFORT=ON
```

波特率实验同样要两边一致：

```bash
cmake -S firmware/f103-microros -B firmware/f103-microros/build \
  -DEXO_UART_BAUD=2000000
tools/run-bridge.sh /dev/ttyUSB0 2000000
```

MCU 本地控制频率阶梯只影响固件本地 tick，不改变 ROS topic 名：

```bash
cmake -S firmware/f103-microros -B firmware/f103-microros/build \
  -DEXO_CONTROL_LOOP_HZ=10000
```

固件 UART transport 默认没数据时按 1 个 FreeRTOS tick 睡眠。要实验性验证“睡眠前
先 `taskYIELD()` 快速轮询几次”能否压低 RX 长尾，可以编译候选 profile：

```bash
cmake -S firmware/f103-microros -B firmware/f103-microros/build \
  -DEXO_UART_READ_POLL_YIELDS=4
```

这个选项只改变固件读串口等待策略；需要烧录后用 `tools/run-com-perf.sh` 看
sampler gap/RTT，不能只凭静态 size 判断收益。

真实控制链路压测时，可以让 MCU 仍接收每条 PC 目标，但降低状态回传频率。
例如 PC 200Hz 下发、MCU 每 20 条或 40 条回一次状态，状态 topic 约为 10Hz 或 5Hz：

```bash
cmake -S firmware/f103-microros -B firmware/f103-microros/build \
  -DEXO_STATUS_EVERY_N=40
```

如果要测试 latest-target 语义，通常还要同时切到 best-effort：

```bash
cmake -S firmware/f103-microros -B firmware/f103-microros/build \
  -DEXO_QOS_BEST_EFFORT=ON \
  -DEXO_STATUS_EVERY_N=40

ros2 run exo_cmd exo_cmd_node --ros-args \
  -p cmd_rate_hz:=200.0 \
  -p cmd_catchup_max:=1 \
  -p qos_depth:=1 \
  -p qos_reliability:=best_effort \
  -p tracking_mode:=sampled \
  -p status_every_n:=40 \
  --log-level fatal
```

同样也可以通过 launch 运行：

```bash
ros2 launch com_bringup pc_cmd.launch.py \
  cmd_rate_hz:=200 \
  cmd_catchup_max:=1 \
  qos_depth:=1 \
  qos_reliability:=best_effort \
  tracking_mode:=sampled \
  status_every_n:=40
```

推荐的 PC 侧 200Hz latest-target preset 已封装成单独 launch：

```bash
ros2 launch com_bringup pc_latest_target.launch.py
```

它默认等价于 `cmd_rate_hz=200`、`cmd_catchup_max=1`、`qos_depth=1`、
`qos_reliability=best_effort`、`tracking_mode=sampled`、`status_every_n=40`。
MCU 固件也必须用匹配 profile（`EXO_QOS_BEST_EFFORT=ON`、
`EXO_STATUS_EVERY_N=40`），否则 DDS QoS 或监控语义会不匹配。

如果要一键复现某个真机通信 profile，可以用压测脚本。它会编译/烧录固件、
重启 bridge、跑 PC node、采样 `/com/tp_mcu_status`，最后打印状态频率、
按 `status_every_n` 反推的 MCU 目标接收频率、status seq 步长
（`seq_delta_avg/min/max`，用来识别 best-effort 跳号），以及最后一条
LinkHealth summary：

```bash
CMD_RATE_HZ=200 \
CMD_CATCHUP_MAX=1 \
QOS_RELIABILITY=best_effort \
QOS_DEPTH=1 \
TRACKING_MODE=sampled \
STATUS_EVERY_N=40 \
tools/run-com-perf.sh n40_200hz
```

脚本默认跑完会停止本次 bridge；如果希望保留 bridge，追加 `KEEP_BRIDGE=1`。
如果当前固件已在板上，只想复测 PC/ROS 串口通信而不碰 ST-LINK/SWD，可以用：

```bash
BUILD_FIRMWARE=0 FLASH_FIRMWARE=0 tools/run-com-perf.sh no_flash_smoke
```

`FLASH_FIRMWARE=0` 时脚本默认也会跳过 OpenOCD reset；确实需要只 reset 不重刷时，
显式追加 `RESET_TARGET=1`。

要按阶梯一次跑完整验证矩阵，用：

```bash
tools/run-com-staircase.sh staircase_$(date +%Y%m%d_%H%M)
```

它会依次跑 1kHz/20Hz reliable baseline，然后跑 1/2/5/10kHz MCU 本地闭环
与 200Hz PC latest-target profile。单个阶段失败会写入
`log/com-staircase/<tag>.summary.log` 并继续；每个完成阶段会追加一行
`METRICS`，汇总 `sampler_hz`、gap p95/p99/max、seq 步长和
`zero_gap_count`、`lost/duplicate/inflight`。当前 ST-LINK/SWD 不可用时，
脚本会跳过需要烧录的阶梯，自动 fallback 到 no-flash smoke，继续验证串口/ROS
链路。只想看将要跑哪些阶段、不碰硬件：

```bash
DRY_RUN=1 tools/run-com-staircase.sh dryrun
```

要同时比较不同波特率，设置 `STAIRCASE_BAUDS`。这会为每个 1/2/5/10kHz
latest-target 阶段分别编译/烧录对应 `EXO_UART_BAUD` 的固件，并用同样 baud 启动
bridge：

```bash
STAIRCASE_BAUDS="921600 2000000" tools/run-com-staircase.sh baud_sweep
```

要把 UART read 低延迟候选也纳入同一个阶梯，设置
`STAIRCASE_UART_READ_POLL_YIELDS`。例如同时比较默认等待策略和 `taskYIELD`
快速轮询 4 次：

```bash
STAIRCASE_UART_READ_POLL_YIELDS="0 4" \
tools/run-com-staircase.sh poll_sweep
```

也可以同时扫波特率和 UART polling 候选：

```bash
STAIRCASE_BAUDS="921600 2000000" \
STAIRCASE_UART_READ_POLL_YIELDS="0 4" \
tools/run-com-staircase.sh baud_poll_sweep
```

阶梯跑完后，可以把 summary 转成表格或 CSV：

```bash
tools/summarize-com-staircase.sh log/com-staircase/<tag>.summary.log
FORMAT=csv tools/summarize-com-staircase.sh log/com-staircase/<tag>.summary.log
```

表格会从 stage 名拆出 `loop_hz`、`baud`、`uart_read_poll_yields`、
`pc_cmd_hz`、`qos`、`status_every_n`，方便横向比较 1/2/5/10kHz、
921600/2Mbps 和 UART polling 候选。
表格还会给每个已知 profile 标出 `verdict/reason`：baseline 按 20Hz reliable
smoke 判断，latest-target 阶段按 200Hz 目标接收率、gap 和 lost/duplicate 判断；
未知 fallback 阶段标 `INFO`。

如果某个阶段用 `MICROROS_AGENT_VERBOSITY=6` 跑过，表格里还会带
`wire_kbit_s` 和 `wire_baud_util_pct`，方便把通信频率、丢包和串口占用放在一起看。

单独跑过多个 `tools/run-com-perf.sh <tag>` 后，也可以直接横向比较这些 tag：

```bash
tools/summarize-com-perf.sh no_flash_smoke noflash_200hz_reliable_v6
FORMAT=csv tools/summarize-com-perf.sh no_flash_smoke noflash_200hz_reliable_v6
```

要生成一份当前通信验证交接报告（不会烧录、不会启动 ROS 节点，只读取已有日志并探测
ST-LINK/串口状态）：

```bash
tools/com-status-report.sh morning_$(date +%Y%m%d_%H%M)
```

报告会写到 `log/handoff/<tag>.md`，里面汇总当前 git 版本、最近提交、SWD 状态、
串口设备、最近 no-flash 指标、latest overnight summary、静态内存矩阵、栈候选和未解决项。

如果要无人值守地持续观察一晚，可用 overnight watcher。它只跑 no-flash smoke
和 handoff 报告，不 build、不 flash、不 reset：

```bash
END_AT="tomorrow 09:00" INTERVAL_SECONDS=1800 \
tools/overnight-com-watch.sh overnight_$(date +%Y%m%d_%H%M)
```

默认 `WIRE_EVERY_N=0`，不会开 micro-ROS Agent `-v6`，日志比较小。如果想每隔几轮
额外采一次同 tag 的串口线速统计，可以打开周期采样：

```bash
END_AT="tomorrow 09:00" INTERVAL_SECONDS=1800 \
WIRE_EVERY_N=6 WIRE_AGENT_VERBOSITY=6 \
tools/overnight-com-watch.sh overnight_wire_$(date +%Y%m%d_%H%M)
```

注意：`-v6` 会大量打印 micro-ROS Agent 串口帧日志，可能给 20Hz 健康判据引入额外
长尾；它适合低频诊断线速，不适合作为每轮 baseline。

日志会写到 `log/overnight-com-watch/<tag>.log`，滚动汇总表会写到
`log/overnight-com-watch/<tag>.summary.md` 和 `.csv`。每轮通信指标仍写入
`log/com-perf/`，每轮交接报告写入 `log/handoff/`。

要把某次 overnight watcher 的所有轮次汇总成表：

```bash
tools/summarize-overnight-com-watch.sh log/overnight-com-watch/<tag>.log
FORMAT=csv tools/summarize-overnight-com-watch.sh log/overnight-com-watch/<tag>.log
```

overnight 汇总默认按 20Hz no-flash smoke 标出 `PASS/WARN/FAIL` 和原因；这只是
当前板上固件的串口/ROS 健康观察，不代表 200Hz latest-target 高频 profile 已完成上板验收。
默认门槛为 `PERF_EXPECTED_RATE_HZ=20`、`lost=0`、`duplicate=0`、
`seq_delta_min/max=1/1`、`p99_gap_s<=0.10`、`max_gap_s<=0.25`；需要时可用同名
环境变量覆盖。

烧录并启动 bridge 后，可以用 SWD 粗测本地 tick 档位：

```bash
tools/measure-control-loop.sh 5 firmware/f103-microros/build/f103-microros.elf
```

也可以读取 FreeRTOS 静态栈高水位，辅助判断 RAM 优化是否安全：

```bash
tools/measure-stack-hwm.sh firmware/f103-microros/build/f103-microros.elf
```

这个脚本通过 GDB 读 RAM，会短暂停核；不要和 `ros2 topic hz` 这类实时测量同时跑。
如果只想看固件静态 Flash/RAM、任务栈大小和最大符号，不需要连接硬件：

```bash
tools/firmware-size-report.sh firmware/f103-microros/build/f103-microros.elf
```

要比较 1/2/5/10kHz、reliable/best-effort 等固件 profile 的静态
Flash/RAM，不需要连接硬件，可以跑：

```bash
tools/firmware-size-matrix.sh current
```

结果会写到 `log/firmware-size-matrix/current.md` 和
`log/firmware-size-matrix/current.csv`；中间构建目录在
`firmware/f103-microros/build-size-matrix/`。这只做编译和 size 统计，
不会烧录、不会碰 ST-LINK/SWD。表格默认按 F103RB `Flash=131072B`、
`SRAM=20480B`、`RAM_STATIC_WARN_BYTES=18432B` 输出 `verdict/reason` 和余量。

要比较 micro-ROS 任务栈候选大小的静态 RAM 收益，也不需要连接硬件：

```bash
tools/firmware-stack-sweep.sh current_stack
```

默认会在 10kHz/best-effort/status_every_40 profile 下比较 768/704/640 words，
输出 `log/firmware-stack-sweep/current_stack.md` 和 `.csv`。这只是静态编译
候选，不能替代上板后的 `tools/measure-stack-hwm.sh` 水位复测。表格中的
`PASS_STATIC` 只表示静态 Flash/RAM 在预算内，仍必须复测运行期栈水位。

固件 DWT timestamp 的双缓冲快照算法可以在 PC 上跑模型测试，不需要连接硬件：

```bash
tools/test-dwt-snapshot-model.sh
```

它覆盖 32-bit CYCCNT 回绕、>60s 静默恢复、writer 半更新期间的 reader 抢占和
generation 变化重读。真实 stamp 单调性仍要等 SWD 恢复后上板跑 >60s 静默恢复对抗。

要估算 micro-ROS Agent debug log 里的串口字节率和波特率占用，需要 bridge 用
`-v6` 生成 `SerialAgentLinux.cpp send_message/recv_message` 行：

```bash
MICROROS_AGENT_VERBOSITY=6 \
BUILD_FIRMWARE=0 FLASH_FIRMWARE=0 \
tools/run-com-perf.sh wirestats_debug

tools/agent-wire-stats.sh log/com-perf/wirestats_debug.bridge.log
```

`run-com-perf.sh` 在 `MICROROS_AGENT_VERBOSITY>=6` 时会自动生成
`log/com-perf/<tag>.wire.log`，并打印一行 `wire_metrics=...`。这个指标只看串口
帧长和线速占用，用来判断 baudrate/消息瘦身/状态降频是否值得做；链路正确性仍以
`status_sampler` 和 LinkHealth 为准。

终端 3：查看通信结果。

```bash
cd ~/robotics
source /opt/ros/jazzy/setup.bash
source ros2_ws/install/setup.bash
ros2 node list
ros2 topic list | grep /com
ros2 topic echo /com/tp_mcu_status exo_msgs/msg/ExoStatus --once
ros2 topic echo /com/tp_link_health exo_msgs/msg/LinkHealth --once
ros2 topic hz /com/tp_mcu_status
```

### 4. 真机一键验收

```bash
cd ~/robotics
source /opt/ros/jazzy/setup.bash
source ros2_ws/install/setup.bash
ros2_ws/scripts/hw_acceptance.sh all 20
```

## Build & Self-Test Detail

```bash
# 1. go to repo root
cd ~/robotics

# 2. ROS2 env
source /opt/ros/jazzy/setup.bash

# 3. build (from the workspace root: ros2_ws/)
cd ros2_ws
colcon build

# 4. overlay the freshly-built workspace
source install/setup.bash

# 5. start the full Phase-A loopback (exo_cmd + MCU simulator)
ros2 launch com_bringup loopback_test.launch.py
```

In a second terminal (each new terminal needs the two `source` lines above):

```bash
cd ~/robotics
source /opt/ros/jazzy/setup.bash
source ros2_ws/install/setup.bash

# watch the echoed values (should be the same increasing counter)
ros2 topic echo /com/tp_mcu_status

# confirm QoS matches the selected profile (RELIABLE / KEEP_LAST / depth)
ros2 topic info -v /com/tp_cmd_heartbeat
ros2 topic info -v /com/tp_mcu_status
```

Pass: `/com/tp_mcu_status` carries the same monotonically increasing values that
`node_com_cmd` publishes on `/com/tp_cmd_heartbeat`, and the node logs matched
sequence numbers.
