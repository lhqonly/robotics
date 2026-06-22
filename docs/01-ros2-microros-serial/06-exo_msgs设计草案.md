# exo_msgs 设计草案（澄清 + 架构草案）

> 作者：Elon（项目经理 / 总架构师）。状态：**草案 — 待用户确认门通过后才出任务卡**。
> 阶段：契约 §6 演进 —— 用带显式时间戳 / 序列号 / CRC 的自定义消息包 `exo_msgs` 替换 `std_msgs/Int32` 最小闭环。
> 上下文锚点：契约 **v1.6**（§7.1(c) RTT、§7.6 seq 回绕、§7.7 `/exo/link_health` 诊断 topic）；T5 双向已通、T8/M4=GO（RAM 72.42% / 14832B，**动态分配为零**、余 ~5.6KB）；MTU=128B、921600、F103 仅 20KB SRAM、QoS 分侧（F103 Depth=1 / WSL Depth=10）、RELIABLE。
> **本草案不是任务卡。** 它的目的是把所有需要拍板的设计决策摆到台面上，让用户一遍过地确认或修正，然后我才出 Tom/Gill 的任务卡并 bump 契约到 v1.7。

---

## 0. 第一性原理：这一步到底买什么、不买什么

当前 `Int32` 闭环已经能做到：sent==matched+lost+inflight 对账、RTT（整链 RTT，WSL 侧本地配对）、丢包/重复/越界判定、回绕安全。真机 10 分钟 soak **零丢包**。换句话说：**功能上没有 bug 逼着我们换消息包**。

那为什么还要 exo_msgs？因为 `Int32` 把三件事**揉进了同一个 31 位整数**，并靠 WSL 侧「推断」补齐：

1. **seq**（序列号）—— 现在 seq 就是 payload 本身（心跳值），二者不可分。一旦 payload 不再是「单调计数器」而是「真实命令」（关节角、力矩、模式），就再没有一个递增整数可以当 seq 用了。
2. **t_send**（发送时刻）—— 现在不在 wire 上，靠 WSL 本地 `t_send[N]` 字典配对。这只能测 **RTT**，无法测单程，也无法让 MCU 知道「这条命令是什么时候发的、是不是已经过期」。
3. **完整性** —— 现在完全依赖 XRCE-DDS 帧层（CRC + 重传）。应用层对「这一帧是不是被悄悄改了一位」零感知。

**exo_msgs 的本质 = 把这三件事从「WSL 侧推断」升格为「wire 上的显式字段」**，为终局（实时电机控制，命令 payload 非平凡、控制环 500Hz–1kHz、安全关键）打地基。这一步**不追求新功能**，追求的是**结构正确**：让 seq / 时间戳 / payload 各占其位，互不耦合。

> 诚实的风险注记：这一步**没有硬件验证回路**（当前板子可烧，但 exo_msgs 的固件侧打包 / 解包 / 重新生成 type support 进 libmicroros 需要真机联调）。所以本草案明确把里程碑切成「今天 WSL 侧能做完的」和「必须等板子的」两段，避免在没有反馈回路时盲目推进固件改动。

---

## 1. 需要用户拍板的关键设计决策

> 每条给：**问题 / 权衡 / Elon 推荐默认**。用户可以逐条「确认」或「改成 X」。

### D1. 消息 schema —— 字段布局

#### D1.1 seq 宽度：`uint32` vs `uint64`

- **问题**：显式 seq 用多宽？
- **权衡**：
  - 当前 `Int32`（实际用 `[0,2^31)`）10Hz 下 ~6.8 年回绕；终局 1kHz 下 `uint32` 满量程 ~49.7 天回绕，`[0,2^31)` 则 ~24.8 天。
  - `uint32`：4 字节，回绕窗口对 1kHz 仍够用（49.7 天连续运行才回绕一次，且回绕安全比较已实现）；ROS/DDS 原生支持；F103 上是单个 32 位字，零成本。
  - `uint64`：8 字节，宇宙年龄都不回绕（1kHz 下 5.8 亿年），逻辑上消灭回绕这个话题；但每条消息多 4 字节、F103 上 64 位运算非原子（Cortex-M3 无 64 位 ALU，但只是赋值/比较，开销可忽略），`rcutils` 当前还配了 `RCUTILS_NO_64_ATOMIC=ON`（这是 atomic，不是普通 64 位运算，不冲突，但值得留意）。
- **Elon 推荐**：**`uint32`**。回绕安全比较（`forward_distance`）已经在 `LinkHealthTracker` 里落地且测过，模数从 `2^31` 改成 `2^32` 是改一个常量 + 重测边界，不是新工作。多花 4 字节去买「永不回绕」在 128B MTU 下不划算，且我们本来就有回绕安全机制。**保留回绕语义，宽度升到 `uint32`（满 32 位，不再砍到 31 位 —— 因为脱离了 Int32 的符号约束）。**
  - 连带：契约 §7.6 的模数从 `2^31` 改成 `2^32`，`SEQ_MODULUS` 常量随之改，A7 回绕测试重标定。

