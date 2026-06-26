# CPU核心整体验证

## 1. 验证目标

整核验证用于检查各流水级组合工作时的架构行为，重点覆盖模块级测试难以发现的
跨级问题：

- IF、MEM 两路 CoreBus 的独立背压和有序响应；
- 流水线寄存器与 FIFO 的背压传播；
- EX/MEM、MEM/WB 数据前递以及 load-use 停顿；
- 分支、JAL、JALR redirect 和错误路径冲刷；
- 子字节 Load/Store 的地址、lane 对齐和符号扩展；
- 指令退休顺序和架构写回结果。

验证不逐周期约束内部流水线状态，而以 WB stage 输出的 `core_debug_o` 退休事件为
检查边界。这样允许流水线和缓存接口继续优化，而不必同步改写大量内部时序断言。

## 2. 文件结构

整核 cocotb 环境位于 `tests/cocotb/riscv_core/`：

| 文件 | 作用 |
| --- | --- |
| `riscv_core_tb.sv` | 实例化整核，并将 packed CoreBus/debug 结构展开为标量端口。 |
| `test_riscv_core.py` | 指令编码器、测试程序、CoreBus 模型、RV32I 参考模型和测试用例。 |
| `run_riscv_core.py` | Verilator 构建与 cocotb 回归入口。 |
| `Makefile` | `test`、`wave` 和 `wave-vcd` 快捷入口。 |

根目录提供以下目标：

```sh
make test-riscv-core
make wave-riscv-core
make wave-riscv-core-vcd
```

`make test` 已包含整核回归。

默认配置与参数化 smoke 配置如下。所有配置使用同一个退休级参考模型；非默认
配置只运行一个代表性用例，用于验证顶层参数透传和各深度组合的兼容性。

| 名称 | `FetchOutstandingDepth` | `IfIdQueueDepth` | `MemOutstandingDepth` | 测试 |
| --- | ---: | ---: | ---: | --- |
| `fetch1_ifq2_mem2` | 1 | 2 | 2 | 全量 |
| `fetch1_ifq1_mem1` | 1 | 1 | 1 | 零延迟 smoke |
| `fetch4_ifq1_mem4` | 4 | 1 | 4 | 随机背压 smoke |

## 3. 共享内存和双 CoreBus 模型

取指端与数据端分别使用一个可独立配置的 CoreBus slave，但共享同一份小端字节内存。
每个 slave 维护自己的有序响应队列，支持：

- 按概率拉低 `req_ready`；
- 为已接受请求注入 0 到指定上限的响应延迟；
- 请求和响应在同一周期握手；
- 返回端反压期间保持响应；
- 响应到达时，同周期完成旧响应 pop 和新请求 push。

模型记录请求、响应和写事务历史。它还检查请求及被背压响应的 valid/payload
稳定性、请求/响应计数、字对齐、读请求零 `wdata`，以及 IF 永不写。失败信息会
附带最近的退休记录及取指请求/响应地址，便于区分“流水线 PC 错误”和“总线模型
配对错误”。

由于当前核心尚未实现异常入口，本版环境固定 `error=0`，暂不把总线错误注入正常
回归。

## 4. 退休级参考模型

Python RV32I 参考模型维护：

- 当前架构 PC；
- 32 个整数寄存器；
- 一份与 DUT 总线内存分离的参考内存；
- 动态退休指令数。

每次 `core_debug_o.valid` 为 1，scoreboard 依次检查：

1. 退休 PC 等于参考 PC；
2. 退休指令等于该 PC 的参考内存内容；
3. 指令未被错误标记为非法；
4. 写回使能、目标寄存器和写回数据一致；
5. 访存命令、大小、符号扩展、地址和 Store 原始数据一致；
6. Load 的完整 CoreBus 返回字和最终写回值一致；
7. taken branch、JAL、JALR 的 redirect 目标一致。

参考内存只在 Store 退休时更新，而 DUT 共享内存在 Store 请求握手时更新。两者分离
可以避免 DUT 的提前总线副作用污染参考结果。

## 5. 当前测试程序

测试程序使用内置 RV32I 编码器生成，不依赖外部交叉编译器。当前综合程序覆盖：

- ADDI、LUI、ADD、SUB、逻辑、比较和移位；
- SB、SH、SW、LB、LBU、LH、LHU、LW；
- 紧邻 Load 的消费者；
- taken 和 not-taken 条件分支；
- JAL、JALR 及 link register；
- 多条错误路径 Store；
- 向 `0x1000` 写入 1 的完成协议。

测试结束时同时检查 DUT 总线内存和 Store 请求日志，确保错误路径 Store 没有产生
外部副作用。

## 6. 时序配置

`zero_latency_core_bus_and_pipeline_flow` 将两路总线配置为始终 ready，并让每一笔
请求都在同周期返回。该用例重点覆盖深度 1 IF outstanding FIFO 的 fall-through 和
同周期 pop/push 路径。

`randomized_core_bus_backpressure` 使用固定种子 `0x5eed`，随机插入请求背压、0～7
周期响应延迟以及少量同周期响应。固定种子使失败可稳定复现。

## 7. 后续扩展

当前版本是整核验证的第一条可靠基线，后续建议依次增加：

1. 覆盖所有合法 RV32I 编码的定向程序；
2. 带约束的随机指令流和多个固定回归种子；
3. 独立协议 assertion/checker，而不只依赖 Python 模型；
4. 异常架构完成后的非法指令、访问错误和非对齐访问测试；
5. 可选外部 ISS 差分，以减少 Python 参考模型与 RTL 出现同源理解错误的风险；
6. 代码覆盖率和功能覆盖率收集。
