# CPU核心静态设计审查

## 1. 审查信息

- 审查日期：2026-06-23
- 审查基线：`5e1d9eb`
- 审查对象：`rtl/common`、`rtl/core`、`rtl/include`、现有 cocotb 模块级与整核验证及
  CoreBus/流水线架构文档。
- 当前目标：RV32I、五级顺序单发射流水线、小面积流片。

本次审查以静态代码阅读和跨模块时序推演为主，并执行：

- Verilator 全核 lint。
- slang/Yosys 全核 lint。
- `make test` 全量模块级回归。
- Yosys 通用门级综合，以及断开 `core_debug_o` 后的对照综合。

这里的综合结果没有使用目标工艺库，只能用于识别结构性趋势，不能替代 PDK 下的
面积、时序和功耗报告。

## 2. 总体结论

当前 RTL 已经形成一套结构清楚、握手语义基本一致的五级流水线骨架。IF 的 epoch
丢弃、各级弹性寄存器、MEM 多 outstanding 顺序合并、load-use 阻塞和 EX 背压期间
的前递值保存都具有明确实现，模块级测试也覆盖了不少容易出错的边界。

但当前版本还不能作为可流片的完整 RISC-V 核心。最主要的阻塞项不是普通 ALU 或
握手逻辑，而是异常体系尚未进入架构：非法指令、取指/数据访问错误和非对齐访问
都会静默退休或产生错误数据。多 outstanding store 也使未来的精确异常不能通过
“在 WB 加一个 trap”简单补齐，需要先确定 LSU 的提交策略。

审查结果按优先级分为：

| 等级 | 含义 | 数量 |
| --- | --- | ---: |
| P0 | 流片或架构正确性阻塞项 | 4 |
| P1 | 建议在继续扩展 ISA/cache 前解决 | 4 |
| P2 | 面积、时序、可维护性优化项 | 5 |

## 3. 已确认的良好设计

### 3.1 级间事务边界清楚

ID/EX、EX/MEM 和 MEM/WB 均由 `stream_register` 管理，stage 使用输入端 fire 表示
事务真正发生。下游反压时 payload 保持稳定，满载寄存器支持同周期 pop/push。
这比全局 stall 网络更容易局部验证，也有利于以后插入缓存或多周期单元。

### 3.2 IF redirect 没有撤销已发出的总线请求

IF 使用 request holding register、PC/epoch FIFO 和返回 fetch FIFO。redirect 会
丢弃尚未暴露的预存请求，但已经进入 CoreBus 握手协议的请求继续完成；旧路径响应
按顺序接收后由 epoch 丢弃。这满足 ready/valid 请求不能中途撤销的约束。

### 3.3 数据相关覆盖了弹性流水线特有边界

前递优先级为 EX/MEM、MEM pending、MEM/WB、已保存 MEM/WB 值、ID/EX 原始值。
匹配但数据未完成的 load 会阻塞消费者，MEM/WB 前递值在 EX 背压期间不会因为
写回完成而消失。x0 写回在 EX 提前消除，寄存器堆仍做防御性过滤。

### 3.4 MEM 请求和元数据入队保持原子性

数据请求只有在 outstanding FIFO 可接受时才向 CoreBus 拉高 valid；请求 fire 与
FIFO push 是同一个事件。响应只与 FIFO 头部合并，并支持空 FIFO 零延迟响应和满
FIFO 同周期 pop/push。当前顺序响应假设下，没有发现请求和元数据错配路径。

### 3.5 无寄存器写回的指令仍能退休

WB 使用 MEM/WB stage valid 形成退休事件，而不是使用 `wb_req.valid` 代替指令
valid。因此 store、branch 和 FENCE 等指令不会因为不写 GPR 而从退休流中消失。

## 4. P0：流片与架构正确性阻塞项

### P0-1：异常和 trap 尚未实现，错误事务会静默退休

#### 现状

- decoder 默认产生 `illegal_instr=1`，但非法指令仍作为无副作用事务穿过流水线，
  最终由 WB 报告为正常退休。
- IF 在组成 `{pc, instr}` 时只使用 `rsp.rdata`，没有保存或处理
  `imem_resp_i.rsp.error`。