#### D1.2 时间戳表示：`builtin_interfaces/Time` vs `uint64` 纳秒 vs `int32 sec + uint32 nsec` 拆开

- **问题**：t_send（以及未来可能的 t_recv）在 wire 上怎么表示？
- **权衡**：
  - `builtin_interfaces/Time`（`int32 sec` + `uint32 nanosec`，8 字节）：ROS 生态标准，`rclpy`/工具链原生，header 风格统一；但语义是 **wall-clock epoch 时间**，而契约 §7.1 **明令 RTT 必须用单调时钟**（禁 wall clock，NTP 跳变污染）。如果直接把 `builtin_interfaces/Time` 当 t_send，要么塞单调时钟值（违反该类型的 epoch 语义、误导消费者），要么塞 wall clock（违反 §7.1）。
  - `uint64` 纳秒（单一字段，8 字节）：纯数字，语义由我们定义为「**发送方单调时钟纳秒**」，不携带 epoch 含义，正好契合 §7.1；F103 上是一个 64 位字，micro-ROS 打包简单；缺点是不是 ROS 标准 Time 类型，ROS 工具（rqt、bag 的时间轴）不会自动识别成时间。
  - `int32 sec + uint32 nsec` 拆开：本质同 `builtin_interfaces/Time`，没有额外好处，反而自己造轮子。
- **Elon 推荐**：**`uint64` 单调纳秒**，字段名 `stamp_mono_ns`，语义在契约里写死「发送方 steady/monotonic 时钟，纳秒，不可跨机器/跨重启比较绝对值，只用于同一发送方内部配对与单程估计」。
  - 理由：§7.1 的硬约束是「单调时钟」，而 `builtin_interfaces/Time` 的 epoch 语义和它冲突。与其滥用标准类型误导消费者，不如用一个语义明确的 `uint64`。
  - **不**把 t_recv 放进消息（见 D4 单程延迟决策）—— 接收时刻是消费方本地盖的，没必要上 wire。

#### D1.3 payload：暂时单个 int vs 一个小命令结构体

- **问题**：ExoCmd 的 payload 现在放什么？
- **权衡**：
  - 单个 int（延续心跳）：迁移成本最低，但等于换了个壳还是心跳，没为终局结构铺路，下次还得再改一次 schema + 再重生成一次 libmicroros（固件侧最贵的一步，见 D6）。
  - 小命令结构体（如 `uint8 mode` + `float32 setpoint` 占位，或留一个 reserved 字段）：一次把「命令 = 一个结构体」的形状立起来，未来加字段是在结构体里扩，不必再动消息根。但现在没有真实控制语义，字段是占位的，有「过度设计」之嫌。
- **Elon 推荐**：**分离关注点，分两层**：
  - **header 部分（seq + stamp_mono_ns）是本阶段的真正目标**，必须显式、必须稳定。
  - **payload 部分本阶段保持最小但留出扩展位**：ExoCmd 的 payload = 一个 `int32 payload`（语义暂仍是「心跳计数 / 回环值」，与 header.seq 解耦），**不**现在就引入 `float setpoint` 等假语义。
  - 理由：现在引入真实控制结构体属于「下一个需求（电机控制）」的范畴，会把这张卡的范围撑爆，且没有硬件能验证控制语义。本阶段只把**信封（header）做对**，payload 维持可回环验证的最小整数。等控制需求来了，payload 从 `int32` 升级成命令结构体时，**header 不动**（这正是分层的价值）。
  - **风险诚实**：这意味着「payload 结构体化」会是未来的第二次 .msg 改动，可能触发第二次 libmicroros 重生成。我接受这个代价，换取本阶段不背真实控制语义的债。如果用户更想「一次到位」，可以选 D1.3-Alt（见问题清单 Q3）。

#### D1.4 CRC：放进 ROS 消息里 vs 依赖串口/XRCE 层自带帧校验 ★关键

- **问题**：要不要在 ExoCmd/ExoStatus 里加一个应用级 `uint16 crc` / `uint32 crc` 字段？
- **第一性原理拆解 —— XRCE-DDS over serial 之上再加应用级 CRC 到底买到什么？**
  - micro-ROS 串口栈已有**两层**保护：
    1. **XRCE 串口帧层（stream framing）**：`UCLIENT_PROFILE_STREAM_FRAMING=ON`（见 colcon.meta），每个串口帧带 **CRC-16**，坏帧直接丢。
    2. **XRCE reliable stream**：`RELIABLE` QoS + reliable stream（`UCLIENT_MAX_*_RELIABLE_STREAMS=1`），丢帧重传、保证有序交付。
  - 所以「线路上一个 bit 翻转」这个场景，**已经被帧层 CRC-16 + 重传覆盖**：坏帧被 CRC-16 拦下丢弃，reliable 层重传，应用层根本看不到坏数据。应用级 CRC 在**串口链路误码**这个威胁上是**冗余**的。
  - 那应用级 CRC 还能多覆盖什么？只有**帧层 CRC 管不到的环节**：
    - MCU **应用代码**打包结构体时的 bug（字段错位、字节序、padding）；
    - micro-ROS **序列化/反序列化栈本身**的 bug；
    - 端到端**内存损坏**（栈溢出、DMA 写飞）—— 但 T8 实测动态分配为零、栈余量大，这个概率很低。
  - 这些是**软件正确性**问题，应用级 CRC 能把它们变成「可检测的损坏」而不是「悄悄的错值」。**但代价**：CRC 字段要 MCU 在打包后、WSL 在校验前各算一遍，且**算的范围必须覆盖 seq+stamp+payload**，否则形同虚设；CRC 算法（CRC-16-CCITT vs CRC-32）要两端写死一致。
