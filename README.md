# RISC V 核心

RV32E/RV32I 五级顺序核心，实现 Zicsr 和 Zifencei。默认独立构建使用 RV32E；接入工作台时，ISA 与地址布局由 `riscv-runner` 的平台契约决定。RTL 负责指令执行、总线事务和退休观察，宿主运行与差分由相邻的仿真模型和 runner 负责。

## 阅读顺序

先看 `rtl/core/riscv_core_impl.sv` 的连接，再按 IF、ID、EX、MEM、WB 读取流水级。基础宽度与标量类型（`XLen`、`word_t`）、功能事务由核心根目录的 `riscv_core_pkg.sv` 和 `riscv_core_if.sv` 定义，独立调试通路由 `rtl/core/debug/` 下的 `riscv_debug_pkg.sv` 和 `riscv_debug_if.sv` 定义。

四组级间寄存器和 `forwarding_unit` 统一在 `riscv_core_impl` 实例化，各级计算输出端口统一命名为 `result`。`if_result`、`id_result`、`ex_result`、`mem_result` 是各级计算输出，对应的 `*_result_buffered` 是级间缓冲输出，`forward_result` 是写入 ID/EX 前已完成操作数选择的 ID 事务；IF/ID 保留空载直通。顶层只声明和连接模块，本级握手由 stage 处理，前递候选提取、操作数选择及数据未就绪时的握手阻塞由前递单元处理。

| 路径 | 责任与边界 |
| --- | --- |
| `rtl/core/riscv_core_impl.sv` | 按流水顺序连接各级和寄存器，实例化前递、架构状态、控制与观察模块 |
| `rtl/core/pipeline/if_stage.sv` | 发出取指并采纳分支预测，保存请求 PC 与预测方向；仲裁 EX/WB 改道，下一拍取消旧存储请求 |
| `rtl/core/pipeline/id_stage.sv` | 译码、立即数与 GPR 实时读取；输出经前递后进入 ID/EX，数据相关在 ID 等待 |
| `rtl/core/pipeline/ex_stage.sv` | 使用前递后的操作数执行、纠正预测方向并训练 BTB；生成提交上下文及独立访存请求 |
| `rtl/core/pipeline/mem_stage.sv` | 数据对齐、CoreBus 请求和响应；EX/MEM 保留元数据直到响应完成 |
| `rtl/core/pipeline/wb_stage.sv` | 唯一架构提交点；提交 GPR、CSR、异常与 MRET |
| `rtl/core/pipeline/serialization_ctrl.sv` | ID/EX 与 EX 之间的组合握手过滤器，集中处理串行化 |
| `rtl/core/pipeline/forwarding_unit.sv` | 跨级选择最新操作数，生产者结果未就绪时反压 ID |
| `rtl/core/units/` | 组合译码、立即数生成、ALU、分支判定与 load/store 数据整理 |
| `rtl/core/units/branch_predictor/` | IF 内实例化的分支预测器、静态 BHT 和组相联 BTB；配置与枚举位于核心公共 package |
| `rtl/core/state/` | GPR 与 CSR 架构状态，只接受 WB 的状态更新 |
| `rtl/core/debug/` | 调试类型与接口、退休影子队列及性能观察，不向功能流水施加反压 |
| `rtl/icache/` | 指令查询、缺失回填、CPU 回应与失效维护 |
| `rtl/bus/` | CoreBus 地址路由、AXI 适配与仲裁；协议类型不依赖核心执行类型 |
| `rtl/common/` | 弹性寄存器、FIFO 和存储原语，时序语义由参数决定 |
| `rtl/peripheral/` | 只读 CLINT 计时器，无中断输出 |
| `rtl/top/` | SoC 固定引脚包装、DPI 仿真包装与独立 I-cache 综合顶层 |
| `formal/icache/` | 取指一致性的有界形式化环境与记分板 |
| `cachesim/` | PC 轨迹回放、缓存几何扫描、综合结果与报告；详见其 README |

## 必须保持的时序约束

流水边界以 `valid && ready` 完成一次传输。反压时保持事务；`stream_register` 不组合穿透，但允许满载时同拍弹出和写入；`fall_through_register` 在空载时组合穿透。两者与 `stream_fifo` 使用相同的 flush 语义：当拍屏蔽输出 valid、将输入 ready 置高，时钟沿清除旧内容并保留当拍握手的新输入；即使启用直通，flush 当拍也不允许输出新输入。上游负责取消旧路径输入。FIFO 的 usage 为寄存计数，在时钟沿后反映新占用量。

