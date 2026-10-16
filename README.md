# RISC V 核心

RV32E/RV32I 五级顺序核心，实现 Zicsr 和 Zifencei。默认独立构建使用 RV32E；接入工作台时，ISA 与地址布局由 `riscv-runner` 的平台契约决定。RTL 负责指令执行、总线事务和退休观察，宿主运行与差分由相邻的仿真模型和 runner 负责。

## 阅读顺序

先看 `rtl/core/riscv_core_impl.sv` 的连接，再按 IF、ID、EX、MEM、WB 读取流水级。功能事务由 `riscv_core_pkg.sv` 和 `riscv_core_if.sv` 定义，独立调试通路由 `riscv_debug_pkg.sv` 和 `riscv_debug_if.sv` 定义。

四组级间寄存器和 `forwarding_unit` 统一在 `riscv_core_impl` 实例化，各级计算输出端口统一命名为 `result`。`if_result`、`id_result`、`ex_result`、`mem_result` 是各级计算输出，对应的 `*_result_buffered` 是级间缓冲输出，`forward_result` 是写入 ID/EX 前已完成操作数选择的 ID 事务；IF/ID 保留空载直通。顶层只声明和连接模块，本级握手由 stage 处理，前递候选提取、操作数选择及数据未就绪时的握手阻塞由前递单元处理。

| 路径 | 责任与边界 |
| --- | --- |
| `rtl/core/riscv_core_impl.sv` | 按流水顺序连接各级和寄存器，实例化前递、架构状态、控制与观察模块 |
| `rtl/core/pipeline/if_stage.sv` | 发出取指，保存请求 PC，将回应交给 IF/ID；改道当拍清前端，下一拍取消旧存储请求 |
| `rtl/core/pipeline/id_stage.sv` | 译码、立即数与 GPR 实时读取；输出经前递后进入 ID/EX，数据相关在 ID 等待 |
| `rtl/core/pipeline/ex_stage.sv` | 使用前递后的操作数进行 ALU、分支、地址和 CSR 计算；生成提交上下文及独立访存请求 |
| `rtl/core/pipeline/mem_stage.sv` | 数据对齐、CoreBus 请求和响应；EX/MEM 保留元数据直到响应完成 |
| `rtl/core/pipeline/wb_stage.sv` | 唯一架构提交点；提交 GPR、CSR、异常、MRET 与 FENCE.I |
| `rtl/core/pipeline/pipeline_ctrl.sv` | 仲裁改道与串行化屏障，阻止年轻访存越过待提交副作用 |
| `rtl/core/units/` | 运算、译码、前递和架构状态；GPR 与 CSR 单元只接受 WB 的状态更新 |
| `rtl/icache/` | 指令查询、缺失回填、CPU 回应与失效维护 |
| `rtl/bus/` | CoreBus 地址路由、AXI 适配与仲裁；协议类型不依赖核心执行类型 |
| `rtl/common/` | 弹性寄存器、FIFO 和存储原语，时序语义由参数决定 |
| `rtl/peripheral/` | 只读 CLINT 计时器，无中断输出 |
| `rtl/top/` | SoC 固定引脚包装、DPI 仿真包装与独立 I-cache 综合顶层 |
| `formal/icache/` | 取指一致性的有界形式化环境与记分板 |
| `cachesim/` | PC 轨迹回放、缓存几何扫描、综合结果与报告；详见其 README |

## 必须保持的时序约束

流水边界以 `valid && ready` 完成一次传输。反压时保持事务；`stream_register` 不组合穿透，但允许满载时同拍弹出和写入；`fall_through_register` 在空载时组合穿透。两者不可互换。

各级计算输出在写入寄存器前可以随操作数更新，寄存器负责保存已经接收的事务。IF/ID 使用 `FlushMask=1`，在改道当拍屏蔽旧事务，并在时钟沿清空；其他三级边界在 WB 改道时清空。MEM/WB 不组合屏蔽输出，保证发起改道的 WB 指令仍能正常提交。

异常随指令传播，已存在的较老异常不被后级覆盖。WB 优先级为 trap、MRET、FENCE.I、普通写回；WB 改道覆盖同拍 EX 改道并冲刷后端，EX 分支只冲刷前端。CSR 和异常构成串行化屏障，执行前等待更老事务排空。CSR 提交使用 NONE、WRITE、TRAP、MRET 操作枚举；WB 在调试输出中提供提交事件与类别。

`wb_sel != WB_NONE` 表示指令产生普通 GPR 写回，EX 再屏蔽 x0 和异常。ECALL/EBREAK 在 ID 转为同步异常，EX 之后的提交上下文直接保存 PC 和 `is_mret`，不再携带完整 SYSTEM 操作；当前没有中断入口，trap 提交的 mcause 中断位固定为零。

