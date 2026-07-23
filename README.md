# riscv-core：RV32I 五级流水线 RTL

本项目以可综合 RTL 子集实现单发射、顺序执行/退休的 RV32I 核心，并包含最小
M-mode 精确同步异常与 Zicsr 支持。当前验证闭环覆盖 Verilator lint、仿真回归
和模型构建；尚未建立面向具体工艺的综合、STA、CDC/RDC 与门级签核流程。

```text
CoreBus imem → IF → ID → EX → MEM → WB → retire/debug
                     ↑       │      │
                 寄存器堆  redirect  CoreBus dmem
```

`rtl/core/riscv_core_impl.sv` 是内部结构化核心，通过独立的指令和数据 CoreBus
端口形成 Harvard 边界。公开顶层 `rtl/core/ysyx_25080230.sv` 将两路 CoreBus
串行到单路 AXI4 Master，并保持 mini-soc/Verilator 使用的调试 ABI。

流水级之间统一使用 ready/valid 事务协议。IF 管理取指请求、旧路径响应丢弃和
IF/ID 队列；ID 负责译码、立即数和寄存器读取；EX 执行 ALU、分支、CSR 组合读取
和数据前递；MEM 管理单 outstanding 顺序访存；WB 是 GPR、CSR、trap 和 MRET 的
唯一架构提交点。

## 实现范围

- RV32I 整数、分支跳转、load/store 和 FENCE；
- ECALL、EBREAK、MRET 和六条 Zicsr 指令；
- `mstatus/mtvec/mepc/mcause/mtval` 及精确同步异常；
- CoreBus 零延迟响应和随机背压；
- 暂不支持中断、其他特权级、M/C/F/A 扩展、MMU、缓存或分支预测。

## 构建与验证

```bash
make lint                         # Verilator 静态检查
make test                         # 全部模块级与整核 cocotb 回归
make test ALL=riscv_core          # 单独运行指定套件
make test ALL=if_stage WAVE=fst   # 生成波形
make verilator                    # 构建 ysyx_25080230 C++ 模型
make check                        # lint + test + verilator
```

测试构建、波形和 JUnit XML 全部写入 `build/`。环境配置见
`docs/开发工具链配置.md`；跨级微架构契约见 `docs/CPU核心整体架构.md`；各流水级
的局部实现与测试由对应设计文档说明。
