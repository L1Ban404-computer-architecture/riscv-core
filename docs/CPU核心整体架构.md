# CPU核心整体架构

本文档描述当前 RISC-V CPU 核心的整体微架构、流水线事务模型、背压传播、
redirect/冲刷和数据前递规则，并给出异常与整核验证等剩余内容的
开发契约。

目标读者是继续开发本核心 RTL 和验证环境的工程师。阅读本文后，应能够在不
破坏现有流水线语义的前提下实现剩余模块、扩展控制通路并编写对应测试。

## 1. 项目目标与当前范围

核心当前以小面积流片为目标，第一阶段实现 RV32I 五级顺序流水线：

```text
IF -> ID -> EX -> MEM -> WB
```

主要设计原则如下：

- 单发射、顺序执行、顺序退休。
- 使用独立的 CoreBus 指令和数据接口，形成 Harvard 风格外部边界。
- 各流水级之间使用 ready/valid 事务协议，而不是全局 stall 信号。
- 流水级寄存器或 FIFO 归属对应 stage，顶层只负责结构连线。
- 通过局部前递和反压解决数据相关。
- 分支在 EX 解析，通过 redirect 改变 IF，不设置独立 ID flush。
- 优先采用清晰、面积可控、易验证的实现，不预先引入乱序、预测、缓存或 MMU。

当前 ISA 状态：

- 已译码 RV32I 的整数、分支、跳转、load/store 和 FENCE。
- SYSTEM、CSR、ECALL、EBREAK 和特权行为尚未实现。
- 非法指令能够被识别，但 trap 通路尚未实现。
- RV32M、压缩指令、浮点和原子扩展尚未实现。

## 2. 实现状态

本文档必须区分“已经实现”与“推荐后续实现”，避免将占位逻辑误认为最终行为。

| 模块 | 当前状态 | 主要内容 |
| --- | --- | --- |
| IF | 已实现并模块级验证 | 默认单 outstanding 取指、PC/epoch FIFO、IF/ID FIFO、redirect。 |
| ID | 已实现并模块级验证 | RV32I 译码、立即数、寄存器堆、ID/EX 寄存器。 |
| EX | 已实现并模块级验证 | ALU、分支、前递、相关阻塞、EX/MEM 寄存器。 |
| MEM | 已实现并模块级验证 | 多 outstanding 顺序访存、全条目相关观察、响应合并、MEM/WB 寄存器。 |
| WB | 已实现并模块级验证 | 组合写回、顺序退休和 `core_debug_o` 展平。 |
| 异常/CSR | 未实现 | 目前只有类型和部分预留 redirect reason。 |
| 整核验证 | 未实现 | 当前五个 stage 均有模块级 cocotb 测试。 |

修改流水线前，应先阅读本文件对应章节以及：

- `docs/取指阶段设计与验证.md`
- `docs/译码阶段设计与验证.md`
- `docs/执行阶段设计与验证.md`
- `docs/访存阶段设计与验证.md`
- `docs/写回阶段设计与验证.md`
- `docs/寄存器传输级编码风格.md`

## 3. 顶层结构

`rtl/core/riscv_core.sv` 是结构化顶层。核心数据流和侧带通路如下：

```text
                    CoreBus imem
                        ^
                        |
              +---------+---------+
              |        IF         |
              | PC / epoch / FIFO |
              +---------+---------+
                        | IF/ID ready/valid
                        v
              +-------------------+
 WB write --->|        ID         |
              | decode / imm / RF |
              +---------+---------+
                        | ID/EX ready/valid
                        v
              +-------------------+
 MEM fwd ---->|        EX         |---- redirect ----> IF
              | ALU / branch / fwd|
              +---------+---------+
                        | EX/MEM ready/valid
                        v
              +-------------------+         CoreBus dmem
              |        MEM        |<------------------------>
              | LSU / align / rsp |
              +---------+---------+
                        | MEM/WB ready/valid
                        v
              +-------------------+
              |        WB         |---- core_debug_o
              | write / retire    |
              +-------------------+
                        |
                        +----------------------> ID regfile
```