- **Elon 推荐**：**本阶段 schema 里预留 `uint32 crc` 字段，但默认值=0 且默认「不校验」（disabled / 仅记录不判定）**，用一个 ROS param + 契约开关控制是否启用强校验。
  - 理由：诚实地说，在 XRCE 帧层 CRC-16 + reliable 重传之上，应用级 CRC 对**链路误码**的边际收益接近零（A8 真机零丢包/零 UNMATCHED 已经佐证链路本身干净）。它真正的价值在**抓打包/序列化软件 bug**，而那恰恰是 exo_msgs 引入自定义打包代码时**最可能出新 bug 的地方**。所以：
    - **留字段**（避免未来再改 schema 重生成 libmicroros）；
    - **本阶段把它当「开发期断言开关」**：bring-up / 联调时开启强校验，专门抓 D6 的固件打包 bug；稳定后可关（仅记录 crc_mismatch_count 到诊断，不阻断）。
  - **明确否定**：不把 CRC 作为「保护链路误码」的卖点——那是帧层 CRC-16 的活，重复造轮子。CRC 字段的定位是**应用层打包正确性自检**，写进契约说清楚，避免给人「我们在 DDS 上又加了一层可靠性」的错觉。
  - **备选（更精简）**：如果用户认为「联调期可以靠对账等式 + 越界 UNMATCHED 判据间接抓打包 bug，不需要 CRC 字段」，可以**直接不放 CRC 字段**（见问题清单 Q4）。我倾向留字段（4 字节，128B MTU 下完全放得下，且省一次未来重生成），但这是可争论的。

#### D1.5 schema 草案（待 D1.1–D1.4 拍板后定稿）

> 以下是**按 Elon 推荐默认**写出的草案，字段名/注释会进契约 v1.7。**未定稿**。

```
# exo_msgs/msg/ExoHeader.msg  —— 信封，ExoCmd 与 ExoStatus 共用
uint32 seq            # §7.6 序列号，mod 2^32 回绕；回环用精确相等配对
uint64 stamp_mono_ns  # 发送方单调时钟纳秒（§7.1：禁 wall clock）。仅同发送方内可比
uint32 crc            # 应用级 CRC（默认 0 / 默认不强校验，开发期可开，抓打包 bug）

# exo_msgs/msg/ExoCmd.msg  —— WSL → MCU
ExoHeader header
int32 payload         # 本阶段=心跳/回环值（与 header.seq 解耦）；未来升级为命令结构体时 header 不动

# exo_msgs/msg/ExoStatus.msg —— MCU → WSL
ExoHeader header      # MCU 回填：seq=原样回填收到的 cmd.header.seq；stamp/crc 为 MCU 侧重新生成
int32 payload         # 本阶段=原样回填 cmd.payload（回环校验，同 §1.2 语义）
```

- **CRC 覆盖范围（若启用）**：契约写死 = CRC 字段置 0 后，对 `seq‖stamp_mono_ns‖payload` 的字节序列计算（避免 CRC 自指）。算法待定，默认建议 **CRC-32（与字段宽度一致，查表实现 F103 上 1KB ROM）**。
- **字节序 / 对齐**：micro-ROS 用 CDR 序列化，字节序由 XRCE 协商，**应用代码不要手动拼字节**；CRC 计算必须基于「两端都能复现的规范字节序」—— 这是 D6 的一个明确风险点（见下）。

---

### D2. 迁移策略：硬切 vs 并行过渡

- **问题**：从 `Int32` 闭环切到 exo_msgs，是**硬切**（删 Int32，topic 类型直接换）还是**过渡期并行**（Int32 与 exo_msgs 两套同时跑一段）？
- **现状约束**：
  - WSL 侧有 **56 个测试**（`test_roundtrip_logic.py` + `test_link_health_adversarial.py` + flake8/pep257/copyright），其中 `LinkHealthTracker` 把 **Int32 的 data 值本身当 seq**（`on_send` 返回 seq、`on_echo(msg.data)`）。
  - 但关键洞察：**`LinkHealthTracker` 本身已经是 rclpy-free、且只认「seq 整数 + 单调时刻」两个输入**，它根本不关心 seq 是来自 `Int32.data` 还是 `ExoStatus.header.seq`。所以 tracker 的核心逻辑**不需要改**，改的只是**节点适配层**（`exo_cmd_node._on_status` 从 `msg.data` 取值改成 `msg.header.seq` 取值）。
  - 56 个测试里**绝大多数是 tracker 逻辑测试**（喂整数 seq + 时刻），它们**与消息类型无关，应当原样保留、继续全绿**。只有「节点层 / 集成层」涉及真实 `Int32` 消息的部分需要适配。
