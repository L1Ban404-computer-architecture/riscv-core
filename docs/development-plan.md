# RISC-V 内核开发计划

本文档记录了该 SystemVerilog RISC-V CPU 内核的初始 RTL 开发计划，包括推荐的工具链、安装布局与验证路线图。

## 目标

- 以小规模、可测试的 ISA 增量构建内核。
- 将第三方工具保留在代码仓库之外，仅在仓库内保留项目本地的配置。
- 使环境易于扩展、复现与升级。
- 优先选用支持 CI 自动化与本地开发的开源工具。

## 初期范围

从 `RV32I` 开始，除非有充分理由直接使用 `RV64I`。第一个里程碑应是一个能取指、译码、执行、加载/存储、分支并退出的最小内核，可处理基本的整数指令。

建议的 ISA 推进顺序：

1. `RV32I`：基本整数指令集。
2. `RV32M`：乘除法扩展。
3. 所选测试环境所需的 CSR 与陷阱机制。
4. 中断、定时器及特权行为。
5. 可选的缓存、总线及性能特性。

避免一开始就引入特权模式、MMU、缓存或复杂的总线集成。这些在指令退出通路稳定之后再添加会容易得多。

## 代码仓库布局

建议的项目结构：

```text
riscv-core/
  docs/
    development-plan.md
  rtl/
    core/
    include/
  tb/
    verilator/
    cocotb/
  sim/
    filelist.f
    Makefile
  tests/
    asm/
    c/
    linker/
    generated/
  formal/
    rvfi/
    riscv-formal/
  scripts/
    env/
    sim/
    test/
  third_party/
    README.md
```

各目录用途：

- `rtl/`：可综合的 SystemVerilog 代码。
- `tb/`：仿真测试平台与顶层测试框架。
- `sim/`：仿真器构建规则、文件列表以及生成的仿真输出。
- `tests/`：汇编/C 测试程序及编译后的内存映像。
- `formal/`：RVFI 包装层与形式验证配置。
- `scripts/`：可复用的环境配置、构建、转换与回归脚本。
- `third_party/`：仅在必要时放置少量固定版本的源码检出；大型二进制工具链不应置于此处。

## 工具链概览

以下列出的开源 RTL 工具栈作为默认选择：

| 用途 | 工具 | 角色 |
| --- | --- | --- |
| RTL 仿真与语法检查 | Verilator | 快速 SystemVerilog 仿真、语法检查、C++ 模型生成 |
| 波形查看 | GTKWave 或 Surfer | 检查 VCD/FST 波形 |
| SystemVerilog 格式化与语言支持 | Verible | 代码格式化、风格检查、语法工具、语言服务器 |
| 综合与形式验证工具 | OSS CAD Suite | Yosys、SymbiYosys、求解器以及面向 FPGA 的实用工具 |
| RISC-V 交叉编译器 | RISC-V GNU Toolchain | 将汇编/C 测试构建为 ELF 及内存映像 |
| Python 测试平台框架 | cocotb | 基于 Python 的协同仿真测试 |
| ISA 测试 | riscv-tests | 有针对性的架构指令测试 |
| 形式化 ISA 检查 | riscv-formal | 基于 RVFI 的指令级形式验证 |
| 架构合规性 | riscv-arch-test | 后期阶段的 RISC-V 架构测试 |

## 安装策略

除非机器专为本项目所用，否则不要将项目专属工具链安装至 `/usr/local` 等系统目录。推荐使用用户自有前缀，以便不同项目可携带不同版本的工具。

推荐的根目录：

```sh
export RISCV_CORE_TOOLS="$HOME/.local/riscv-core-tools"
```

推荐布局：

```text
$RISCV_CORE_TOOLS/
  bin/
  env/
    riscv-core-env.sh
  src/
    verilator/
    riscv-gnu-toolchain/
    riscv-tests/
    riscv-arch-test/
    riscv-formal/
  opt/
    verilator/<version>/
    oss-cad-suite/<version>/
    verible/<version>/
    riscv-gnu-toolchain/<version>/
  python/
    cocotb-venv/
  cache/
  downloads/
```

版本管理策略：

- 将每个主工具安装至 `opt/<工具名>/<版本号>/` 下。
- 仅对所选默认版本，在 `$RISCV_CORE_TOOLS/bin` 中建立符号链接。
- 将源码检出存放在 `$RISCV_CORE_TOOLS/src`。
- 将下载的归档文件存放于 `$RISCV_CORE_TOOLS/downloads` 以便可重复安装。
- 保持项目代码仓库中不含任何生成的二进制文件与下载的归档文件。

示例 shell 入口脚本：

