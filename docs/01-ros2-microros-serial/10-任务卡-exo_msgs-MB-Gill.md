# 任务卡 10：exo_msgs 里程碑 M-B —— 真机验收（Gill）

- 负责测试 / 独立验证：**Gill**
- 对应开发卡：`09-任务卡-exo_msgs-MB-Tom.md`（Tom）
- 验收基准：契约 `01-接口契约.md` **v1.7**（§1.1/§1.2 消息 schema、§7.1 stamp / RTT 权威、§7.6 seq mod 2^32、§7.7 LinkHealth、§7.9 CRC）；设计草案 `06-exo_msgs设计草案.md`（§D6 固件影响、§2.2 M-B 表、§3 风险）；Phase B 攻坚计划 `05-PhaseB攻坚计划.md`（T8 量化工具、`hw_acceptance` / `bidi_recon` 真机对账思路）；**`11-exo_msgs-MB放行前复核.md`(放行前复核 checklist，与本卡配套)**
- 状态：⬜ 未开始

> **⚠️ 验收前必读**：本卡随附 `11-exo_msgs-MB放行前复核.md`，列了 4 个派卡前补进来的硬约束（流缓冲闸门 B1 / payload bit-exact H1 / creation mode 回退是下策需拍板 H2 / DWT 回绕用独立高频源 H3）。Gill 的对抗验收要专门盯这 4 条 + 两个确认门是否被 Tom 自决绕过。

> **里程碑边界**：本卡 = **M-B，强依赖真机在环、反复烧录/联调**。**无硬件不能做**。验证目标：Tom 迁移后的固件（exo_msgs 载体）在**真板**上把 M-A 在 WSL loopback 内已验证的 A1–A8 + 诊断 + CRC + 水位**等价复现**，且无重连 / 无 HardFault。对 Tom 的固件做**独立交叉验证**：对照契约逐项检查、真机实跑、用对抗思维找漏洞。必要时用 `tools/codex-review.sh` 取第二意见。
>
> **前置依赖（硬条件，缺一不能验收）**：① **真板已接上**（Nucleo-F103RB + USB-TTL 接 USART1 PA9/PA10）；② **usbipd attach 两个设备进 WSL**：`/dev/ttyUSB0`（USB-TTL 通信口）+ `/dev/ttyACM0`（ST-Link 烧录口），`ls /dev/ttyUSB* /dev/ttyACM*` 都在；③ **M-A 已绿**（v1.7 契约、WSL 侧 exo_msgs `exo_cmd` 节点 / tracker / 诊断 topic 全绿，81 tests 全绿）；④ Tom 已交付：含 exo_msgs type support 的 libmicroros 重建成功 + 迁移后固件烧上板 + **任务 5.0 流缓冲闸门结论** + 任务 5 agent 兼容性结论 + 任务 6 量化数据。
>
> **真机对端**：用 **M-A 迁移后的 `exo_cmd` 节点**（已 exo_msgs 载体）对接真板，跑 `hw_acceptance.sh`（真机对账脚本，思路沿用 `05` 文档 `bidi_recon` / endurance）。**注明**：`hw_acceptance.sh` 若原为 Int32 载体，需适配 —— ① topic 类型 / `ros2 topic echo` 改 `exo_msgs/msg/ExoStatus`（且 source 了 exo_msgs install）；② 对账取 seq 从 `header.seq`（非 `data`）；③ 若脚本内嵌断言按 Int32 字段名，同步改 exo_msgs 字段。Gill 在 V0 先确认脚本适配到位再跑 A1–A8。

---

## 验收判据（逐条可执行）

### V0 — 重建 libmicroros + 固件链接 + 烧录上板（M-B 最重一步的产物验收）
- **libmicroros 含 exo_msgs type support**：确认 Tom 把 `exo_msgs` 喂进固件构建（`~/uros_ws/firmware/mcu_ws/uros/exo_msgs/`）、**完整重建** libmicroros、产物覆盖 `firmware/f103-microros/ThirdParty/microros/libmicroros.a` + `include/`（含生成的 `exo_msgs/msg/exo_cmd.h` / `exo_status.h` / `exo_header.h`）。
- **裁剪真生效**（重建后回读，键名错会被静默忽略）：生成的 rmw `config.h` 里 `RMW_UXRCE_MAX_PUBLISHERS/SUBSCRIPTIONS/HISTORY/STREAM_HISTORY` 与 `UCLIENT_CUSTOM_TRANSPORT_MTU=128` 与 colcon.meta 一致。**`RMW_UXRCE_STREAM_HISTORY` 实际值要单独确认**（若 Tom 因 V0.5 闸门把它从 2 调大，确认 config.h、colcon.meta、libmicroros 三者一致且已据此重建）。
- **固件链接通过**：`cmake --build` 产出 `.elf`/`.bin`，无 undefined ref / multiple def（ABI flag 一致）；map 显示链接了 exo_msgs type support。
- **烧录上板**：`st-flash --connect-under-reset write build/<...>.bin 0x08000000` 成功（WSL+usbip 下 F103 **必须 `--connect-under-reset`**）。
- **判定**：含 exo_msgs 的 lib 重建成功、固件链接通过、烧录上板、裁剪生效。

