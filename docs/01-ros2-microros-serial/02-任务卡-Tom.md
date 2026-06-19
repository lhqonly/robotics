# 任务卡：Tom（开发）

> 按顺序执行。接口以 `01-接口契约.md` 为准，设计背景见 `00-架构文档.md`。
> 状态标记：⬜ 未开始 / 🔵 进行中 / ✅ 完成。每张卡完成后通知 Gill 对应验收卡。

---

## T1 — 环境与工具链安装 ｜ Phase A ｜ 无需硬件 ｜ ✅（2026-06-18 完成）
> 实测：ros2(jazzy)/colcon/arm-none-eabi-gcc 13.2.1/cmake 3.28.3/ninja/make/st-flash 1.8.0/openocd 0.12.0/codex 0.140.0 均就位，env-check 关键组件齐备退出 0。安装脚本 `tools/install-toolchain.sh`、自检 `tools/env-check.sh`。arm gdb 用 gdb-multiarch（24.04 无 arm-none-eabi-gdb）。
**目标**：在 Ubuntu 24.04 装齐全部工具链，为后续一切打底。

**步骤**
1. 安装 **ROS2 Jazzy**（desktop 或 ros-base），`source /opt/ros/jazzy/setup.bash` 写入 `~/.bashrc`。
2. 安装 **micro_ros_setup**（jazzy 分支）所需依赖；准备好后续 build micro_ros_agent 与固件静态库。
3. 安装 **arm-none-eabi-gcc** 工具链 + `cmake` + `ninja`/`make`，验证 `arm-none-eabi-gcc --version` 可用。
4. 安装 **codex CLI**（gill 的 `tools/codex-review.sh` 依赖；登录态已随 `~/.codex` 迁移，装二进制即可）。
5. 安装烧录工具 `stlink-tools`（或 OpenOCD），供 Phase B 烧板。

**产出物**：可用的工具链；一份 `tools/env-check.sh`（打印各组件版本，便于复现）。
**验收标准**：`ros2 --version`、`arm-none-eabi-gcc --version`、`cmake --version`、`codex --version` 全部正常输出；`env-check.sh` 跑通。

---

## T2 — ROS2 侧消息/节点 + bringup launch ｜ Phase A ｜ 无需硬件 ｜ ✅（2026-06-18 实跑验证通过）
> 已落盘 `ros2_ws/src/exo_cmd`(节点 exo_cmd_node/loopback_node + qos.py 单点 QoS)与 `exo_bringup`(loopback_test.launch.py 一键起全套)。
> **主 agent 端到端实跑验证**:`colcon build` 两包零报错通过;起 launch 后 `/exo/mcu_status` 输出单调递增(902→907 无重复无丢序),回环判据成立;`topic info -v` 显示 Reliability=RELIABLE、Pub/Sub count 各 1。
> **QoS 铁证(applied QoS,本地端点真值)**:Tom 在 `qos.py` 加了 `qos_summary()`,节点启动直接从 `publisher.qos_profile` 读并打印。实测四端点均 `reliability=RELIABLE history=KEEP_LAST depth=10`,与契约逐项一致。
> **已知 introspection 现象(非 bug)**:`ros2 topic info -v` 的 History(Depth) 显示 UNKNOWN——rmw(FastDDS)发现阶段不传播 history/depth。验收以上面的 applied-QoS 日志为准,Gill 勿据 `topic info -v` 误判。
> loopback 模拟节点名用 exo_loopback(非真机 exo_mcu),避免 Phase B 冲突。另有 `ros2_ws/selftest_t2.sh`(Tom 写的一键自测脚本)。
**目标**：WSL 侧 pub/sub 节点就绪，可在**无 MCU**情况下用两个本地节点自测。

**步骤**
1. 建 `ros2_ws/src/exo_cmd`（C++ 或 Python 皆可，建议 Python 起步快）：
   - pub `/exo/cmd_heartbeat`（Int32，10 Hz，递增计数器，QoS 见契约）。
   - sub `/exo/mcu_status`，打印并比对回环值。
2. 建 `ros2_ws/src/exo_bringup`，提供 launch：可单独起 `exo_cmd`，也可起一个**本地 loopback 测试节点**（订阅 cmd_heartbeat、原样转发到 mcu_status）模拟 MCU 行为。
3. `colcon build` 通过，`source install/setup.bash`。

