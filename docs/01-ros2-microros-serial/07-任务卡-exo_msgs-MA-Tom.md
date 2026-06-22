# 任务卡 07：exo_msgs 里程碑 M-A —— WSL 侧实现（Tom）

- 负责开发：**Tom**
- 负责测试：**Gill**（验收卡见 `08-任务卡-exo_msgs-MA-Gill.md`）
- 依赖：现有 `exo_cmd` / `exo_bringup` 包（T2 已落地、G2 有条件通过）；契约 `01-接口契约.md` 当前 **v1.6**；设计草案 `06-exo_msgs设计草案.md`（D1–D7，**已通过确认门，Q1–Q9 已拍板**）
- 状态：⬜ 未开始

> **里程碑边界（务必先读）**：本卡 = **M-A，全部在 WSL 侧、零硬件依赖**。固件 / 重建 libmicroros / MCU 时钟 / CRC 端到端字节序 / 真机 A1–A8 **全部属 M-B，不在本卡**（见文末「不在本卡范围内」）。M-A 与 M-B 解耦：M-A 全绿后真机仍可继续跑已验证的 Int32 链路（git tag 退路，见任务 7）。
>
> **拍板结论锚点（Q1–Q9，用户已确认）**：Q1 seq=`uint32`（模数 2^31→2^32，回绕语义保留）；Q2 时间戳=`uint64 stamp_mono_ns`（单调纳秒，不用 `builtin_interfaces/Time`）；Q3 payload=本阶段最小 `int32`（与 seq 解耦）；Q4 CRC=预留 `uint32 crc`、默认 disabled / 开发期可开，定位「抓应用打包/序列化 bug 的自检开关」，**不**宣称防链路误码；Q5 `/exo/link_health` 纳入 M-A（p95/max 默认纳入）；Q6 WSL 侧硬切 + git tag 退路，固件暂不切；Q7 RTT 为权威延迟指标、不测单程；Q8 M-A/M-B 解耦；Q9 先出 M-A 卡。

## 目标
把 `std_msgs/Int32` 最小闭环升级为自定义消息包 `exo_msgs`：把 **seq / 时间戳 / 完整性自检** 从「WSL 侧推断」升格为「wire 上的显式字段」，并把 `/exo/link_health` 诊断 topic 落地。本阶段**只把信封（header）做对**，payload 维持可回环验证的最小整数；**不**引入真实控制语义。全部在 WSL 侧 `colcon build` + `colcon test` 全绿，并在 loopback 内复现 A1–A8。

---

## 接口契约

### 任务 1 — 新建 `exo_msgs` 包（ament_cmake 纯接口包，4 个 .msg）
在 `src/exo_msgs/` 新建一个 **ament_cmake 纯接口包**（无逻辑代码，仅 `.msg` + `rosidl` 生成）。`package.xml` 需含 `rosidl_interface_packages` 成员组、`builtin_interfaces` 与 `std_msgs` 依赖（`LinkHealth` 用 `std_msgs/Header`）；`CMakeLists.txt` 用 `rosidl_generate_interfaces`。四个消息 schema **按草案 D1.5 + D5 定稿**（字段名/注释逐字进契约 v1.7）：

```
# exo_msgs/msg/ExoHeader.msg  —— 信封，ExoCmd 与 ExoStatus 共用
uint32 seq            # §7.6 序列号，mod 2^32 回绕；回环用精确相等配对
uint64 stamp_mono_ns  # 发送方单调时钟纳秒（§7.1：禁 wall clock）；仅同发送方内可比
uint32 crc            # 应用级 CRC（默认 0 / 默认不强校验，开发期可开，抓打包 bug）

# exo_msgs/msg/ExoCmd.msg  —— WSL → MCU
ExoHeader header
int32 payload         # 本阶段=心跳/回环值（与 header.seq 解耦）

# exo_msgs/msg/ExoStatus.msg  —— MCU → WSL（结构同 ExoCmd，语义=MCU 回填）
ExoHeader header      # MCU 回填：seq 原样回填收到的 cmd.header.seq；stamp/crc 为回填方重新生成
int32 payload         # 本阶段=原样回填 cmd.payload（回环校验）

# exo_msgs/msg/LinkHealth.msg  —— /exo/link_health，~1 Hz（草案 D5）
std_msgs/Header header   # 标准 Header（wall-clock stamp）：诊断/bag 时间轴，不参与 §7.1 RTT
uint64 sent
uint64 matched
uint64 lost
uint64 duplicate
uint64 stale_duplicate
uint32 inflight
float64 rtt_last_ms
float64 rtt_p95_ms
float64 rtt_max_ms
bool reconciles          # sent==matched+lost+inflight，一眼看链路是否在悄悄掉东西
```