各级计算输出在写入寄存器前可以随操作数更新，寄存器负责保存已经接收的事务。IF/ID 保留空载直通，在改道当拍屏蔽旧事务；IF 同时取消旧路径输入，因而时钟沿后为空。ID/EX、EX/MEM 在 WB 改道当拍屏蔽旧输出，年轻输入已由上游取消，因而时钟沿后为空；ID、EX、MEM 本级无需重复 flush 门控。MEM/WB 的 flush 固定为零，保证发起改道的 WB 指令正常提交，随后由恒 ready 的 WB 自然弹空，避免改道到自身 valid 的组合反馈。调试影子队列遵循相同的取消与退休边界。

异常随指令传播，已存在的较老异常不被后级覆盖。WB 优先级为 trap、MRET、普通写回；WB 改道覆盖同拍 EX 改道并冲刷后端，EX 分支和 FENCE.I 只冲刷前端。`serialization_ctrl` 在 ID/EX 与 EX 之间让 CSR 访问和 FENCE.I 等待更老事务排空；异常及 MRET 按普通握手推进，由 WB 顺序提交和冲刷保证精确状态。CSR 提交使用 NONE、WRITE、TRAP、MRET 操作枚举；WB 在调试输出中提供提交事件与类别。

改道仲裁位于 `if_stage` 内部。顶层将 IF/ID 的 flush 直接连接到 `wb_redirect.valid || ex_redirect.valid`，ID/EX 与 EX/MEM 的 flush 直接连接到 `wb_redirect.valid`，无需独立的流水控制模块或后端冲刷信号。

`wb_sel != WB_NONE` 表示指令产生普通 GPR 写回，EX 再屏蔽 x0 和异常。ECALL/EBREAK 在 ID 转为同步异常，EX 之后的提交上下文直接保存 PC 和 `is_mret`，不再携带完整 SYSTEM 操作；当前没有中断入口，trap 提交的 mcause 中断位固定为零。

MEM 最多一笔访存在途，允许请求与响应同拍完成。请求握手后，EX/MEM 继续保持元数据，直到响应进入 MEM/WB；后端冲刷只能发生在没有在途数据请求时。旧指令的异常在进入 WB 前已确定，WB 改道通过 EX/MEM 的 flush 门控取消年轻访存请求，无需重复的提交屏障。MEM 保留请求/响应所有权检查，元数据有效性断言同时检查在途访存不被冲刷。ID 前递先检查 ID/EX 生产者，相关时等待；再按 EX/MEM、MEM/WB、GPR 实时读值的顺序选择。最近数据未就绪时不能使用更老结果；WB 离开后从 GPR 读取已提交值，无需前递暂存。

GPR/CSR 组合读接口直接暴露地址和数据，CSR 的 `implemented` 表示地址是否实现。GPR 只组合读取阵列、在时钟沿写入 WB 值；同拍读写相关由前递单元的 MEM/WB 路径处理，寄存器堆不重复旁路。`gpr_write_if` 只表示 WB 已确认的架构写入，流水中的写回候选仍区分生产者有效与数据就绪。

前递来源、优先级、相邻 ALU 依赖与 load-use 停顿详见 [数据前递说明](FORWARDING.md)。

IF 的存储回应至少晚于请求一拍，因此功能和调试侧取指元数据使用 `stream_register`，不增加回应等待。改道当拍仍可能接受旧 PC，该请求不保存元数据；存储侧 flush 延迟一拍，取消旧请求并保留同拍接受的目标 PC 请求及其新元数据。

FENCE.I 经串行化过滤器等待更老事务排空后，在 EX 的 `id_ex.fire` 成功时，将 `imem_invalidate` 与重取目标一并写入 `redirect.payload`。
IF 内部按 WB 优先选择完整 payload，以 `resolved_redirect.valid` 门控该标志，组合输出
`imem_invalidate_o`，表示取指侧指令状态失效，由 I-cache 及 IF 内的分支预测器共用。
I-cache 的失效、取指及取消控制均从 IF 引出；失效发生在 EX 执行当拍，
不随 `imem_flush_o` 延迟一拍。普通分支、trap 和 MRET 不产生 I-cache 失效请求。
FENCE.I 不向提交 payload 传递专用标志，WB 按普通指令退休；其前端重取计入性能统计，
不作为退休记录中的架构跳转。执行控制和提交 payload 均不保存 `serialize` 标志；ID 不设置全局串行化屏障。
串行化判断集中在 `serialization_ctrl`：输入连接 ID/EX，输出连接 EX，通过 monitor 读取 EX/MEM、MEM/WB。
无上游异常的 CSR 或 FENCE.I 等待两级排空；等待期间同时屏蔽输出 valid 和输入 ready，
payload 直接透传，两侧 fire 始终一致。模块无时钟、无状态，不增加流水级。
寄存器墙没有 stall 端口，依靠普通 ready 反压保持事务；各流水级不再接收串行化控制。
CSR 读取等待旧写入提交，因此无需 CSR 地址相关比较或前递；普通年轻指令可在 CSR 执行后继续推进。
前递监测过滤前的 ID/EX，等待中的生产者仍可见；过滤后的 EX 结果决定是否能使用该生产者的值。
性能统计仍按各级实际入口握手计数：过滤器屏蔽的事务不计作 EX 接口反压，若其阻塞年轻指令则体现在 ID 等待中。