### V0.5 — 🔴 流缓冲闸门：exo_msgs create bin 描述消息塞进 STREAM_HISTORY（★先于 V1，B1 / T5 ③ 同款）
> 这是比 agent 兼容性更靠前的技术风险闸门（对应 Tom 任务 5.0）。T5 ③ 已踩过：`STREAM_HISTORY=1`(128B) 下 `create_topic` bin 描述消息塞不下 → publisher 创建失败；当时调到 `=2`(256B) 才修。exo_msgs 类型名/topic 名/type hash 比 Int32 长，create 描述消息更大，**256B 是否仍够是未知数，必须实测**。该失效会伪装成「agent 兼容性问题」误导排查——所以先排除这一层。
- **复验 publisher/subscriber 真建出**：烧最小 exo_msgs spike（或迁移后固件），固件侧 `rclc_publisher_init_default` / `rclc_subscription_init_default` 返回成功（不是建实体失败）；agent `-v6` 日志无 reliable 输出流缓冲溢出 / create 描述消息发不完整 / create 超时反复重试。
- **若 Tom 调大了 STREAM_HISTORY**：复验最终取值已写进 colcon.meta、libmicroros 已据此再重建（V0 config.h 一致）、`-v6` 实测 XRCE 分片正常（串口单帧仍 ≤128B 不破契约 §3）、agent 能重组、且 V6 的 RAM 复测把增大的流缓冲占用计入仍有正裕度。
- **对抗点**：不要把「publisher 创建失败」直接归因到 agent 兼容性（V1）——先确认 client 侧实体本身建出来了（流缓冲够），再谈 agent 能否桥接。两层分清。
- **判定**：exo_msgs create bin 描述消息能在最终 STREAM_HISTORY 配置下塞进流缓冲、实体在 client 侧成功创建；若调大了 STREAM_HISTORY，MTU 分片不破 + RAM 复测达标 + 已记录回报。

### V1 — agent bin 模式自定义类型兼容性结论（★技术风险闸门，先于 A1–A8，在 V0.5 通过之后）
> 这是 M-B 的技术风险闸门（契约 colcon.meta `RMW_UXRCE_CREATION_MODE=bin`、`tools/run-agent.sh` = bin 模式 vanilla agent）。Gill 独立复验 Tom 任务 5 的结论。**前提：V0.5 流缓冲闸门已过**（client 侧实体建得出来），否则 agent 根本看不到 create 子消息。
- 起 `tools/run-agent.sh /dev/ttyUSB0 921600`（vanilla bin agent），烧迁移后固件，看 agent `-v6` 日志：**datawriter（`/exo/mcu_status`，类型 `exo_msgs::msg::dds_::ExoStatus_`）与 datareader（`/exo/cmd_heartbeat`，`ExoCmd`）都建出**（不是建实体失败、不是退回通用类型）。
- WSL 侧（source 了 exo_msgs install）`ros2 topic echo /exo/mcu_status` **正确反序列化**出 exo_msgs 字段（`header.seq` / `header.stamp_mono_ns` / `header.crc` / `payload`），不是乱码 / 不匹配。
- **若 Tom 的结论是「需喂 agent 侧 exo_msgs」（首选 (a)）**：复验重建 agent 工作区后兼容性恢复，且**确认 Tom 没动 colcon.meta 的 creation mode**（仍是 bin，固件侧建链路径/RAM 不变）。
- **🛑 若 Tom 改了 `RMW_UXRCE_CREATION_MODE` 为 `xml`（下策 (b)）**：Gill 必须先**确认该决策已经过用户/Elon 拍板**（见 `11` checklist 的确认门——Tom 不得自决切 xml）。若是 Tom 自行切换、未经拍板 → **直接判 V1 不通过并回报**。若已拍板：复验改动后兼容性恢复 + 复核 colcon.meta 变更已记录 + libmicroros 已据此再重建 + **V0.5 流缓冲闸门在 xml 模式下重测**（xml 实体描述更大）+ RAM 复测仍达标（V6）+ 建链路径重跑 T5 级对账（4 根因在 xml 下复核）。
- **判定**：datawriter/datareader 都建出、WSL 侧正确反序列化、兼容性结论明确且复验通过；若走 (b) 则确认已拍板且全套复测通过。