- MEM 收到数据错误响应后仍把 load 的 `wb_req.data_valid` 置 1，并将返回数据写入
  目标寄存器；`error` 只进入 debug。
- SYSTEM 指令全部按非法指令处理，尚无 ECALL、EBREAK、CSR、MRET 或中断入口。

#### 代码证据

- `rtl/core/units/decoder.sv:26-35,259-265`
- `rtl/core/pipe/if_stage.sv:116-119`
- `rtl/core/pipe/mem_stage.sv:135-146`
- `rtl/core/pipe/wb_stage.sv:31-45`

#### 风险

这不仅是“缺少一个可选功能”。错误 load 会写回并参与后续前递，取指错误数据会
被当作指令译码，非法指令会被观察为成功退休。软件无法可靠发现故障，也不满足
完整 RV32I/特权架构运行环境的基本要求。

#### 建议

先定义最小 M-mode 异常体系，再扩展流水线：

1. 增加每条指令携带的 exception cause、fault address 和有效位。
2. IF 保存 instruction access fault；ID 生成 illegal/ECALL/EBREAK；EX/MEM 生成
   misaligned 和 data access fault。
3. 在唯一提交点进行异常优先级仲裁，异常指令不写 GPR、不提交 store。
4. 实现最小 `mtvec/mepc/mcause/mtval/mstatus` 和 trap redirect。
5. 明确异常 redirect 对 IF、ID/EX、EX/MEM、MEM outstanding 的 kill/保留规则。

### P0-2：非对齐 load/store 会产生截断或错误数据

#### 现状

MEM 无条件把有效地址向下对齐到字边界。store unit 根据原地址低位移位并截断到
4-bit `wstrb`，load unit 只从一个返回字右移数据。

例如：

- `SH` 到地址低位 `2'b11` 时，`0011 << 3` 截断为 `1000`，第二个字节丢失。
- 非对齐 `LW` 只读取一个对齐字并右移，无法取得下一个字中的剩余字节。
- 非对齐 `SW` 仍对向下对齐的地址写 `1111`，写入位置错误。

#### 代码证据

- `rtl/core/pipe/mem_stage.sv:74-76`
- `rtl/core/units/store_data_unit.sv:15-36`
- `rtl/core/units/load_data_unit.sv:15-33`
- `docs/核心总线设计规范.md:75-76` 已要求断言捕获跨字访问，但 RTL 中尚无该断言。

#### 建议

第一版小面积实现应直接在 EX/MEM 边界检测：

```text
byte: always aligned
half: addr[0] == 0
word: addr[1:0] == 0
```

不满足时产生 load/store address misaligned exception，并且禁止 CoreBus 请求。不要
在没有明确需求时实现跨两个 CoreBus 请求的非对齐访问；它会显著增加异常、原子性
和 outstanding 元数据复杂度。

在异常通路完成前，至少加入断言，防止错误访问在验证中静默通过。

### P0-3：取指地址对齐没有检查

#### 现状

当前只对 JALR 目标清除 bit 0。RV32I 在不支持 C 扩展时 `IALIGN=32`，JAL、条件
分支或 JALR 的目标 bit 1 仍可能为 1，此时应该产生 instruction-address-misaligned
异常。boot PC 也没有对齐约束，IF 直接把 PC 送给 CoreBus。

#### 代码证据

- `rtl/core/units/branch_unit.sv:32-44`
- `rtl/core/pipe/if_stage.sv:93-100`

#### 建议

- 对 boot PC 和所有 redirect target 增加 `pc[1:0]==0` 检查。
- JALR 仍按 ISA 清 bit 0，然后检查最终 target 的 bit 1。
- misaligned taken branch/jump 应在跳转指令本身产生异常，而不是等 IF 总线报错。
- 如果未来实现 C 扩展，再把检查改为参数化 IALIGN。

### P0-4：多 outstanding store 与精确异常存在结构性冲突

#### 现状

MEM 允许连续 load/store 在更老请求尚未响应时继续发出。store 的外部副作用可能
在 CoreBus 请求被接受时或响应前已经发生，而更老 load 的 error 尚未返回。

#### 失败场景

