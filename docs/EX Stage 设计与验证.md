# EX Stage 设计与验证

本文档说明当前 `ex_stage` 的微架构、ALU 与分支执行、数据前递和相关阻塞、
EX/MEM 握手协议，以及对应的模块级 cocotb 验证方案。

## 范围

`ex_stage` 位于 ID 和 MEM 之间，负责：

- 根据译码控制选择 ALU 操作数。
- 执行 RV32I 整数算术、逻辑、比较和移位运算。
- 计算 load/store 地址以及 branch、JAL、JALR 目标地址。
- 比较条件分支的两个源操作数。
- 在跳转事务真正执行时向 IF 发出 redirect。
- 从 EX/MEM、MEM outstanding load 和 MEM/WB 写回候选中选择前递数据。
- 在匹配的数据尚未有效时反压 ID。
- 生成写回候选 `wb_req_bus_t`。
- 生成未经 store lane 对齐的 `mem_req_bus_t`。
- 通过单入口 ready/valid 寄存器将结果交给 MEM。
- 生成随指令继续流动的 EX debug payload。

EX 不负责 CoreBus 数据事务、load 数据提取、store lane 对齐、最终寄存器堆写入或
指令退休。这些职责分别属于 MEM 和 WB。

## 数据通路

```text
                              EX/MEM wb_req
                                    |
MEM pending wb_req[] ----------------+------+
MEM/WB wb_req -----------------------+      |
                                             v
ID/EX rs1/rs2 ----------------> +-------------------+
                                | forwarding_unit   |
                                +-------------------+
                                  | forwarded rs1/rs2
                 +----------------+----------------+
                 |                                 |
                 v                                 v
        +-----------------+                +-----------------+
PC/imm | operand mux     |                | branch_unit     |----> redirect
------>| + ALU           |--------------->| compare/target  |
       +-----------------+  ALU result    +-----------------+
                 |
                 +--------> wb_req / mem_req / EX debug
                                      |
                                      v
                             +-----------------+
                             | stream_register |
                             +-----------------+
                                      |
                                      v
                                    MEM
```

`alu` 和 `branch_unit` 是组合逻辑。`forwarding_unit` 除组合选择与相关检测外，
还保存受阻事务已经获得的 MEM/WB 前递值。完整的 `ex_mem_bus_t` 由项目本地
`stream_register` 在时钟沿保存。

## ID/EX 输入

EX 从 ID/EX 接收：

- `fetch`：当前指令的 PC 和原始指令。
- `reg_addr`：`rs1`、`rs2`、`rd` 地址。
- `exec_data`：PC、ID 读出的两个寄存器值和扩展后的立即数。
- `ctrl`：ALU、分支、访存、写回和非法指令控制。
- `debug`：前级形成的 debug 快照。

ID/EX 中的寄存器值可能已经过 WB-to-ID 同周期旁路，但仍可能落后于 EX/MEM
或 MEM/WB 中尚未写回寄存器堆的较老指令，因此必须在 EX 再做数据前递。

## 模块划分

EX 的主要执行逻辑拆分为三个小单元：

| 模块 | 职责 |
| --- | --- |
| `alu.sv` | RV32I 整数运算和地址/目标地址加法。 |
| `branch_unit.sv` | 条件比较、JAL/JALR 处理和 redirect 组装。 |
| `forwarding_unit.sv` | 源寄存器使用判断、数据前递、outstanding load 阻塞和跨背压操作数保存。 |

`ex_stage.sv` 只负责实例化这些单元、选择 ALU 操作数、组装请求，以及维护
EX/MEM 流水级边界。

## 数据前递

### 前递来源

当前 EX 使用三类较老写回候选：

1. 已寄存在 EX/MEM 中的 `wb_req`。
2. MEM outstanding FIFO 暴露的全部未完成 load `wb_req`。
3. MEM/WB 提供的 `mem_wb_req_i`。

优先级为：

```text
EX/MEM > MEM pending load > 当前 MEM/WB > 已暂存 MEM/WB > ID 读出的寄存器值
```