- **权衡**：
  - 硬切：干净，没有两套代码长期并存的维护负担；但「WSL 侧 build/test 已就绪」与「固件侧没硬件验证」之间会出现一个**断层期**——WSL 切到 exo_msgs 后，旧 Int32 固件就连不上了（topic 类型不匹配），而新 exo_msgs 固件还没联调。在这个断层期，**Phase A 的 loopback 回归仍可在 WSL 内自洽**（loopback 也切 exo_msgs），所以硬切**不会让 WSL 侧失去验证能力**。
  - 并行：可以「Int32 链路保持真机可用 + exo_msgs 链路在 WSL loopback 内开发」两条腿走路，降低「一旦切了就退不回去」的风险；代价是节点/loopback 要支持两种消息（参数选择或两套节点），维护成本翻倍，且容易出「测了 Int32 没测 exo_msgs」的盲区。
- **Elon 推荐**：**WSL 侧硬切 + 用「分支/标签」保留 Int32 退路，不在主干长期并行**。具体：
  1. **tracker 逻辑零改动**（除 D1.1 的模数 2^31→2^32 + 重标定回绕测试），56 个 tracker 逻辑测试基本原样保留、继续全绿 —— 这是迁移**低风险**的最强证据。
  2. **节点层（exo_cmd_node / loopback_node）硬切到 exo_msgs**：topic 类型从 `Int32` 换成 `ExoCmd`/`ExoStatus`，适配层从 `msg.data` 改读 `msg.header.seq`，新增 stamp/crc 的填充与（可选）校验。
  3. **Int32 退路用 git tag/分支保留**（如 `int32-baseline` 标签），真机若需回退到已验证的 Int32 链路，可 checkout 该标签，而不是在主干背两套消息。
  4. **固件侧暂不切**（没硬件验证回路，见里程碑 M-B），所以**当前真机仍跑 Int32**，WSL exo_msgs 在 loopback 内开发验证，互不阻塞。
- **对 56 测试 + LinkHealthTracker 的具体影响（给 Gill 预览）**：
  - 不变：全部 tracker 逻辑/对抗测试（喂整数 seq，与消息类型无关）；只需把测试里的 `2^31` 边界常量改成 `2^32`（A7 回绕）。
  - 改：任何构造真实 `Int32()` 消息喂给节点的集成测试，改成构造 `ExoStatus()`；loopback 故障注入（delay/drop/duplicate）逻辑不变，只是 echo 的载体从 `Int32` 变 `ExoStatus`（回填 header.seq + 新 stamp + crc）。
  - 新增：seq 来源从 payload 改为 header.seq 后，要新测「payload 与 seq 解耦」（payload 任意值不影响 seq 配对）；若启用 CRC，新增 CRC 校验路径测试（坏 CRC → 计数 / 告警）。

---

### D3.（并入 D2）—— 见上。

---

### D4. 单程延迟：测单程 vs 仍只测 RTT

- **问题**：既然能在消息里盖 `stamp_mono_ns`，我们要测**单程延迟**（WSL→MCU 或 MCU→WSL），还是**仍只测 RTT**、时间戳仅作记录？
- **第一性原理 —— 单程延迟需要什么？**
  - 单程 = `t_recv(接收方时钟) − t_send(发送方时钟)`。这要求**两个时钟在同一基准上可比**。MCU（F103，无 RTC 校时、无 NTP）与 WSL 的单调时钟**各自从各自上电/启动起算，绝对值不可比**。
  - 要测真单程，必须做**时钟同步**：要么 NTP/PTP 式偏移估计（MCU 没有这能力，且 XRCE 串口链路抖动大，估不准），要么用「RTT/2 假设对称」反推偏移（但电机控制链路恰恰**不对称**——命令下行和状态上行的处理路径不同，这个假设在安全关键场景站不住）。
  - 结论：**真单程延迟在 F103↔WSL 上是「难且不可靠」的**，强行做会引入一个估不准的时钟偏移，反而污染数据，违背 §7 的「如实暴露、绝不掩盖」哲学。