```sh
# $RISCV_CORE_TOOLS/env/riscv-core-env.sh
# 设置工具链根目录
export RISCV_CORE_TOOLS="$HOME/.local/riscv-core-tools"

export PATH="$RISCV_CORE_TOOLS/bin:$PATH"
export PATH="$RISCV_CORE_TOOLS/opt/oss-cad-suite/current/bin:$PATH"
export PATH="$RISCV_CORE_TOOLS/opt/verible/current/bin:$PATH"
export PATH="$RISCV_CORE_TOOLS/opt/riscv-gnu-toolchain/current/bin:$PATH"

# 若 cocotb 虚拟环境存在，则激活
if [ -f "$RISCV_CORE_TOOLS/python/cocotb-venv/bin/activate" ]; then
  . "$RISCV_CORE_TOOLS/python/cocotb-venv/bin/activate"
fi
```

每个开发终端都应显式 source 该文件：

```sh
. "$HOME/.local/riscv-core-tools/env/riscv-core-env.sh"
```

## 工具安装计划

### 1. 系统软件包

通过主机包管理器安装操作系统层面的构建依赖。这些并非项目专属，保持在系统层面是合理的：

- C/C++ 编译器及构建工具。
- `git`、`make`、`cmake`、`autoconf`、`automake`、`libtool`。
- Python 3 与 `python3-venv`。
- Verilator 与 RISC-V GNU 工具链所需的常见库。

在 Debian/Ubuntu 类系统上，可使用 `apt` 安装。具体软件包名称可稍后在 `scripts/env/install-ubuntu-deps.sh` 中记录。

### 2. Verilator

推荐安装位置：

```text
$RISCV_CORE_TOOLS/src/verilator/
$RISCV_CORE_TOOLS/opt/verilator/<版本号>/
```

推荐方法：

- 基于已知版本的官方源码仓库构建。
- 配置时使用 `--prefix=$RISCV_CORE_TOOLS/opt/verilator/<版本号>`。
- 创建符号链接 `opt/verilator/current` 指向所选版本。
- 将 `opt/verilator/current/bin` 加入 `PATH`，或将选定的二进制文件链接至 `$RISCV_CORE_TOOLS/bin`。

理由：

- 发行版提供的包可能落后于当前 SystemVerilog 支持。
- 带版本的前缀使升级与回滚更简单。

参考：https://verilator.org/guide/latest/install.html

### 3. OSS CAD Suite

推荐安装位置：

```text
$RISCV_CORE_TOOLS/opt/oss-cad-suite/<版本号>/
```

推荐方法：

- 下载官方发布归档文件。
- 将其解压至对应版本的安装目录下。
- 创建符号链接 `opt/oss-cad-suite/current` 指向所选版本。
- 将 `opt/oss-cad-suite/current/bin` 加入 `PATH`。

理由：

- OSS CAD Suite 已以二进制工具发行版形式打包。
- 它提供了一套连贯的 Yosys、SymbiYosys、求解器及相关工具。

参考：https://github.com/YosysHQ/oss-cad-suite-build

### 4. Verible

推荐安装位置：

```text
$RISCV_CORE_TOOLS/opt/verible/<版本号>/
```

推荐方法：

- 下载面向当前主机平台的最新官方发布归档文件。
- 将其解压至对应版本的安装目录下。
- 创建符号链接 `opt/verible/current` 指向所选版本。
- 将 `opt/verible/current/bin` 加入 `PATH`。

用例：

- `verible-verilog-format`：代码格式化。
- `verible-verilog-lint`：风格检查。
- `verible-verilog-ls`：编辑器语言服务器支持。

参考：https://github.com/chipsalliance/verible

### 5. RISC-V GNU Toolchain

推荐安装位置：

```text
$RISCV_CORE_TOOLS/src/riscv-gnu-toolchain/
$RISCV_CORE_TOOLS/opt/riscv-gnu-toolchain/<版本号>/
```

推荐方法：

- 从官方源码仓库构建。
- 配置时使用带版本号的 `--prefix`。
- 若预期同时需要 RV32 和 RV64 构建，则启用 multilib。
- 优先使用裸机环境下的 `riscv64-unknown-elf-*` 工具链。

示例配置意图：

```sh
./configure \
  --prefix="$RISCV_CORE_TOOLS/opt/riscv-gnu-toolchain/<版本号>" \
  --enable-multilib
```

理由：

- 裸机 ELF 工具链是内核启动的首选目标。
- Multilib 使得同一编译器可面向 `rv32i`、`rv32im`、`rv64i`、`rv64im` 等变体。

参考：https://github.com/riscv-collab/riscv-gnu-toolchain

### 6. cocotb

推荐安装位置：