顶层不应插入匿名的 `pipeline_regs`。每个边界的状态由相邻 stage 明确拥有：

| 边界 | 状态所有者 | 当前/计划结构 |
| --- | --- | --- |
| IF/ID | IF | 非 fall-through fetch FIFO。 |
| ID/EX | ID | 单入口 `stream_register`。 |
| EX/MEM | EX | 单入口 `stream_register`。 |
| MEM/WB | MEM | 单入口 `stream_register`。 |

这种所有权规则让顶层保持纯结构化，也让每个 stage 的模块级测试可以完整覆盖其
输出事务协议。

## 4. 类型与 Payload 组织

共享类型统一由 `riscv_core_pkg` 按依赖顺序聚合：

1. `riscv_core_config.svh`：XLEN、基础宽度和基础类型。
2. `riscv_isa_config.svh`：ISA 编码与归一化执行控制。
3. `core_bus_types.svh`：CoreBus 请求、响应和握手类型。
4. `transaction_bus_types.svh`：可复用流水线事务类型。
5. `debug_bus_types.svh`：扁平 debug/retire trace 类型。
6. `pipeline_bus_types.svh`：流水线边界 payload。

### 4.1 流水线 Payload

| 类型 | 主要字段 |
| --- | --- |
| `if_id_bus_t` | fetch、IF debug。 |
| `id_ex_bus_t` | fetch、寄存器地址、执行数据、译码控制、ID debug。 |
| `ex_mem_bus_t` | 访存请求、写回候选、EX debug。 |
| `mem_wb_bus_t` | 最终写回候选、MEM debug。 |

payload 只携带后级仍然需要的信息。例如立即数格式 `imm_type_e` 只在 ID 内部
使用，进入 ID/EX 的是已经扩展到 XLEN 的立即数。

### 4.2 Payload 内部 Valid 与阶段 Valid

阶段接口的 `valid` 表示“当前 payload 对应一条真实流水线事务”。payload 内部
的 `mem_req.valid`、`wb_req.valid` 表示“这条真实指令是否产生某类副作用”。

两者不可混用：

```text
stage_valid = 0
    -> 整个 payload 都没有事务语义
    -> 即使寄存器中残留 wb_req.valid = 1，也必须忽略
```

`stream_register` 清除输出 valid 时不保证同步清零 data。所有从流水线 payload
抽出的旁路请求都必须用所属 stage valid 门控。EX 的前递源已经这样处理：

```systemverilog
ex_mem_wb_req.valid = ex_mem_valid_o && ex_mem_bus_o.wb_req.valid;
```

MEM 生成的 `mem_wb_req_o` 同样使用 `mem_wb_valid_o` 门控。

## 5. Ready/Valid 事务模型

### 5.1 基本定义

所有流水级边界遵循统一语义：

- producer 驱动 `valid` 和 payload。
- consumer 驱动 `ready`。
- 只有当前周期同时满足二者时，事务才在时钟沿发生。

```systemverilog
fire = valid && ready;
```

必须满足以下不变量：

1. `valid=1 && ready=0` 时，producer 保持 valid 和 payload 稳定。
2. producer 不能等待 ready 后才决定是否拉高 valid，否则容易形成死锁。
3. consumer 可以组合产生 ready，也可以通过内部状态产生 ready。
4. 所有架构副作用必须绑定到正确的事务 fire，不能只看 payload 控制位。
5. 同一事务只能被接受一次，不能因等待状态重复写寄存器、重复 redirect 或重复
   发起总线请求。

### 5.2 弹性寄存器

ID/EX 和 EX/MEM 使用项目本地 `stream_register`：

```systemverilog
ready_o = ready_i | ~valid_o;
```

它的行为是：

- 空寄存器可以接受新事务。
- 满寄存器在下游 ready 时可以同拍 pop/push。
- 下游反压时保持输出事务。
- 连续流水不额外插入气泡。