- **Elon 推荐**：**仍以 RTT 为权威延迟指标**（沿用已验证的 WSL 本地配对 `t_send[N]`/`t_recv`，§7.1 整链 RTT）。`stamp_mono_ns` 的定位是：
  1. **wire 上携带发送方时刻**，让 RTT 的「t_send」从 WSL 字典里的本地配对，**升级为消息自带**（消除「WSL 重启/丢字典则 t_send 丢失」的脆弱性，且 echo 回填后 WSL 能直接算 RTT 而不必维护 in-flight 时刻字典——但注意 in-flight 字典因丢包检测仍需保留）；
  2. **记录与诊断**：把 t_send 落进 bag / 诊断，供离线分析、供未来真有时钟同步手段时回溯；
  3. **MCU 侧命令时效判断的地基**：未来 MCU 可以用「我本地时钟 − 命令里的 stamp」**估计命令在途时长**（即便绝对值不可比，**同一发送方连续命令的相对间隔**是可比的，可用于检测「命令流是否卡顿/抖动」）。
  - 一句话：**stamp 上 wire，但单程延迟不作为权威安全指标**，权威仍是 RTT；stamp 是「记录 + 未来地基」，不是「现在就测单程」。契约 §7.1 据此更新（见 D7）。
  - **风险诚实**：有人会问「那盖 stamp 是不是白盖」。不白盖——它让 t_send 从「WSL 进程内的易失状态」变成「wire 上的事实」，并为 MCU 侧时效判断铺路；只是我们**不**假装能用它算出可信的单程延迟。

---

### D5. 诊断 topic `/exo/link_health`（§7.7）：本次纳入 vs 单列后续任务卡

- **问题**：§7.7 规划的 `/exo/link_health` 诊断 topic，本次 exo_msgs 就实现，还是单列一张后续任务卡？
- **现状**：`LinkHealthTracker.counters()` 已经把 §7.7 要的字段**全部算好了**（sent/matched/lost/duplicate/stale_duplicate/inflight），`exo_cmd_node._on_summary` 已经周期性把它们打成日志。差的只是「把这个 dict 发布成一个 ROS 消息」这一层。
- **权衡**：
  - 本次纳入：§7.7 本就规划在「exo_msgs 阶段」落地，而且这是一个**纯 WSL 侧、无硬件依赖、低风险**的工作（再定义一个 `LinkHealth.msg` + 一个 publisher）。它正好凑成 exo_msgs 包的「第三个消息」，逻辑内聚。**不纳入反而割裂**（§7.7 明说是 exo_msgs 阶段的事）。
  - 单列：如果想让 exo_msgs 第一张卡聚焦「ExoCmd/ExoStatus 信封 + 迁移」，把诊断 topic 留作纯增量的第二张卡，范围更小、更快见绿。
- **Elon 推荐**：**本次纳入 exo_msgs 包，但作为里程碑 M-A 内的独立子任务**（schema + publisher 在 WSL 侧，今天就能做完）。它无硬件依赖、字段已就绪、与 §7.7 规划一致，没有理由拆出去。
- **`LinkHealth.msg` 字段草案**（依 §7.7 + tracker 现有计数器）：

```
# exo_msgs/msg/LinkHealth.msg  —— /exo/link_health，~1 Hz
std_msgs/Header header   # 这里用标准 Header（wall-clock stamp）是合适的：诊断/bag 时间轴
uint64 sent
uint64 matched
uint64 lost
uint64 duplicate
uint64 stale_duplicate   # v1.6 新增计数器，纳入
uint32 inflight
float64 rtt_last_ms
float64 rtt_p95_ms       # 需 tracker 增维护一个 RTT 滚动窗口（当前 tracker 不存 RTT 分布！见风险）
float64 rtt_max_ms
bool reconciles          # sent==matched+lost+inflight，一眼看链路是否在悄悄掉东西
```

- **风险/范围诚实**：§7.7 要 `rtt_p95_ms` / `rtt_max_ms` / `rtt_last_ms`，但当前 `LinkHealthTracker` **只在 matched 事件里算单条 rtt_ms，不保存 RTT 分布**（没有滚动窗口、没有 p95）。要发布 p95 就得给 tracker **加一个有界 RTT 滚动统计**（环形 buffer + 分位数）。这是一个**真实的新增工作量**，不是「把现有 dict 发出去」那么轻。我建议：**M-A 先发布已有的计数器 + rtt_last（matched 时更新），p95/max 作为 M-A 内一个明确子项**（给 tracker 加滚动窗口），或如果想压缩范围，p95/max 单列（见问题清单 Q5）。诊断 topic 用标准 `std_msgs/Header`（wall clock）是对的——它是给人/bag 看的时间轴，不参与 §7.1 的 RTT 计算（那条线仍严格单调时钟）。

---

### D6. 固件影响（F103 micro-ROS）★关键成本所在