pending 数组中的 `data_valid` 恒为 0。任何真实源寄存器与其匹配都会阻塞 EX，
因此这里只综合寄存器地址比较和 stall 归约，不需要为每个 FIFO 条目生成数据
选择器。pending 匹配必须优先于 MEM/WB：更年轻的未完成 load 不能被更老的已完成
写回值绕过。

WB 输出不再单独接入 EX。WB 写回数据和 MEM/WB 候选表示同一个值，重复接入
只会增加端口、比较器输入和顶层连线。

### `valid` 与 `data_valid`

`wb_req_bus_t` 中两个有效位语义不同：

- `valid`：该指令会写入 `rd`。
- `data_valid`：当前候选的 `wdata` 已经可以用于前递。

ALU 和 `PC+4` 结果在 EX 已经形成，因此进入 EX/MEM 时通常满足：

```text
valid = 1, data_valid = 1
```

load 尚未收到存储器响应，因此进入 EX/MEM 时为：

```text
valid = 1, data_valid = 0
```

若地址匹配但最近的候选 `data_valid=0`，EX 必须阻塞，不能绕过它使用更老的
MEM/WB 值。

### MEM/WB 前递值的跨周期保存

ID/EX 锁存的是 ID 读取到的寄存器值。若当前指令已经从 MEM/WB 获得正确前递，
但 EX/MEM 同周期反压，执行结果不会被接收；MEM/WB 却可以独立完成写回并在下一
周期消失。此时直接退回 ID/EX 中的旧值会产生错误。

`forwarding_unit` 因此为 rs1、rs2 各维护一份按需操作数暂存：

- 只有当前 MEM/WB 候选真正被 forwarding unit 选中时才允许捕获。
- `ex_execute_fire=0` 时保存命中的前递值。
- 后续周期把暂存值作为 ID/EX 基础值，仍允许 EX/MEM、pending 和新的 MEM/WB
  候选按年龄优先级覆盖它。
- 当前 ID/EX 事务执行、被同周期替换或变为无效时清除暂存有效位。

该机制不会阻止 MEM/WB 退休，不会在 ready 链上形成环，也不要求把寄存器堆读取
多路器移入 EX 关键路径。数据寄存器只在前递值即将消失时翻转。

### EX/MEM stage valid 门控

`stream_register` 在输出 valid 清零时不会同步清除 data payload。若直接把
`ex_mem_bus_o.wb_req.valid` 送入前递单元，空寄存器中残留的上一条 load payload
可能被误认为仍然有效，导致相关指令永久阻塞。

因此 EX 先形成经过阶段有效位门控的候选：

```systemverilog
ex_mem_wb_req = ex_mem_bus_o.wb_req;
ex_mem_wb_req.valid = ex_mem_valid_o && ex_mem_bus_o.wb_req.valid;
```

模块级测试曾实际捕获该问题。流水级 payload 内部的 `valid` 不能脱离所属阶段
的 ready/valid 协议单独解释。

### 源寄存器使用判断

ID 保留原始指令位域中的 `rs1` 和 `rs2`，某些指令中的这些位没有寄存器语义。
前递单元根据控制信号推导真实读取关系，避免伪相关。

`rs1` 在以下情况被使用：

- 条件分支。
- JALR。
- load/store 地址计算。
- 选择 `OP_A_RS1` 且结果来自 ALU，并且不是 `ALU_PASS_B`。

`rs2` 在以下情况被使用：

- 条件分支。
- store 数据。
- 选择 `OP_B_RS2` 的 ALU 写回指令。

x0 永远不建立相关性。

## ALU

ALU 支持：