这个单元切断 valid 和 data 路径，但 ready 可以组合向上游传播。若综合报告显示
ready 链成为关键路径，应优先考虑局部加入 `spill_register` 或更深 FIFO，而不是
改成难以验证的全局 stall 状态机。

### 5.3 边界断言

每个实现了 ready/valid 输出寄存器的 stage 至少应加入：

- valid 等待 ready 时 payload 稳定断言。
- valid 在被接受前不能撤销的断言。

IF 还针对 CoreBus 请求通道加入了相同性质的断言。MEM 实现后，应为 CoreBus
请求通道和 MEM/WB 边界加入对应断言；CoreBus slave 应对响应通道做对称检查。

## 6. 背压传播

核心没有一个广播到所有流水级的全局 stall。背压逐级沿 ready 方向传播：

```text
WB not ready
  -> MEM/WB full
  -> MEM cannot complete current instruction
  -> ex_mem_ready = 0
  -> EX/MEM full
  -> id_ex_ready = 0
  -> ID/EX full
  -> if_id_ready = 0
  -> IF fetch FIFO fills
  -> imem response ready may become 0
  -> outstanding PC FIFO fills
  -> stop allocating new CoreBus requests
```

IF 内部的两个 FIFO 会吸收短暂后端停顿，所以一次短 stall 不一定立即传播到
指令 CoreBus 接口。只有缓冲逐级填满，取指请求才最终停止。

### 6.1 普通 ALU 指令

在所有边界 ready 且无相关时，流水级可以每周期接受一条新指令。ID/EX 和
EX/MEM 都允许同拍替换：

```text
cycle N:   EX/MEM 保存 I0，ID/EX 保存 I1
edge N:    MEM 接受 I0，同时 EX/MEM 接受 I1
cycle N+1: EX/MEM 保存 I1，ID/EX 可保存 I2
```

### 6.2 长延迟 load/store

MEM 的 outstanding FIFO 会在 CoreBus 响应返回前保留访存元数据，并在队列满时
通过 EX/MEM 反压自然停止前端，不需要额外的全局 memory stall。连续访存可以并行
在飞；非访存指令不能越过尚未完成的更老访存事务。

### 6.3 数据相关阻塞

数据尚未有效时，EX 在 EX/MEM 输入端撤销 valid 并拉低 ID/EX ready：

```systemverilog
ex_mem_input_valid = id_ex_valid_i && !forward_stall;
id_ex_ready_o = ex_mem_input_ready && !forward_stall;
```

当前 ID/EX 指令保持不动，等候较老 load 的数据进入 MEM/WB。

## 7. 数据相关与前递

### 7.1 三个数据可见层次

一条依赖指令在 EX 执行时，需要观察四个数据层次：

```text
最近：EX/MEM 写回候选
其次：MEM outstanding FIFO 中尚未完成的 load
再次：MEM/WB 写回候选
最老：ID 从寄存器堆读出的值
```

优先级必须是：

```text
EX/MEM > MEM pending load > MEM/WB > regfile
```

若两个较老指令写同一个 `rd`，消费者必须看到年龄最近的值。

### 7.2 `wb_req_bus_t` 语义

```text
valid       该指令在架构上会写 rd
data_valid  当前 wdata 已可用于前递
rd_addr     目标寄存器
wdata       候选写回值
```

典型状态：

| 指令位置 | 指令类型 | `valid` | `data_valid` |
| --- | --- | ---: | ---: |
| EX/MEM | ALU、AUIPC、JAL/JALR | 1 | 1 |
| EX/MEM | load | 1 | 0 |
| MEM outstanding FIFO | 尚未响应的 load | 1 | 0 |
| MEM/WB | 已完成 load | 1 | 1 |
| 任意 | store、branch、FENCE | 0 | 0 |

若最近的匹配候选 `data_valid=0`，必须 stall，不能绕过它使用更老候选。

