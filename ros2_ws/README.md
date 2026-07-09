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

`EXO_CONTROL_LOOP_HZ>1000` 时固件使用 TIM2 ISR 驱动本地控制 tick。默认
`EXO_CONTROL_TIMER_IRQ_PRIORITY=4`，高于 FreeRTOS syscall critical section，
用于减少 micro-ROS/ROS 通信侧临界区带来的闭环抖动；ISR 不调用 FreeRTOS API，
latest target 用双缓冲提交，避免读到半更新的 `seq/payload`。如果需要保守地让
TIM2 也被 FreeRTOS critical section 屏蔽，可以设为 5：

```bash
cmake -S firmware/f103-microros -B firmware/f103-microros/build \
  -DEXO_CONTROL_LOOP_HZ=10000 \
  -DEXO_CONTROL_TIMER_IRQ_PRIORITY=5
```

固件 UART transport 默认没数据时按 1 个 FreeRTOS tick 睡眠。要实验性验证“睡眠前
先 `taskYIELD()` 快速轮询几次”能否压低 RX 长尾，可以编译候选 profile：

```bash
cmake -S firmware/f103-microros -B firmware/f103-microros/build \
  -DEXO_UART_READ_POLL_YIELDS=4
```

这个选项只改变固件读串口等待策略；需要烧录后用 `tools/run-com-perf.sh` 看
sampler gap/RTT，不能只凭静态 size 判断收益。

MCU micro-ROS executor 默认 `spin_some` 最多等 1000us。要实验性验证更短等待
能否降低串口响应长尾，可以编译候选 profile：

```bash
cmake -S firmware/f103-microros -B firmware/f103-microros/build \
  -DEXO_EXECUTOR_SPIN_TIMEOUT_US=200
```

这个选项只改变 executor 等待上限；agent 掉线检测已经按 FreeRTOS tick 计时，不依赖
spin 循环次数。收益仍要烧录后看 sampler gap/RTT。

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
`qos_reliability=best_effort`、`tracking_mode=sampled`、`status_every_n=40`、
`sample_window=1024`、`summary_period_s=5.0`、`link_health_period_s=5.0`。
这组参数的含义是：

| 参数 | 默认值 | 用途 |
|---|---:|---|
| `cmd_rate_hz` | `200` | PC/ROS 下发 latest target 的目标频率 |
| `cmd_catchup_max` | `1` | ROS timer 偶发慢一拍时允许补发 1 条，贴近长期 200Hz |
| `qos_reliability` | `best_effort` | 控制目标采用“最新值优先”，避免 reliable 重传拖慢实时链路 |
| `status_every_n` | `40` | MCU 每 40 条命令回一次状态，200Hz 下约 5Hz 状态 topic |
| `sample_window` | `1024` | PC 侧 sampled 匹配窗口，200Hz 下覆盖约 5.1s |
| `summary_period_s` | `5.0` | 降低 PC 诊断 summary timer 对 200Hz command timer 的干扰 |
| `link_health_period_s` | `5.0` | 降低 `/com/tp_link_health` 发布频率，保留链路健康观测但减少热路径负载 |

逐条发送日志默认关闭，避免 200Hz/1000Hz 热路径里为 debug 文本产生额外分配；
排障时可临时追加 `log_sent_commands:=true`。
MCU 固件也必须用匹配 profile（`EXO_QOS_BEST_EFFORT=ON`、
`EXO_STATUS_EVERY_N=40`），否则 DDS QoS 或监控语义会不匹配。

如果要一键复现某个真机通信 profile，可以用压测脚本。它会编译/烧录固件、
重启 bridge、跑 PC node、采样 `/com/tp_mcu_status`，最后打印状态频率、
按 `status_every_n` 反推的 MCU 目标接收频率、status seq 步长
（`seq_delta_avg/min/max`，用来识别 best-effort 跳号）、PC 命令发布 gap
（`pc_wire_gap_p95/p99/max_ms`，用来识别 ROS 侧 timer 长尾），以及最后一条
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

