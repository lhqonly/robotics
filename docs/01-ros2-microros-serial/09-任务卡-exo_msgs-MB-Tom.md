# 任务卡 09：exo_msgs 里程碑 M-B —— 固件实现（Tom）

- 负责开发：**Tom**
- 负责测试：**Gill**（验收卡见 `10-任务卡-exo_msgs-MB-Gill.md`）
- 依赖：**M-A 已绿**（exo_msgs WSL 侧落地：契约已 bump **v1.7**、81 tests 全绿、loopback 实跑通过、git tag `int32-baseline` 退路就位）；契约 `01-接口契约.md` **v1.7**（§1.1/§1.2 消息 schema、§7.1 stamp 语义、§7.6 seq mod 2^32、§7.7 LinkHealth、§7.9 CRC）；设计草案 `06-exo_msgs设计草案.md`（**尤其 §D6 固件影响、§2.2 M-B 表、§3 风险登记**）；Phase B 攻坚计划 `05-PhaseB攻坚计划.md`（**T5 重建 libmicroros 的 4 根因经验 + colcon.meta + toolchain.cmake、T8 RAM/ROM 量化工具、烧录命令**）
- 状态：⬜ 未开始

> **里程碑边界（务必先读）**：本卡 = **M-B，强依赖真机在环、反复烧录/联调**。**无硬件不能做**。把 M-A（WSL 侧 exo_msgs）已经做对的「信封 + 回环 + 诊断」搬到 F103 固件上：让真板用 `exo_msgs/ExoCmd`(sub)/`ExoStatus`(pub) 替换现在的 `std_msgs/Int32`，并把 exo_msgs 喂进 micro-ROS 固件构建、**完整重建 libmicroros**。WSL 侧不动（M-A 已绿，节点已是 exo_msgs 载体）。
>
> **前置依赖（硬条件，缺一不能开工）**：① **真板已接上**（Nucleo-F103RB + 独立 USB-TTL 适配器接 USART1 PA9=TX/PA10=RX，契约 §3 / v1.3 接线）；② **usbipd attach 两个设备进 WSL**：通信口 `/dev/ttyUSB0`（USB-TTL）+ 烧录口 `/dev/ttyACM0`（ST-Link，仅 SWD 烧录），`usbipd attach` 后 `ls /dev/ttyUSB* /dev/ttyACM*` 都在；③ **M-A 已绿**（v1.7 契约、WSL 侧 exo_msgs 节点 / loopback / tracker 全绿，本卡以此为既成事实）。
>
> **当前固件基线锚点（本卡基于真机已读源码，落到具体符号/文件）**：
> - 应用：`firmware/f103-microros/src/microros_app.c` —— rclc 双向应用，节点 `exo_mcu`，当前**全程 `std_msgs__msg__Int32`**。
> - transport：`firmware/f103-microros/src/microros_transport.c` —— custom transport 4 回调（阻塞/轮询，USART1+DMA），**与消息类型无关，本卡不改**。
> - 时钟：`firmware/f103-microros/src/main.c` `Clock_Init()` —— HSE 8MHz → PLL×9 = **72MHz SYSCLK**，`SystemCoreClock=72000000`。**当前无任何 DWT / CYCCNT 使用**（已全仓确认）——M-B 要新建 DWT 时钟源。
> - 裁剪：`firmware/f103-microros/colcon.meta` —— `RMW_UXRCE_MAX_*=1`、`UCLIENT_*`、`MTU=128`、**`RMW_UXRCE_CREATION_MODE=bin`**（★见任务 5 兼容性调研）。
> - libmicroros：预构建静态库在 `firmware/f103-microros/ThirdParty/microros/libmicroros.a` + `include/`；构建工作区在 `~/uros_ws/firmware/`（`mcu_ws/uros/` = 自定义消息注入点，`build/libmicroros.a` = 产物）。
> - agent：`tools/run-agent.sh` —— `micro_ros_agent serial --dev /dev/ttyUSB0 -b 921600 -v6`，**bin 模式 vanilla agent**（不带自定义类型）。