### 7.3 WB-to-ID 旁路

寄存器堆在 ID 内部提供 WB 同周期写后读旁路。这条旁路解决 WB 写回与 ID
组合读取同地址时对 SRAM/read-during-write 语义的依赖。

WB-to-ID 旁路不能替代 EX 前递：ID 读取后，EX/MEM 和 MEM/WB 中仍可能有尚未
写入寄存器堆的更新值。

### 7.4 WB 不作为独立 EX 前递源

WB 输出和 MEM/WB payload 表示同一条指令、同一份数据。EX 直接使用 MEM/WB
候选，不再将 WB 输出绕回前递网络。WB 输出只回到 ID 寄存器堆。

### 7.5 EX 背压期间保存 MEM/WB 前递值

MEM/WB 可以在 EX/MEM 反压期间独立退休，而受阻的 ID/EX payload 仍保存译码时
读取的旧寄存器值。为避免 MEM/WB 候选消失后重新使用旧值，`forwarding_unit`
为两个源操作数各维护一份按需暂存。只有 MEM/WB 候选被实际选中且当前事务没有
执行时才捕获；事务执行后立即清除。

暂存值只是 ID/EX 原始值的修正，EX/MEM、pending load 和当前 MEM/WB 候选仍按
年龄优先级覆盖它。这样既不阻止写回退休，也不破坏 ready/valid payload 稳定性。

### 7.6 实际源寄存器判断

不能仅根据指令位域中的 `rs1_addr/rs2_addr` 建立相关。LUI、JAL、FENCE 等编码
位置可能包含无语义比特。`forwarding_unit` 根据译码控制判断指令是否真实使用
每个源操作数，并忽略 x0。

未来增加 CSR、乘除法或其它执行单元时，必须同步扩展“源操作数是否使用”的
表达。若控制条件继续变复杂，可以在 decoder 中显式加入 `rs1_read/rs2_read`
控制位，但应结合流水线寄存器面积评估。

### 7.7 Load-use 时序

```text
EX/MEM: load x5, ...     wb.valid=1, data_valid=0
ID/EX:  add  x6, x5, x7
                    |
                    +--> forwarding_unit 匹配 x5，forward_stall=1

MEM 收到 R response：
MEM/WB: load x5          wb.valid=1, data_valid=1
ID/EX:  add  x6, x5, x7  从 MEM/WB 前递后进入 EX/MEM
```

load 离开 EX/MEM 后仍由 MEM pending 数组保持相关可见性。响应进入 MEM/WB 后，
消费者从 MEM/WB 前递；当前没有 response-to-EX 的同周期组合旁路。

## 8. 控制相关、Redirect 与冲刷

### 8.1 当前 Redirect 来源

当前只有 EX 产生 redirect，原因包括：

- taken 条件分支。
- JAL。
- JALR。

`redirect_bus_t` 同时包含：

- `valid`
- `target_pc`
- `reason`

`REDIR_TRAP` 和 `REDIR_MRET` 已预留，但尚未连接实际异常/特权控制。

### 8.2 Redirect 必须绑定 EX/MEM 输入握手

EX/MEM 输出是寄存后的较老事务，因此不能用 EX/MEM 输出握手触发当前分支的
redirect。当前分支执行事件定义为：

```systemverilog
ex_execute_fire = ex_mem_input_valid && ex_mem_input_ready;
```

只有该事件成立且分支 taken 时，branch unit 才拉高 redirect valid。

### 8.3 当前冲刷范围

redirect 只冲刷尚未进入 EX 的年轻事务：

```text
保留：产生 redirect 的 EX 指令，以及 EX/MEM、MEM/WB 中所有更老指令
丢弃：IF 内已返回队列、旧路径 outstanding fetch response、可能送往 ID 的年轻指令
```

当前不设置 ID `flush_i`，原因是 redirect 发生时 ID/EX 中保存的正是产生跳转的
指令。它本身必须进入 EX/MEM，不能被清除。

