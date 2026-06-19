# 任务卡：Gill（测试 / 独立验证）

> 对 Tom 的实现做**独立交叉验证**：对照接口契约逐项检查、写并跑测试、用对抗性思维找漏洞。
> 必要时调用 `tools/codex-review.sh` 用 Codex/GPT 做对抗性第二意见。
> 验收基准：`01-接口契约.md`。Phase A 的验收**全部不依赖硬件**。

---

## G1 — 验收环境与工具链（对应 T1）｜ Phase A ｜ ⬜
- 独立运行 `tools/env-check.sh`，核对 ROS2 Jazzy / arm-none-eabi-gcc / cmake / codex / 烧录工具版本均真实可用。
- 对抗点：在干净 shell（不 source bashrc）下确认 source 流程文档化、可复现。
- **判定**：所有组件命令可用且版本满足要求。

## G2 — 验收 ROS2 节点回环（对应 T2）｜ Phase A ｜ ✅ 有条件通过（2026-06-18）
> **判定：PASS with conditions，无 P0。** Gill 静态审查 + 主 agent 代跑运行级证据 + Codex(GPT)跨厂商对抗审查，三方一致。
> 代跑证据（主 agent）：① gill 的 `test_roundtrip_logic.py` 6/6 PASS；② 频率实测 10.001–10.006 Hz；③ 只起 exo_cmd（无 loopback）时 `/exo/mcu_status` 零输出（证明无自发数据）；④ Codex 独立复现下列三问题，QoS/契约合规无异议。
> **遗留项（均 P1，不阻塞 Phase A 最小闭环）**：
> - **P1-1（Medium/Codex）** `exo_cmd_node.py:57-58` `_inflight` 用 `min()` 驱逐，回环延迟超 1000 tick(100s) 会把迟到的正确 echo 误报 UNMATCHED。Phase A 不触发；Phase B 串口积压/重连可能逼近。
> - **P1-2（Low）** 重复 echo（RELIABLE 重传）落入 else 误报 UNMATCHED。Phase B 真机可能制造噪声告警。
> - **P1-3（High/Codex，6.8年后/远期）** Int32 计数器 2^31 溢出 + 回绕点 `value>last_status` 误判。引入 exo_msgs（契约第6节）时必须定义回绕语义。
> **放行条件**：P1-1/P1-2 在代码或文档层给出明确处置；P1-3 在 exo_msgs 阶段解决。
> 命名结论：loopback 用 `exo_loopback`(非 exo_mcu) Gill 从测试视角**支持维持现状**（避免 Phase B 同名冲突），要求 Phase B 联调禁用 loopback_test.launch.py（已由 exo_cmd.launch.py 提供独立入口）。
> 新增测试：`ros2_ws/src/exo_cmd/test/test_roundtrip_logic.py`（无 rclpy 依赖的逻辑单测）。
- 不依赖 MCU：起 `exo_cmd` + loopback 节点，用 `ros2 topic echo`/`ros2 topic hz` 独立验证：
  - `/exo/cmd_heartbeat` 频率 ≈10 Hz、值单调递增；
  - `/exo/mcu_status` 值与 cmd 一致（回环判据成立）。
- 核对节点/topic 的 **QoS** 与契约一致（`ros2 topic info -v`）。
- 对抗点：拔掉 loopback 节点后 mcu_status 应无输出，确认不是节点内自发数据。
- **判定**：回环判据成立且 QoS 匹配。

## G3 — 验收 Agent 起法（对应 T3）｜ Phase A ｜ ⬜
- 独立运行 `tools/run-agent.sh`，确认 agent 二进制启动、串口参数(921600/dev)正确传入、无设备时优雅等待。
- 对抗点：故意传错 `DEV` 路径，确认报错清晰而非静默失败。
- **判定**：agent 可启动且参数化正确。

## G4 — 验收固件编译（对应 T4）｜ Phase A ｜ ⬜
- 独立跑 `tools/build-firmware.sh`，确认从干净状态可编译出 `.elf`/`.bin`。
- 检查 map/链接产物确实含 FreeRTOS 与 micro-ROS 静态库。
- 对抗点：删 build 目录重编，确认无残留依赖、可复现。
- **判定**：干净编译成功并产出固件。

## G5 — 审查固件 micro-ROS 应用（对应 T5）｜ Phase A ｜ ⬜
- 代码审查：topic 名 `/exo/cmd_heartbeat`、`/exo/mcu_status`，类型 `Int32`，**QoS RELIABLE/KEEP_LAST/10**，回调原样回填——逐项对照契约。
- USART2(PA2/PA3)+DMA、921600、8N1 配置正确。
- 用 `codex-review.sh` 做一次对抗性复审，重点查 DMA/中断/缓冲区竞态、QoS 不一致导致的匹配失败。
- **判定**：实现与契约逐项一致，无明显并发/配置缺陷。

## G6 — 验收脚本（对应 T6）｜ Phase A ｜ ⬜
- 审查 `build-firmware.sh`/`flash.sh`/`run-demo.sh`：参数化、错误处理、无设备时行为。
- 对抗点：在缺设备/缺产物条件下运行，确认报错可读、不误导。
- **判定**：脚本逻辑正确、健壮。

## G7 — 真机回环独立复验（对应 T7）｜ **Phase B ｜ 需硬件** ｜ ⬜
- 独立按契约第 2 节判据复验双向回环（不照搬 Tom 的执行，自己跑一遍 `ros2 topic echo`/`hz`）。
- 对抗点：长时间运行查丢序/错值/重连后是否仍正确；变更发送频率看 status 是否跟随。
- **判定**：满足回环判据，链路稳定。

---

### 备注
- Phase A（G1–G6）应在无硬件时**全部完成**，这是当前阶段的验收闭环。
- 发现问题回写给 Tom 并标注对应任务卡编号，闭环修复后再复验。