### V2 — 真机 A1–A8 在 exo_msgs 载体上复现
> 用迁移后的 `exo_cmd` 节点对接真板，跑 `hw_acceptance.sh`（已 V0 适配 exo_msgs 载体）。判据 = **tracker 对账恒等 + datawriter/datareader 都建出 + 零 UNMATCHED**。逐点（语义同 M-A，载体换 exo_msgs、链路换真机）：
- **A1 RTT 可测**：真机回环每条 matched echo 算出并记录 `rtt_ms`（WSL 本地配对 t_send/t_recv，整链 RTT，单调时钟非 wall clock，§7.1）。
- **A2 超限告警**：真机 RTT 自然或注入超 `rtt_warn_ms` → WARN 含 seq + 实测 rtt；阈值内无误报。
- **A3 丢包可检**：制造丢包 → `rtt_deadline_ms` 后判 lost、`lost_count` 精确 +1、告警；丢 k 条 ⇒ lost 增 k。
- **A4 禁止静默驱逐**：积压超容量上界 → 无条目被无声删除，要么 matched 要么 lost；对账恒等不破。
- **A5 / A5b 重复 / 超窗重传**：RELIABLE 重传导致同 seq echo 多次（F103 侧 depth=1 真机更易触发）→ `duplicate` / `stale_duplicate` 精确计数，**不**误报 UNMATCHED。
- **A6 / A6b 错值 / 越界仍报**：从未发出的 seq / 越界值 → UNMATCHED（域 `[0,2^32)`，§7.6）。
- **A7 回绕安全（2^32）**：真机长跑或注入近回绕起始值，跨回绕点判定仍正确（验证手段：真机 + 逻辑层对照，2^32 边界）。
- **A8 对账可观测**：任意时刻 `sent / matched / lost / duplicate / stale_duplicate / inflight` 可读，**`sent == matched + lost + inflight` 恒成立**。
- **A9 payload bit-exact 透传（H1）**：抓真机回发的 `ExoStatus.payload`，与对应 `ExoCmd.payload` **逐位相同**（含负值 / 极值 / 0 / -1）——固件不得对 payload 做任何变换（不缩放/不饱和/不字节序翻转）。配对只看 `header.seq`，payload 任意值不影响配对（§7.5），但回发的 payload 字节必须与下发逐位一致（回环校验位）。
- **判定**：A1–A9 全部成立，**tracker 对账恒等任意时刻为真 + datawriter/datareader 都建出 + 零 UNMATCHED + payload bit-exact**（无故障注入的正常真机回环下）。

### V3 — endurance soak（长跑稳定）
- 真机连续跑 endurance soak（沿用 `05` 文档 10min+ soak 思路，可更长），全程：对账恒等成立、`lost=0` / `duplicate` 仅来自 RELIABLE 正常重传 / 零 UNMATCHED；无值错乱。
- **判定**：soak 全程链路健康、对账恒等不破、无丢序 / 无错值。

### V4 — CRC 开启端到端无 mismatch（★最易出 bug 点）
> 默认 `crc_enabled=False` 不阻断主链路；本判据**单独开启** crc 验证两端字节序逐字节一致（契约 §7.9 / Tom 任务 4）。
- WSL 侧 + 固件**同时开 `crc_enabled=True`**，真机端到端跑：WSL 侧 `crc_mismatch_count` **恒为 0**（说明 MCU 端 CRC-32 与 `zlib.crc32` 规范 `<IQi`（crc 置 0、规范小端序、覆盖**回填后的** `seq‖stamp‖payload`）逐字节对齐）。
- 对抗点：若 mismatch 非零 → 即字节序/覆盖范围/CRC 参数不一致，定位 Tom 任务 4（提示常见错：依赖 C struct padding 拼字节、未把 crc 置 0、端序拼错、**误用 cmd 的三元组而非回填后的 ExoStatus 三元组算 CRC**）。
- 默认关路径：`crc_enabled=False` 时主链路不依赖 CRC，A1–A8 正常。
- **判定**：开启 crc 端到端 `crc_mismatch_count`=0；关闭时主链路不受影响。

