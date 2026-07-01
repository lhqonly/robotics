# ros2_ws — exoskeleton ROS2 workspace (Jazzy)

MacBook-side ROS2 packages for the ROS2 ↔ micro-ROS minimal serial loopback.
Interface contract: `docs/01-ros2-microros-serial/01-接口契约.md` (v1.0).

## Packages

- **exo_cmd** (ament_python) — MacBook command node + local MCU simulator.
  - `exo_cmd_node`: pub `/exo/cmd_heartbeat` (`exo_msgs/ExoCmd`, 10 Hz,
    monotonic `header.seq`), sub `/exo/mcu_status` (`exo_msgs/ExoStatus`),
    verifies round-trip sequence values.
  - `loopback_node`: Phase-A MCU stand-in. Sub `/exo/cmd_heartbeat`, echoes the
    same value to `/exo/mcu_status`.
- **exo_bringup** (ament_python) — launch files.
  - `loopback_test.launch.py`: exo_cmd + loopback (hardware-free self-test).
  - `exo_cmd.launch.py`: exo_cmd only (for the real MCU / agent).

QoS for all `/exo/*` topics (contract): RELIABLE / KEEP_LAST / depth 10.
Defined once in `exo_cmd/exo_cmd/qos.py`.

## Build & self-test (no hardware)

```bash
# 1. ROS2 env
source /opt/ros/jazzy/setup.bash

# 2. build (from the workspace root: ros2_ws/)
cd ros2_ws
colcon build

# 3. overlay the freshly-built workspace
source install/setup.bash

# 4. start the full Phase-A loopback (exo_cmd + MCU simulator)
ros2 launch exo_bringup loopback_test.launch.py
```

In a second terminal (each new terminal needs the two `source` lines above):

```bash
source /opt/ros/jazzy/setup.bash
source ros2_ws/install/setup.bash

# watch the echoed values (should be the same increasing counter)
ros2 topic echo /exo/mcu_status

# confirm QoS matches the contract (RELIABLE / KEEP_LAST / depth 10)
ros2 topic info -v /exo/cmd_heartbeat
ros2 topic info -v /exo/mcu_status
```

Pass: `/exo/mcu_status` carries the same monotonically increasing values that
`exo_cmd` publishes on `/exo/cmd_heartbeat`, and the `exo_cmd` node logs
`round-trip OK`.

## Real F103 board on macOS

Connect the USB-TTL adapter to the MacBook and wire it to USART1 on the F103:
USB-TTL RXD ← PA9, TXD → PA10, GND ↔ GND. Do not power the board from the
USB-TTL VCC pin unless the hardware setup explicitly requires it.

```bash
# Optional: pick the serial device explicitly if multiple adapters are present.
export EXO_DEV=/dev/cu.usbserial-xxxx

# Terminal 1: agent
../tools/run-agent.sh

# Terminal 2: full hardware acceptance
./scripts/hw_acceptance.sh all
```

If ROS2 is not already on `PATH`, set `EXO_ROS_SETUP=/path/to/setup.bash`.