## 目标
把固件从 `std_msgs/Int32` 最小闭环迁移到 `exo_msgs/ExoCmd`(sub) / `exo_msgs/ExoStatus`(pub)：① 把 `exo_msgs` 喂进 micro-ROS 固件构建、**完整重建 libmicroros**（含 exo_msgs type support）；② 固件应用收 `ExoCmd` 解包 → 回填 `ExoStatus`（`header.seq` 原样回填、`header.stamp_mono_ns`=MCU 本地 DWT 时钟、`payload` 原样、`header.crc`=按开关重算）；③ MCU 时钟源用 **DWT CYCCNT @72MHz** 折纳秒；④ CRC（启用时）端到端字节序与 WSL 规范逐字节一致；⑤ 调研并回答 **bin 模式 vanilla agent 能否桥接自定义 exo_msgs 类型**；⑥ 用 T8 工具量化 RAM/ROM 增量、确认动态分配仍为零。全部需真机反复烧录联调验证。

---

## 接口契约（本卡对外保证 / 不变边界）

- **不变边界**（与 M-A 一致，迁移可控）：topic 名 `/exo/cmd_heartbeat`、`/exo/mcu_status`、节点名 `exo_mcu`、命名空间、QoS（RELIABLE / KEEP_LAST / F103 侧 depth=1，`RMW_UXRCE_MAX_HISTORY=1`）、波特率 921600、MTU 128、8N1/DMA、custom transport 4 回调 —— **全部不变**。只换消息载荷类型。
- **本卡交付的固件 wire 语义**（契约 §1.1/§1.2 v1.7 的固件侧落实）：
  - 收 `ExoCmd`：读出 `header.seq` / `header.stamp_mono_ns` / `header.crc` / `payload`（CRC 开关开时先校验，mismatch 计数+不阻断）。
  - 回 `ExoStatus`：`header.seq` = **原样回填** `cmd.header.seq`；`header.stamp_mono_ns` = **MCU 自己 DWT 时钟重盖**（不回填 cmd 的 stamp，两端时钟不可比，§7.1 / §D4）；`payload` = **原样回填** `cmd.payload`；`header.crc` = CRC 开关开时按 §7.9 规范重算、否则置 0。

---

## 实现要点 / 约束（按建议顺序）

> **顺序建议（最重 → 收尾）**：任务 1（喂 exo_msgs 重建 libmicroros，**最重一步**）→ 任务 5（**先验证 bin 模式 vanilla agent 兼容性，这是必须先回答的技术风险，可能影响后续做法**）→ 任务 2（应用代码迁移）→ 任务 3（DWT 时钟源）→ 任务 4（CRC 一致性，最易出 bug，单独开关验证）→ 任务 6（RAM/ROM 量化收尾）。
>
> 实操建议：任务 1 与任务 5 强耦合——重建 libmicroros 出 exo_msgs type support 后，**第一件事就是起 vanilla agent + 烧最小 exo_msgs pub 看 agent 能否建出 datawriter/datareader**（任务 5 的判定），据此决定是否需要把 exo_msgs 也喂给 agent 侧 / 改 creation mode。**不要**在任务 5 未验证前就把应用代码全迁完。

### 任务 1 — 把 `exo_msgs` 喂进 micro-ROS firmware 构建、**完整重建 libmicroros**（M-B 最重一步）

> micro-ROS 的消息类型是**编译进静态库 libmicroros 的**，不是运行时动态加载（§D6）。新增 `exo_msgs` 必须把包喂给固件构建流程、重新生成 type support、**完整重建静态库**——这是 **T5 同类操作**（改 colcon.meta → 重建 libmicroros），**有经验但是一次完整重建非增量**，耗时较长。

