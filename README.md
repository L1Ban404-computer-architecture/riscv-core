# riscv-core：RV32I 五级流水线 RTL

本项目以可综合 RTL 子集实现单发射、顺序执行/退休的 RV32I 核心，并包含最小
M-mode 精确同步异常、Zicsr 与 Zifencei 支持。仓库提供 Verilator lint 和模型构建；尚未建立
面向具体工艺的综合、STA、CDC/RDC 与门级签核流程。

```text
CoreBus imem → IF → ID → EX → MEM → WB → retire/debug
                     ↑       │      │
                 寄存器堆  redirect  CoreBus dmem
```

`rtl/core/riscv_core_impl.sv` 是内部结构化核心，通过独立的指令和数据 CoreBus
interface 形成 Harvard 边界。流水、控制、CSR、调试、I-cache 内部协议及 AXI4 也使用
带 modport 的参数化 interface。公开顶层 `rtl/top/ysyx_25080230.sv` 在数据侧内接
CLINT（`mtime` 位于 `0x0200_bff8`），其余数据请求通过 CoreBus AXI4 适配器、取指请求
通过 I-cache 和临时 burst splitter 接入单路 AXI4 Master，并保持 mini-soc/Verilator 使用的
调试 ABI。

流水级之间统一使用 ready/valid 事务协议。IF 管理取指请求、旧路径响应丢弃和
IF/ID 队列；ID 负责译码、立即数和寄存器读取；EX 执行 ALU、分支、CSR 组合读取
和数据前递；MEM 管理单 outstanding 顺序访存；WB 是 GPR、CSR、trap 和 MRET 的
唯一架构提交点。

## 实现范围

- RV32I 整数、分支跳转、load/store、FENCE 与 Zifencei FENCE.I；
- ECALL、EBREAK、MRET 和六条 Zicsr 指令；
- `mstatus/mtvec/mepc/mcause/mtval` 及精确同步异常；
- 只读 64 位 CLINT `mtime`，每周期递增；
- CoreBus 零延迟响应及请求/响应背压；
- 阻塞式、组相联的 I-cache，以及单 outstanding 的数据侧 CoreBus 到 AXI4 转换；
- 暂不支持中断、其他特权级、M/C/F/A 扩展、MMU、真实缓存或分支预测。

`riscv_core_impl` 在 FENCE.I 精确退休当拍输出单周期 `icache_invalidate_o`，并从
`PC+4` 重取指以清除已预取的旧指令。公开 SoC 顶层将该信号连接到 I-cache 的失效请求；
I-cache 在排空当前事务后清除全部有效位。

仿真专用顶层 `rtl/top/riscv_core_sim.sv` 与 `ysyx_25080230` 并列，直接将核心的
imem/dmem CoreBus 连接到同文件内的 `mem_sim` 模块，通过 `IsDmem` 参数分别选择
`dpi_imem_read_sim` 或 `dpi_dmem_access_sim`。具体内存内容和地址映射由仿真环境提供。
退休调试和性能接口已展开为顶层标量端口。对应的检查和 Verilator 生成入口为
`make sim-lint`、`make sim-parameter-lint` 与 `make sim-verilator`。

`riscv_core_sim` 提供四个仿真参数：`ImemResponseLatency`、`ImemMaxOutstanding`、
`DmemResponseLatency` 和 `DmemMaxOutstanding`，默认值分别为 `1、1、1、1`。
存储器模块内部按请求接受顺序缓存 DPI-C 返回值；响应延迟从请求握手开始计时，响应
背压不会改变已到期响应的数据。`ResponseLatency` 必须至少为 `1`，`MaxOutstanding`
必须大于零。DPI-C 函数仅在请求握手的上升沿调用，两个函数均通过输出参数返回访问错误：

```systemverilog
void dpi_imem_read_sim(addr, rdata, error)
void dpi_dmem_access_sim(addr, write, wdata, wstrb, rdata, error)
```

错误信号会随响应进入 `CoreBus.rsp_payload.error`；数据写请求按 `wstrb` 调用 DPI-C，
写响应的数据固定为零。

## 构建

```bash
make lint       # Verilator 静态检查（包含 RTL 仿真 assertion）
make verilator  # 构建 ysyx_25080230 C++ 模型
make yosys-slang # 默认核心和 cache elaboration/synthesis
make check      # lint + verilator + yosys-slang
```

构建产物写入 `build/`。设计说明见 `docs/架构设计.md`，内部总线契约见
`docs/CoreBus接口.md`，编码和构建约定见 `docs/RTL开发约定.md`。复杂实现细节记录
在对应 RTL 的局部注释中。