```text
older load  -> 请求已发出，尚未返回，最终将产生 access fault
younger store -> 请求随后被接受，外部内存或 MMIO 已发生写副作用
older load response -> 现在才发现异常
```

此时无法回滚年轻 store，违反精确异常要求。类似问题也会影响 MMIO、总线错误和
未来的中断边界。

#### 建议

在实现异常前先选择 LSU 策略：

- 最简单可靠：仅允许 load 多 outstanding；store 在所有更老可异常事务完成后再
  发出，且一次只保留一个未提交 store。
- 或增加 store buffer，并把“进入 store buffer”和“对外提交 store”分离；只有
  store 成为最老且无更老异常时才产生外部副作用。
- 若坚持所有访存都可多 outstanding，则 CoreBus/cache 必须支持可取消或事务提交
  语义，复杂度通常不适合当前小面积目标。

对本项目，推荐第一种方案。

## 5. P1：继续扩展前建议解决

### P1-1：CoreBus 只约束响应顺序，没有明确内存可见性顺序

CoreBus 文档要求响应按请求顺序返回，但“返回顺序”不自动保证年轻 load 一定看到
更老 store 的数据。cache 可以先用旧数据完成年轻 load lookup，再延迟其响应直到
store 响应之后；表面顺序正确，数据却错误。

协议必须增加以下语义之一：

```text
每个读请求必须观察到所有更早被接受写请求的效果。
```

或者由 MEM 对 pending store 做地址相关检测，对可能别名的 load 阻塞/前递。考虑
当前 CoreBus 是单条顺序请求流，建议把“按接受顺序执行、读观察全部更老写”明确
规定为 slave/cache 的强制契约，并为 store→load 同地址编写整核测试。

MMIO 还需要比普通 cacheable memory 更严格的请求数和副作用约束，后续应增加区域
属性或单独的 uncached 接口策略。

### P1-2（已完成）：整核程序级验证基线已建立

审查基线后已新增 `tests/cocotb/riscv_core`：双 CoreBus 内存模型、RV32I 小程序、
退休级 scoreboard、零延迟与随机背压回归均已接入 `make test`。当前还以参数化
smoke 覆盖 `(IF outstanding, IF/ID queue, MEM outstanding)` 的 `(1,1,1)`、
`(1,2,2)` 与 `(4,1,4)` 组合。

后续验证重点应转向多 seed 的约束随机、riscv-arch-test、错误注入、协议 checker
的独立复用，以及从 `core_debug_o` 或精简 RVFI 风格端口派生形式验证接口。

### P1-3：debug/trace 数据路径对小面积目标过重

旧版 `core_debug_o` 是 309-bit 展平退休总线。为了形成它，fetch、reg_addr、ctrl、
redirect、ALU、mem request/response 等字段随流水线移动，MEM outstanding FIFO
还保存完整 `ex_mem_bus_t`。当前实现已收敛为约 207-bit 的扁平退休 trace，只保留
valid、PC、指令、GPR 写回、访存事件和 redirect 事件。

同一 Yosys 通用综合流程的对照结果：

| 配置 | 顺序单元位数 | 总映射 cell 数 |
| --- | ---: | ---: |
| 当前顶层，保留 `core_debug_o` | 2279 | 9253 |
| wrapper 断开 `core_debug_o` | 1698 | 8664 |
| 差值 | 581（约 25.5%） | 589（约 6.4%） |

该数字不是工艺面积，但说明 trace 对寄存器资源的影响非常显著。建议：

1. 增加综合期 `TraceEnable` 配置，验证版本保留退休 trace，流片版本可进一步裁剪。
2. 功能 payload 与 trace payload 分离；功能逻辑不得依赖 trace。
3. 流片若需要可观测性，保留紧凑退休接口，例如 valid、PC、instr、rd、wdata、
   trap cause，而不是携带所有控制字段和中间结果。
4. outstanding FIFO 使用专用紧凑 LSU metadata，不保存完整 `ex_mem_bus_t`。

最终决策必须在 PDK 综合下比较；即便当前 trace 已裁剪，流片配置仍应确认是否需要
全部退休字段。

### P1-4：CoreBus 环境契约缺少完整断言

core 侧已经断言请求 valid/payload 在背压下保持稳定，但尚缺少：

