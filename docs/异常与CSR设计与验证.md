# 精确异常与最小 M-mode CSR 设计

本文档是当前核心异常、SYSTEM 指令、CSR 和全流水冲刷语义的规范说明。实现范围为
RV32I、M-mode、`IALIGN=32`；暂不支持中断、委托、分页和 vectored `mtvec`。

## 1. 架构原则

核心继续采用五级 ready/valid 顺序流水线，WB 是唯一架构提交点：

```text
IF -> ID -> EX -> MEM -> WB
                         |
                         +-- GPR/CSR/trap/MRET commit
```

异常不是独立的旁路脉冲，而是 `exception_bus_t` payload，随所属指令逐级向后
传递。各级只负责检测本级异常并关闭普通副作用，WB 统一更新 CSR 和重定向 PC。
因此异常指令以前的事务已经退休，异常指令及其后的事务均不会产生错误的架构状态。

`exception_bus_t` 字段如下：

| 字段 | 语义 |
| --- | --- |
| `valid` | 本条指令存在待提交异常。 |
| `is_interrupt` | 区分同步异常与未来中断；当前始终为 0。 |
| `cause` | RISC-V `mcause` 异常编号。 |
| `tval` | 写入 `mtval` 的异常附加值。 |

异常采用“最老、最早发现者优先”：上游已有异常时，下游不得覆盖；下游只能在
payload 尚无异常时补充本级检测结果。

## 2. 支持的同步异常

| 检测级 | cause | 条件 | `mtval` |
| --- | ---: | --- | --- |
| IF | 1 | 指令 CoreBus 返回 error | 取指 PC |
| ID | 2 | 非法编码或未实现 CSR | 原始指令字 |
| ID | 3 | EBREAK | 0 |
| ID | 11 | M-mode ECALL | 0 |
| EX | 0 | taken branch/JAL/JALR 目标非四字节对齐 | 目标地址 |
| EX | 4/6 | load/store 地址未自然对齐 | 有效地址 |
| MEM | 5/7 | 数据 CoreBus 返回 load/store error | 有效地址 |
| WB | 0 | MRET 的 `mepc` 非四字节对齐 | `mepc` |

取指错误响应仍完成 CoreBus 握手，但返回指令位不参与有效译码。访存未对齐在 EX
检测，因此不会发出数据请求；访问错误在 MEM 合并响应时产生，并关闭 load 写回。
错误 store 是否无外部副作用依赖平台契约：`error=1` 必须表示该写入没有架构可见
效果。

## 3. CSR 与 SYSTEM 指令

当前实现以下五个 M-mode CSR：

| CSR | 地址 | 实现约束 |
| --- | ---: | --- |
| `mstatus` | `0x300` | `MPP` 固定为 M；实现 MIE/MPIE 的 trap 转换。 |
| `mtvec` | `0x305` | 仅 direct mode，写入时低两位清零。 |
| `mepc` | `0x341` | 普通读写；MRET 提交时检查四字节对齐。 |
| `mcause` | `0x342` | trap entry 写入 interrupt 位与 cause。 |
| `mtval` | `0x343` | trap entry 写入异常附加值。 |

decoder 支持 `CSRRW/CSRRS/CSRRC` 及三个立即数形式。CSR 指令写入 `rd` 的值始终是
修改前旧值；`CSRRS/CSRRC` 的 `rs1=x0` 和立即数为 0 时只读、不产生 CSR 写请求。
访问白名单以外的 CSR 产生非法指令异常。

ECALL 和 EBREAK 在 ID 转换为异常。MRET 不在前级直接修改状态，而是携带
`SYS_MRET` 到 WB 原子提交。

`csr_unit` 实例化在 `wb_stage` 内部，使 CSR 寄存器物理所有权与唯一架构提交点
一致。EX 仅通过组合读端口取得旧值；顶层不再展开 CSR 写、trap 更新和五个状态
字，只转发 `csr_read_rsp_bus_t`。

## 4. CSR 串行化与数据相关

所有 CSR/SYSTEM 指令均为串行化事务：

1. 指令进入 ID/EX 后阻止更年轻指令进入执行流水线。
2. EX 等待更老的 EX/MEM、LSU outstanding 和 MEM/WB 事务排空。
3. 排空后读取 CSR、计算旧值写回和新值写请求。
4. 从 EX/MEM 到 WB 提交期间继续保持年轻指令阻塞。

