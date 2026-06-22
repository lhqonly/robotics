# 任务卡 10：exo_msgs 里程碑 M-B —— 真机验收（Gill）

- 负责测试 / 独立验证：**Gill**
- 对应开发卡：`09-任务卡-exo_msgs-MB-Tom.md`（Tom）
- 验收基准：契约 `01-接口契约.md` **v1.7**（§1.1/§1.2 消息 schema、§7.1 stamp / RTT 权威、§7.6 seq mod 2^32、§7.7 LinkHealth、§7.9 CRC）；设计草案 `06-exo_msgs设计草案.md`（§D6 固件影响、§2.2 M-B 表、§3 风险）；Phase B 攻坚计划 `05-PhaseB攻坚计划.md`（T8 量化工具、`hw_acceptance` / `bidi_recon` 真机对账思路）
- 状态：⬜ 未开始

> **里程碑边界**：本卡 = **M-B，强依赖真机在环、反复烧录/联调**。**无硬件不能做**。验证目标：Tom 迁移后的固件（exo_msgs 载体）在**真板**上把 M-A 在 WSL loopback 内已验证的 A1–A8 + 诊断 + CRC + 水位**等价复现**，且无重连 / 无 HardFault。对 Tom 的固件做**独立交叉验证**：对照契约逐项检查、真机实跑、用对抗思维找漏洞。必要时用 `tools/codex-review.sh` 取第二意见。
>
> **前置依赖（硬条件，缺一不能验收）**：① **真板已接上**（Nucleo-F103RB + USB-TTL 接 USART1 PA9/PA10）；② **usbipd attach 两个设备进 WSL**：`/dev/ttyUSB0`（USB-TTL 通信口）+ `/dev/ttyACM0`（ST-Link 烧录口），`ls /dev/ttyUSB* /dev/ttyACM*` 都在；③ **M-A 已绿**（v1.7 契约、WSL 侧 exo_msgs `exo_cmd` 节点 / tracker / 诊断 topic 全绿，81 tests 全绿）；④ Tom 已交付：含 exo_msgs type support 的 libmicroros 重建成功 + 迁移后固件烧上板 + 任务 5 agent 兼容性结论 + 任务 6 量化数据。
>
> **真机对端**：用 **M-A 迁移后的 `exo_cmd` 节点**（已 exo_msgs 载体）对接真板，跑 `hw_acceptance.sh`（真机对账脚本，思路沿用 `05` 文档 `bidi_recon` / endurance）。**注明**：`hw_acceptance.sh` 若原为 Int32 载体，需适配 —— ① topic 类型 / `ros2 topic echo` 改 `exo_msgs/msg/ExoStatus`（且 source 了 exo_msgs install）；② 对账取 seq 从 `header.seq`（非 `data`）；③ 若脚本内嵌断言按 Int32 字段名，同步改 exo_msgs 字段。Gill 在 V0 先确认脚本适配到位再跑 A1–A8。

---

## 验收判据（逐条可执行）

### V0 — 重建 libmicroros + 固件链接 + 烧录上板（M-B 最重一步的产物验收）
- **libmicroros 含 exo_msgs type support**：确认 Tom 把 `exo_msgs` 喂进固件构建（`~/uros_ws/firmware/mcu_ws/uros/exo_msgs/`）、**完整重建** libmicroros、产物覆盖 `firmware/f103-microros/ThirdParty/microros/libmicroros.a` + `include/`（含生成的 `exo_msgs/msg/exo_cmd.h` / `exo_status.h` / `exo_header.h`）。
- **裁剪真生效**（重建后回读，键名错会被静默忽略）：生成的 rmw `config.h` 里 `RMW_UXRCE_MAX_PUBLISHERS/SUBSCRIPTIONS/HISTORY/STREAM_HISTORY` 与 `UCLIENT_CUSTOM_TRANSPORT_MTU=128` 与 colcon.meta 一致。
- **固件链接通过**：`cmake --build` 产出 `.elf`/`.bin`，无 undefined ref / multiple def（ABI flag 一致）；map 显示链接了 exo_msgs type support。
- **烧录上板**：`st-flash --connect-under-reset write build/<...>.bin 0x08000000` 成功（WSL+usbip 下 F103 **必须 `--connect-under-reset`**）。
- **判定**：含 exo_msgs 的 lib 重建成功、固件链接通过、烧录上板、裁剪生效。