- **问题**：自定义 `.msg` 对固件意味着什么？
- **第一性原理 —— 自定义消息在 micro-ROS 上的真实成本链**：
  1. **重新生成 type support 进 libmicroros**：micro-ROS 的消息类型是**编译进静态库 libmicroros 的**，不是运行时动态加载。新增 `exo_msgs` 必须把这个包**喂给 micro-ROS 的 firmware 构建流程**（把 `exo_msgs` 放进 `firmware/.../extra_packages` 或 micro_ros_setup 的自定义消息目录），然后**重建 libmicroros**。这正是 T5 踩过的同类操作（改 colcon.meta → 重建 libmicroros），是一次**完整重建**，不是增量编译。
  2. **占 RAM/ROM**：每个消息类型的 type support + (de)serialization 代码进 ROM；消息实例进静态内存池。T8 实测 RAM 72.42%、余 ~5.6KB、**动态分配为零**——新消息字段（seq4 + stamp8 + crc4 + payload4 = 20B 一条，pub/sub 各一个静态实例）相比当前 `Int32`（4B）每个实例多 ~16B，**对 5.6KB 余量是九牛一毛**；type support 代码进 ROM（Flash 当前 59%、128KB，余量大）。**T8 已证明 20KB 裕度极大，exo_msgs 这点增量不构成 RAM 风险**——这是个好消息，要写进契约。
  3. **MCU 上手写打包/解包结构体**：固件要把收到的 `ExoCmd`（micro-ROS 反序列化后给的 C struct）读出 seq/stamp/payload，回填进 `ExoStatus`（seq 原样、stamp 用 MCU 自己的时钟、payload 原样、crc 重算）再发。这是**新的固件应用代码**，且涉及：
     - MCU 侧拿什么当 `stamp_mono_ns`？F103 用 **FreeRTOS tick / DWT cycle counter / SysTick** 折算纳秒（DWT CYCCNT @72MHz 精度最好），要新写一段时钟读取代码。
     - **CRC 计算两端字节序必须一致**（若启用 D1.4）——这是最易出 bug 的点，MCU 手算 CRC 的字节序必须和 WSL Python 端复现的规范字节序对齐，否则永远 mismatch。
  4. **没有硬件就没有这一步的验证回路**：当前板子能烧，但「重建 libmicroros + 固件打包代码 + 真机联调」是一条**必须有板子在手反复烧/联调**的链路。本草案据此把它整体推到里程碑 **M-B**，**不在没硬件时盲推**。
- **Elon 结论**：**固件侧（重建 libmicroros + 打包/解包 + MCU 时钟 + CRC 一致性）= 这一步的真正成本与风险集中地**，且**强依赖真机联调**。好在 **T8 已证明 RAM/ROM 裕度极大，资源不是约束**；约束是**人/硬件在环的联调时间**。因此：
  - **今天（无硬件）能做完的**：WSL 侧整包 exo_msgs（schema、节点迁移、loopback 迁移、诊断 topic、全部测试）—— 这些**不碰 libmicroros、不碰固件**，今天就能 build/test 全绿。
  - **必须等板子的**：重建 libmicroros、固件打包/解包、MCU 时钟、CRC 端到端一致性、真机 A1–A8 在 exo_msgs 上复现。

---

### D7. 契约版本 bump 计划（v1.6 → v1.7）

- **问题**：契约怎么升、§7 哪些要求从「WSL 侧推断」升格为「wire 保证」？
- **Elon 推荐 v1.7 变更清单**（待 D1–D6 拍板后落定）：
  1. **§1.1/§1.2 topic 类型**：`std_msgs/Int32` → `exo_msgs/msg/ExoCmd`（cmd_heartbeat）/ `exo_msgs/msg/ExoStatus`（mcu_status）。语义：seq 移到 `header.seq`，回环值移到 `payload`，新增 `header.stamp_mono_ns`、`header.crc`。
  2. **§6 演进**：标注 exo_msgs 阶段**已落地**，记录本阶段为 WSL 侧先行、固件侧待真机（M-B）。
  3. **§7.1 wire 边界升格**：t_send 从「WSL 侧本地配对的易失状态」**升格为 wire 上的 `header.stamp_mono_ns`**（显式时间戳）。**明确写清**：RTT 仍是权威延迟指标（WSL 本地配对，整链 RTT）；**单程延迟不作为权威指标**（缺 MCU↔WSL 时钟同步，§D4 论证）；stamp 用于记录 + MCU 侧相对时效判断地基。
  4. **§7.5 seq 来源升格**：从「payload 整数兼作 seq」**升格为 `header.seq` 显式字段**，与 payload 解耦。重复/stale/UNMATCHED/越界判据语义不变（仍由 tracker 落实），但「越界」域从 `[0,2^31)` 改为 `[0,2^32)`（uint32 满量程）。
  5. **§7.6 回绕语义重标定**：模数 `2^31` → `2^32`；`forward_distance` / `SEQ_MODULUS` 随之更新；A7 回绕测试边界重标定。
  6. **§7.7 诊断 topic 落地**：`/exo/link_health` 从「规划」变「已实现」，字段定稿（见 D5），新增 `stale_duplicate`、`reconciles`、p95/max（含 tracker 滚动窗口的新增说明）。
  7. **新增「应用级 CRC」条款**：定义 `header.crc` 的算法、覆盖范围、默认 disabled / 开发期可开的语义，并**明确写「这不是为防链路误码（帧层 CRC-16 + reliable 已覆盖），而是抓应用打包/序列化 bug 的自检开关」**——避免误导。
  8. **RAM 注记**：引用 T8 结论，明确 exo_msgs 的内存增量在 20KB 上裕度仍极大、动态分配仍为零（前提：维持静态池配置），消除「自定义消息会撑爆 20KB」的潜在担忧。

