# ros2_ws — ROS2 communication workspace (Jazzy)

WSL-side ROS2 packages for the ROS2 ↔ micro-ROS minimal serial loopback.
Interface contract: `docs/01-ros2-microros-serial/01-接口契约.md` (v1.13).

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

`pc_cmd.launch.py` 默认按当前已验证稳定基线启动：20 Hz、QoS depth 1、
`rtt_warn_ms=10`、`rtt_deadline_ms=50`。需要退回历史 10 Hz 时：

```bash
ros2 launch com_bringup pc_cmd.launch.py cmd_rate_hz:=10 qos_depth:=10
```

200 Hz 是目标压力测试，不是当前稳定默认值：

```bash
ros2 launch com_bringup pc_cmd.launch.py cmd_rate_hz:=200 qos_depth:=1
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