### V1 — agent bin 模式自定义类型兼容性结论（★必须先验证的技术风险，先于 A1–A8）
> 这是 M-B 的技术风险闸门（契约 colcon.meta `RMW_UXRCE_CREATION_MODE=bin`、`tools/run-agent.sh` = bin 模式 vanilla agent）。Gill 独立复验 Tom 任务 5 的结论。
- 起 `tools/run-agent.sh /dev/ttyUSB0 921600`（vanilla bin agent），烧迁移后固件，看 agent `-v6` 日志：**datawriter（`/exo/mcu_status`，类型 `exo_msgs::msg::dds_::ExoStatus_`）与 datareader（`/exo/cmd_heartbeat`，`ExoCmd`）都建出**（不是建实体失败、不是退回通用类型）。
- WSL 侧（source 了 exo_msgs install）`ros2 topic echo /exo/mcu_status` **正确反序列化**出 exo_msgs 字段（`header.seq` / `header.stamp_mono_ns` / `header.crc` / `payload`），不是乱码 / 不匹配。
- **若 Tom 的结论是「需改 creation mode 为 xml / 喂 agent 侧 exo_msgs」**：复验改动后兼容性恢复，且若改了 `RMW_UXRCE_CREATION_MODE` → 复核 colcon.meta 变更已记录、libmicroros 已据此再重建、RAM 复测仍达标（V6）。
- **判定**：datawriter/datareader 都建出、WSL 侧正确反序列化、兼容性结论明确且复验通过。

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
- **判定**：A1–A8 全部成立，**tracker 对账恒等任意时刻为真 + datawriter/datareader 都建出 + 零 UNMATCHED**（无故障注入的正常真机回环下）。

### V3 — endurance soak（长跑稳定）
- 真机连续跑 endurance soak（沿用 `05` 文档 10min+ soak 思路，可更长），全程：对账恒等成立、`lost=0` / `duplicate` 仅来自 RELIABLE 正常重传 / 零 UNMATCHED；无值错乱。
- **判定**：soak 全程链路健康、对账恒等不破、无丢序 / 无错值。

### V4 — CRC 开启端到端无 mismatch（★最易出 bug 点）
> 默认 `crc_enabled=False` 不阻断主链路；本判据**单独开启** crc 验证两端字节序逐字节一致（契约 §7.9 / Tom 任务 4）。
- WSL 侧 + 固件**同时开 `crc_enabled=True`**，真机端到端跑：WSL 侧 `crc_mismatch_count` **恒为 0**（说明 MCU 端 CRC-32 与 `zlib.crc32` 规范 `<IQi`（crc 置 0、规范小端序、覆盖 `seq‖stamp‖payload`）逐字节对齐）。
- 对抗点：若 mismatch 非零 → 即字节序/覆盖范围/CRC 参数不一致，定位 Tom 任务 4（提示常见错：依赖 C struct padding 拼字节、未把 crc 置 0、端序拼错）。
- 默认关路径：`crc_enabled=False` 时主链路不依赖 CRC，A1–A8 正常。
- **判定**：开启 crc 端到端 `crc_mismatch_count`=0；关闭时主链路不受影响。

### V5 — MCU 时钟 stamp 长跑单调不倒退（DWT CYCCNT）
- 抓真机回发的 `ExoStatus.header.stamp_mono_ns` 序列，长跑（**至少跨过 CYCCNT 32 位 ~59.65s 回绕点多次**）验证 **stamp 单调不倒退**（Tom 任务 3 要求 64 位软件扩展处理 CYCCNT 回绕；若实现不当，会在 ~59s 处 stamp 跳变倒退）。
- 绝对值不可比已 §D4 接受，**只验稳定单调**（同一发送方内相对可比）；不验跨端单程（§7.1 RTT 才是权威）。
- **判定**：stamp_mono_ns 长跑（跨多次 CYCCNT 回绕）单调不倒退。

