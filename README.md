# riscv-core：RV32I 五级流水线 RTL

`riscv-core` 是一个可综合、单发射、顺序执行/退休的 RISC-V 核心，当前实现范围为 RV32I。顶层模块是 `riscv_core`，通过独立的 CoreBus 指令/数据端口形成 Harvard 风格的外部边界。

```text
CoreBus imem → IF → ID → EX → MEM → WB → retire/debug
                     ↑       │      │
                 寄存器堆  redirect  CoreBus dmem
```

流水级之间使用 ready/valid 事务协议；IF 维护取指与 epoch，ID 完成译码/立即数/寄存器读，EX 负责 ALU、分支和前递，MEM 管理顺序访存，WB 执行写回并输出退休信息。分支在 EX 决议并重定向 IF。共享类型集中在 `rtl/include/riscv_core_pkg.sv`，模块实现位于 `rtl/core/pipe/` 和 `rtl/core/units/`。

## 当前范围

- 已覆盖 RV32I 整数、分支跳转、load/store 与 FENCE 的主要流水线数据通路；
- 不包含 CSR、SYSTEM/ECALL/EBREAK、特权态、异常完整通路，也不包含 M/C/F/A 扩展、MMU、缓存或分支预测；
- 各流水级有 cocotb 模块测试；整核验证仍应与 `mini-soc` + `riscv-runner` 的差分链结合进行。

## 构建与验证

```bash
make test                 # 运行 tests/* 中的测试
make verilator            # 以 riscv_core 为顶层生成 Verilator C++ 模型
```

需要 Verilator、GNU Make、Python 3 与测试所需的 cocotb/Python 包。`.slang/riscv_core.f` 是 RTL 文件清单。作为完整 DUT 时不直接加载该核心，而应构建 `../mini-soc`，由其提供 RAM、MMIO 和 runner ABI。

## 深入文档

`docs/CPU核心整体架构.md` 是微架构总览；其余文档分别覆盖 IF/ID/EX/MEM/WB、CoreBus、RTL 编码风格、静态审查和验证方法。改动流水线前，应保持 stage 对 payload 与 valid 的所有权，避免引入顶层匿名流水寄存器。

