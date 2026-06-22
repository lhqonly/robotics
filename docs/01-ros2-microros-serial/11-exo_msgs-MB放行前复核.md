# 11 — exo_msgs M-B 放行前复核 checklist（开工前必读）

- 适用：派 `09-任务卡-exo_msgs-MB-Tom.md`（Tom 开发）/ `10-任务卡-exo_msgs-MB-Gill.md`（Gill 验收）时**一并带上本文**。
- 背景：6/22 的 exo_msgs 设计/契约/任务卡由「通用 agent 扮演 Elon」产出。真身复核结论——**M-A 已落地代码/契约判干净，无需重做**；但**尚未实现的 M-B 任务卡埋了若干雷，在派 Tom 实现前修掉**。本文是那轮复核的沉淀，是 M-B 开工前的硬约束 + 确认门清单。
- 状态：✅ 已落地进 09 / 10 卡（本文是「为什么 + 一页速查」）。

---

## 一、四条硬约束（必须遵守，已融进 09/10）

### 🔴 B1 — 流缓冲闸门：exo_msgs create bin 描述消息能否塞进 STREAM_HISTORY=2（必修，T5 ③ 同款失效）
- **问题**：micro-ROS 在 `bin` creation mode 下，建实体（`create_topic`/`create_publisher`/`create_datawriter` 等）要把实体的**二进制描述消息**经 reliable 输出流发给 agent，这条消息**必须整条塞进 reliable 输出流缓冲**。缓冲容量由 `RMW_UXRCE_STREAM_HISTORY` 决定（当前 `=2`，即 2×128B = 256B；取证见 `firmware/f103-microros/colcon.meta` L57）。
- **为什么是雷**：这正是 **T5 ③ 已经踩过的失效模式**（交接文档 `00` L86：`STREAM_HISTORY 1→2`——「reliable 输出流缓冲 128B 塞不下 create_topic bin 消息 → publisher 创建失败；HISTORY=2 → 256B 经 XRCE 分片，串口 MTU 仍 128 不破契约」）。**当前 256B 是按 `std_msgs/Int32` 实体描述调的**。exo_msgs 的类型名（`exo_msgs::msg::dds_::ExoStatus_`）/ topic 名 / type hash 都比 Int32 长，**create 描述消息更大，256B 是否仍够是未知数**。
- **伪装风险**：若塞不下，现象是 **publisher/subscriber 创建失败**——极易被误判成「任务 5 的 agent 兼容性问题」而排错方向。**必须先排除流缓冲这一层（client 侧），再谈 agent 兼容性。**
- **落地**：09 卡 **任务 5.0**（前置闸门，先于任务 5，与任务 1 重建强绑定）；10 卡 **V0.5**（先于 V1）。失败处置：按 T5 ③ 调大 `STREAM_HISTORY`（触发再一次 libmicroros 完整重建）+ `-v6` 复核 MTU=128 分片不破契约 + RAM 余量复测，记录回报。

### 🟠 H1 — payload 全程 bit-exact 透传
- **约束**：固件**不得对 payload 做任何变换**（不缩放 / 不饱和 / 不字节序翻转 / 不重新解释类型）。`ExoStatus.payload` 必须与 `ExoCmd.payload` 内存字节逐位相同。
- **为什么**：payload 是上行原样回环校验位。任何固件侧变换都会把「回环校验」自身变成伪故障源（WSL 侧会看到回发值≠下发值，误判成链路/序列化 bug）。
- **附带**：ExoStatus 的 CRC（启用时）用**回填后的 (seq, MCU-stamp, payload) 三元组**重算——不是 cmd 的三元组（seq 原样、payload 原样，但 stamp 被 MCU 重盖，所以三元组数值变了，CRC 必须按回填后的算）。
- **落地**：09 卡「接口契约」段 + 任务 2 回调 + 任务 4 CRC 覆盖范围；10 卡 V2 新增 **A9**、V4 对抗点、对抗清单。

### 🟠 H2 — creation mode 改 xml 是「下策」，被迫考虑必须拍板（不得自决）
- **背景**：当前 `RMW_UXRCE_CREATION_MODE=bin`（colcon.meta L60），这是 **T5 刻意选择并签字 GO** 的（交接文档 `00` L86 ②：「bin = vanilla agent 开箱即用，免 XML profile」）。
- **任务 5 两条出路的优先级**：
  - **首选 (a)**：把 exo_msgs **喂给 agent 侧**（重建 agent 工作区）。**不动 creation mode，固件侧 colcon.meta / libmicroros / 建链路径 / RAM 全不变**，风险最小——优先走这条。
  - **下策 (b)**：把 creation mode 改成 `xml`。**这会回退 T5 已验证的 bin 决策**，不是轻量改动：① 改 colcon.meta → 触发再一次 libmicroros 完整重建；② 需**重跑 T5 级建链验证**（4 根因里 best_effort 流踩穿 / STREAM_HISTORY / 键名静默忽略等都要在 xml 下重新对账）；③ xml 实体描述更大，B1 流缓冲闸门要在 xml 下重测；④ xml 占用更多 RAM/带宽，要复测 RAM + 动态分配仍为零。
- **🛑 确认门**：**若 (a) 走不通、被迫考虑 (b)，Tom 必须把情况回报主 agent → 转用户/Elon 拍板，不得自行切到 xml。** 理由：(b) 推翻一项已签字的架构决策，影响面（建链 / RAM / 已验证的 4 根因）超出本卡授权。
- **落地**：09 卡任务 5 出路排序 + 确认门；10 卡 V1（Gill 复验：若发现 Tom 自决切 xml 未经拍板 → 直接判不通过回报）。