---

## 2. 草案级模块/接口拆分 + 里程碑划分

### 2.1 模块/接口拆分（草案，待确认后进任务卡）

```
exo_msgs/                         ← 新 ROS 包（纯接口定义，ament_cmake，无逻辑）
  msg/ExoHeader.msg               seq:uint32  stamp_mono_ns:uint64  crc:uint32
  msg/ExoCmd.msg                  header:ExoHeader  payload:int32
  msg/ExoStatus.msg               header:ExoHeader  payload:int32
  msg/LinkHealth.msg              §7.7 诊断字段（见 D5）

exo_cmd/  (改造现有包，不是新包)
  link_health.py                  ← 逻辑核心：仅改 SEQ_MODULUS 2^31→2^32 + 加 RTT 滚动窗口(p95/max)。
                                     【关键：tracker 不认消息类型，迁移对它近乎透明】
  exo_cmd_node.py                 ← 适配层：pub ExoCmd（填 header.seq/stamp/crc+payload）、
                                     sub ExoStatus（读 header.seq 喂 tracker、可选 CRC 校验）、
                                     新增 link_health publisher
  loopback_node.py                ← MCU 模拟器迁移：sub ExoCmd → echo ExoStatus
                                     （回填 seq、盖本地 stamp、重算 crc、payload 原样）；
                                     故障注入逻辑不变
  qos.py                          ← 不变（QoS 与消息类型无关，分侧 Depth 不变）
  test/                           ← tracker 逻辑测试基本不变（改回绕边界常量）；
                                     集成测试 Int32→ExoStatus；新增 payload/seq 解耦、CRC、p95 测试

firmware/f103-microros/  (M-B，等板子)
  extra_packages / colcon.meta    ← 把 exo_msgs 喂进 micro-ROS firmware 构建 → 重建 libmicroros
  app 代码                         ← 收 ExoCmd 解包、回填 ExoStatus（seq 原样 / MCU 时钟 stamp /
                                     payload 原样 / crc 重算）；MCU 时钟源（DWT CYCCNT @72MHz）
```

**接口契约不变的边界**（让迁移可控）：
- topic 名（`/exo/cmd_heartbeat`、`/exo/mcu_status`）、节点名、命名空间、QoS（RELIABLE/分侧 Depth）、波特率 921600、MTU 128、8N1/DMA —— **全部不变**。只换消息**载荷**。
- `LinkHealthTracker` 的对外语义（对账等式、判据、计数器）—— **不变**。

### 2.2 里程碑划分：今天能做 vs 必须等板子

| 里程碑 | 内容 | 硬件依赖 | 风险 | 验证手段 |
|---|---|---|---|---|
| **M-A（今天就能全做完，WSL 侧）** | ① 建 `exo_msgs` 包（4 个 .msg）；② tracker 模数 2^31→2^32 + RTT 滚动窗口；③ exo_cmd_node / loopback_node 迁移到 ExoCmd/ExoStatus；④ 诊断 topic publisher；⑤ 全部测试迁移 + 新增（payload/seq 解耦、CRC、p95、回绕重标定）；⑥ 契约 bump v1.7 | **无** | 低（tracker 逻辑零改动是最强证据；纯 WSL 内 loopback 自洽） | `colcon build` + `colcon test` 全绿；loopback 跑 A1–A8（exo_msgs 载体）；零 UNMATCHED / 对账恒等 |
| **M-B（必须等板子）** | ① 把 exo_msgs 喂进 micro-ROS firmware 构建、**重建 libmicroros**；② 固件收 ExoCmd 解包 / 回填 ExoStatus；③ MCU 时钟源（DWT CYCCNT）盖 stamp；④ CRC 端到端字节序一致（若启用）；⑤ 真机 A1–A8 在 exo_msgs 上复现 + endurance soak；⑥ 量 RAM/ROM 增量、确认动态分配仍为零 | **是（反复烧 / 联调）** | 中（重建 libmicroros 是 T5 同类操作有经验；真风险=CRC 字节序一致 + MCU 时钟折算 + 联调时间） | `tools/run-agent.sh` + 真机对账（沿用 `bidi_recon.sh` 思路，载体换 exo_msgs）；gdb 读 RAM 水位 |

**关键调度结论**：M-A 与 M-B **解耦**。M-A 今天就能让 exo_msgs 在 WSL 侧 build/test 全绿、在 loopback 内复现 A1–A8，**完全不依赖硬件**；真机仍可继续跑已验证的 Int32 链路（git tag 退路）。M-B 在有板子的时段做。这正好契合「当前没有硬件、WSL 侧今天就能 build/test、板子集成推后」的现实。

---

## 3. 风险登记（诚实）