MEM 最多一笔访存在途，允许请求与响应同拍完成。请求握手后，EX/MEM 继续保持元数据，直到响应进入 MEM/WB；flush 不取消已经发出的数据请求。ID 前递先检查 ID/EX 生产者，相关时等待；再按 EX/MEM、MEM/WB、GPR 实时读值的顺序选择。最近数据未就绪时不能使用更老结果；WB 离开后从 GPR 读取已提交值，无需前递暂存。

GPR/CSR 组合读接口直接暴露地址和数据，CSR 的 `implemented` 表示地址是否实现。`gpr_write_if` 只表示 WB 已确认的架构写入，流水中的写回候选仍区分生产者有效与数据就绪。

前递来源、优先级、相邻 ALU 依赖与 load-use 停顿详见 [数据前递说明](FORWARDING.md)。

IF 的存储回应至少晚于请求一拍。改道当拍仍可能接受旧 PC，所以存储侧 flush 延迟一拍；这个 flush 取消旧请求并保留同拍接受的目标 PC 请求。

I-cache 的查询、回填与回应有不同寿命：

- Array 保存查询快照，回填起始锁定牺牲路，逐字写数据，只有完整且无错误的末拍才置整行有效。
- Miss 使用 WRAP 从目标字开始回填，首拍保存后即可回应 CPU；回应消费与背景回填都完成后才能接受下一笔 miss。
- Rsp 在 flush 时取消旧查询，并单独排空已发出的 miss；背景回填仍可完成，其他行可命中，目标行等待回填结束。
- Invalidate 立即阻止新查询，等待查询与回填排空后清 valid。它与取消取指的 flush 不同。

数据侧 AXI 适配器分别跟踪 AW 与 W 的握手，完整请求被接受后等待响应。仲裁器让数据侧优先取得 AR，并在反压期间锁定来源；R 按固定且互异的 ID 返回，写通道全部属于数据侧。`axi4_burst_splitter` 是保留的 INCR 突发转单拍适配器，后续地址只递增，不支持 WRAP，当前 SoC 顶层不实例化它。

缓存地址布局为 `{tag, set, block offset}`，优先占用最低编号无效路。满组后使用 fixed、round-robin 或 Tree-PLRU；RTL 与 C++ 模型需要保持相同选路和更新规则。C++ 缺失立即填入，不模拟握手、错误、flush 或回填时序。

各级通过单向 `debug_o` 输出独立事件；前递等待通过反压计入 ID，EX 直接输出执行握手与改道事件。`core_debug_if` 汇集取指、流水握手、访存、提交与 CSR 快照。retire/perf 模块只消费调试总线，不读取功能 interface，也不向流水施加反压。I-cache 性能统计使用独立的 `icache_debug_if`。

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

模块按输入解释、计算与异常、输出事务、握手和状态更新的逻辑展开。信号放在相关功能附近或紧凑的声明区；接口 payload 直接使用，仅为有独立含义的计算结果命名。ID、MEM 的 `next_payload` 表示下一流水事务；EX 分别计算 `next_commit` 与 `next_mem_req`，再组成 EX/MEM。

时序状态使用 `_q`，组合下一状态使用 `_d`；端口使用 `_i`、`_o`，接口名表达角色；类型使用 `_t`，枚举类型使用 `_e`。缩进为两空格。注释说明协议约束、优先级和设计原因，小节标题保持单行。模块拆分以独立协议或状态所有权为依据。

调试端口与实例连接放在各自列表末尾；调试声明、事件导出、寄存器、观察器和仿真检查统一放在模块末尾的 `ifndef SYNTHESIS` 区域，必要时使用 `gen_debug` 命名块。功能逻辑不得读取调试信号，功能事务类型不得按仿真配置增减调试字段。

## 验证入口

从本目录执行：

```sh
make check RVE=1              # RV32E 综合语义检查
make check RVE=0              # RV32I 综合语义检查
make test-forwarding RVE=1    # 前递优先级、EX 相关阻塞、GPR 写回与 ID/EX 锁存；也支持 RVE=0
make formal-icache           # 默认两字行，复位后 20 拍的有界一致性检查
make cachesim                # C++ 功能模型
```

工作台集成需设置 `YSYX_HOME`、`AM_HOME`、`RISCV_CORE_HOME` 并保持当前平台契约。按工作台 `AGENTS.md` 执行包装 lint、dummy 冒烟和 RT-Thread 差分测试；总线或缓存修改同时验证 `DUT=npc` 与 `DUT=soc` 的实际路径。局部检查不能替代系统验证，20 拍有界检查也不代表任意长度的完整证明。

生成物放在各组件的 `build/`。不要手改平台契约或提交可再生产物。