1. **把 exo_msgs 放进固件构建工作区的自定义消息目录**：micro_ros_setup 的固件工作区在 `~/uros_ws/firmware/`，自定义/额外消息包注入点是 **`~/uros_ws/firmware/mcu_ws/uros/`**（与 `rcl` / `rclc` / `rmw_microxrcedds` 等并列；micro_ros_setup 的 `mcu_ws` 会把 `uros/` 下的包一并纳入 libmicroros 构建）。把 M-A 落盘的 `exo_msgs` 包源码（`ros2_ws/src/exo_msgs/`，含 `msg/ExoHeader.msg` / `ExoCmd.msg` / `ExoStatus.msg` / `LinkHealth.msg` + `package.xml` + `CMakeLists.txt`）**拷贝/软链**进 `mcu_ws/uros/exo_msgs/`。
   - 注：`LinkHealth.msg` 依赖 `std_msgs/Header`，固件侧不发布它（诊断 topic 是 WSL 侧的），但**它会被一并生成 type support 进 lib**——确认 `std_msgs` 在 mcu_ws 里可解析（std_msgs 已在基线 lib 里，应无碍）；若 LinkHealth 的依赖在固件侧拖累构建，可考虑固件构建时只喂 `ExoHeader/ExoCmd/ExoStatus`（保留 LinkHealth 在 WSL 包里），但**契约要求 exo_msgs 是同一个包**——优先整包喂入，遇阻再裁剪并记录。
2. **重新生成 type support + 完整重建静态库**（沿用 T5 命令链，`05-PhaseB攻坚计划.md` T5「第一步」）：
   - `source /opt/ros/jazzy/setup.bash` + `~/uros_ws/install/local_setup.bash`。
   - `cd ~/uros_ws`，**复用既有 `toolchain.cmake`**（T5 已写，M3 flags：`-mcpu=cortex-m3 -mthumb` 无 VFP、soft-float、`CMAKE_SYSTEM_NAME Generic`、`CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY`、`arm-none-eabi-gcc/g++`——**必须与固件 `firmware/f103-microros/CMakeLists.txt` 的 ABI flags 完全一致**，否则链接期 undefined ref / multiple def）。
   - **参数顺序：toolchain 在前、colcon.meta 在后**（T5 已踩过）：
     `ros2 run micro_ros_setup build_firmware.sh $(pwd)/toolchain.cmake /home/lhq24/robotics/firmware/f103-microros/colcon.meta`
   - 产物：`~/uros_ws/firmware/build/libmicroros.a` + `build/include/`（现在含 `exo_msgs/msg/exo_cmd.h` / `exo_status.h` / `exo_header.h` 等生成头）。
   - **拷进固件**：把新 `libmicroros.a` 覆盖 `firmware/f103-microros/ThirdParty/microros/libmicroros.a`，把 `build/include/exo_msgs/`（及任何新增依赖头）拷进 `ThirdParty/microros/include/`。
3. **T5 的 4 根因经验复用**（重建 libmicroros 的已知坑，逐条避开）：
   - **键名错被静默忽略**：core/rmw config 用错键名会被默默吃掉。重建后**回读生成的 rmw `config.h`**，确认 `RMW_UXRCE_MAX_PUBLISHERS/SUBSCRIPTIONS/HISTORY/STREAM_HISTORY` 与 `UCLIENT_CUSTOM_TRANSPORT_MTU=128` 与 colcon.meta 一致（裁剪真生效）。
   - **toolchain.cmake 必含 `CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY`**，否则 generate_lib 的 try_compile 失败。
   - **ABI flags 三处一致**（toolchain.cmake / 固件 CMakeLists / 链接），soft-float、无 VFP。
   - **rosdep 缺包** → 交互终端 `[SUDO]` 补（主 agent 不持 sudo）。
4. **完整重建确认**：这是 M-B 最重的一步；构建失败优先查（ABI flag 不一致 / try_compile target type / exo_msgs 包依赖未解析 / 键名错）。**注明给 Gill**：本步产物（含 exo_msgs type support 的 libmicroros.a）是后续一切的前提，链接不过则 M-B 阻塞。

### 任务 2 — 固件应用代码迁移：`Int32` → `ExoCmd`/`ExoStatus`（改 `microros_app.c`）