- slave 响应 valid/payload 在 `rsp_ready=0` 时保持稳定的 assumption/assertion。
- 不允许无 outstanding response。
- 每个 request 最终恰好一个 response 的计数检查。
- outstanding 数不超过配置深度。
- 读请求 `wstrb=0/wdata=0`、IF 永不写、请求地址对齐。
- data error 时禁止正常 GPR/store 提交。

建议为 CoreBus master/slave 编写可复用 protocol checker，在模块级和整核测试中均
实例化。liveness 属性可以在形式环境中加有界公平假设。

### P1-5：MEM 验证覆盖还没有达到接口复杂度

现有 MEM 测试覆盖两个 outstanding、顺序响应、满队列交接和零延迟响应，但缺少：

- 请求端长时间 `req_ready=0` 时 payload/valid 的显式测试。
- 读写交替、连续 store 和 store→load 同地址。
- error response 的功能语义。
- 非对齐访问断言。
- 随机请求/响应双向背压和参考队列。
- MEM stage 单模块的 `MemOutstandingDepth=1` 及大于 2 的参数化运行；整核
  配置矩阵现已覆盖 1、2、4。
- reset 发生在 outstanding 不为空时的系统约束。

这些场景应在实现异常策略后与整核 scoreboard 一起补齐。

## 6. P2：面积、时序和可维护性改进

### P2-1：寄存器堆实现需要结合工艺重新评估

当前寄存器堆是 31×32、双组合读、单同步写。Yosys 通用综合将其展开成 31 个
32-bit 寄存器和两套读 mux；这通常不会自动映射到单端口 SRAM。

对于很小的 RV32 核，可比较：

- 标准单元 FF/latch regfile。
- 工艺提供的 2R1W register-file macro。
- 双 bank 或复制 SRAM 的面积代价。
- 将读取改为同步/分时后增加流水周期的代价。

不要仅凭 RTL 行数判断面积；寄存器堆和读 mux 很可能是核心主要面积来源之一。

### P2-2：MEM outstanding FIFO 的条目过宽

默认 `ex_mem_bus_t` 约 274 bit，深度 2 时数据阵列约 548 bit，并且全条目可观察。
功能上真正需要长期保存的主要是：

- load/store 类型和地址低位。
- size、sign extension。
- load 目标 rd/write enable。
- 退休顺序所需的最小 metadata。
- 可选 trace 信息。

建议定义专用 `lsu_outstanding_t`。即使保留完整 trace，也应把 trace 配置与功能
metadata 分开，避免参数深度增加时线性复制大量无关字段。

### P2-3：barrel shifter 和分支比较器应由 PDK 综合决定是否多周期化

当前 ALU 使用组合动态移位，branch unit 同时包含 equality、signed 和 unsigned
比较。它们可能成为面积或 EX 时序热点，但是否值得改成迭代多周期单元必须看真实
报告。

建议顺序：

1. PDK 综合和 STA 定位真实热点。
2. 先优化比较共享、高扇出和 mux 结构。
3. 若 shifter 面积仍明显，再评估 1/4/8-bit 每周期的迭代 shifter。
4. 保持 branch compare 单周期，除非时序报告明确要求改变。

### P2-4：ready 组合路径需要 STA 检查

弹性寄存器的 SameCycleRW 会形成从下游 ready 向上游 ready 的组合链。当前值得关注：

- D-cache/CoreBus `req_ready` 到 MEM `ex_mem_ready_o`。
- MEM/WB ready 到非访存 EX/MEM ready。
- IF PC FIFO 满载交接时 response 到 request valid 的组合关系。

逻辑上没有发现组合环，但外部 cache 若也组合依赖 core 输出，可能形成系统级环或
长路径。接口规范应限制 slave 的组合依赖，STA 后再决定是否插入 spill register。

### P2-5（已完成）：IF 配置已从 core 顶层暴露

`riscv_core` 现已统一暴露 `FetchOutstandingDepth`、`IfIdQueueDepth` 和
`MemOutstandingDepth`，并将前两个参数直接传递到 `if_stage`。默认组合保持
`(1,2,2)`；整核 cocotb 回归同时编译运行代表性参数组合，便于后续做可重复的
面积/性能比较。