`tools/run-com-perf.sh` 默认传 `log_sent_commands:=false`。如果确实要看每条
PC 命令发送日志，可用 `LOG_SENT_COMMANDS=true` 临时打开；正式 200Hz/1000Hz
性能采样保持默认关闭。
当脚本识别到 `best_effort + sampled + status_every_n>1` 的 latest-target
profile，且你没有显式设置 `SUMMARY_PERIOD_S` / `LINK_HEALTH_PERIOD_S` 时，
会自动把二者默认到 5s，和 `pc_latest_target.launch.py` 保持一致。
只想确认脚本最终会采用哪些参数、不访问串口和 ST-LINK 时，可以用：

```bash
PRINT_CONFIG_ONLY=1 QOS_RELIABILITY=best_effort TRACKING_MODE=sampled \
STATUS_EVERY_N=40 tools/run-com-perf.sh config_preview
```

脚本默认 `SAMPLE_WINDOW=1024`，在 200Hz 下约覆盖 5.1s、1000Hz 下约覆盖
1.0s，远大于当前 `rtt_deadline_ms=120ms`；需要更长 sampled 匹配窗口时可覆盖
`SAMPLE_WINDOW=<n>`。

注意：`tracking_mode=sampled` 下，LinkHealth 的 `lost=0` 只表示已经收到的
sampled status 能和最近发送窗口匹配；未回来的降频状态不会像 full-echo 那样自动
计为 lost。状态漏样/跳号要看 `status_sampler` 的 `seq_delta_avg/min/max`、
`sampler_target_rx_hz` 和 gap 指标。

```bash
LOG_SENT_COMMANDS=true BUILD_FIRMWARE=0 FLASH_FIRMWARE=0 \
tools/run-com-perf.sh debug_sent_commands
```

脚本默认跑完会停止本次 bridge；如果希望保留 bridge，追加 `KEEP_BRIDGE=1`。
如果当前固件已在板上，只想复测 PC/ROS 串口通信而不碰 ST-LINK/SWD，可以用：

```bash
BUILD_FIRMWARE=0 FLASH_FIRMWARE=0 tools/run-com-perf.sh no_flash_smoke
```

`FLASH_FIRMWARE=0` 时脚本默认也会跳过 OpenOCD reset；确实需要只 reset 不重刷时，
显式追加 `RESET_TARGET=1`。
默认 echo/status_every_1 基线会执行健康门槛：sampler 频率在目标频率附近、
status seq 不跳号、`lost=0`、`duplicate=0`、gap 不超过默认阈值，否则脚本退出
非 0。对 sampled/latest-target profile，脚本用 `sampler_target_rx_hz`
（`sampler_hz * status_every_n`）判断 MCU 目标接收进度是否接近 PC 命令频率；
此时不要求每个 status 的 seq delta 都等于 1，因为状态本来就是降频采样。
gap 阈值默认 `auto`：20Hz 基线为 p99<=0.10s/max<=0.25s，高频或
`status_every_n>1` 为 p99<=0.50s/max<=1.00s。刻意采集压力失败样本时可关闭门槛：

```bash
REQUIRE_HEALTH_PASS=0 CMD_RATE_HZ=200 \
BUILD_FIRMWARE=0 FLASH_FIRMWARE=0 \
tools/run-com-perf.sh pressure_collect_only
```

如果要验证 PC 主机调度是否导致 command timer 长尾，可以给 PC command node 加
launch prefix。常用的低权限实验是绑到某个 CPU 核，跑完后对比
`pc_wire_gap_p95/p99/max_ms`：

```bash
PC_LAUNCH_PREFIX="taskset -c 2" \
BUILD_FIRMWARE=0 FLASH_FIRMWARE=0 \
tools/run-com-perf.sh no_flash_taskset_cpu2
```

也可以用 sweep 脚本一次比较 baseline 和多个绑核候选。它只跑 no-flash，不会
build、flash 或 reset：

```bash
TASKSET_CPUS="2 3" RUNS=2 \
tools/run-pc-scheduler-sweep.sh pc_sched_$(date +%Y%m%d_%H%M)
```

结果会写到 `log/pc-scheduler-sweep/<tag>.metrics.md/.csv`，原始通信日志仍在
`log/com-perf/`。

对 200Hz latest-target 方向做 PC 调度对比时，把 high-rate 参数也一起显式传入；
脚本会把这些参数写进 summary，并原样传给 `run-com-perf.sh`：