### 8.4 Redirect 周期的精确时序

假设 J 是当前 ID/EX 中的跳转指令：

1. EX 对 J 完成前递、ALU 和分支判断。
2. EX/MEM 输入 ready 时，`ex_execute_fire=1`。
3. branch unit 同周期输出 redirect。
4. IF 组合屏蔽 `if_id_valid_o`，不再向 ID 提交旧路径年轻指令。
5. 时钟沿到来时：
   - J 进入 EX/MEM。
   - ID/EX 因 IF valid 被屏蔽而不装入错误路径指令。
   - IF flush fetch FIFO、更新 PC 并翻转 epoch。
6. 已经完成 CoreBus 请求握手的旧路径响应不能取消，返回后按 epoch 丢弃。

所以当前冲刷机制依赖 redirect 在 EX/MEM 输入 fire 周期产生。将 redirect 延迟到
EX/MEM 输出握手会晚一拍，并可能让错误路径指令进入 ID/EX。

### 8.5 IF Epoch 前提

IF 使用 1 bit epoch 标记 outstanding fetch。其正确性依赖：

- 指令 CoreBus 响应严格按请求接受顺序返回。
- redirect 当前只来自 EX。
- 新路径指令进入 EX 并产生下一次 redirect 前，旧 epoch 响应已经按序消费。

若未来允许更早或更多来源的 redirect、多个无序取指通道、异常嵌套或预测恢复，
必须重新评估 1 bit epoch，可能需要更宽 generation tag 或精确取消计数。

### 8.6 未来异常 Redirect

异常可能在不同 stage 被发现：

- ID/EX：非法指令。
- MEM：访问未对齐及 CoreBus `error` 响应。
- 未来 CSR/特权单元：ECALL、EBREAK、中断、MRET。

一旦存在多个 redirect 来源，不能简单地把它们组合 OR。必须定义年龄优先级：

- 更老指令的异常优先于更年轻指令的分支 redirect。
- 被更老异常覆盖的年轻指令不能产生架构副作用。
- 需要明确清除哪些流水级寄存器，并阻止同周期年轻事务进入后级。

建议在引入 trap 时增加集中 redirect/exception arbitration，并为各流水级增加
明确的 kill/flush 契约。当前“只冲 IF、不 flush ID/EX”的规则仅适用于 EX 是唯一
redirect 来源的阶段。

## 9. 各流水级职责

### 9.1 取指阶段

IF 已实现：

- 顺序 PC 分配。
- CoreBus request holding register。
- outstanding PC/epoch FIFO。
- 已返回 fetch FIFO。
- redirect PC 更新、fetch FIFO flush 和旧 epoch response 丢弃。

关键规则：

- 已在时钟沿看到 `req_valid && !req_ready` 的 CoreBus 请求不能被 redirect 撤销。
- IF/ID valid 在 redirect 周期必须组合屏蔽。
- response 只有和 PC FIFO 头部配对后才能接受。
- 旧 epoch response 应被消费并丢弃，不能让总线永久阻塞。

### 9.2 译码阶段

ID 已实现：

- RV32I decoder。
- I/S/B/U/J/Z 立即数生成。
- 双读单写寄存器堆。
- x0 语义和 WB 同周期旁路。
- ID/EX `stream_register`。

关键规则：

- 普通 GPR 不复位，测试必须先写后读。
- decoder 对非法编码产生无副作用控制。
- ID 不因 redirect 清除当前 ID/EX 指令。
- debug 快照随指令移动，不参与功能控制。

### 9.3 执行阶段

EX 已实现：

- 主 ALU、branch unit、forwarding unit。
- EX/MEM、MEM pending、MEM/WB 前递/相关检测和 load-use stall。
- 写回与访存候选生成。
- EX/MEM `stream_register`。
- EX redirect 和 debug。

面积相关选择：