### V6 — RAM/ROM 水位达标 + 动态分配为零（沿用 T8 工具）
> 沿用 T8 量化工具复核 Tom 任务 6 数据。**T8 基线**：RAM 72.42% / 14840B / 余 ~5.6KB、Flash 59.1%、动态分配实测=0、uros 栈峰值 285w/1536w。
- **RAM `.data+.bss`**：`arm-none-eabi-size` + gdb 读段水位；exo_msgs 增量（每实例 +16B 量级 + type support 进 ROM）后**仍有正裕度**（20KB 上，§D6 / 契约 §6 RAM 注记）。
- **动态分配为零**（关键）：gdb 读 `heap_end` / `sbrk_start` / `ucHeap`（FreeRTOS heap）确认仍全零；`xPortGetMinimumEverFreeHeapSize` 确认 heap 未触底。**自定义消息不得引入任何动态分配**（维持 colcon.meta 静态池配置；若任务 5 改成 xml 模式，重新确认动态分配仍为零）。
- **栈水位**：扫 0xA5 栈水位 / `uxTaskGetStackHighWaterMark`，micro-ROS 任务 HWM_min ≥ 安全余量（≥128 words），解包/回填/CRC 的额外栈深度已纳入。
- **Flash/ROM**：`size`/`.map` 确认 type support + CRC 表（~1KB）增量后 Flash 仍有裕度。
- **判定**：RAM/ROM 正裕度、**动态分配实测为零**、栈水位达标。

### V7 — 无重连 / 无 HardFault
- 真机全程（含 A1–A8 + soak）：`rmw_uros_ping_agent` 重连路径**不被触发**（`create_client` / session established 各一次，长跑零重连，沿用 `05` 文档 GO 判据「10min 零重连零 fault」）；无 HardFault（LED 心跳 / 自检串 / agent `-v6` 不出现断链重建 / 固件死循环 fail_stop）。
- 对抗点：复位重连后能稳定重建一次；但**稳态运行期不得无故重连**（重连=链路或资源问题，需暴露）。
- **判定**：稳态零重连、零 HardFault、单次稳定建链。

---

## 对抗性重点（给 Gill 的「找漏洞」清单）
- **agent 类型桥接退化**：确认 `-v6` 日志真建出 `exo_msgs::msg::dds_::ExoStatus_/ExoCmd_` 的 datawriter/datareader，而非建实体失败 / 退回通用类型导致 WSL 侧静默匹配不上（V1 是闸门，先于 A1–A8）。
- **seq 回填遗漏**：固件回发的 `ExoStatus.header.seq` 必须是**原样回填** `cmd.header.seq`，不是 MCU 自造 / 不是 payload；payload 任意值不得影响配对（exo_msgs 相对 Int32 的核心改进，§7.5）。
- **stamp 重盖而非回填**：`ExoStatus.header.stamp_mono_ns` 必须是 MCU 自己 DWT 时钟（§7.1：两端时钟不可比，回填方重盖），不是把 cmd 的 stamp 原样回填。
- **CRC 字节序**：开启 crc 时端到端 mismatch 必须为 0；任一字节序 / 覆盖范围错都会持续 mismatch（V4，最易出 bug 点）。确认 crc 计算时 crc 字段置 0（避免自指）。
- **CYCCNT 回绕**：stamp 跨 ~59s CYCCNT 回绕点单调不倒退（V5）；这是 DWT 折算最易踩的坑。
- **动态分配偷偷溜入**：exo_msgs type support / CRC / 重建后是否引入任何 malloc —— gdb 读 heap 三处必须仍全零（V6）。
- **稳态重连**：长跑期任何非预期重连都要查（资源 / 链路退化），不得当噪声忽略（V7）。
- 用 `tools/codex-review.sh` 对固件 callback 迁移（解包/回填/stamp/crc）+ DWT 时钟扩展 + CRC 实现做一次跨厂商对抗复审。

---

## 不在本卡范围内
- **WSL 侧 exo_msgs 逻辑验收**（tracker 模数 / RTT 窗口 / 诊断 topic / CRC Python 规范自洽 / seq-payload 解耦的纯逻辑层）：**M-A 已由 `08` 卡验收通过**，本卡只验真机在环复现，不重验 WSL 侧纯逻辑。
- **payload 结构体化 / 真实控制语义**（关节角 / 力矩 / 模式）：属未来电机控制需求。
- **真单程延迟测量 / 时钟同步**：§D4 / Q7 已定 RTT 为权威，stamp 仅记录 + 相对时效；本卡只验 stamp 单调，不验跨端单程。
- **custom transport 从轮询升 DMA circular 优化**的性能验收：那是独立 Phase B 优化项（`05` 文档 C.2）。
- **契约正文核对**：v1.7 已由 `08` 卡（V6）核对落地；本卡是 v1.7 固件侧落实的真机验收，不重核契约正文。
- **git 操作**：tag `int32-baseline` 由主 agent 维护；Gill 可提醒主 agent「真机若需回退到已验证 Int32 链路，checkout 该 tag」，但不执行 git。
