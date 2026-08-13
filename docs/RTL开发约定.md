# RTL 开发约定

## 目录

```text
rtl/top/             公开 SoC 顶层
rtl/core/pipeline/   五级流水模块
rtl/core/units/      译码、ALU、CSR 等组合或局部单元
rtl/cache/           I/D cache 边界与实现
rtl/cache_dev/       参数化 cache 独立开发区及 cache 域 package
rtl/bus/             公共总线 package、CoreBus 路由和 AXI4 汇聚
rtl/peripheral/      核心本地外设
rtl/common/          ready/valid 基础单元和公共 assertion 宏
.slang/              SystemVerilog 文件列表
```

`riscv_core_impl.sv` 只负责内部核心连接；`rtl/top/ysyx_25080230.sv` 保持公开
SoC ABI。跨子系统共享的字宽和标量类型由
`rtl/common/riscv_common_pkg.sv` 唯一定义；`rtl/bus/riscv_bus_pkg.sv` 只拥有
CoreBus/AXI4 协议结构和常量，`rtl/core/riscv_core_pkg.sv` 与
`rtl/cache_dev/cache_pkg.sv` 只聚合各自领域声明。common 声明不通过领域 package
间接重导出；为了兼容 yosys-slang，直接使用 `XLen`、`ByteW`、`StrbW`、`word_t`
或 `byte_en_t` 的模块必须显式导入 `riscv_common_pkg`，package 内部则使用
`riscv_common_pkg::` 限定名。module header import 可以避免文件级 import 污染
compilation-unit scope 或依赖工具的库文件解析顺序。

`riscv_common_pkg` 必须保持为无依赖的最底层 package，不得加入具体总线协议或子系统
私有声明。其他 package 只保存跨模块共享且不依赖实例参数的常量、类型和纯函数。依赖实例几何的跨模块
协议直接暴露语义字段，字段位宽由两端相同的基础配置参数推导；所有派生宽度使用
`localparam`，不得作为可覆盖参数。模块私有状态、流水 payload、只使用一次的实现类型
和状态相关函数继续留在拥有者模块中。公共 include 根固定为 `rtl/`，引用 `.svh` 时带上
子系统目录名。

## 编码规则

- 使用 SystemVerilog、`logic`、`always_comb` 和 `always_ff`。
- 文件、模块、信号和字段使用 `snake_case`；参数使用 `UpperCamelCase`。
- 输入、输出分别使用 `_i`、`_o`；寄存器状态和下一状态使用 `_q`、`_d`。
- 主时钟和低有效复位命名为 `clk_i`、`rst_ni`。
- 组合块先给默认值，避免 latch；互斥且完整的分支优先使用 `unique case`。
- 流水 payload 使用 packed struct，控制选择使用有明确位宽的 enum。
- 同一 ABI 类型只允许一个 package 实际定义，其他模块通过显式 package import 或限定名重用；
  不得复制一份字段相同的 struct。
- ready/valid 在受背压时必须保持 valid 和 payload 稳定。
- 优先复用 `stream_register`、`fall_through_register` 和 `stream_fifo`。

注释应解释协议假设、优先级和非直观状态转换，并放在对应 RTL 附近；不要在文档
中复制实现过程，也不要写仅重复代码表面的注释。关键握手和状态约束使用
`rtl/common/assertions.svh` 中的仿真 assertion 宏。使用这些宏的每个 `.sv` 文件都必须
在自身文件头显式 `` `include "common/assertions.svh" ``；宏属于预处理器命名空间，
不属于 package，也不会由 package import 传递。文件列表仍应保持 common package 最先
编译，以满足基础类型 package 的依赖顺序。

第三方代码保持上游格式。项目自有 RTL 可参考 lowRISC Verilog Coding Style，避免
把纯格式调整和功能修改混在同一次变更中。

## 构建

确保 GNU Make、C++ 工具链、Verilator、Yosys 和 yosys-slang 插件可从 `PATH` 访问。
编辑器诊断可选用 slang-server；编译入口由 `.slang/riscv_core.f` 维护。

```bash
make lint       # SystemVerilog lint
make verilator  # 构建 ysyx_25080230 C++ 模型
make yosys-slang # 使用 yosys-slang 检查 core 和 cache 综合入口
make check      # 执行 lint、Verilator 和 yosys-slang 检查
```

yosys-slang 检查使用 `--single-unit`，保证由 `riscv_common_pkg.sv` 首次包含的
assertion 宏对整个 filelist 可见。`rtl/cache_dev/` 下的 testbench 仍由 Verilator
仿真，不作为 Yosys 综合顶层。

生成文件统一写入 `build/`，不应手工修改或提交。