I-cache 的查询、回填与回应有不同寿命：

- Array 保存查询快照，回填起始锁定牺牲路，逐字写数据，只有完整且无错误的末拍才置整行有效。
- Miss 使用 WRAP 从目标字开始回填，首拍保存后即可回应 CPU；回应消费与背景回填都完成后才能接受下一笔 miss。
- Rsp 在 flush 时取消旧查询，并单独排空已发出的 miss；背景回填仍可完成，其他行可命中，目标行等待回填结束。
- Invalidate 立即阻止新查询，等待查询与回填排空后清 valid。它与取消取指的 flush 不同。

数据侧 AXI 适配器分别跟踪 AW 与 W 的握手，完整请求被接受后等待响应。仲裁器让数据侧优先取得 AR，并在反压期间锁定来源；R 按固定且互异的 ID 返回，写通道全部属于数据侧。`axi4_burst_splitter` 是保留的 INCR 突发转单拍适配器，后续地址只递增，不支持 WRAP，当前 SoC 顶层不实例化它。

缓存地址布局为 `{tag, set, block offset}`，优先占用最低编号无效路。满组后使用 fixed、round-robin 或 Tree-PLRU；RTL 与 C++ 模型需要保持相同选路和更新规则。C++ 缺失立即填入，不模拟握手、错误、flush 或回填时序。

各级通过单向 `debug_o` 输出独立事件；前递等待通过反压计入 ID，EX 直接输出执行握手与改道事件。`core_debug_if` 汇集取指、流水握手、访存、提交与 CSR 快照。retire/perf 模块只消费调试总线，不读取功能 interface，也不向流水施加反压。I-cache 性能统计使用独立的 `icache_debug_if`。

调试总线不另设 control 字段：前端冲刷由 `execute.redirect` 与 `writeback.redirect.valid` 取或，后端冲刷直接使用后者。EX 的单比特 `redirect` 表示实际纠错或 FENCE.I 重取，`branch` 保存实际架构跳转；正确预测的跳转仍进入退休记录，错误的跳转预测被纠正到 PC+4 时不报告架构跳转。性能统计只累计实际纠错、FENCE.I 和 WB 改道，EX/WB 同拍只计一次。

退休和性能快照通过普通 struct 输出，退休事件另带 valid；顶层直接接收并展开字段，不为单向快照额外包装 interface。性能观察器只保存自己负责的计数，输出时组合访存子观察器的统计。

`retire_debug` 自行生成指令编号，并维护取指及四个流水边界的影子队列，保存指令字、分类、改道与访存观察信息。功能事务不携带 `instid`，EX 之后只保留功能所需的 PC；load 到 x0 的观察数据也走调试通路。影子队列随真实握手推进，前端 redirect 和后端 flush 分别清除对应事务。

调试类型、接口、队列及计数器全部由 `ifndef SYNTHESIS` 排除。仿真包装对外的退休和性能信号名保持稳定。

性能日志的 `ready lat(cyc)` 从 CoreBus 请求接受计时，到响应首次有效时采样，
不包含等待 CPU 接收响应的时间；这部分背压由 `rsp stall(%)` 单独表示。
平均延迟只使用已产生有效响应的样本，未响应的在途请求和 flush 取消不参与。
已经采样的响应不会因后续背压或取消而撤销，没有样本时显示 `-`。
I-cache 的 hit/miss 延迟使用相同边界；命中率按全部已接受并完成 lookup 分类的
请求计算，包含错误路径访问。阻塞百分比的分母是总周期数，局部 stall 的分母
是对应分类的退休指令数；局部阻塞允许重叠，不能相加解释为总 CPI 损失。
延迟总和及样本数使用 64 位计数，与全局周期计数采用相同的自然回绕约定。