```bash
CMD_RATE_HZ=200 CMD_CATCHUP_MAX=1 \
QOS_RELIABILITY=best_effort QOS_DEPTH=1 \
TRACKING_MODE=sampled STATUS_EVERY_N=40 \
SUMMARY_PERIOD_S=5.0 LINK_HEALTH_PERIOD_S=5.0 \
REQUIRE_CORE_METRICS=0 REQUIRE_HEALTH_PASS=0 \
EXECUTOR_THREADS=0 TASKSET_CPUS="2 3" RUNS=2 \
tools/run-pc-scheduler-sweep.sh pc_sched_200hz_$(date +%Y%m%d_%H%M)
```

`REQUIRE_CORE_METRICS=0 REQUIRE_HEALTH_PASS=0` 用于当前“PC 侧 200Hz 发包证据”
场景：即使 MCU 固件 QoS 还没刷成 best-effort、没有真实 match，也能继续比较 PC
发包间隔。等 MCU/PC QoS 已匹配后，把这两个开关恢复为 `1` 做严格验收。
`EXECUTOR_THREADS=0` 表示让 rclpy 自动选择线程数；可以改成 `2` 单独复跑一次，
用 metrics 表里的 `pc_wire_gap_p95/p99/max_ms`、`lost`、`duplicate` 对比。

如果要比较更具体的调度策略，可以用多行 `PC_SCHEDULER_CASES`。每行格式为
`label|launch_prefix`，空 prefix 用 `label|`：

```bash
PC_SCHEDULER_CASES=$'default|\ntaskset_cpu2|taskset -c 2\nbatch|chrt -b 0' \
RUNS=2 tools/run-pc-scheduler-sweep.sh pc_sched_custom_$(date +%Y%m%d_%H%M)
```

`chrt -b 0` 通常不需要额外权限；`chrt -f/-r` 这类实时调度通常需要 root 或
`CAP_SYS_NICE`，建议只在明确授权的测试机上使用。
调度 sweep 默认会继续跑完所有 case，并用 metrics 表里的 `PASS/WARN/FAIL` 表示
候选好坏；如果要让任一失败 case 使脚本整体返回非 0，追加
`FAIL_ON_CASE_ERROR=1`。

要无人值守地跑一轮“先诊断、再选择最好可用路径”的验证 cycle，用：

```bash
tools/run-com-validation-cycle.sh validation_$(date +%Y%m%d_%H%M)
```

这个入口会先运行只读 SWD 诊断。日志里如果出现 `PATH full_staircase`，说明
`SWD_STATUS=ok`，脚本会继续跑完整 1/2/5/10kHz × 921600/2000000 staircase，
再用 `tools/check-com-staircase-contract.py` 做上板验收检查；如果出现
`PATH no_flash_fallback`，说明当前不能可靠烧录/访问 target，脚本会自动跑
no-flash smoke 和 `tools/com-status-report.sh`，保留串口/ROS 侧证据和未解决项，
但不会把 fallback 当成完整上板验收。只想预览路径、不碰硬件：

```bash
DRY_RUN=1 tools/run-com-validation-cycle.sh dry_cycle
SWD_STATUS_OVERRIDE=ok DRY_RUN=1 tools/run-com-validation-cycle.sh dry_full
```

要按阶梯拆开跑完整验证矩阵，用：

```bash
tools/diagnose-swd.sh
tools/run-com-staircase.sh staircase_$(date +%Y%m%d_%H%M)
```

`tools/diagnose-swd.sh` 只读检查 ST-LINK/SWD，不会 reset 或 flash。输出里
`SWD_STATUS=ok` 时再跑完整 staircase；如果是 `bad_unknown_target` 或
`bad_probe_failed`，先按脚本里的 recovery checklist 检查 usbip 独占、供电、
BOOT0/RESET、SWDIO/SWCLK/NRST 和共地。需要给自动化 gate 用时可加
`STRICT=1 tools/diagnose-swd.sh`，SWD 未恢复会返回非 0。

它会依次跑 1kHz/20Hz reliable baseline，然后跑 1/2/5/10kHz MCU 本地闭环
与 200Hz PC latest-target profile；latest-target 默认同时比较 `921600` 和
`2000000` 两个 baud。单个阶段失败会写入
`log/com-staircase/<tag>.summary.log` 并继续；每个完成阶段会追加一行
`METRICS`，汇总 `sampler_hz`、gap p95/p99/max、seq 步长和
`zero_gap_count`、`lost/duplicate/inflight`、`qos_incompatibility`。当前 ST-LINK/SWD 不可用时，
脚本会跳过需要烧录的阶梯，自动 fallback 到 no-flash smoke，继续验证串口/ROS
链路。只想看将要跑哪些阶段、不碰硬件：