- 地址和跳转目标复用主 ALU 加法器。
- 分支比较使用并行轻量比较逻辑，不将分支拆成两周期。
- JAL/JALR 的 `PC+4` 使用常数增量器。
- store 数据移位和 byte enable 生成移到 MEM，缩短 EX 关键路径。

### 9.4 访存阶段

MEM 使用参数化 `peek_fifo` 保存完整 `ex_mem_bus_t` 访存元数据。每周期最多发出
一个 load 或 store，但允许多个请求 outstanding。CoreBus 保证所有读写响应严格
按照请求接受顺序返回，因此 FIFO 头部总能与下一个响应直接配对。

FIFO 只保存访存指令。为了保持顺序退休，只要 FIFO 非空，后续非访存指令就停在
EX/MEM；连续访存指令仍可继续进入 FIFO。已经进入 MEM/WB 输出寄存器的更老普通
指令不阻止年轻访存发出请求，响应会在 MEM/WB 不可接受时受到反压。

#### 请求分配

CoreBus 请求 payload 为固定字宽：

```systemverilog
core_req.addr = {effective_addr[XLen-1:2], 2'b00};
core_req.wdata = aligned_store_data;
core_req.wstrb = is_store ? store_byte_enable : '0;
```

EX/MEM 本身满足严格 ready/valid 保持规则，因此 MEM 不设置额外 request holding
register。事件关系为：

```text
EX/MEM fire = CoreBus request fire = outstanding FIFO push
CoreBus response fire = outstanding FIFO pop
```

#### 响应合并

响应直接与 outstanding FIFO 头部合并后进入 MEM/WB `stream_register`。Load 根据
保存的 `addr[1:0]`、`size` 和 `sign_ext` 提取 byte/half/word 并产生有效写回值；
store 等待响应后以无寄存器写回事务继续流动。

MEM/WB 无法接受时，MEM 拉低 `rsp_ready`，由 CoreBus slave 保持响应。空 FIFO 的
fall-through 路径支持请求握手同周期返回响应。FIFO 满且响应 pop 时也允许同周期
push 新请求。

#### 数据相关

`peek_fifo` 暴露所有物理条目。MEM 将有效 load 转换为 `wb_req_bus_t` 数组，其中
`data_valid=0`、`wdata=0`。EX 对全部目标寄存器做 pending 检查：

- 任一 pending load 匹配都阻塞消费者。
- pending 匹配优先于更老的 MEM/WB 已完成值。
- 数据只从 EX/MEM 或 MEM/WB 前递，pending 数组不生成数据选择器。

#### MEM/WB 边界

MEM/WB 使用 `stream_register`。`mem_wb_req_o` 取自其输出，并使用
`mem_wb_valid_o` 门控，避免空寄存器残留 payload 参与前递。

#### 当前异常边界

CoreBus `error` 和原始返回数据会记录到 debug，但当前不产生 trap。非对齐访问也
留待异常通路统一处理；实现异常后必须重新审查多 outstanding store 的精确副作用。

### 9.5 写回阶段

WB 是当前五级流水线的退休点。实现语义：

```systemverilog
wb_fire = mem_wb_valid_i && mem_wb_ready_o;
```

当前没有外部退休 backpressure，`mem_wb_ready_o` 恒为 1。MEM/WB
`stream_register` 是最后一道时序边界，WB 本身是纯组合逻辑，不再增加寄存器。

WB 负责：

- 将有效且 `data_valid=1` 的 `wb_req`送回 ID 寄存器堆。
- 用 `wb_fire` 门控写回，保证事务只提交一次。
- 将扁平 debug payload 和最终写回行为形成 `core_debug_o`。
- 仅在 `wb_fire` 时拉高 `core_debug_o.valid`。
- 确保 store、branch、FENCE 等无寄存器写回指令仍能正常退休。

实际寄存器堆写入条件：

```text
wb_fire
&& mem_wb_bus_i.wb_req.valid
&& mem_wb_bus_i.wb_req.data_valid
&& rd_addr != x0
```