- **CRC 覆盖范围（启用时）**：契约写死 = `crc` 字段置 0 后，对 `seq‖stamp_mono_ns‖payload` 的**规范小端序字节流**计算（避免 CRC 自指）。算法 = **CRC-32**（与字段宽度一致）。M-A 只需 WSL 侧 Python 端实现这个规范，**两端字节序一致是 M-B 联调事**。
- **不变边界（迁移可控）**：topic 名（`/exo/cmd_heartbeat`、`/exo/mcu_status`）、节点名（`exo_cmd` / `exo_loopback`）、命名空间 `/exo/`、QoS（RELIABLE / KEEP_LAST / 分侧 Depth WSL=10 F103=1）、921600 / MTU 128 / 8N1 —— **全部不变**，只换消息载荷。

### 任务 2 — `exo_cmd/link_health.py`：模数重标定 + RTT 滚动窗口
`LinkHealthTracker` **仍 rclpy-free、仍只认「整数 seq + 单调时刻」两个输入，不认消息类型**——这是迁移低风险的最强证据，迁移对它近乎透明。改动仅两处：

1. **`SEQ_MODULUS` 2^31 → 2^32**（草案 D1.1）。连带把所有依赖该常量的域校验/回绕逻辑重标定到 `[0, 2^32)`：
   - `_on_echo_locked` 的入口域守卫 `0 <= seq < SEQ_MODULUS`（越界即 UNMATCHED）随常量自动到 `[0,2^32)`；
   - `_ever_sent` 的 `forward_distance` / `min(sent_count, SEQ_MODULUS-1)` 随常量重标定；
   - `on_send` 的 `(_next_seq + 1) % SEQ_MODULUS` 回绕、`start_seq % SEQ_MODULUS`、`__post_init__` 的 `start_seq` 合法区间从 `[0,2^31)` 改为 `[0,2^32)`。
   - 注释里所有 `2^31` / `[0,2^31)` 字样改 `2^32` / `[0,2^32)`（含模块 docstring 的 §7.5/§7.6 描述）。
2. **新增有界 RTT 滚动窗口**（草案 D5；当前 tracker 只在 matched 事件里算单条 `rtt_ms`、**不存 RTT 分布**）：
   - 加一个**有界环形 buffer**（如 `collections.deque(maxlen=N)`，N 可配置、默认数百~数千条），在 `_on_echo_locked` 的 matched 分支把 `rtt_ms` 推入；
   - tracker 维护并暴露 `rtt_last_ms`（最近一条 matched 的 RTT）、`rtt_p95_ms`、`rtt_max_ms`（窗口内分位数 / 最大值；窗口为空时给确定的占位如 `0.0` 或 `nan`，由你定但要在测试里写死预期）；
   - 经 `counters()` **扩展返回**这三个值，或新增方法（如 `rtt_stats()`）暴露之——任选其一，但要让节点能一次性拿到「计数器 + RTT 统计 + reconciles」喂给 LinkHealth publisher。
   - 全程持 `self._lock`（已有的 `threading.RLock`），与 `MultiThreadedExecutor` 下 sub 回调 / sweep / summary 定时器并发兼容。

### 任务 3 — `exo_cmd/exo_cmd_node.py`：topic 类型 Int32 → ExoCmd/ExoStatus + LinkHealth publisher
适配层硬切（草案 D2），保留已实现的 `MultiThreadedExecutor`、`start_value` nonce、`executor_threads` 参数与三定时器结构：

