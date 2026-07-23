# CPU 核心整体验证

整核 cocotb 环境以 WB 退休事件为检查边界，对照独立的 Python RV32I 参考状态，
不绑定内部逐周期流水实现。

## 运行方式

```sh
make test ALL=riscv_core
make test ALL=riscv_core WAVE=fst
make test ALL=riscv_core WAVE=vcd
```

所有构建、波形和 JUnit XML 位于 `build/tests/riscv_core/`。统一 runner
`tests/run.py` 也负责其他模块测试。

默认配置执行全部用例；两个参数化配置执行代表性 smoke：

| 配置 | Fetch outstanding | IF/ID depth | 测试 |
| --- | ---: | ---: | --- |
| `fetch1_ifq2` | 1 | 2 | 全量 |
| `fetch1_ifq1` | 1 | 1 | 零延迟 |
| `fetch4_ifq1` | 4 | 1 | 随机背压 |

数据侧固定单 outstanding，不再暴露深度参数。

## 总线模型

指令和数据 CoreBus slave 共享小端字节内存，各自支持请求背压、0～N 周期有序
响应、请求/响应同周期完成以及响应背压。模型检查：

- 请求和响应等待期间的 valid/payload 稳定；
- 请求方向、size、自然对齐及 IF 固定 word read；
- 读请求零 wdata/wstrb；
- 请求/响应计数与顺序。

## 覆盖范围

- RV32I ALU、比较、移位、分支、JAL/JALR；
- byte/half/word load/store、符号扩展和 load-use；
- 错误路径 store 抑制和随机 CoreBus 背压；
- 六条 Zicsr、ECALL、EBREAK、MRET 和 CSR 串行化；
- 非法指令、地址未对齐、控制目标未对齐及访问错误；
- `mepc[1:0]` WARL 行为；
- IF 重复 redirect 与延迟旧响应；
- 退休 PC、指令、GPR、内存、redirect、CSR 和 trap 快照。

模块级测试另行覆盖 FIFO 边界、各 stage 背压稳定性、前递优先级、AXI 通道独立
握手与错误响应。`make check` 依次执行 lint、全部回归和公开顶层 Verilator 构建。

## 后续验证

后续优先增加外部 ISS 差分、多个约束随机种子、代码/功能覆盖率，以及目标 SoC
环境中的协议 assertion 和门级回归。