### V5 — MCU 时钟 stamp 长跑单调不倒退（DWT CYCCNT）+ 🔴 >60s 静默对抗（H3）
- **基础长跑单调**：抓真机回发的 `ExoStatus.header.stamp_mono_ns` 序列，长跑（**至少跨过 CYCCNT 32 位 ~59.65s 回绕点多次**）验证 **stamp 单调不倒退**（Tom 任务 3 要求 64 位软件扩展处理 CYCCNT 回绕；若实现不当，会在 ~59s 处 stamp 跳变倒退）。
- **🔴 静默对抗（H3，必做）**：**两次 stamp 之间人为制造 >60s 静默**——停发 cmd（或断开 WSL 侧发送）至少 65s（确保跨过一整个 CYCCNT 回绕周期 59.65s），然后恢复发 cmd，检查恢复后第一条及后续 `ExoStatus.header.stamp_mono_ns` **仍单调不倒退、不出现回退/跳变**。
  - **为什么这条专门设**：若 Tom 把回绕检测做成「在 `dwt_now_ns()` 调用点比较上次 CYCCNT」（H3 禁止的做法），则两次 stamp 调用间隔 >59.65s 时会漏检一个回绕、累加少加 2^32 → 恢复后 stamp 倒退。这个 bug 在持续发包的长跑里**抓不到**（调用够频不会漏检），**只有断流 >60s 再恢复才暴露**。这正是链路断流/重连场景（控制环安全关键），必须如实暴露不可掩盖。
  - 复验 Tom 的回绕扩展确实由独立高频源（SysTick / FreeRTOS tick，周期 << 59.65s）维护、`dwt_now_ns()` 只读累加值（看 Tom 交付的实现说明 + 必要时 `tools/codex-review.sh` 复审 DWT 时钟扩展代码）。
- 绝对值不可比已 §D4 接受，**只验稳定单调**（同一发送方内相对可比）；不验跨端单程（§7.1 RTT 才是权威）。
- **判定**：stamp_mono_ns 长跑（跨多次 CYCCNT 回绕）单调不倒退，**且 >60s 静默后恢复仍单调不倒退**。

### V6 — RAM/ROM 水位达标 + 动态分配为零（沿用 T8 工具）
> 沿用 T8 量化工具复核 Tom 任务 6 数据。**T8 基线**：RAM 72.42% / 14840B / 余 ~5.6KB、Flash 59.1%、动态分配实测=0、uros 栈峰值 285w/1536w。
- **RAM `.data+.bss`**：`arm-none-eabi-size` + gdb 读段水位；exo_msgs 增量（每实例 +16B 量级 + type support 进 ROM）后**仍有正裕度**（20KB 上，§D6 / 契约 §6 RAM 注记）。**若 Tom 调大了 STREAM_HISTORY（V0.5）或改了 xml（V1），把增大的 reliable 流缓冲静态占用一并核进 RAM 增量**。
- **动态分配为零**（关键）：gdb 读 `heap_end` / `sbrk_start` / `ucHeap`（FreeRTOS heap）确认仍全零；`xPortGetMinimumEverFreeHeapSize` 确认 heap 未触底。**自定义消息不得引入任何动态分配**（维持 colcon.meta 静态池配置；若任务 5 改成 xml 模式，重新确认动态分配仍为零）。
- **栈水位**：扫 0xA5 栈水位 / `uxTaskGetStackHighWaterMark`，micro-ROS 任务 HWM_min ≥ 安全余量（≥128 words），解包/回填/CRC 的额外栈深度已纳入（**含新增的 DWT 高频 tick 钩子 / 回绕扩展逻辑的栈影响**）。
- **Flash/ROM**：`size`/`.map` 确认 type support + CRC 表（~1KB）增量后 Flash 仍有裕度；若 Tom 按 M4 裁掉了 LinkHealth，确认裁剪理由（Flash 余量）有量化依据。
- **判定**：RAM/ROM 正裕度、**动态分配实测为零**、栈水位达标。

### V7 — 无重连 / 无 HardFault
- 真机全程（含 A1–A8 + soak + V5 静默对抗）：`rmw_uros_ping_agent` 重连路径**不被触发**（`create_client` / session established 各一次，长跑零重连，沿用 `05` 文档 GO 判据「10min 零重连零 fault」）；无 HardFault（LED 心跳 / 自检串 / agent `-v6` 不出现断链重建 / 固件死循环 fail_stop）。
  - **注意 V5 的 >60s 静默**：静默期只是停发 cmd（WSL 侧不发），**不应**触发固件侧重连/重建——若静默期固件误判 agent 掉线而重连，要查（ping 超时配置 / 静默不等于断链）。静默恢复后链路应无缝续上、不重建 session。