- **发布端**：`create_publisher` 类型从 `Int32` 改为 `exo_msgs/ExoCmd`，topic 名 `/exo/cmd_heartbeat` 不变。`_publish_heartbeat`（当前 `seq, events = self._tracker.on_send(...)` → `msg.data = seq`）改为构造 `ExoCmd`：
  - `header.seq = seq`（tracker 返回的 seq）；
  - `header.stamp_mono_ns =` 单调纳秒（如 `time.monotonic_ns()`，与喂给 tracker 的单调秒同源同一时刻）；
  - `header.crc =` CRC 开关打开时按规范字节流算、否则置 `0`；
  - `payload =` 回环值（沿用心跳计数 / 回环语义；**可与 seq 相同也可不同，但要与 seq 解耦——即 payload 取值不影响 tracker 配对**）。
- **订阅端**：`create_subscription` 类型从 `Int32` 改为 `exo_msgs/ExoStatus`，topic 名 `/exo/mcu_status` 不变。`_on_status`（当前 `self._tracker.on_echo(msg.data, ...)`）改为 `self._tracker.on_echo(msg.header.seq, ...)`——**seq 来源从 payload 改为 `header.seq`**。
  - 若 **CRC 开关打开**：先按规范字节流校验 `header.crc`；mismatch 时 **`crc_mismatch_count++` + WARN 告警，但不阻断**（仍把 `header.seq` 喂 tracker）。开关关闭时不做校验、不判定。新增一个 `crc_mismatch_count` 计数（节点级即可，或并入 tracker，由你定，但要可观测）。
- **新增 `/exo/link_health` publisher**：`create_publisher(LinkHealth, '/exo/link_health', ...)`，由一个周期定时器（~1 Hz，复用或新增；与现有 `summary_period_s` 解耦，新增 `link_health_period_s` 参数默认 1.0）把 tracker 的 `counters()` + RTT 统计 + `reconciles()` 打包成 `LinkHealth` 发布。`header.stamp` 用 wall-clock（`self.get_clock().now()`，诊断时间轴，**不参与 §7.1 RTT**）。
- 新增 CRC 开关参数：`declare_parameter('crc_enabled', False)`（默认关，草案 D1.4 / Q4）。

### 任务 4 — `exo_cmd/loopback_node.py`：MCU 模拟器迁移 sub ExoCmd → echo ExoStatus
载体迁移，**故障注入逻辑（delay / drop / duplicate / drop_seqs / drop_rate / seed）完全不变**，只换消息类型：

- `create_subscription` 类型 `Int32` → `ExoCmd`；`create_publisher` 类型 `Int32` → `ExoStatus`；topic 名不变。
- `_on_heartbeat(msg)`：`value = msg.data` 改为从 `ExoCmd` 取——丢弃判据用 `msg.header.seq`（与发送侧 seq 同域），payload 原样透传。
- `_publish_echo` / `_schedule_delayed_echo`：构造 `ExoStatus`——`header.seq =` 原样回填收到的 `cmd.header.seq`；`header.stamp_mono_ns =` **盖本地单调纳秒**（模拟 MCU 用自己时钟重盖，不回填 cmd 的 stamp）；`payload =` 原样回填 cmd.payload；`header.crc =` CRC 开关打开时按规范重算、否则 0。
- `duplicate` 注入：重复发布同一 `ExoStatus`（seq 相同），仍触发 A5 duplicate 路径。

### 任务 6 — 契约 bump v1.6 → v1.7（Tom 用 **Edit** 改 `01-接口契约.md` 正文）
> Tom 有 Edit 能力，本卡授权 Tom 直接改契约**正文**。按草案 §D7 的 **8 条变更清单**落地，并把版本号 v1.6→v1.7 + 加一段 v1.7 变更说明：