小面积默认配置建议重点比较：

- IF outstanding 1、fetch queue 1/2。
- MEM outstanding 1/2。
- trace on/off。

### P2-6（已完成）：FIFO 数据阵列与异步复位状态已拆分

`peek_fifo` 的 `mem_q` 写入现已位于仅 `posedge clk_i` 触发的独立 `always_ff`，而
valid/count/pointer 控制状态仍使用异步复位。数据阵列不复位的功能语义保持不变，
同时准确表达了无复位存储与控制状态的硬件边界，消除了 lint 对 `mem_q` 异步复位
赋值的误判。

### P2-7：decoder 控制可进一步显式化

`forwarding_unit` 目前从 branch/mem/wb/operand select 反推 rs1/rs2 是否真实使用。
当前 RV32I 条件尚可维护；加入 CSR、乘除法或自定义单元后容易漏项。

建议未来在 decoder 中增加 `rs1_read`、`rs2_read`，或定义统一 operand-use mask。
这会增加少量 ID/EX 控制位，却能简化 hazard 单元并降低扩展时的功能风险。是否采用
应结合 ID/EX payload 精简一并决定。

## 7. 验证与工具结果

### 7.1 静态检查

| 工具 | 结果 |
| --- | --- |
| Verilator `--lint-only -Wall`（项目既有告警豁免） | 通过，无新增 warning |
| slang/Yosys `--lint-only` | 0 error，7 个 FIFO 数据阵列复位表达 warning |
| Yosys 通用综合 | 通过 |

lint 通过只证明语法、类型和部分结构规则满足工具要求，不证明 ISA、异常或协议功能
正确。本报告中的 P0 问题大多不会被普通 lint 自动发现。

### 7.2 模块级回归

`make test` 全部通过：

- common FIFO 多深度/FallThrough/SameCycleRW 组合。
- IF 基本取指、背压、零延迟响应、redirect 和参数 smoke。
- ID 译码、立即数、寄存器堆旁路和弹性寄存器。
- EX ALU、branch、前递、load-use 和背压。
- MEM 顺序 outstanding、load/store lane、零延迟响应和 MEM/WB 背压。
- WB 写回与 debug 展平。

尚无整核测试、ISA compliance、RVFI 或形式证明。

## 8. 推荐实施顺序

### 阶段 1：先建立整核验证基线

1. 新增 `tests/cocotb/riscv_core` 和双 CoreBus 内存模型。
2. 用小型 RV32I 程序覆盖 ALU、前递、branch、load/store 和随机背压。
3. 以退休事件维护寄存器/内存 scoreboard。
4. 增加 wrong-path store/GPR 不提交、store→load 同地址和 reset/boot 场景。

### 阶段 2：冻结异常和 LSU 提交架构

1. 决定最小 M-mode CSR/trap 集合。
2. 决定 store 不可回滚问题的解决方案；推荐 store 不多 outstanding。
3. 增加 instruction/data misaligned 和 access fault。
4. 建立集中 redirect/exception arbitration 和逐级 kill 契约。

### 阶段 3：收敛面积

1. 增加 trace on/off 配置，并定义紧凑 LSU metadata。
2. 在目标 PDK 下比较 IF/MEM FIFO 深度组合。
3. 评估 regfile macro/标准单元实现。
4. 根据真实面积和 STA 决定是否迭代化 shifter 或切断 ready 路径。

### 阶段 4：架构签核

1. riscv-arch-test。
2. RVFI/riscv-formal 或等价属性验证。
3. 随机指令流、错误注入和长期随机背压。
4. CDC/reset/DFT、时序约束、功耗和物理实现检查。

## 9. 审查结语

当前设计最值得保留的是清晰的事务化流水线边界；最需要警惕的是为了性能引入的
多 outstanding memory 与精确异常之间的矛盾，以及验证用 debug 状态进入流片数据
路径后的面积成本。

建议下一步不要立即加入 cache 或 RV32M。先用整核程序验证固定当前基础行为，再
确定异常与 store 提交模型，随后做 trace 裁剪和 PDK 综合。这样后续扩展会建立在
可验证、可回滚、面积可量化的架构基础上。
