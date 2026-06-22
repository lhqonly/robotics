# 任务卡 08：exo_msgs 里程碑 M-A —— WSL 侧验收（Gill）

- 负责测试 / 独立验证：**Gill**
- 对应开发卡：`07-任务卡-exo_msgs-MA-Tom.md`（Tom）
- 验收基准：契约 `01-接口契约.md`（Tom 应已 bump 至 **v1.7**）；设计草案 `06-exo_msgs设计草案.md`（D1–D7）
- 状态：⬜ 未开始

> **里程碑边界**：本卡 = **M-A，全部 WSL 侧、零硬件依赖**。固件 / 重建 libmicroros / MCU 时钟 / CRC 端到端字节序 / 真机 A1–A8 **全部属 M-B，不在本卡**（见文末）。
>
> 对 Tom 的实现做**独立交叉验证**：对照契约逐项检查、写并跑测试、用对抗性思维找漏洞。必要时用 `tools/codex-review.sh` 取 Codex/GPT 第二意见。延续 G2 的无 rclpy 逻辑单测风格（`test_roundtrip_logic.py` / `test_link_health_adversarial.py`），再辅以集成跑。

---

## 验收判据（逐条可执行）

### V1 — 构建与测试全绿（含 lint）
- 干净状态下 `colcon build`（含新包 `exo_msgs`）零报错；`source install/setup.bash` 后 `exo_msgs/ExoCmd`、`ExoStatus`、`ExoHeader`、`LinkHealth` 可被 `ros2 interface show` 列出，字段与契约 v1.7 / 草案 D1.5+D5 **逐字一致**（`uint32 seq` / `uint64 stamp_mono_ns` / `uint32 crc` / `int32 payload`；LinkHealth 的 11 个字段含 `std_msgs/Header`）。
- `colcon test` 全绿，**含 flake8 / pep257 / copyright lint 门禁**。对抗点：删 `build`/`install`/`log` 重建重测，确认可复现、无残留依赖。
- **判定**：build + test（含 lint）全绿，消息 schema 与契约逐字一致。

### V2 — loopback 用 exo_msgs 载体复现 A1–A8
> 用 loopback 节点注入 delay / drop / duplicate（参数 `inject_delay_ms` / `drop_seqs` / `drop_rate` / `duplicate` / `seed` 不变），载体已换 `ExoCmd`/`ExoStatus`。优先逻辑单测，再集成跑。

- **A1 RTT 可测**:正常 loopback 下每条 matched echo 算出并记录 `rtt_ms`;注入固定延迟 D 后 RTT≈D(合理误差)。确认用单调时钟、非 wall clock。
- **A2 超限告警**:注入延迟 > `rtt_warn_ms`(如 60 ms > 50 ms 占位)→ 必产 WARN 含 seq + 实测 rtt;延迟设回阈值内则无告警(无误报);阈值确为可配置 param。
- **A3 丢包可检**:loopback 对指定 seq 不回 echo → 经 `rtt_deadline_ms` 后判 lost、`lost_count` **精确 +1**、打告警;丢 k 条 ⇒ lost 增 k,不多不少。
- **A4 禁止静默驱逐**:制造 echo 全面迟到 / 积压(超任何容量上界)→ 无任何条目被无声删除;被移除的条目要么 matched 要么 lost;代码层确认无 `min()` 式静默驱逐路径(注:`on_send` 的 `max_inflight` cap 命中时必须走 `evict_lost`→lost 结算 + WARN,非静默)。
- **A5 重复 echo**:对同一 seq 重复回 echo → **不得** UNMATCHED / 错值告警;`duplicate_count` 精确累加;`matched_count` 不因重复重复 +1。
- **A5b 超窗重传**:对曾发出、已挤出 `settled_window` 的 seq 重发 → 判 `stale_duplicate`(非 UNMATCHED),`stale_duplicate_count` 精确 +1(独立于 duplicate),≥INFO 可观测。
- **A6 错值仍报**:回一个从未发出的值 → 必报 UNMATCHED。
- **A6b 越界 echo 仍报**:回一个落在 **`[0, 2^32)` 之外**的值 → 必报 UNMATCHED,不得被取模 alias 漏报。**注意域已从 2^31 升到 2^32**(草案 D1.1);`header.seq` 是 `uint32`,所以「越界」语义为「负数(若构造得出)/ 非法值」——重点验证入口域守卫随 `SEQ_MODULUS=2^32` 重标定后仍先于取模判 UNMATCHED。
- **A7 回绕安全(2^32 重标定)**:用单测把 seq 置于 **2^32** 边界附近、跨回绕点,验证 ① 发送计数按 2^32 取模回绕不溢出;② matched/lost/duplicate 判定在回绕点仍正确(距离比较,不被裸 `>` 误判);③ 健康计数器累加不溢出。**确认 Tom 已把测试里的 2^31 常量改成 2^32**——若仍残留 2^31 边界则判不通过。
- **A8 对账可观测**:任意时刻可读 `sent / matched / lost / duplicate / stale_duplicate / inflight`,且 **`sent == matched + lost + inflight` 恒成立**(duplicate / stale_duplicate 不入对账恒等式)。
- **判定**:A1–A8 全部成立,对账恒等任意时刻为真,**零 UNMATCHED**(无故障注入的正常回环下)。