阶梯的目的不是让 PC/ROS 直接跑 1/2/5/10kHz，而是验证“MCU 本地闭环频率提高后，
200Hz PC latest-target 通信是否仍然稳定”。因此收益判断主要看每档的
`sampler_target_rx_hz` 是否接近 200Hz、`pc_wire_gap_p99/max_ms` 是否收敛、
`lost/duplicate` 是否为 0，以及状态回传 gap 是否没有长尾失控。高频 latest-target
还会在 `run-com-perf.sh` 输出 `pc_cmd_catchup_events` 和
`pc_cmd_catchup_extra`：它们表示 PC timer 晚到后靠 `cmd_catchup_max` 补发的次数
和额外命令数。这个值越低，说明 200Hz 发包越接近稳定定时，而不是靠 burst 追平。

```bash
DRY_RUN=1 tools/run-com-staircase.sh dryrun
```

默认已经比较 `921600` 与 `2000000`。如果只想收窄或扩展波特率矩阵，设置
`STAIRCASE_BAUDS`；这会为每个 1/2/5/10kHz latest-target 阶段分别编译/烧录
对应 `EXO_UART_BAUD` 的固件，并用同样 baud 启动 bridge：

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

要把 executor `spin_some` 等待上限也纳入阶梯，设置
`STAIRCASE_EXECUTOR_SPIN_TIMEOUT_US`：

```bash
STAIRCASE_EXECUTOR_SPIN_TIMEOUT_US="1000 500 200 100" \
tools/run-com-staircase.sh spin_timeout_sweep
```

要把 PC 侧调度策略也纳入 latest-target 阶梯，设置多行
`STAIRCASE_PC_LAUNCH_PREFIX_CASES`。每行格式为 `label|launch_prefix`，空 prefix
用 `label|`；多 case 时阶段名会追加 `pc<label>`，避免日志互相覆盖：

```bash
STAIRCASE_PC_LAUNCH_PREFIX_CASES=$'default|\ntaskset_cpu2|taskset -c 2' \
tools/run-com-staircase.sh pc_sched_staircase
```

要比较 TIM2 本地闭环中断优先级，设置
`STAIRCASE_CONTROL_TIMER_IRQ_PRIORITIES`。例如同时比较高优先级 `4` 和
FreeRTOS syscall 边界附近的 `5`：

```bash
STAIRCASE_CONTROL_TIMER_IRQ_PRIORITIES="4 5" \
tools/run-com-staircase.sh irq_priority_sweep
```

这些维度可以组合使用；矩阵会展开成
`latest_<loop>hz_<baud>baud_irqp<prio>_poll<n>_spin<us>us_200hz_be_n40`
这样的阶段名。若同时扫 PC 调度 case，会追加 `_pc<label>` 后缀。

阶梯跑完后，可以把 summary 转成表格或 CSV：

```bash
tools/summarize-com-staircase.sh log/com-staircase/<tag>.summary.log
FORMAT=csv tools/summarize-com-staircase.sh log/com-staircase/<tag>.summary.log
```

完整上板验收可以再跑 contract 检查：

```bash
tools/check-com-staircase-contract.py log/com-staircase/<tag>.metrics.csv
```

默认要求 `1/2/5/10kHz × 921600/2000000` 的 8 个 latest-target 阶段都存在，
并且每个组合至少有一个 `PASS` 行，`lost=0`、`duplicate=0`、
`qos_incompatibility=0`。如果当前 SWD 不可用、只有 no-flash fallback 表，
这个 contract 会明确 `FAIL missing_required_stage(...)`，不能当作上板矩阵完成。

表格会从 stage 名拆出 `loop_hz`、`baud`、`timer_irq_priority`、
`uart_read_poll_yields`、`executor_spin_timeout_us`、`pc_cmd_hz`、`qos`、
`status_every_n`，并从 summary 里带出 `pc_launch_prefix`，方便横向比较
1/2/5/10kHz、921600/2Mbps、TIM2 IRQ
优先级、UART polling 和 executor spin timeout 候选。
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

改过汇总字段或日志解析后，可以先跑一个离线 parser smoke test。它只用合成日志，
不会访问硬件：