### 🟠 H3 — DWT CYCCNT 64 位回绕扩展必须由独立高频源维护（禁「stamp 调用点比较」）
- **物理事实**：CYCCNT 是 32 位 @72MHz，约 **59.65s 回绕**（2^32 / 72e6）。`stamp_mono_ns` 是 uint64，必须做 64 位回绕扩展。
- **错误做法（禁）**：在 `dwt_now_ns()` 里靠「本次 CYCCNT 比上次小就 +2^32」判回绕。`dwt_now_ns()` 只在收 cmd 时（回调里）被调用——**若链路断流/重连导致两次 stamp 调用间隔 > 59.65s（一次完整回绕），「本次 > 上次」可能假成立 → 漏掉一个回绕 → 64 位累加少加 2^32 → stamp 倒退**。这是控制环延迟安全关键场景里最该暴露却被掩盖的失效（链路刚恢复时 stamp 反而倒退，污染时序判断）。
- **正确做法**：由**独立高频源**（SysTick 中断 / FreeRTOS tick 钩子，周期 `<< 59.65s`，如 1ms）维护 64 位 cycle 累加：每 tick 读 CYCCNT、检测回绕（本次 < 上次 ⇒ +2^32）、累加进 64 位 cycle 计数。tick 周期远小于回绕周期 → 两次采样间最多回绕一次、绝不漏检。`dwt_now_ns()` **只读累加值**（64 位高位 + 当前 CYCCNT 低位，原子读防撕裂），折纳秒 `ns = cycles64 * 1e9 / 72e6`。
- **对抗验收**：10 卡 V5 新增——**两次 stamp 间人为制造 >60s 静默（停发 cmd），恢复后 stamp 仍单调不倒退**。这个 bug 在持续发包长跑里抓不到（调用够频不漏检），只有断流 >60s 再恢复才暴露。
- **落地**：09 卡任务 3（独立高频源 + 原子读取 + 实现说明交 Gill）；10 卡 V5（基础长跑单调 + >60s 静默对抗）+ V7（静默期不误重连)+ 对抗清单。

---

## 二、两处确认门（必须回报用户/Elon 拍板，Tom 不得自决）

1. **creation mode 回退（H2 / 09 任务 5 出路 (b)）**：若 agent 兼容性首选方案 (a 喂 agent 侧) 走不通、被迫考虑改 `RMW_UXRCE_CREATION_MODE=xml` → **回报 → 拍板后才动**。理由：推翻 T5 已签字的 bin 决策 + 触发 T5 级重验。

2. **DWT 实现策略（H3 / 09 任务 3）**：Tom 在动手前应把回绕扩展的实现策略写清回报——①用哪个高频源（SysTick / FreeRTOS tick，周期多少）；②如何保证 64 位高位 + 32 位低位的原子一致读取。**这关系到链路断流场景下 stamp 是否如实单调**（安全关键，不可掩盖），实现策略需经确认再编码，避免 Gill 验收阶段才发现用了被禁的「调用点比较」式做法返工。

---

## 三、两条澄清（非阻断，已融进 09，避免 Tom 误解）

- **M3 — 行号是快照**：09 任务 2 列的 `microros_app.c` 行号是 2026-06-22 快照。**Tom 以当前源码实际内容为准，按符号名定位**（`g_msg_cmd` / `g_msg_status` / `cmd_heartbeat_callback` / `ROSIDL_GET_MSG_TYPE_SUPPORT` / `g_pub_status` / `microros_app_task`），不盲信行号。

- **M4 — LinkHealth 裁剪是 ROM 权衡，不是「依赖拖累」**：固件侧不发布 LinkHealth；已确认 `std_msgs` 在 mcu_ws 可解析、**整包喂入不会构建失败，所以整包喂入是安全的**。是否裁掉 LinkHealth（只喂 ExoHeader/ExoCmd/ExoStatus）纯粹是**省 ROM 的权衡**——按任务 6 量化出的 Flash 余量决定:充裕则整包喂入(简单、契约一致)，吃紧则裁掉并记录。**先整包喂入跑通，量化后再决定。**

---

## 四、一页速查（派卡时核对）
| 项 | 等级 | 09 卡落点 | 10 卡落点 | 确认门 |
|---|---|---|---|---|
| B1 流缓冲闸门(STREAM_HISTORY) | 🔴 必修 | 任务 5.0(先于 5) | V0.5(先于 V1) | — |
| H1 payload bit-exact 透传 | 🟠 | 接口契约段 + 任务 2/4 | V2-A9 / V4 对抗 | — |
| H2 creation mode 改 xml 是下策 | 🟠 | 任务 5 出路排序 | V1 复验拍板 | ✅ Tom 不得自决 |
| H3 DWT 回绕用独立高频源 | 🟠 | 任务 3 | V5(+>60s 静默对抗) | ✅ 实现策略先回报 |
| M3 行号是快照按符号定位 | 🟡 | 任务 2 注 | — | — |
| M4 LinkHealth 裁剪=ROM 权衡 | 🟡 | 任务 1 / 6 | V6 Flash | — |

> **派卡原则**：09/10 自包含，Tom/Gill 拿卡即可开工/验收；本文是「为什么这么改 + 速查」，随卡带上。任何触发确认门的情况（H2 切 xml / H3 实现策略），先回报主 agent 转用户/Elon，不自决。
