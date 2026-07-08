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

烧录并启动 bridge 后，可以用 SWD 粗测本地 tick 档位：

```bash
tools/measure-control-loop.sh 5 firmware/f103-microros/build/f103-microros.elf
```

也可以读取 FreeRTOS 静态栈高水位，辅助判断 RAM 优化是否安全：

```bash
tools/measure-stack-hwm.sh firmware/f103-microros/build/f103-microros.elf
```

这个脚本通过 GDB 读 RAM，会短暂停核；不要和 `ros2 topic hz` 这类实时测量同时跑。

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