> 改 `firmware/f103-microros/src/microros_app.c`。**rclc API 调用序列、节点名、topic 名、QoS、executor、ping/重连循环全部不变**，只换消息类型 + 回调里的解包/回填 + stamp/crc。逐符号对照（左=现状，右=迁移后）：

- **头文件**：`#include <std_msgs/msg/int32.h>` → `#include <exo_msgs/msg/exo_cmd.h>` + `#include <exo_msgs/msg/exo_status.h>`（生成头名以 task 1 重建产物为准，通常 `exo_msgs/msg/exo_cmd.h`）。`__has_include` 守卫里的 `<std_msgs/msg/int32.h>` 同步换成 exo_msgs 头（保留「lib 未就位编占位」策略）。
- **静态消息体**（`microros_app.c` L68–69）：
  - `static std_msgs__msg__Int32 g_msg_cmd;` → `static exo_msgs__msg__ExoCmd g_msg_cmd;`
  - `static std_msgs__msg__Int32 g_msg_status;` → `static exo_msgs__msg__ExoStatus g_msg_status;`
- **type support 宏**（L133 / L142，pub/sub 各一处）：
  - pub：`ROSIDL_GET_MSG_TYPE_SUPPORT(std_msgs, msg, Int32)` → `ROSIDL_GET_MSG_TYPE_SUPPORT(exo_msgs, msg, ExoStatus)`
  - sub：`ROSIDL_GET_MSG_TYPE_SUPPORT(std_msgs, msg, Int32)` → `ROSIDL_GET_MSG_TYPE_SUPPORT(exo_msgs, msg, ExoCmd)`
  - （`rclc_publisher_init_default` / `rclc_subscription_init_default` 调用本身、topic 字符串 `"exo/mcu_status"` / `"exo/cmd_heartbeat"` 不变。）
- **订阅回调** `cmd_heartbeat_callback`（L96–105）—— 这是迁移核心，从「原样搬一个 int」升级为「解包 ExoCmd → 回填 ExoStatus」：
  - `const std_msgs__msg__Int32 *m = (const std_msgs__msg__Int32 *)msgin;` → `const exo_msgs__msg__ExoCmd *m = (const exo_msgs__msg__ExoCmd *)msgin;`
  - 原 `g_msg_status.data = m->data;` 改为：
    - `g_msg_status.header.seq = m->header.seq;`（**原样回填 seq**，§1.2）
    - `g_msg_status.payload = m->payload;`（**原样回填 payload**）
    - `g_msg_status.header.stamp_mono_ns = dwt_now_ns();`（**MCU 本地 DWT 时钟重盖**，见任务 3；不回填 `m->header.stamp_mono_ns`）
    - `g_msg_status.header.crc =` CRC 开关开时 `exo_crc32(&g_msg_status)`（按 §7.9 规范、crc 置 0 后算）、否则 `0u`（见任务 4）
    - （可选，CRC 开关开时）先对收到的 `m` 校验 `header.crc`：mismatch → `g_crc_mismatch_count++`（固件侧计数，可经诊断串口或后续 topic 暴露），**不阻断**——仍回填回发（与 WSL 侧 §7.9「不阻断」语义对齐）。
  - `(void)rcl_publish(&g_pub_status, &g_msg_status, NULL);`（不变）。
- **初值**（`microros_app_task` L186–188）：`g_msg_status.data = -1; g_msg_cmd.data = 0;` 改为对新结构置初值：`g_msg_status.header.seq=0; g_msg_status.payload=-1; g_msg_status.header.stamp_mono_ns=0; g_msg_status.header.crc=0;`（`payload=-1` 仍作「未收到任何 cmd」哨兵）。
- **rclc 序列保持**：`rclc_support_init` → `rclc_node_init_default(&g_node,"exo_mcu","",&g_support)` → `rclc_publisher_init_default` → `rclc_subscription_init_default` → `rclc_executor_init`（`EXECUTOR_HANDLES=1`）→ `rclc_executor_add_subscription(...,ON_NEW_DATA)` → `rmw_uros_ping_agent` 重连循环 → `rclc_executor_spin_some`。**全不变**。