WB 使用 `wb_fire` 门控整个 `wb_req` 事务，但保留 payload 中
`valid/data_valid/rd_addr` 的原始语义。regfile 防御性忽略 x0 和无效数据。

WB 不需要再次向 EX 提供独立前递端口；EX 已直接观察 MEM/WB 候选。

## 10. CoreBus 边界

完整协议定义见 `docs/核心总线设计规范.md`。CoreBus 使用一条请求通道和一条
响应通道：每周期最多接受一个读或写请求，允许多个 outstanding，所有响应共享
同一个严格请求顺序。

### 10.1 请求编码

请求包含对齐地址、字宽写数据和 byte strobe：

- `wstrb=0`：读取完整总线字。
- `wstrb!=0`：写入置位的 byte lane。
- 读请求 `wdata=0`，避免无意义翻转。
- load/store size 留在 MEM 元数据中，不进入 CoreBus。

### 10.2 顺序与握手

每个被接受的请求都必须产生一个响应，写请求也不例外。响应顺序必须和请求接受
顺序完全一致，读写之间也不能互相越过。请求或响应在 backpressure 下必须保持
valid 和 payload 稳定。

允许 slave 在请求握手同周期给出响应，因此请求元数据 FIFO 和响应保存逻辑必须
支持 fall-through 或等价的零延迟配对路径。

### 10.3 Cache 与外部互连

CoreBus 是 core/cache 边界，不承担外部 SoC 协议。D-cache core 侧每周期只需处理
一次 load 或 store lookup，与单端口 SRAM 匹配；其 memory 侧可以使用适合 cache
line refill/writeback 的独立协议。无 cache 配置也应通过单独适配器连接外部总线，
不要重新把外部互连状态机塞进 MEM stage。

## 11. Debug 与退休追踪

Debug payload 随指令逐级移动，但各级类型直接列出字段，不再互相嵌套：

```text
IF/ID  -> pc + instr
ID/EX  -> pc + instr
EX/MEM -> pc + instr + mem access + redirect valid/target
MEM/WB -> pc + instr + mem access + redirect valid/target
WB     -> MEM/WB debug + gpr write + retire valid
```

原则：

- debug 描述“这条指令退休时对外可观察到什么”。
- debug 不得反向参与功能控制。
- payload 被反压时 debug 必须和功能 payload 一起保持稳定。
- `core_debug_o.valid` 只表示退休事件，不表示流水线中存在指令。
- `core_debug_o` 不携带译码控制、源寄存器地址、ALU 中间结果、load 符号扩展控制
  或原始 CoreBus response；这些要么可由 `instr` 重译码，要么已经体现在
  `gpr_wdata`/访存事件字段中。

未来接入 RVFI 时，建议从 WB 退休 payload 派生，而不是从不同 stage 临时拼接，
这样更容易保证所有字段属于同一条指令。

## 12. 复位与启动

- 所有有状态 stage 使用同一个 `clk_i` 和低有效 `rst_ni`；纯组合 WB 不需要时钟或复位。
- 流水线 valid、FIFO usage、CoreBus holding register 和 outstanding 状态必须复位为空。
- 普通 GPR 不复位；RISC-V 不要求复位后普通寄存器具有确定值。
- x0 始终读为 0。
- IF 在复位释放后的第一个正常周期采样 `boot_pc_i`。

不要通过复位整个大数据 payload 来掩盖 valid 语义。只要 stage valid 为 0，残留
payload 就不应参与功能判断。

## 13. 时序与面积考虑

当前最可能的关键路径位于 EX：

```text
EX/MEM or MEM/WB compare
 -> forwarding mux
 -> operand mux
 -> ALU / branch compare
 -> EX/MEM input
```

已有优化：

- store lane 移位放到 MEM。
- 分支目标、地址和普通加法复用主 ALU。
- 不在顶层引入宽的重复前递聚合总线。
- 流水线 payload 删除后级不再使用的控制字段。