- 对抗点：复位重连后能稳定重建一次；但**稳态运行期不得无故重连**（重连=链路或资源问题，需暴露）。
- **判定**：稳态零重连、零 HardFault、单次稳定建链、静默期不误重连。

---

## 对抗性重点（给 Gill 的「找漏洞」清单）
- **🔴 流缓冲层 vs agent 兼容性别混淆（B1 / V0.5）**：「publisher 创建失败」先排查是不是 exo_msgs create bin 描述消息塞不进 STREAM_HISTORY（T5 ③ 同款，client 侧问题），别一上来就归因到 agent 兼容性。两层分清，V0.5 先于 V1。
- **agent 类型桥接退化**：确认 `-v6` 日志真建出 `exo_msgs::msg::dds_::ExoStatus_/ExoCmd_` 的 datawriter/datareader，而非建实体失败 / 退回通用类型导致 WSL 侧静默匹配不上（V1 是闸门，先于 A1–A8）。
- **🛑 creation mode 是否被偷偷改成 xml（H2）**：若 Tom 把 colcon.meta 的 `RMW_UXRCE_CREATION_MODE` 改成 `xml`，确认这经过用户/Elon 拍板（确认门）。Tom 自决切 xml = 越权回退 T5 已签字的 bin 决策 → 判不通过并回报。
- **seq 回填遗漏**：固件回发的 `ExoStatus.header.seq` 必须是**原样回填** `cmd.header.seq`，不是 MCU 自造 / 不是 payload；payload 任意值不得影响配对（exo_msgs 相对 Int32 的核心改进，§7.5）。
- **🔴 payload bit-exact 透传（H1 / A9）**：ExoStatus.payload 与 ExoCmd.payload 逐位相同；固件不得缩放/饱和/翻字节序/重解释类型。任何变换都把回环校验位自身变成伪故障源。
- **stamp 重盖而非回填**：`ExoStatus.header.stamp_mono_ns` 必须是 MCU 自己 DWT 时钟（§7.1：两端时钟不可比，回填方重盖），不是把 cmd 的 stamp 原样回填。
- **🔴 CYCCNT 回绕 + 断流漏检（H3 / V5）**：stamp 跨 ~59s CYCCNT 回绕点单调不倒退；**且 >60s 静默（停发 cmd）后恢复仍单调**——这是「在 stamp 调用点比较上次 CYCCNT」式实现的致命盲区（断流 >59.65s 漏检一个回绕致 stamp 倒退），持续发包长跑抓不到，必须断流对抗。确认回绕扩展由独立高频源维护。
- **CRC 字节序**：开启 crc 时端到端 mismatch 必须为 0；任一字节序 / 覆盖范围错都会持续 mismatch（V4，最易出 bug 点）。确认 crc 计算时 crc 字段置 0（避免自指）、且算的是**回填后的 ExoStatus 三元组**而非 cmd 的。
- **动态分配偷偷溜入**：exo_msgs type support / CRC / 重建后 / 调大 STREAM_HISTORY 后是否引入任何 malloc —— gdb 读 heap 三处必须仍全零（V6）。
- **稳态重连**：长跑期任何非预期重连都要查（资源 / 链路退化），不得当噪声忽略（V7）；V5 静默期误重连也要查。
- 用 `tools/codex-review.sh` 对固件 callback 迁移（解包/回填/stamp/crc/payload 透传）+ DWT 时钟扩展（独立高频源 + 原子读取）+ CRC 实现做一次跨厂商对抗复审。

---

## 不在本卡范围内
- **WSL 侧 exo_msgs 逻辑验收**（tracker 模数 / RTT 窗口 / 诊断 topic / CRC Python 规范自洽 / seq-payload 解耦的纯逻辑层）：**M-A 已由 `08` 卡验收通过**，本卡只验真机在环复现，不重验 WSL 侧纯逻辑。
- **payload 结构体化 / 真实控制语义**（关节角 / 力矩 / 模式）：属未来电机控制需求。
- **真单程延迟测量 / 时钟同步**：§D4 / Q7 已定 RTT 为权威，stamp 仅记录 + 相对时效；本卡只验 stamp 单调，不验跨端单程。
- **custom transport 从轮询升 DMA circular 优化**的性能验收：那是独立 Phase B 优化项（`05` 文档 C.2）。
- **契约正文核对**：v1.7 已由 `08` 卡（V6）核对落地；本卡是 v1.7 固件侧落实的真机验收，不重核契约正文。
- **git 操作**：tag `int32-baseline` 由主 agent 维护；Gill 可提醒主 agent「真机若需回退到已验证 Int32 链路，checkout 该 tag」，但不执行 git。