## 代码组织

`rtl/core/` 根目录保留核心装配与公共功能定义；`pipeline/` 负责流水阶段和跨级协调，`units/` 负责组合计算，`state/` 保存架构状态，`debug/` 集中仿真观察通路。通用寄存器和 FIFO 仍归 `rtl/common/`，I-cache 及其性能观察器仍归 `rtl/icache/`。

模块按输入解释、计算与异常、输出事务、握手和状态更新的逻辑展开。信号放在相关功能附近或紧凑的声明区；接口 payload 直接使用，仅为有独立含义的计算结果命名。ID、MEM 的 `next_payload` 表示下一流水事务；EX 分别计算 `next_commit` 与 `next_mem_req`，再组成 EX/MEM。

核心接口统一在 `riscv_core_if.sv` 定义，payload 类型由 `riscv_core_pkg.sv` 拥有。
`RISCV_CORE_STREAM_IF` 生成 `valid/ready/fire/payload`，用于四组流水通道；
`RISCV_CORE_VALID_IF` 生成无背压的 `valid/payload`，用于 GPR 写回、改道及预测器训练。
例如 GPR 写回访问 `wb.payload.rd_addr/wdata`，改道访问 `redirect.payload.target_pc`。
组合读及预测查询保持 requester/responder 协议；CSR 状态为持续输出，CSR 提交由 NONE 操作
表示无效，均不增加额外握手或有效信号。两个宏仅在接口文件内使用，结束后取消定义。

时序状态使用 `_q`，组合下一状态使用 `_d`；端口使用 `_i`、`_o`，接口名表达角色；类型使用 `_t`，枚举类型使用 `_e`。缩进为两空格。注释说明协议约束、优先级和设计原因，小节标题保持单行。模块拆分以独立协议或状态所有权为依据。

调试端口与实例连接放在各自列表末尾；调试声明、事件导出、寄存器、观察器和仿真检查统一放在模块末尾的 `ifndef SYNTHESIS` 区域，必要时使用 `gen_debug` 命名块。功能逻辑不得读取调试信号，功能事务类型不得按仿真配置增减调试字段。

## 分支预测与验证

CPU 直接使用公共 package 的默认配置，不逐层传递配置参数。预测器位于 IF 内；
`riscv_core_impl` 用 `branch_update_if` 将 EX 训练连接到 IF。独立模块仍支持参数覆盖。
IF 持续用请求 PC 查询，仅在请求握手时采纳方向及目标；WB/EX 改道优先。
取指元数据、IF/ID 和 ID/EX 各保存一位 `predicted_taken`，目标不随流水传递。
反压或后续训练不会改变已采纳的预测；EX 之后不再保留预测信息。

EX 在握手且无异常时比较实际方向与预测方向，不一致才改道到实际目标或 PC+4。
正确预测不触发 flush；功能路径不比较预测目标，也不对实际目标等于 PC+4 的情况
增加抑制比较，方向不一致时允许冗余纠错。目标未对齐仍在方向纠错之前检查，
即使预测正确也必须报告异常。退休调试保持 PC+4 不算架构跳转的既有口径。

EX 在 `id_ex.fire && !executed_exception.valid` 时提交 PC、类型和 ALU 编码目标，
预测器筛选六种条件分支与 JAL；不必等待 WB，也不向后端添加训练字段。
普通指令及 JALR 不改变表项。训练来自合法的执行事务；若更老异常随后使其取消，
在代码一致的前提下，其直接目标仍有效，无需预测状态回滚。

分支预测器 `branch_predictor` 的默认参数由 `riscv_core_pkg` 定义：
`Algorithm=BHT_BTFN`、`Enable=1`、`SetCount=16`、`WayCount=2`、
`ReplacementPolicy=BTB_REPLACEMENT_ROUND_ROBIN`。可选 `BHT_NOT_TAKEN` 和
`BTB_REPLACEMENT_LRU`；组数须为正二次幂，路数为任意正整数。禁用 BTB 时不生成表及替换状态。

`riscv_core_if.sv` 定义预测和训练接口；训练的 `branch_update_payload_t` 在
`riscv_core_pkg.sv` 中定义，复用现有 `pc_t`、`branch_op_e`：

| 顶层端口 | 接口字段 | 调用方 modport | 预测器 modport |
| --- | --- | --- | --- |
| `predict` | `pc`、`taken`、`target_pc` | `branch_predict_if.requester` | `branch_predict_if.responder` |
| `update` | `valid`、`payload.pc`、`payload.branch_op`、`payload.target_pc` | `branch_update_if.producer` | `branch_update_if.consumer` |