但面积和时序必须以综合结果为准。RTL 中出现两个 `+` 不一定综合成两个完整通用
加法器；常数 `PC+4` 通常能被优化为较简单的增量器。

如果 EX 仍不满足时序，优先顺序建议为：

1. 查看真实综合关键路径和单元面积报告。
2. 优化高扇出控制、前递比较和 mux 结构。
3. 评估 ready 路径是否需要 spill register。
4. 最后才考虑将移位或比较改成多周期执行，因为这会显著增加控制和验证复杂度。

## 14. 扩展流水线时的规则

新增功能时必须回答以下问题：

1. 新状态属于哪个 stage？
2. 哪个 ready/valid fire 表示事务真正发生？
3. 下游反压时哪些信号必须保持？
4. 新结果在哪个周期 `data_valid`？
5. 是否增加新的源寄存器使用关系？
6. 是否产生 redirect、异常或其它架构副作用？
7. 更老异常如何压制年轻副作用？
8. debug 和最终退休信息如何随指令移动？
9. 空 stage 中的残留 payload 是否被 stage valid 正确门控？
10. 模块级测试如何覆盖同时 pop/push、零延迟响应和请求/响应双向反压？

若修改共享 payload，应同步更新：

- 类型定义。
- 所有 producer 和 consumer。
- debug 展平逻辑。
- cocotb wrapper。
- 模块级参考模型和断言。
- 本文及对应 stage 文档。

## 15. 推荐的剩余开发顺序

### 步骤 1：整核最小程序验证

- CoreBus 指令/数据存储器模型。
- 小型 RV32I 汇编程序。
- 架构寄存器和内存 scoreboard。
- 分支、load-use、store、背压混合场景。

### 步骤 2：异常与 CSR

- 非法指令、ECALL、EBREAK。
- misaligned、instruction/data access fault。
- `mepc`、`mcause`、`mtvec`、`mstatus` 等最小 M-mode CSR。
- 多来源 redirect 仲裁和精确冲刷。

### 步骤 3：架构与形式验证

- riscv-tests / riscv-arch-test。
- RVFI 和 riscv-formal。
- 更广泛的随机指令流和 CI。

只有在上述基础路径稳定后，再评估 RV32M、缓存、预测或更复杂 LSU。

## 16. 验证现状与命令

当前模块级 cocotb 回归包括：

- IF：10 组运行。
- ID：3 组测试。
- EX：5 组测试。
- MEM：4 组测试。
- WB：3 组测试。

运行完整回归：

```sh
make test
```

分 stage 运行：

```sh
make test ALL=if_stage
make test ALL=id_stage
make test ALL=ex_stage
make test ALL=mem_stage
make test ALL=wb_stage
```

生成 FST 波形：

```sh
make test ALL=if_stage WAVE=fst
make test ALL=id_stage WAVE=fst
make test ALL=ex_stage WAVE=fst
make test ALL=mem_stage WAVE=fst
make test ALL=wb_stage WAVE=fst
```

生成 VCD 波形时使用对应的 `*-vcd` 目标。

模块实现完成的最低验证门槛：

- Slang/Yosys 全核读取无错误。
- Verilator 不出现组合环、锁存器或多驱动警告。
- ready/valid 稳定性断言通过。
- 模块级定向测试通过。
- FST 至少实际生成一次并可查看。
- 根目录完整回归通过。

## 17. 当前已知限制

- 非法指令和总线错误尚不能产生 trap。
- 不支持中断、CSR、特权级、缓存和 MMU。
- 非对齐数据访问策略尚未最终实现。
- 分支在 EX 解析，没有预测。
- IF 的 1 bit epoch 依赖有序响应和当前单一 EX redirect 来源。
- 当前只有 stage 模块级验证，尚无整核架构参考模型。

这些限制是开发边界，不是可以静默忽略的行为。实现剩余功能时，应优先把每个
限制转化为明确的 RTL 状态、断言、异常或测试，而不是依赖仿真环境“不会这样做”。