### 任务 3 — MCU 时钟源：DWT CYCCNT @72MHz 折算 `stamp_mono_ns`

> F103 当前**无任何 DWT 使用**（已全仓确认）。`stamp_mono_ns` 用 **DWT CYCCNT** 折纳秒（§D6 / §3 风险登记：精度最好，需正确配置 DWT）。绝对值不可比已 §D4 接受，**只需稳定单调**。

- **初始化 DWT**（开机一次，建议在 `main.c` `Clock_Init()` 之后、或 micro-ROS 任务起步时调一次 `dwt_init()`）：
  - 开 trace：`CoreDebug->DEMCR |= CoreDebug_DEMCR_TRCENA_Msk;`
  - 清零并使能 cycle counter：`DWT->CYCCNT = 0; DWT->CTRL |= DWT_CTRL_CYCCNTENA_Msk;`
  - （Cortex-M3 上 DWT/CYCCNT 标配存在；若某些 part 不实现可读回 `DWT->CTRL` 校验，但 F103 标配可用。）
- **读取 + 折纳秒**：`SystemCoreClock = 72000000`（72MHz），1 cycle = 1/72e6 s ≈ 13.888… ns。
  - `dwt_now_ns()` = `(uint64_t)cyc * 1000000000ULL / 72000000ULL`。注意 **CYCCNT 是 32 位、约 59.65s 回绕**——`stamp_mono_ns` 是 `uint64`，要么维护一个软件高位扩展（在某处周期性读 CYCCNT、检测回绕累加到 64 位 ns 基准），要么接受 stamp 仅在 ~59s 窗口内单调（§D4 只要「同一发送方相对可比 / 稳定单调」即可，但**回绕跳变会破坏单调**）。**推荐**：实现 64 位累加扩展（每次 `dwt_now_ns()` 调用时检测 CYCCNT 较上次回绕、累加 `2^32` cycle 的 ns）——这一步要在并发/中断语境下保证读取一致（关中断或用 last-seen 比较）。把实现选择写清，交 Gill 验「长跑 stamp 单调不倒退」。
  - 这是固件侧**唯一**的 stamp 来源；**禁**用任何 wall clock / `rmw_uros_epoch`（§7.1 / §D4：两端时钟不可比，不参与跨端单程）。

### 任务 4 — CRC 端到端字节序一致（若启用 crc）★M-B 最易出 bug 点

> 标为 **M-B 最易出 bug 点**（§D6 / §3 风险登记：「MCU 手算 CRC 的字节序必须与 WSL Python 端规范字节序对齐，否则永远 mismatch」）。**默认 `crc_enabled=False` 不阻断主链路**；CRC 一致性作为**联调时单独开启验证**的独立项，不卡主链路。

- **MCU 端 CRC-32 实现**：与 WSL 端规范（契约 §7.9）**逐字节一致**：
  - 规范（WSL 侧 = `zlib.crc32`，即标准 CRC-32 / IEEE 802.3，多项式 0xEDB88320 反射、init 0xFFFFFFFF、xorout 0xFFFFFFFF）：MCU 端用**查表实现**（256 项表 ≈ 1KB ROM，§D6）匹配同一参数集，**逐字节复现**。
  - **覆盖范围 = `crc` 字段置 0 后**，对 `seq‖stamp_mono_ns‖payload` 的**规范小端序字节流**：
    - `seq` → `uint32`（4 字节 LE）
    - `stamp_mono_ns` → `uint64`（8 字节 LE）
    - `payload` → `int32`（4 字节 LE 补码）
    - 即 WSL 侧 `struct.pack('<IQi', seq, stamp_mono_ns, payload)` 再 `zlib.crc32`。**F103 是小端**（Cortex-M3 默认 LE），所以可直接按内存布局拼字节——但**不要**依赖 C struct 的 padding/对齐去拼（`ExoHeader` 里字段顺序/对齐由 rosidl 决定，可能有 padding），**显式把 `seq`/`stamp`/`payload` 三个标量按 `<IQi` 顺序拷进一个紧凑字节缓冲再算 CRC**，与 WSL 规范逐字节对齐。
  - 自检：`exo_crc32()` 对发出的 `ExoStatus` 算（先把 `header.crc` 置 0）填回 `header.crc`；收到 `ExoCmd` 时同样把 `header.crc` 暂存、置 0、重算、比对（避免 CRC 自指，§7.9）。