| 操作 | 行为 |
| --- | --- |
| `ALU_ADD` | `operand_a + operand_b`。 |
| `ALU_SUB` | `operand_a - operand_b`。 |
| `ALU_SLL` | 逻辑左移，移位量取低 5 bit。 |
| `ALU_SLT` | 有符号小于比较。 |
| `ALU_SLTU` | 无符号小于比较。 |
| `ALU_XOR` | 按位异或。 |
| `ALU_SRL` | 逻辑右移。 |
| `ALU_SRA` | 算术右移。 |
| `ALU_OR` | 按位或。 |
| `ALU_AND` | 按位与。 |
| `ALU_PASS_B` | 直接输出 operand B，用于 LUI。 |

操作数选择为：

```systemverilog
operand_a = (op_a_sel == OP_A_PC)  ? pc  : forwarded_rs1;
operand_b = (op_b_sel == OP_B_IMM) ? imm : forwarded_rs2;
```

同一个主 ALU 加法器承担：

- ADD/ADDI。
- AUIPC。
- load/store 地址。
- branch 和 JAL 目标地址。
- JALR 目标地址。

这避免为不同指令类别重复放置通用双操作数加法器。

## 分支与 Redirect

### 条件判断

`branch_unit` 使用前递后的两个源操作数，支持：

- BEQ、BNE。
- BLT、BGE。
- BLTU、BGEU。
- 无条件 JAL、JALR。

条件比较逻辑与主 ALU 并行。分支不需要复用 ALU 分成两个周期，因此不会为
每条分支引入额外停顿状态。

### 目标地址

- branch、JAL：ALU 计算 `PC + imm`。
- JALR：ALU 计算 `rs1 + imm`，branch unit 将结果 bit 0 清零。

```systemverilog
jalr_target = alu_target & ~word_t'(1);
```

### Redirect 触发时机

EX/MEM 输出已经经过寄存，因此它的输出握手表示较老事务离开 EX/MEM，不是
当前 ID/EX 指令完成执行。为了避免错误路径指令进入 ID/EX，redirect 必须在
当前执行结果被 EX/MEM 输入端接收时产生：

```systemverilog
ex_mem_input_valid = id_ex_valid_i && !forward_stall;
ex_execute_fire = ex_mem_input_valid && ex_mem_input_ready;
```

`branch_unit` 生成：

```systemverilog
redirect.valid = ex_execute_fire && taken && !illegal_instr;
```

因此：

- 前递等待时不 redirect。
- EX/MEM 反压时不 redirect。
- 同一条分支只在输入握手周期 redirect 一次。
- redirect 发生时，ID/EX 中仍然保存产生跳转的指令。
- IF 同周期屏蔽年轻输入，ID/EX 不需要独立 flush。

redirect 结果以扁平字段写入 EX debug，其中包含 `redirect_valid` 和
`redirect_target_pc`。功能通路的 `redirect_o.reason` 仍保留给前端和验证 wrapper。

## 写回请求

EX 根据 `wb_sel` 形成写回候选：

| `wb_sel` | `wdata` | `data_valid` |
| --- | --- | --- |
| `WB_NONE` | 0 | 0 |
| `WB_ALU` | ALU result | 1 |
| `WB_MEM` | 0，等待 MEM 填充 | 0 |
| `WB_PC4` | `PC + 4` | 1 |

`valid` 还受以下条件约束：

- decoder 请求写 `rd`。
- 指令不是非法指令。
- `rd` 不是 x0。

JAL 和 JALR 的主 ALU 同周期用于计算跳转目标，因此 `PC+4` 使用独立的常数
增量器。常数加法器通常比通用双操作数加法器简单，也避免让跳转指令变成多周期。

## 访存请求

EX 只形成访存的架构语义：

| 字段 | 内容 |
| --- | --- |
| `valid` | 当前指令是合法 load/store。 |
| `write` | store 为 1，load 为 0。 |
| `size` | byte、half 或 word。 |
| `sign_ext` | load 是否进行符号扩展。 |
| `addr` | ALU 计算的有效地址。 |
| `wdata` | 前递后的原始 rs2 数据。 |

EX 不对 store 数据做 byte lane 移位，也不生成 CoreBus `wstrb`。MEM 根据地址低位
和访问大小生成 lane-aligned `wdata/wstrb`，从而缩短以下 EX 关键路径：