1. **§1.1 / §1.2 topic 类型**：`std_msgs/Int32` → `exo_msgs/msg/ExoCmd`（cmd_heartbeat）/ `exo_msgs/msg/ExoStatus`（mcu_status）；语义：seq 移到 `header.seq`，回环值移到 `payload`，新增 `header.stamp_mono_ns` / `header.crc`。
2. **§6 演进**：标注 exo_msgs 阶段**已落地（M-A，WSL 侧先行）**，固件侧待真机（M-B）。
3. **§7.1 wire 边界升格**：t_send 从「WSL 侧本地配对的易失状态」升格为 wire 上的 `header.stamp_mono_ns`；**明确写清** RTT 仍是权威延迟指标（WSL 本地配对、整链 RTT），**单程延迟不作为权威指标**（缺 MCU↔WSL 时钟同步，§D4），stamp 用于记录 + MCU 侧相对时效地基。
4. **§7.5 seq 来源升格**：从「payload 整数兼作 seq」升格为 `header.seq` 显式字段，与 payload 解耦；重复 / stale / UNMATCHED / 越界判据语义不变，但「越界」域从 `[0,2^31)` 改为 `[0,2^32)`。
5. **§7.6 回绕语义重标定**：模数 `2^31` → `2^32`；`forward_distance` / `SEQ_MODULUS` 随之更新；A7 回绕测试边界重标定。
6. **§7.7 诊断 topic 落地**：`/exo/link_health` 从「规划」改「已实现」，字段定稿（见任务 1 LinkHealth schema），含 `stale_duplicate`、`reconciles`、`rtt_p95/max`（注明 tracker 新增 RTT 滚动窗口）。
7. **新增「应用级 CRC」条款**：定义 `header.crc` 的算法（CRC-32）、覆盖范围（`seq‖stamp‖payload`、crc 置 0、规范小端序）、默认 disabled / 开发期可开的语义，并**明确写「这不是为防链路误码（帧层 CRC-16 + reliable 已覆盖），而是抓应用打包/序列化 bug 的自检开关」**——避免误导。
8. **RAM 注记**：引用 **T8** 结论（RAM 72.42% / 余 ~5.6KB / 动态分配为零），明确 exo_msgs 内存增量在 20KB 上裕度仍极大、动态分配仍为零（前提：维持静态池配置），消除「自定义消息撑爆 20KB」的担忧。

---

## 实现要点 / 约束

- **顺序建议**：任务 1（建包）→ 任务 2（tracker，纯逻辑可先单测）→ 任务 3 + 4（节点迁移，需任务 1 的消息类型已能 build）→ 任务 5（测试）→ 任务 6（契约 bump，可与测试并行）。先把 `exo_msgs` build 出来，否则节点 import 不到消息类型。
- **tracker 零行为回退**：除模数与 RTT 窗口两处，`LinkHealthTracker` 的对外语义（对账等式 `sent==matched+lost+inflight`、三类判定 duplicate/stale_duplicate/unmatched、`counters()` 既有键、`reconciles()`）**不得变**。现有大量 tracker 逻辑测试应基本原样继续全绿。
- **seq / payload 解耦是硬要求**：tracker 只认 `header.seq`；payload 任意取值都不得影响配对结果。这是 exo_msgs 相对 Int32 的核心结构改进，必须有测试守住。
- **CRC 默认关**：`crc_enabled=False` 时，发送侧 `crc` 置 0、接收侧不校验不判定；只有显式开启才走校验路径。mismatch **计数 + 告警但不阻断**。
- **单调时钟唯一来源**：节点喂给 tracker 的单调秒、与填进 `stamp_mono_ns` 的单调纳秒必须**同源同一时刻**（如同一次 `time.monotonic_ns()` 折算）。禁 wall clock 进 RTT 路径（§7.1）。
- **lint 门禁**：flake8 / pep257 / copyright 必须全过（沿用现有 `test_flake8.py` / `test_pep257.py` / `test_copyright.py` 风格；新建的 `exo_msgs` 包若含 Python 也要过，纯接口包通常无 Python 源）。
- **不碰**：`qos.py`（QoS 与消息类型无关，分侧 Depth 不变）；topic 名 / 节点名 / 命名空间 / 波特率 / MTU。