- **联调验证（单独开启 crc_enabled）**：WSL 侧（M-A 已实现）开 `crc_enabled=True`，真机固件也开；端到端跑，**WSL 侧 `crc_mismatch_count` 应恒为 0**（说明两端字节序逐字节一致）。任一字节序不对 → WSL 侧持续 mismatch，即定位到本任务。**默认关，主链路不依赖它**。

### 任务 5 — agent 侧兼容性调研点 ★必须先验证的技术风险（卡里让 Tom 先回答）

> **这是必须先验证的技术风险**（§3 风险登记：「agent bin 模式自定义类型兼容性」）。当前 `colcon.meta` 有 **`RMW_UXRCE_CREATION_MODE=bin`**，`tools/run-agent.sh` 起的是 **bin 模式 vanilla agent**（不带自定义类型）。**问题**：bin 模式 vanilla agent 能否桥接自定义 `exo_msgs` 类型（在 DDS 侧建出 `exo_msgs/ExoCmd` / `ExoStatus` 的 datawriter/datareader），还是需要把 exo_msgs 也喂给 agent 侧 / 改 creation mode？

- **背景（要点）**：micro-ROS 的 entity creation 有两种模式——
  - **`xml`（ref）模式**：client 把类型/topic 的完整 XML 描述发给 agent，agent 据此在 DDS 侧动态建实体；vanilla agent 不需要预知类型。
  - **`bin`（binary）模式**：client 发紧凑二进制表示，agent 需要能解析出 type/topic。**bin 模式下 agent 能否对一个它本地没有的自定义类型建出 DDS datawriter/datareader，是本卡必须先回答的问题**——若 agent 需要类型信息却拿不到，会建实体失败 / 用通用类型导致 WSL 侧 `exo_cmd` 节点匹配不上。
- **Tom 必须先做的验证（在任务 2 大规模迁移前）**：
  1. 重建 libmicroros 出 exo_msgs type support 后，做一个**最小 exo_msgs pub spike**（固件只 pub 一条 `ExoStatus` 到 `/exo/mcu_status`），起 `tools/run-agent.sh`（vanilla bin agent），看 agent `-v6` 日志：**能否 create datawriter for `exo_msgs::msg::dds_::ExoStatus_`**；WSL 侧 `ros2 topic echo /exo/mcu_status`（source 了 exo_msgs 的 install）**能否收到正确解出的 exo_msgs 消息**。
  2. **若 bin + vanilla agent 桥接成功**（agent 不需要预知类型即可建出实体、WSL 侧能正确反序列化）→ 记录「vanilla agent 兼容自定义类型」，无需额外工作。
  3. **若失败**（agent 建实体失败 / WSL 侧收到的是乱码或匹配不上）→ 评估两条出路并选一条记录：
     - (a) **把 exo_msgs 也喂给 agent 侧**：重建 agent 工作区（`micro_ros_setup` 的 agent 侧 / `create_agent_ws.sh` 流程）让 agent 内置 exo_msgs 类型；或
     - (b) **改 creation mode 为 `xml`/ref**：把 colcon.meta 的 `RMW_UXRCE_CREATION_MODE` 从 `bin` 改 `xml`（client 发完整类型描述，vanilla agent 据此建实体）——注意这会**改 colcon.meta → 触发再一次 libmicroros 重建**，且 xml 模式占用更多 RAM/带宽（在 20KB 上要复测，但 T8 余量大）。
- **交付：Tom 在本卡执行中先把这个验证结果回报主 agent**（哪种模式、是否需要喂 agent 侧 / 改 creation mode、对 colcon.meta / RAM 的影响），再继续后续任务。**这是 M-B 的技术风险闸门**。

### 任务 6 — RAM/ROM 增量量化（沿用 T8 工具）