```text
$RISCV_CORE_TOOLS/python/cocotb-venv/
```

推荐方法：

- 创建 Python 虚拟环境。
- 在该虚拟环境中安装 cocotb 及项目 Python 测试依赖。
- 后续应将 Python 依赖固定记录在 `requirements-dev.txt` 中。

理由：

- Python 依赖应与系统 Python 隔离。
- 该虚拟环境可在不影响代码仓库的情况下重新创建。

参考：https://docs.cocotb.org/en/stable/install.html

### 7. RISC-V 测试代码仓库

推荐源码位置：

```text
$RISCV_CORE_TOOLS/src/riscv-tests/
$RISCV_CORE_TOOLS/src/riscv-arch-test/
$RISCV_CORE_TOOLS/src/riscv-formal/
```

推荐的项目集成方式：

- 最初不要将整个测试仓库复制到本项目中。
- 添加脚本，构建选定的测试，并将生成的输出放入 `tests/generated/`。
- 记录每个外部测试套件所使用的精确上游提交。
- 如果版本固定对 CI 至关重要，后续可考虑使用 git 子模块。

参考：

- https://github.com/riscv-software-src/riscv-tests
- https://github.com/riscv/riscv-arch-test
- https://github.com/YosysHQ/riscv-formal

## 验证路线图

### 阶段 0：工具冒烟测试

目标：

- 确认工具链已安装并在 `PATH` 中可见。

检查项：

- `verilator --version`
- `verible-verilog-format --version`
- `yosys -V`
- `sby --version`
- `riscv64-unknown-elf-gcc --version`
- `python -c "import cocotb; print(cocotb.__version__)"`

### 阶段 1：最小 RTL 冒烟测试

目标：

- 使用 Verilator 编译顶层模块。
- 翻转复位与时钟。
- 加载微型指令内存映像。
- 至少退出一条已知指令。

预计仓库新增内容：

- `rtl/core/`
- `tb/verilator/`
- `sim/filelist.f`
- `sim/Makefile`

### 阶段 2：定向 ISA 测试

目标：

- 通过小段汇编测试验证每条已实现的指令。

测试类别：

- 整数 ALU 运算。
- 寄存器 `x0` 行为。
- 立即数译码。
- 加载与存储。
- 分支与跳转。
- 非对齐或未定义行为（待相关定义确定后）。

### 阶段 3：riscv-tests 集成

目标：

- 运行与 `RV32I` 相关的 `rv32ui` 测试。

方法：

- 使用 `riscv64-unknown-elf-gcc` 构建选定的测试。
- 将 ELF 文件转换为内存映像。
- 通过 Verilator 回归运行这些映像。
- 自动报告通过/失败。

### 阶段 4：cocotb 测试平台

目标：

- 增加高层次 Python 测试，以覆盖那些难以在纯 C++ 或 SystemVerilog 测试框架中表达的用例。

有用的检查：

- 小指令子集的随机指令流。
- 内存模型检查。
- 流水线停顿/冲刷场景。
- 针对架构寄存器状态的记分板比对。

### 阶段 5：RVFI 与 riscv-formal

目标：

- 添加 RVFI 包装层，证明已支持 ISA 子集的指令级行为。

方法：

- 在退级阶段附近定义并连接 RVFI 信号。
- 从单指令检查开始。
- 在流水线行为稳定后扩展证明范围。

### 阶段 6：架构测试与 CI

目标：

- 添加更广泛的架构测试与自动化回归。

方法：

- 集成选定的 `riscv-arch-test` 测试目标。
- 为格式化、语法检查、仿真冒烟测试与回归添加 CI 作业。
- 在文档与配置脚本中固定工具版本。

## 维护指南

- 在文档与配置脚本中明确记录工具版本。
- 除非有特定的调试原因，否则不要将生成的波形、仿真器构建目录或编译后的测试映像提交至仓库。
- 在生成的输出变得嘈杂之前，添加 `.gitignore` 规则。
- 所有常用操作优先使用 Makefile 或脚本目标。
- 保持安装脚本的幂等性，以便可安全重复执行。
- 记录用于验证的外部仓库提交。
- 每次仅升级一个主要工具，并在升级后重新运行完整回归。

## 推荐的后续文件

完成本计划之后，接下来有用的文件是：

- `scripts/env/check-tools.sh`：验证所需工具及版本。
- `scripts/env/riscv-core-env.sh`：项目环境入口脚本模板。
- `sim/Makefile`：首个 Verilator 仿真目标。
- `sim/filelist.f`：有序的 RTL 文件列表。
- `.gitignore`：排除生成的构建、波形与测试输出。
- `docs/verification-plan.md`：更详细的 ISA 与形式化验证检查清单。