### V3 — 诊断 topic `/exo/link_health` 真发布且字段对
- `ros2 topic echo /exo/link_health` 周期(~1 Hz)有输出;`ros2 topic info -v` 确认类型 `exo_msgs/msg/LinkHealth`。
- 字段与 tracker 快照一致:`sent` / `matched` / `lost` / `duplicate` / `stale_duplicate` / `inflight` 与 `counters()` 对齐;`reconciles` 字段**真实反映对账**(正常时 `true`;人为制造对账破坏时为 `false`——若 tracker 设计保证恒等,则验证它恒 `true` 且与手算一致)。
- `rtt_last_ms` / `rtt_p95_ms` / `rtt_max_ms` **合理**:注入已知延迟 D 后三者量级与 D 吻合;`p95 ≤ max`、`last` 在窗口内;空窗口(刚启动无 matched)给确定占位、不崩。
- 对抗点:注入丢包后看 `lost` 在 topic 上如实增长、`reconciles` 不被掩盖;`inflight` 积压时如实上升。
- **判定**:topic 真发布、字段与 tracker 一致、RTT 统计合理、`reconciles` 不掩盖丢失。

### V4 — CRC 开关两条路径
- **关(默认 `crc_enabled=False`)**:喂 `header.crc` 与内容不符的 `ExoStatus` → **不判定**(`crc_mismatch_count` 不动、无 CRC 告警),seq 正常喂 tracker。
- **开(`crc_enabled=True`)**:喂坏 crc 的 `ExoStatus` → `crc_mismatch_count` **精确 +1** + WARN 告警,但**不阻断**(`header.seq` 仍喂 tracker,该 seq 仍正常 matched / 计数);喂正确 crc → 无 mismatch、无告警。
- 对抗点:确认 CRC 覆盖范围 = `seq‖stamp_mono_ns‖payload`(crc 置 0、规范小端序);改其中任一字段都应触发 mismatch,只改 crc 字段本身不应自指干扰。
- **判定**:两条路径行为正确,坏 crc 被检出计数 + 告警且不阻断主链路。

### V5 — seq / payload 解耦
- 构造 `ExoStatus`:`header.seq` 固定为某个 in-flight 值、`payload` 取**任意值**(与 seq 不等、负值、极值)→ 验证 tracker 配对**只看 `header.seq`**,matched / duplicate / unmatched 判定与 payload 取值无关。
- 反向:`header.seq` 取从未发出的值、`payload` 取一个曾发出的值 → 必须按 `header.seq` 判 UNMATCHED(payload 不能把它「救」成 matched)。
- **判定**:配对完全由 `header.seq` 决定,payload 不参与任何健康判定。

### V6 — 契约 v1.7 落地核对
- 版本号 v1.6 → **v1.7**,有独立 v1.7 变更说明段。
- 逐条核对草案 §D7 **8 条变更清单**全部落地:§1.1/§1.2 topic 类型、§6 演进、§7.1 wire 边界升格 + RTT 权威 / 不测单程、§7.5 seq 来源 + 越界域 2^31→2^32、§7.6 模数 2^32、§7.7 诊断 topic 落地、新增应用级 CRC 条款(写明「抓打包 bug、非防链路误码」定位)、RAM 注记引用 T8。
- 对抗点:确认契约**没有**把 stamp 写成「可测单程延迟」、**没有**把 CRC 宣传成「链路可靠性层」——这两处是草案明令避免的误导。
- **判定**:8 条全部落地,无误导性表述,版本号 / 变更说明就位。

---

## 对抗性重点(给 Gill 的「找漏洞」清单)
- **域升级遗漏**:全仓 grep `2 ** 31` / `2^31` / `2147483648` / `0x80000000`,确认 tracker 与测试里**无残留 2^31 边界**(草案 D1.1 要求全部到 2^32)。残留即 A7 隐患。
- **seq 来源遗漏**:确认节点 `_on_status` 喂的是 `msg.header.seq` 而非 `msg.payload`;loopback 回填的是 `cmd.header.seq`。任何一处误用 payload 当 seq = 退化回 Int32 耦合。
- **单调时钟一致性**:喂 tracker 的单调秒与填进 `stamp_mono_ns` 的纳秒是否同源同一时刻;确认 RTT 路径无 wall clock 渗入(§7.1)。
- **RTT 窗口有界性**:窗口是否真有上界(`maxlen`),长跑不无限增长;p95 在窗口刚好填满 / 超窗淘汰时是否正确。
- **CRC 自指**:确认 crc 计算时被校验字段里的 crc 位是置 0 的,否则永远 mismatch。
- 用 `tools/codex-review.sh` 对 tracker 模数重标定 + RTT 窗口 + CRC 校验路径做一次跨厂商对抗复审。

---

## 不在本卡范围内(全部属 M-B,等板子)
- 固件收 `ExoCmd` 解包 / 回填 `ExoStatus`、重建 libmicroros、MCU 时钟源(DWT CYCCNT)盖 stamp。
- **CRC 端到端字节序一致性**:MCU 手算 CRC 与 WSL 规范小端序对齐——M-A 只验 WSL 侧 Python 规范的自洽,不验跨端。
- **真机 A1–A8 复现 + endurance soak + RAM/ROM 增量实测 + 动态分配为零确认**。
- 真单程延迟测量 / 时钟同步(Q7 定 RTT 权威)。
- payload 结构体化 / 真实控制语义。
- git tag `int32-baseline`(主 agent 打,不在验收范围,但 Gill 可提醒主 agent 迁移前先打 tag 作退路)。