> 沿用 **T8 量化工具**（`05-PhaseB攻坚计划.md` T8 / M4），确认 exo_msgs 增量在 20KB 上仍有裕度。**T8 基线**：RAM 14840B/20KB = **72.42%**、Flash 59.1%、**动态分配实测=0**（heap_end/sbrk_start/ucHeap 全零）、uros 栈峰值 285w/1536w、余 ~5.6KB。

- **RAM `.data+.bss` 增量**：`arm-none-eabi-size build/*.elf` + 读 `.map`（`--print-memory-usage` 链接期 + gdb 读 `.data`/`.bss` 段水位）。exo_msgs 一条 = `header`(seq4+stamp8+crc4=16B) + payload4 = **20B**，pub/sub 各一个静态实例，比 Int32（4B）每实例多 ~16B → 对 5.6KB 余量是九牛一毛（§D6 / 契约 §6 RAM 注记）。**确认 RAM 增量后仍有正裕度**。
- **ROM/Flash 增量**：exo_msgs type support + (de)serialization 代码进 ROM + CRC-32 查表 ~1KB；Flash 当前 59.1%（128KB，余量大）。读 `size`/`.map` 确认。
- **动态分配仍为零**（关键，维持纯静态池）：用 T8 同法 gdb 读 `heap_end` / `sbrk_start` / `ucHeap`（FreeRTOS）确认仍全零；`xPortGetMinimumEverFreeHeapSize` 确认 heap 未触底（若用 heap_4）。**自定义消息不得引入任何动态分配**——前提是维持 colcon.meta 的 `RMW_UXRCE_MAX_*=1` 静态池配置（任务 5 若改成 xml 模式要重新确认）。
- **栈水位**：`uxTaskGetStackHighWaterMark` 扫 micro-ROS 任务栈（0xA5 填充水位），解包/回填/CRC 计算的额外栈深度纳入；确认 HWM_min ≥ 安全余量（≥128 words）。
- **交付（给 Gill）**：一份量化对照（RAM/ROM 较 T8 基线的增量 + 仍有裕度 + 动态分配为零 + 栈水位达标）。

---

## 烧录 / 联调命令（前置 + 复用）

- **usbipd attach**（前置，主 agent / 用户在交互终端）：`usbipd attach` 把 USB-TTL（`/dev/ttyUSB0`）+ ST-Link（`/dev/ttyACM0`）都进 WSL；`ls /dev/ttyUSB* /dev/ttyACM*` 都在。
- **烧录**（契约 §3，WSL + usbip 下 F103 **必须 `--connect-under-reset`**）：
  `st-flash --connect-under-reset write build/<elf 对应的>.bin 0x08000000`
- **起 agent**（`tools/run-agent.sh`，bin 模式 vanilla agent）：`tools/run-agent.sh /dev/ttyUSB0 921600` → `micro_ros_agent serial --dev /dev/ttyUSB0 -b 921600 -v6`。**烧录与起 agent 串行**（别同占串口；ST-Link SWD 烧录 vs USART1 通信是两个口，但联调节奏沿用 T5）。
- **WSL 侧对端**：M-A 已迁移的 `exo_cmd` 节点（已是 exo_msgs 载体）对接真板（任务交付给 Gill 验收，见 `10` 卡）。

---

## 验收标准（给 Gill）
> 完整可执行判据见 `10-任务卡-exo_msgs-MB-Gill.md`。概要：
- libmicroros 含 exo_msgs type support 重建成功、固件链接通过、烧录上板。
- **bin 模式 vanilla agent 兼容性结论已给出**（datawriter/datareader 都建出、WSL 侧正确反序列化；或记录所需的 agent 侧改动）。
- 真机 A1–A8 在 **exo_msgs 载体**上复现（迁移后 `exo_cmd` 节点对接真板）：tracker 对账恒等 + datawriter/datareader 都建出 + 零 UNMATCHED。
- endurance soak、无重连 / 无 HardFault。
- CRC 开启端到端无 mismatch（WSL 侧 `crc_mismatch_count`=0）。
- RAM/ROM 水位达标、动态分配为零、stamp 长跑单调不倒退。