该规则使连续 CSR 指令自然读取上一条已经提交的状态，不需要 CSR forwarding。
普通 GPR 相关仍使用现有 EX/MEM、pending load 和 MEM/WB 前递。例如 CSR 写入 `rd`
后紧跟普通 ALU 指令时，旧 CSR 值通过普通 WB/GPR 路径可见。

## 5. WB 提交与状态转换

WB 每周期按以下优先级处理唯一有效事务：

```text
trap entry > MRET > 普通 CSR 写；普通 GPR 写与合法 CSR 指令一同提交
```

trap entry 原子执行：

```text
mepc   <- faulting_pc
mcause <- {is_interrupt, cause}
mtval  <- tval
MPIE   <- MIE
MIE    <- 0
MPP    <- M
next_pc <- mtvec
```

MRET 原子执行：

```text
MIE    <- MPIE
MPIE   <- 1
MPP    <- M
next_pc <- mepc
```

若 MRET 目标未对齐，则 MRET 状态转换不发生，改为以 MRET 自身 PC 进入 cause 0
异常。`csr_state_bus_t` 输出 `csr_unit` 的提交后下一状态，使 runner 在当前退休
周期立即观察到最新 `mepc/mcause/mtval`。

## 6. Redirect 与 Pipeline Kill

顶层集中仲裁两类控制流：

| 来源 | 作用范围 |
| --- | --- |
| EX branch/JAL/JALR | 更新 IF PC、清 fetch FIFO、翻转 epoch；不清后端。 |
| WB trap/MRET | 执行相同前端改道，并清 ID/EX、EX/MEM、MEM/WB 年轻事务。 |

同周期竞争时 WB 优先，因为 WB 指令必然比 EX 指令更老。`pipeline_kill` 同周期门控
级间 push、GPR/CSR 写和数据请求，防止即将清除的年轻事务产生副作用。已经握手的
取指请求不可取消，响应返回后依靠 epoch 丢弃。

RTL 使用 `pipeline_control_bus_t` 绑定最终 redirect 与 kill 属性。IF 只消费仲裁后
redirect，不理解流水线年龄；顶层负责选择 WB control 或 EX branch redirect，并把
同一 control 的 kill 位分发给后端。

ECALL 后顺序存放的 CSR、store 或 branch 都属于年轻事务，会在 ECALL 到达 WB 时
被清除。handler 从 `mtvec` 重新取指发生在 trap CSR 状态提交之后，因此 handler
首条 CSR 指令读取到的是最新 `mepc`。

## 7. LSU 精确异常边界

`MemOutstandingDepth` 当前默认且强制为 1。这样，数据错误进入 MEM/WB 后可以阻止
任何年轻请求发出，不会出现更老 load fault 已确定、年轻 store 已经被外部接受的
情况。参数仍保留以兼容接口，但 elaboration assertion 会拒绝非 1 配置。

未来若恢复多 outstanding，只能直接允许多个 speculative load。store 必须进入由
WB 提交的 store buffer，或者总线提供可撤销事务；否则无法保持精确异常。

## 8. 退休 Trace 与验证

异常指令仍产生一条 `core_debug_o.valid` 退休记录，并设置 `trap/cause/tval`；其
`gpr_we` 和 `mem_valid` 为 0。trap/MRET 的 redirect 字段记录真实目标。顶层额外
输出 `mstatus/mtvec/mepc/mcause/mtval` 五个提交后快照，供 mini-soc runner ABI
和差分测试使用。

整核 cocotb 测试覆盖：

- 六条 CSR 指令、零源只读规则、旧值写回和连续 CSR 相关；
- ECALL handler、年轻指令清除、handler 读取最新 `mepc` 和 MRET；
- 非法指令、EBREAK、访存未对齐及跳转目标未对齐的 cause/tval；
- 随机 CoreBus 背压、零延迟响应和旧 epoch 取指响应排空。

常用验证命令：

```bash
make test
make verilator
make -C ../mini-soc lint
make -C ../mini-soc build
```

## 9. 中断扩展约束

中断尚未实现，但类型已保留 `is_interrupt`，WB 已提供统一 trap entry。后续加入
中断时，应在提交边界按“当前最老可提交指令之前”采样，并补充 `mie/mip` 与
`mstatus.MIE` 仲裁；不得从 IF/ID 异步清流水而绕开 WB 精确提交模型。