```text
forwarded rs2 -> variable shift -> EX/MEM register
ALU address   -> byte enable    -> EX/MEM register
```

## EX/MEM 握手寄存器

EX/MEM 边界使用项目本地 `stream_register`，类型参数为 `ex_mem_bus_t`。

输入端流控为：

```systemverilog
ex_mem_input_valid = id_ex_valid_i && !forward_stall;
id_ex_ready_o = ex_mem_input_ready && !forward_stall;
```

该寄存器具有以下行为：

- 空闲时接受一条执行结果。
- MEM 反压时保持输出 valid 和 payload 稳定。
- MEM 消费当前结果的同一周期可以装入下一条结果。
- 连续无相关指令之间不插入气泡。
- 前递未就绪时不接受当前 ID/EX 事务。
- EX/MEM 数据路径在寄存器边界切断。

这里的 `ex_execute_fire` 明确使用 `stream_register` 输入端握手，而不是通过
`id_ex_valid_i && id_ex_ready_o` 间接表达。两者当前逻辑等价，但前者能够准确
描述执行结果被 EX/MEM 接收的事件。

## EX/MEM Payload

EX 输出的 `ex_mem_bus_t` 包含：

| 字段 | 内容 |
| --- | --- |
| `mem_req` | 地址、访问大小、load/store 属性及原始 store 数据。 |
| `wb_req` | ALU、PC+4 或尚未有效的 load 写回候选。 |
| `debug.pc/instr` | 从 ID 继续传递的取指快照。 |
| `debug.mem_*` | 本条指令的访存事件字段，来自 EX 生成的 `mem_req`。 |
| `debug.redirect_*` | 本条指令产生的 redirect valid 和目标 PC。 |

Debug 总线只记录指令行为，不反向参与功能控制。

## 非法指令

当前异常和 trap 通路尚未实现。EX 对 `illegal_instr` 采取无副作用策略：

- 不产生写回请求。
- 不产生访存请求。
- 不产生 redirect。
- 仍可通过流水线携带 debug 信息。

未来实现异常控制后，非法指令应转换为 trap redirect，而不是作为普通空操作
退休。

## 协议断言

EX stage 使用本地 assertion 宏检查 EX/MEM 输出接口：

- `ExMemStable`：`ex_mem_valid_o=1` 且 MEM 不 ready 时，payload 必须稳定。
- `ExMemValidStable`：有效事务在被 MEM 接收前不能撤销 valid。

断言只在 `rst_ni=1` 时有效。

## 验证结构

模块级验证位于 `tests/cocotb/ex_stage/`。

| 文件 | 作用 |
| --- | --- |
| `ex_stage_tb.sv` | 构造 `id_ex_bus_t` 并将 EX 输出展开为 cocotb 友好的标量端口。 |
| `test_ex_stage.py` | ALU、分支、前递、访存请求和握手测试。 |
| `run_ex_stage.py` | cocotb runner、Verilator 构建和结果检查入口。 |
| `Makefile` | 测试及 FST/VCD 波形入口。 |

运行 EX stage 测试：

```sh
make test-ex-stage
```

也可直接运行：

```sh
python tests/cocotb/ex_stage/run_ex_stage.py
```

runner 会解析 cocotb 生成的 XML。若其中存在 failure 或 error，即使仿真进程
本身返回 0，测试命令仍会报告失败。

## 测试覆盖点

### `alu_writeback_and_operand_selection`

- 覆盖全部 11 种 ALU 操作。
- 检查 signed/unsigned 比较和逻辑/算术右移。
- 检查 RS1/PC 与 RS2/立即数操作数选择。
- 检查 `WB_ALU` 和 `WB_PC4`。
- 检查 PC+4 的 32-bit 回绕。
- 检查 `WB_NONE`、x0 和非法指令不产生写回。

### `branch_redirect_targets_and_debug`