| 风险 | 等级 | 说明 / 缓解 |
|---|---|---|
| CRC 两端字节序不一致 | 中 | MCU 手算 CRC 的字节序必须与 WSL 端规范字节序对齐，否则永远 mismatch。缓解：契约写死「CRC 字段置 0、对 CDR 之外的规范小端序字节流计算」，M-B 联调首要验证项；且默认 disabled，不阻断主链路。 |
| MCU 时钟源选型/折算 | 低-中 | F103 无 RTC 校时；用 DWT CYCCNT @72MHz 折纳秒精度最好但需正确配置 DWT。绝对值不可比已在 §D4 接受，只需稳定单调。 |
| 重建 libmicroros 引入回归 | 低-中 | T5 已做过同类（改 colcon.meta 重建），有经验；但每次重建是完整流程、耗时。缓解：M-B 独立里程碑、保留 Int32 tag 退路。 |
| tracker 加 RTT 滚动窗口（p95）增内存/复杂度 | 低 | WSL 侧、有界环形 buffer，影响可忽略；但确属新代码需测。可选择 p95/max 单列压缩 M-A 范围（Q5）。 |
| 「payload 现在还是 int，未来要再改成命令结构体」= 第二次 .msg 改动 → 可能第二次重建 libmicroros | 中 | 这是 D1.3 分层选择的代价。若用户选「一次到位」放命令结构体占位（Q3），可避免，但背假语义债。Elon 推荐接受这次代价，换本阶段干净。 |
| 应用级 CRC 边际收益被高估 | 低（认知风险） | 已在 D1.4 说清：链路误码由帧层 CRC-16 + reliable 覆盖，应用 CRC 只抓打包/序列化 bug。契约必须写明定位，避免「以为加了一层可靠性」的错觉。 |

---

## 4. 需要用户回答的问题清单（请逐条确认或修正）

> 默认值都是 Elon 的推荐。回「全部按推荐」即可一遍过；要改的逐条点名。

- **Q1（D1.1 seq 宽度）**：seq 用 `uint32`（满 32 位，回绕语义保留，模数 2^31→2^32）。同意？还是要 `uint64`（永不回绕、每条多 4B）？ —— *推荐：uint32*
- **Q2（D1.2 时间戳）**：t_send 用 `uint64 stamp_mono_ns`（单调纳秒，语义明确、契合 §7.1 禁 wall clock），**不**用 `builtin_interfaces/Time`（其 epoch 语义与单调时钟冲突）。同意？ —— *推荐：uint64 单调纳秒*
- **Q3（D1.3 payload）**：本阶段 payload 维持最小 `int32`（与 seq 解耦），**不**现在引入真实命令结构体（留给电机控制需求）。接受「未来 payload 结构体化是第二次 .msg 改动」的代价？还是要现在就放命令结构体占位「一次到位」？ —— *推荐：本阶段最小 int32*
- **Q4（D1.4 CRC）★**：schema 预留 `uint32 crc`，**默认 disabled / 开发期可开**，定位是「抓应用打包/序列化 bug 的自检开关」，**不**宣称防链路误码（那是帧层 CRC-16 + reliable 的活）。同意留字段+默认关？还是干脆**不放 CRC 字段**（靠对账等式+越界判据间接抓打包 bug）? —— *推荐：留字段、默认关、开发期可开*
- **Q5（D5 诊断 topic 范围）**：`/exo/link_health` 本次纳入 M-A。`rtt_p95_ms/max` 需要给 tracker 新加 RTT 滚动窗口——是放进 M-A 一起做，还是先发已有计数器+rtt_last、把 p95/max 单列一张小卡？ —— *推荐：纳入 M-A，但允许 p95/max 作为可拆子项*
- **Q6（D2 迁移策略）**：WSL 侧**硬切** exo_msgs（tracker 逻辑零改动，56 测试基本保留）、用 git tag 保留 Int32 退路、固件暂不切（仍跑 Int32 直到 M-B）。同意硬切+tag 退路？还是要主干长期并行两套消息？ —— *推荐：硬切 + tag 退路*
- **Q7（D4 单程延迟）**：仍以 **RTT 为权威延迟指标**；stamp 上 wire 只作记录 + MCU 侧相对时效地基，**不**做（不可靠的）单程延迟测量。同意？还是坚持要尝试时钟同步测单程？ —— *推荐：RTT 权威、不测单程*
- **Q8（里程碑）**：按 **M-A（今天 WSL 侧全做完）/ M-B（等板子做固件+重建 libmicroros+真机 A1–A8）** 切分，两者解耦、真机迁移前继续跑 Int32。同意这个切分与排期形状？ —— *推荐：M-A/M-B 解耦*
- **Q9（出卡授权）**：以上确认后，我即把 v1.7 契约草案 + Tom（M-A 实现）/ Gill（M-A 验收）任务卡落盘；M-B 任务卡是否现在一并起草，还是等 M-A 绿了、临近有硬件时段再起草？ —— *推荐：先出 M-A 卡 + v1.7 契约，M-B 卡等 M-A 绿再起草*

---

> 确认门：**在用户对 Q1–Q9 给出确认/修正之前，不产出最终任务卡、不改契约正文。** 本文件仅为草案。
