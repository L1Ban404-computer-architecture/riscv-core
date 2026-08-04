# RTL 开发约定

## 目录

```text
rtl/top/             公开 SoC 顶层
rtl/core/pipeline/   五级流水模块
rtl/core/units/      译码、ALU、CSR 等组合或局部单元
rtl/cache/           I/D cache 边界与实现
rtl/interconnect/    CoreBus 路由和 AXI4 汇聚
rtl/peripheral/      核心本地外设
rtl/common/          ready/valid 基础单元
rtl/include/         配置、总线类型和 assertion
.slang/              SystemVerilog 文件列表
```

`riscv_core_impl.sv` 只负责内部核心连接；`rtl/top/ysyx_25080230.sv` 保持公开
SoC ABI。共享类型由 `riscv_core_pkg.sv` 聚合，模块局部实现不要放入 package。

## 编码规则

- 使用 SystemVerilog、`logic`、`always_comb` 和 `always_ff`。
- 文件、模块、信号和字段使用 `snake_case`；参数使用 `UpperCamelCase`。
- 输入、输出分别使用 `_i`、`_o`；寄存器状态和下一状态使用 `_q`、`_d`。
- 主时钟和低有效复位命名为 `clk_i`、`rst_ni`。
- 组合块先给默认值，避免 latch；互斥且完整的分支优先使用 `unique case`。
- 流水 payload 使用 packed struct，控制选择使用有明确位宽的 enum。
- ready/valid 在受背压时必须保持 valid 和 payload 稳定。
- 优先复用 `stream_register`、`fall_through_register` 和 `stream_fifo`。

注释应解释协议假设、优先级和非直观状态转换，并放在对应 RTL 附近；不要在文档
中复制实现过程，也不要写仅重复代码表面的注释。关键握手和状态约束使用
`rtl/include/common/assertions.svh` 中的仿真 assertion。

第三方代码保持上游格式。项目自有 RTL 可参考 lowRISC Verilog Coding Style，避免
把纯格式调整和功能修改混在同一次变更中。

## 构建

确保 GNU Make、C++ 工具链和 Verilator 可从 `PATH` 访问。编辑器诊断可选用
slang-server；编译入口由 `.slang/riscv_core.f` 维护。

```bash
make lint       # SystemVerilog lint
make verilator  # 构建 ysyx_25080230 C++ 模型
make check      # 执行以上两项
```

生成文件统一写入 `build/`，不应手工修改或提交。