**产出物**：`exo_cmd`、`exo_bringup` 两个包 + loopback 测试节点 + launch 文件。
**验收标准**：仅用 ROS2（无 MCU），起 `exo_cmd` + loopback 节点，`ros2 topic echo /exo/mcu_status` 能看到与 cmd_heartbeat 一致的递增值；回环判据成立。

---

## T3 — micro-ROS Agent 起法与脚本 ｜ Phase A ｜ 无需硬件（真机连通在 G7 验）｜ ⬜
**目标**：把 micro_ros_agent build 出来并固化启动方式。

**步骤**
1. 用 `micro_ros_setup`（或 Docker）build `micro_ros_agent`。
2. 写 `tools/run-agent.sh`：封装 `ros2 run micro_ros_agent micro_ros_agent serial --dev ${DEV:-/dev/ttyACM0} -b 921600 -v6`，设备可由环境变量覆盖。

**产出物**：可执行的 micro_ros_agent；`tools/run-agent.sh`。
**验收标准**：agent 二进制可启动（无设备时会等待连接，不报致命错误即可）；脚本参数化正确。

---

## T4 — STM32 固件骨架 ｜ Phase A ｜ 无需硬件 ｜ ⬜
**目标**：`firmware/nucleo_f401_microros/` 裸 CMake 工程，编译出 `.elf`/`.bin`。

**步骤**
1. 用 STM32F401 HAL + 启动文件 + 链接脚本搭裸 CMake 工程（arm-none-eabi-gcc）。
2. 集成 **FreeRTOS**。
3. 用 `micro_ros_setup` 生成 **micro-ROS 静态库**（含 Int32 等 std_msgs），链接进固件。
4. 配置 **USART2(PA2/PA3) + TX/RX DMA**，921600，8N1。

**产出物**：完整可编译的固件工程 + 构建产物 `.elf`/`.bin`。
**验收标准**：`cmake --build` 成功产出 `.elf`/`.bin`，无错误；map 文件显示链接了 micro-ROS 与 FreeRTOS。

---

## T5 — 固件 micro-ROS 应用 ｜ Phase A（编译过即可）｜ 无需硬件 ｜ ⬜
**目标**：固件内实现契约里的 pub/sub。

**步骤**
1. 配置 micro-ROS **serial transport**，绑定 USART2+DMA。
2. 建节点 `exo_mcu`：sub `/exo/cmd_heartbeat`，回调里把收到的值原样 pub 到 `/exo/mcu_status`。
3. 两端 QoS 设为 RELIABLE/KEEP_LAST/10，与契约一致。

**产出物**：含 micro-ROS 应用逻辑的固件，编译通过。
**验收标准**：编译产出更新的 `.bin`；代码审查确认 topic 名/类型/QoS 与契约逐项一致（真机回环在 T7/G7 验）。

---

## T6 — 构建/烧录/一键启动脚本 ｜ Phase A（烧录执行属 B）｜ 无需硬件 ｜ ⬜
**目标**：把构建与运行固化成脚本。

**步骤**
1. `tools/build-firmware.sh`：一键 cmake configure + build。
2. `tools/flash.sh`：用 st-flash/OpenOCD 烧 `.bin`（写好即可，执行在 Phase B）。
3. `tools/run-demo.sh`：一键起 agent + exo_cmd（供 Phase B 联调）。

**产出物**：上述脚本。
**验收标准**：build/run 脚本可 dry-run 或在无设备时优雅退出；flash 脚本逻辑经审查正确。

---

## T7 — 真机联调 ｜ **Phase B ｜ 需硬件** ｜ ⬜
**目标**：接上 Nucleo，验证双向 topic 回环。

**步骤**
1. `usbipd-win` 把 ST-Link 从 Windows attach 到 WSL，确认 `/dev/ttyACM0`。
2. `flash.sh` 烧固件 → 起 `run-agent.sh` → 起 `exo_cmd`。
3. 观察 `/exo/mcu_status` 是否回填 `/exo/cmd_heartbeat` 的值。

**产出物**：联调记录（含 `ros2 topic echo` 截图/日志）。
**验收标准**：满足契约第 2 节回环判据；交 Gill G7 独立复验。