### 任务 5 — 测试迁移 + 新增（详列，供 Gill 对照）
- **保留并重标定**：tracker 逻辑 / 对抗测试基本保留；把所有 `2^31` 边界常量改 `2^32`（**A7 回绕重标定**：起始值置 `2^32` 边界附近、跨回绕点，验证取模回绕 / matched·lost·duplicate 判定 / 计数器不溢出仍正确）。
- **集成测试载体迁移**：任何构造真实 `Int32()` 喂节点的集成测试，改构造 `ExoStatus()`（回填 `header.seq` + 新 stamp + crc）；loopback 故障注入断言不变。
- **新增**：
  - **payload / seq 解耦**：构造 `ExoStatus`，`header.seq` 固定、`payload` 取任意值（含与 seq 不等、负值、极值），验证配对只看 `header.seq`、payload 不影响 matched/duplicate/unmatched 判定。
  - **CRC 校验路径**：`crc_enabled=True` 下，喂一条 `header.crc` 与内容不符的 `ExoStatus` → `crc_mismatch_count` +1 + WARN，但 seq 仍喂 tracker（不阻断）；`crc_enabled=False` 下，坏 crc 不被判定（计数不动）。
  - **RTT p95 滚动窗口**：喂一串已知 RTT 的 matched 事件，验证 `rtt_last_ms` / `rtt_p95_ms` / `rtt_max_ms` 计算正确、窗口有界（超窗后旧值淘汰）、空窗口给确定占位。
  - **LinkHealth 发布**:验证 publisher 周期发 `LinkHealth`，字段与 tracker 快照一致（sent/matched/lost/duplicate/stale_duplicate/inflight/rtt_*/reconciles）。
- lint（flake8 / pep257）门禁必须过。

### 任务 7 — git tag 退路（**主 agent 执行，Tom 不碰 git**）
Int32 baseline 用 git tag **`int32-baseline`** 保留，由**主 agent** 在 WSL 侧硬切迁移**之前**打。Tom **不执行任何 git 操作**——本卡仅注明此退路，供主 agent 在派发前先打 tag。真机若需回退到已验证的 Int32 链路，checkout 该 tag 即可。

---

## 验收标准（给 Gill）
> 完整可执行判据见 `08-任务卡-exo_msgs-MA-Gill.md`。概要：
- `colcon build`（含 `exo_msgs`）+ `colcon test` 全绿（含 flake8 / pep257 / copyright lint）。
- loopback 用 **exo_msgs 载体** 复现 A1–A8：对账恒等 `sent==matched+lost+inflight`、零 UNMATCHED、A2 延迟告警、A3 丢包精确计数。
- `/exo/link_health` 真发布且字段对（`reconciles` 反映对账；`rtt_p95/max/last` 合理）。
- CRC 开关两条路径：关=不判定、开=坏 crc 被检出计数 + 告警不阻断。
- seq / payload 解耦验证；回绕在 **2^32** 边界仍正确。
- 契约已 bump v1.7、8 条变更清单全部落地、版本号与变更说明段就位。

---

## 不在本卡范围内（全部属 M-B，等板子）
- **固件侧任何改动**：F103 收 `ExoCmd` 解包、回填 `ExoStatus`（seq 原样 / MCU 时钟 stamp / payload 原样 / crc 重算）。
- **重建 libmicroros**：把 `exo_msgs` 喂进 micro-ROS firmware 构建、重新生成 type support、重建静态库。
- **MCU 时钟源**：F103 用 DWT CYCCNT @72MHz 折算 `stamp_mono_ns`。
- **CRC 端到端字节序一致性**：MCU 手算 CRC 与 WSL 端规范小端序对齐（M-A 只交付 WSL 侧 Python 规范实现，不做跨端联调）。
- **真机 A1–A8 在 exo_msgs 上复现 + endurance soak + RAM/ROM 增量实测**。
- **payload 结构体化 / 真实控制语义**（关节角 / 力矩 / 模式）：属未来电机控制需求，本阶段 payload 维持最小 `int32`。
- **真单程延迟测量 / 时钟同步**：Q7 已定 RTT 为权威，stamp 仅记录 + 地基。
- **git 操作**：tag `int32-baseline` 由主 agent 打，Tom 不碰 git。