```bash
tools/test-com-summary-parsers.sh
```

要生成一份当前通信验证交接报告（不会烧录、不会启动 ROS 节点，只读取已有日志并探测
ST-LINK/串口状态）：

```bash
tools/com-status-report.sh morning_$(date +%Y%m%d_%H%M)
```

报告会写到 `log/handoff/<tag>.md`，里面汇总当前 git 版本、最近提交、SWD 状态、
串口设备、最近 no-flash 指标、latest overnight summary、静态内存矩阵、栈候选和未解决项。
只想看 blockers 时，可以直接抽取 `未解决项`：

```bash
tools/summarize-com-unresolved.sh morning_$(date +%Y%m%d_%H%M)
```

要把已有 wire log、PC 调度 sweep、staircase QoS 结果收敛成通信优化推荐：

```bash
tools/recommend-communication-optimizations.py
```

输出里的 `RECOMMENDATION control_link=pc_200hz_latest_target_mcu_status_decimated`
表示控制链路目标仍是 PC 200Hz latest-target、MCU 状态降频回传；`CANDIDATE ...`
会列出 921600/2Mbps 线速预算、当前最优 PC 调度样本、可靠 full-echo 避免项和
`qos_incompatibility` gate。只要 QoS 还不匹配，就不能把 best-effort latest-target
验收为闭环 OK。

如果要无人值守地持续观察一晚，可用 overnight watcher。它只跑 no-flash smoke
和 handoff 报告，不 build、不 flash、不 reset：

```bash
END_AT="tomorrow 09:00" INTERVAL_SECONDS=1800 \
tools/overnight-com-watch.sh overnight_$(date +%Y%m%d_%H%M)
```

如果要把 PC command node 绑到固定 CPU 核做长期调度对比，可把同一个
`PC_LAUNCH_PREFIX` 传给 watcher；每一轮 no-flash smoke 都会透传给
`tools/run-com-perf.sh`：

```bash
END_AT="tomorrow 09:00" INTERVAL_SECONDS=1800 \
PC_LAUNCH_PREFIX="taskset -c 2" \
tools/overnight-com-watch.sh overnight_taskset_$(date +%Y%m%d_%H%M)
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
环境变量覆盖。`tools/run-com-perf.sh` 本身也会执行健康门槛，失败轮次会在 watcher
日志中记录为 `smoke=fail`。

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

要把当前 RAM 分类、栈候选、executor spin timeout 候选和 linker heap/MSP
候选汇总成一份短报告，可以用：

```bash
tools/summarize-firmware-memory-plan.sh
```

这份报告不会连接硬件；其中 `PASS_STATIC` 只代表静态编译和 size 预算通过，
默认栈/heap/MSP 仍必须等 SWD 恢复后用运行期水位确认。

要把这些静态结果收敛成“现在能不能改默认值、恢复 SWD 后先验证什么”的候选清单：

```bash
tools/recommend-firmware-optimizations.sh
```

输出里的 `RECOMMENDATION default_policy=keep_defaults_until_runtime_evidence`
表示当前默认值先不动；`CANDIDATE ... saved_bytes=... gate=...` 会列出每个
候选最多能省多少 SRAM，以及必须满足的运行期门槛。例如 linker reserve 和
micro-ROS stack 候选都必须等 SWD 恢复后完成 HWM/MSP/heap/HardFault 证据，
不能只靠静态 RAM 余量直接改默认。

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
要把关键 profile 的静态 Flash/RAM 预算当作门槛检查：

```bash
tools/check-firmware-size-matrix-contract.sh log/firmware-size-matrix/current.csv
```

默认检查 `default_reliable_1khz` 和 `besteffort_10000hz_status40` 都存在、
`verdict=PASS`，且 `flash_bytes<=131072`、`ram_static_bytes<=18432`。

要比较 micro-ROS 任务栈候选大小的静态 RAM 收益，也不需要连接硬件：

```bash
tools/firmware-stack-sweep.sh current_stack
```

默认会在 10kHz/best-effort/status_every_40 profile 下比较 768/704/640 words，
输出 `log/firmware-stack-sweep/current_stack.md` 和 `.csv`。这只是静态编译
候选，不能替代上板后的 `tools/measure-stack-hwm.sh` 水位复测。表格中的
`PASS_STATIC` 只表示静态 Flash/RAM 在预算内，仍必须复测运行期栈水位。

要比较 executor `spin_some` 等待上限候选的静态 Flash/RAM，也不需要连接硬件：

```bash
tools/firmware-spin-timeout-sweep.sh current_spin
```

默认会在 10kHz/best-effort/status_every_40 profile 下比较 `1000/500/200/100us`，
输出 `log/firmware-spin-timeout-sweep/current_spin.md` 和 `.csv`。这只说明候选
可编译且静态预算 OK；是否改善 RTT/gap 长尾必须上板实测。

要比较 linker 里 newlib heap 和 MSP/ISR 栈的链接期预留，也可以离线跑：

```bash
tools/firmware-linker-reserve-sweep.sh current_reserve
```

默认会比较 `512+1024B` 基线和 `0+512B`、`0+768B`、`256+512B`
候选。`heap0_stack512` 在 10kHz/best-effort/status_every_40 静态 profile
里可把静态 RAM 从约 13.9KB 降到约 12.9KB，但它只说明链接期预算可过；
是否安全必须等 SWD 恢复后确认 MSP/ISR 栈余量，以及 newlib malloc 失败路径。

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

`run-bridge.sh` 和 `run-com-perf.sh` 会对通信串口加同一把本地 lock，避免
overnight watcher、scheduler sweep、手动 bridge 和手动验证同时抢 `/dev/ttyUSB0`。
默认抢不到会直接退出并提示串口忙；如果希望排队等待，可以设置：

```bash
SERIAL_LOCK_WAIT_SECONDS=120 BUILD_FIRMWARE=0 FLASH_FIRMWARE=0 \
tools/run-com-perf.sh wait_for_serial
```

有了 `.wire.log` 后，可以先做线速外推，粗看某个目标 profile 是否可能打满串口：

```bash
tools/com-wire-budget.py \
  --wire-log log/com-perf/<tag>.wire.log \
  --cmd-hz 200 \
  --status-every-n 40 \
  --baud 921600