两个接口均提供只读 `monitor` modport。查询端输入 `predict.pc`，持续组合输出
`predict.taken` 与 `predict.target_pc`，无 valid/ready；预测不跳转时目标输出零，
调用方自行决定何时采纳结果。训练端接受已确认合法的实际执行结果，无背压；条件分支
未跳转时仍须提供编码目标，当前静态 BHT 不需要实际方向输入。
`clk_i`、`rst_ni`、`invalidate_i` 保持独立端口；`clk_i` 上升沿采样 `update.valid`
及训练字段，`rst_ni` 低有效异步复位；
同址查询沿前看到旧状态、沿后看到新状态，无写入旁路及反压。

`invalidate_i` 用于 FENCE.I 等指令内容一致性事件：置位当拍屏蔽预测，上升沿清空所有
BTB valid；须保持到至少一个上升沿，优先级为复位 > 失效 > 训练。失效与训练同拍时丢弃训练，
连续置位期间不接受训练。标签、目标、类型及替换状态不因失效而清零；空路优先使重新填表时
自然建立新的 RR/LRU 顺序，无需额外复位替换状态。

六种条件分支和 JAL 训练 BTB，所有 JALR（包括 RET）、`BR_NONE` 及未定义操作均不更新或
清除表项。查询按已训练类型预测，不识别当前指令；同址代码改变而未失效时可能命中旧表项。
没有 RAS、指令编码检查或推测回滚。BTFN 按 RV32 差值的符号位判断后向分支，零偏移不跳转。
BTB 使用完整 PC 标签，已有项优先、其次最低编号空路；RR 仅在新分配时推进，LRU 仅在训练时更新。

后级若只比较实际方向而不比较目标，调用方必须保证：训练提供准确的编码目标，同一 PC 的
指令及地址映射在两次失效之间保持一致；改变后须在使用新指令前失效。CPU 从 IF 的 `imem_invalidate_o` 触发失效（源于 EX 的
FENCE.I 执行事件），并通过 FENCE.I 串行化、I-cache 失效和前端清空，避免旧指令在失效后重新训练。
在这些前提下，命中的直接分支/JAL 目标保持正确；BTFN 方向仍可能预测错误，后级必须纠正。
`invalidate_i` 本身不能证明目标正确，也不能替代 I-cache 一致性及错误路径取消。

[branchsim](branchsim/README.md) 使用相同的仅 PC 查询和预测规则，但默认 BTB 为 64×2，
训练端从轨迹指令分类，并在每条记录预测后立即更新，不模拟 RTL 时钟或复位引脚。
现有控制流轨迹不记录 FENCE.I，因此 branchsim 回放不建模失效事件；独立测试适配层在 RTL
失效沿重建参考模型，以验证清表后的可观察行为。含代码修改的回放需要额外的失效事件才能准确建模。
临时独立测试保留在 `build/branch_predictor-test/`（不纳入版本管理），当前工作目录中可运行
`python3 build/branch_predictor-test/run.py --all`，执行 24 组配置的 lint、定向测试、固定种子
随机比对、独立综合展开、branchsim 回放及源码兼容性检查。
CPU 接入测试保留在 `build/branch-predictor-integration-test/`，`run.py` 运行取指快照、
FENCE.I 自修改、分支/CSR/异常与随机延迟回归及源码检查；`verify_synth.py` 检查
流水增量与目标比较器。系统差分和形式检查的命令、结果见该目录 `results.txt`。

从本目录执行：

```sh
make check RVE=1              # RV32E 综合语义检查
make check RVE=0              # RV32I 综合语义检查
make formal-icache            # 默认两字行，复位后 20 拍的有界一致性检查
make cachesim                # C++ 功能模型
make branchsim               # C++ 分支预测功能模型
```

本组件保留 I-cache 形式化验证环境，不维护独立仿真测试；保留 RTL 内部断言、调试接口、退休跟踪和性能观察通路。

工作台集成需设置 `YSYX_HOME`、`AM_HOME`、`RISCV_CORE_HOME` 并保持当前平台契约。按工作台 `AGENTS.md` 执行包装 lint、dummy 冒烟和 RT-Thread 差分测试；总线或缓存修改同时验证 `DUT=npc` 与 `DUT=soc` 的实际路径。局部检查不能替代系统验证，20 拍有界检查也不代表任意长度的完整证明。

生成物放在各组件的 `build/`。不要手改平台契约或提交可再生产物。