- 覆盖 BEQ、BNE、BLT、BGE、BLTU、BGEU。
- 覆盖 taken 和 not-taken 条件。
- 覆盖 JAL 和 JALR。
- 检查 signed/unsigned 条件比较。
- 检查 JALR 目标地址 bit 0 清零。
- 检查 redirect reason、target 和 EX debug 快照。
- 检查非法跳转不产生 redirect。

### `forwarding_priority_load_stall_and_false_dependencies`

- 检查 MEM/WB 到 rs1 的前递。
- 检查 MEM/WB 到 store rs2 数据的前递。
- 检查 EX/MEM 优先于同地址的 MEM/WB 候选。
- 检查 pending load 优先于同地址的已完成 MEM/WB 候选。
- 检查 EX/MEM load 的 `data_valid=0` 阻塞消费者。
- 检查 load 移到 MEM/WB 后继续由 `data_valid` 控制阻塞。
- 检查数据有效后恢复并使用返回值。
- 检查 LUI/`ALU_PASS_B` 不因无语义 rs1 字段产生伪相关。
- 检查空 EX/MEM 中残留 payload 不会继续参与前递。

### `mem_wb_forwarding_survives_ex_backpressure`

- 先填满 EX/MEM，使消费者保持在 ID/EX。
- 让 rs1、rs2 的两个 MEM/WB 生产者在连续周期依次完成写回并消失。
- 解除反压后检查消费者仍使用两份已暂存前递值，而不是 ID/EX 中的旧值。
- 检查暂存操作数不会阻止 EX/MEM 同周期 pop/push。

### `memory_request_address_and_raw_store_data`

- 检查 store 有效地址和访问大小。
- 检查 EX/MEM 保存未经 lane 移位的原始 store 数据。
- 检查 store 不产生寄存器写回。
- 检查 load 地址、大小和符号扩展控制。
- 检查 load 写回候选为 `valid=1, data_valid=0`。

### `ex_mem_backpressure_stability_and_same_cycle_replacement`

- MEM 反压期间检查 EX/MEM valid、PC、指令和数据保持稳定。
- 检查被阻塞的年轻跳转不会提前 redirect。
- 检查满载 EX/MEM 寄存器同周期 pop/push，不插入气泡。
- 检查解除反压后 redirect 与输入端握手同周期发生。
- 检查 redirect 随执行结果进入 EX debug。

## 波形

生成 FST 波形：

```sh
make wave-ex-stage
```

输出位置：

```text
build/cocotb/ex_stage/dump.fst
```

生成 VCD 波形：

```sh
make wave-ex-stage-vcd
```

输出位置：

```text
build/cocotb/ex_stage/dump.vcd
```

也可以在子目录直接执行：

```sh
make -C tests/cocotb/ex_stage wave
make -C tests/cocotb/ex_stage wave-vcd
```

runner 接受环境变量：

- `WAVES=1`：启用波形。
- `TRACE_FORMAT=fst`：生成 FST，默认值。
- `TRACE_FORMAT=vcd`：生成 VCD。

## 当前验证结果

EX Stage 模块级测试共 5 组，当前全部通过。根目录 `make test` 同时运行 IF、
ID 和 EX，共 18 组测试。

FST 和 VCD 两种波形模式均已实际运行并生成对应文件。Slang/Yosys 全核读取为
0 errors、0 warnings。

## 已知限制

- MEM Stage 尚未完成，真实 CoreBus load/store 时序和返回数据前递仍需在 MEM
  模块级验证中覆盖。
- 非对齐 load/store 的异常策略尚未实现；当前 EX 只传递原始地址和访问大小。
- CoreBus 错误响应、非法指令、访问错误和地址错误尚未连接 trap 通路。
- 当前没有分支预测，taken branch 和 jump 在 EX 才 redirect。
- RV32M 乘除法及多周期执行单元尚未实现。
- `PC+4` 使用独立常数增量器；后续应结合综合时序和面积报告判断是否需要进一步
  优化，而不应仅依据 RTL 运算符数量推断面积。
- 当前测试以定向边界场景为主，还没有随机指令流、形式验证或全流水线参考模型。