```

也可以一次输出矩阵，横向比较 topic 频率、状态降频和波特率：

```bash
tools/com-wire-budget.py \
  --wire-log log/com-perf/<tag>.wire.log \
  --cmd-hz 200,500,1000 \
  --status-every 1,10,20,40 \
  --baud 921600,2000000 \
  --max-baud-util-pct 30 \
  --show-wire-time
```

加上 `--max-baud-util-pct 30` 后，表格会多出 `min baud @ budget`、
`budget margin %` 和 `PASS/OVER_BUDGET`：前者表示在该利用率红线下至少需要的
baud，后者表示当前 baud 离红线还有多少百分点余量。如果要在脚本里把超预算当作失败，
再加 `--fail-on-over-budget`。
加上 `--show-wire-time` 后会多出单条 command/status 在 UART 8N1 上的串行发送时间下限；
它只解释裸线速，不包含 ROS executor、DDS/XRCE、OS 调度、MCU read/spin timeout 或控制环耗时。
这个工具用已测 XRCE 串口字节数做线性估算，只用于排序实验优先级；真实验收仍以
上板 `run-com-perf.sh` / staircase 实测为准。

要离线复查某个 `run-com-perf.sh` tag 是否满足性能契约，可以用：

```bash
EXPECTED_CMD_RATE_HZ=20 tools/check-com-perf-contract.sh <tag>

EXPECTED_CMD_RATE_HZ=200 STATUS_EVERY_N=40 \
tools/check-com-perf-contract.sh <latest_target_tag>
```

默认契约是 PC 目标发包频率在 90%-110%，PC publish p99 gap 不超过 4 个周期、
max gap 不超过 10 个周期，`lost/duplicate=0`。对 200Hz 来说，对应 p99 <= 20ms、
max <= 50ms。改过解析工具后可以离线跑：

```bash
tools/test-com-wire-budget.sh
tools/test-control-loop-config.sh
tools/test-com-perf-contract.sh
tools/test-com-summary-parsers.sh
tools/test-com-staircase-dry-run.sh
tools/test-firmware-size-report.sh
tools/test-microros-config.sh
tools/test-com-status-report.sh
```

也可以一条命令跑完当前不碰硬件/串口的离线契约测试：

```bash
tools/test-offline-contracts.sh
```

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