---

## 风险登记（承草案 §3，每条给缓解 / 验证手段）
| 风险 | 等级 | 缓解 / 验证手段 |
|---|---|---|
| **CRC 两端字节序不一致**（M-B 最易出 bug 点） | 中 | MCU 端显式按 `<IQi`（crc 置 0、规范小端序）拼紧凑字节流，**不依赖 C struct padding**；查表 CRC-32 参数与 `zlib.crc32` 逐字节对齐。**默认 `crc_enabled=False` 不阻断主链路**；联调单独开启，WSL 侧 `crc_mismatch_count` 恒 0 即验证通过。任务 4 标为首要联调验证项。 |
| **MCU 时钟源 DWT 折算**（CYCCNT 32 位 ~59s 回绕 / DWT 未配） | 低-中 | 正确初始化 DWT（DEMCR.TRCENA + CYCCNT 使能）；用 64 位软件扩展处理 32 位 CYCCNT 回绕，保证 `stamp_mono_ns` 长跑单调；绝对值不可比已 §D4 接受。Gill 验「长跑 stamp 单调不倒退」。 |
| **重建 libmicroros 引入回归** | 低-中 | T5 同类操作有经验（toolchain.cmake / colcon.meta / 参数顺序 / try_compile target type / 键名静默忽略 4 坑已知）；重建后回读 rmw config.h 确认裁剪生效；**完整重建非增量**，耗时计入工期；保留 git tag `int32-baseline` 退路（真机可回退已验证 Int32 链路）。 |
| **agent bin 模式自定义类型兼容性** ★ | 中 | **任务 5 设为技术风险闸门**：大规模迁移前先用最小 exo_msgs pub spike 验证 vanilla bin agent 能否建出 datawriter/datareader、WSL 侧能否正确反序列化。失败则二选一（喂 agent 侧 exo_msgs / 改 creation mode 为 xml，后者触发再一次 libmicroros 重建 + RAM 复测）。结论先回报主 agent 再继续。 |
| RAM/ROM 增量撑爆 20KB | 低 | T8 已证基线 72.42% / 余 ~5.6KB；exo_msgs 每实例 +16B 量级 + type support 进 ROM，量级小；任务 6 用 T8 工具实测确认正裕度 + 动态分配为零（维持静态池配置）。 |

---

## 不在本卡范围内
- **WSL 侧任何 exo_msgs 改动**：tracker / `exo_cmd_node` / `loopback_node` / 诊断 topic / WSL 侧测试 —— **M-A 已绿、本卡不动**（本卡只把固件搬到 exo_msgs 载体，对接 M-A 已就绪的 WSL 节点）。
- **契约正文改动**：v1.7 已落地（M-A），本卡是 v1.7 固件侧的**落实**，不 bump 契约（除非任务 5 选择改 `RMW_UXRCE_CREATION_MODE`，那属 colcon.meta 配置变更 + 回报，不是契约 wire 语义变更）。
- **payload 结构体化 / 真实控制语义**（关节角 / 力矩 / 模式）：属未来电机控制需求，本阶段 payload 维持原样回填 `int32`。
- **真单程延迟测量 / 时钟同步**：§D4 / Q7 已定 RTT 为权威，stamp 仅记录 + MCU 侧相对时效地基；MCU 不据 cmd 的 stamp 算跨端单程。
- **transport / DMA / USART1 / 时钟树改动**：`microros_transport.c`（4 回调）、main.c 的 USART1+DMA / `Clock_Init` 现状不变（仅**新增** DWT 时钟源，不改时钟树）。
- **custom transport 从轮询升 DMA circular 优化**：那是独立的 Phase B 优化项（`05` 文档 C.2），不在本卡。
- **真机验收的执行**（A1–A8 复现 / soak / 水位达标判定）：由 Gill 在 `10` 卡独立复验；本卡交付可联调的固件 + 量化数据。
- **git 操作**：tag `int32-baseline` 由主 agent 维护，Tom 不碰 git。
