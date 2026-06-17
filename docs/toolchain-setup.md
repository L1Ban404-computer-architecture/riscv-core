# RISC-V 内核工具链配置

本文档记录了为本代码仓库安装的阶段 0 工具链。目标是在一台全新的 Ubuntu 24.04 x86_64 机器上可完整复现。

## 本次配置所用的主机

- 日期：2026-06-17
- 操作系统：Ubuntu 24.04.4 LTS，WSL2
- 内核：Linux 5.15.167.4-microsoft-standard-WSL2
- 架构：x86_64
- 工具根目录：`$HOME/.local/riscv-core-tools`

该系统初始状态下没有 `make`、`gcc`、`g++`、`cmake`、`unzip`、全局 `pip` 或可用的 `ensurepip`。因此阶段 0 流程优先使用官方二进制归档文件，并仅在项目的 cocotb 虚拟环境内引导安装 `pip`。

## 已安装的工具

| 工具 | 已安装版本 | 安装位置 |
| --- | --- | --- |
| OSS CAD Suite | 发布版本 `2026-06-17` | `$RISCV_CORE_TOOLS/opt/oss-cad-suite/2026-06-17` |
| Verilator | `5.049 devel rev v5.048-279-ga534a1d1b (mod)`，来自 OSS CAD Suite | `$RISCV_CORE_TOOLS/opt/oss-cad-suite/current/bin/verilator` |
| Yosys | `0.66+103`，git `e2903c4a5`，来自 OSS CAD Suite | `$RISCV_CORE_TOOLS/opt/oss-cad-suite/current/bin/yosys` |
| SymbiYosys | `SBY v0.66-4-gd3e72d2`，来自 OSS CAD Suite | `$RISCV_CORE_TOOLS/opt/oss-cad-suite/current/bin/sby` |
| Verible | `v0.0-4080-ga0a8d8eb` | `$RISCV_CORE_TOOLS/opt/verible/v0.0-4080-ga0a8d8eb` |
| RISC-V GNU Toolchain | 发布版本 `2026.06.06`，`riscv64-unknown-elf-gcc 16.1.0`，binutils `2.46` | `$RISCV_CORE_TOOLS/opt/riscv-gnu-toolchain/2026.06.06-riscv64-elf-ubuntu-24.04-gcc` |
| 用于 cocotb 的 Python | Python `3.12.3` 虚拟环境 | `$RISCV_CORE_TOOLS/python/cocotb-venv` |
| cocotb | `2.0.1` | `$RISCV_CORE_TOOLS/python/cocotb-venv` |
| find_libpython | `0.5.1` | `$RISCV_CORE_TOOLS/python/cocotb-venv` |

## 目录布局

实际顶层结构：

```text
$HOME/.local/riscv-core-tools/
  bin/
  downloads/
  env/
    riscv-core-env.sh
  opt/
    oss-cad-suite/
      2026-06-17/
      current -> 2026-06-17
    riscv-gnu-toolchain/
      2026.06.06-riscv64-elf-ubuntu-24.04-gcc/
      current -> 2026.06.06-riscv64-elf-ubuntu-24.04-gcc
    verible/
      v0.0-4080-ga0a8d8eb/
      current -> v0.0-4080-ga0a8d8eb
  python/
    cocotb-venv/
  src/
```

大致磁盘占用：

| 路径 | 大小 |
| --- | ---: |
| `$RISCV_CORE_TOOLS` | 6.2G |
| `$RISCV_CORE_TOOLS/downloads` | 1.2G |
| OSS CAD Suite 安装 | 2.4G |
| Verible 安装 | 42M |
| RISC-V GNU Toolchain 安装 | 2.5G |
| cocotb 虚拟环境 | 29M |

## 已下载的归档文件

以下文件缓存在 `$RISCV_CORE_TOOLS/downloads` 中。

| 文件 | 来源 URL | SHA256 |
| --- | --- | --- |
| `oss-cad-suite-linux-x64-20260617.tgz` | `https://github.com/YosysHQ/oss-cad-suite-build/releases/download/2026-06-17/oss-cad-suite-linux-x64-20260617.tgz` | `fe28f69db0c5013831292fba4f170568431bb96e685cdf363d73e02980473eb0` |
| `verible-v0.0-4080-ga0a8d8eb-linux-static-x86_64.tar.gz` | `https://github.com/chipsalliance/verible/releases/download/v0.0-4080-ga0a8d8eb/verible-v0.0-4080-ga0a8d8eb-linux-static-x86_64.tar.gz` | `f75daa70f29dbe9624ffee3738408341cfdadbdaf7e5d714a5bcceb9223953e6` |
| `riscv64-elf-ubuntu-24.04-gcc.tar.xz` | `https://github.com/riscv-collab/riscv-gnu-toolchain/releases/download/2026.06.06/riscv64-elf-ubuntu-24.04-gcc.tar.xz` | `373862418256887081e0876857076ec7852e71292b7e8c5518cf027fcb2d93b5` |
| `get-pip.py` | `https://bootstrap.pypa.io/get-pip.py` | `a341e1a43e38001c551a1508a73ff23636a11970b61d901d9a1cad2a18f57055` |

## 复现命令

在一台全新的 Ubuntu 24.04 x86_64 机器上执行以下命令。

### 1. 可选的系统软件包

以下软件包对于后续的 RTL 开发及源码构建会有帮助。如果采用下文的二进制归档流程，阶段 0 也可以在没有它们的情况下复现。

```sh
sudo apt-get update
sudo apt-get install -y \
  curl git tar xz-utils python3 python3-venv \
  build-essential make cmake autoconf automake libtool unzip
```

如果 `python3-venv` 不可用或 `ensurepip` 被禁用，请使用下面展示的 `--without-pip` 虚拟环境创建方式。

### 2. 创建工具目录

```sh
export RISCV_CORE_TOOLS="$HOME/.local/riscv-core-tools"

mkdir -p \
  "$RISCV_CORE_TOOLS/bin" \
  "$RISCV_CORE_TOOLS/downloads" \
  "$RISCV_CORE_TOOLS/env" \
  "$RISCV_CORE_TOOLS/opt" \
  "$RISCV_CORE_TOOLS/src" \
  "$RISCV_CORE_TOOLS/python"
```

### 3. 下载归档文件

```sh
curl -L \
  -o "$RISCV_CORE_TOOLS/downloads/oss-cad-suite-linux-x64-20260617.tgz" \
  "https://github.com/YosysHQ/oss-cad-suite-build/releases/download/2026-06-17/oss-cad-suite-linux-x64-20260617.tgz"

curl -L \
  -o "$RISCV_CORE_TOOLS/downloads/verible-v0.0-4080-ga0a8d8eb-linux-static-x86_64.tar.gz" \
  "https://github.com/chipsalliance/verible/releases/download/v0.0-4080-ga0a8d8eb/verible-v0.0-4080-ga0a8d8eb-linux-static-x86_64.tar.gz"

curl -L \
  -o "$RISCV_CORE_TOOLS/downloads/riscv64-elf-ubuntu-24.04-gcc.tar.xz" \
  "https://github.com/riscv-collab/riscv-gnu-toolchain/releases/download/2026.06.06/riscv64-elf-ubuntu-24.04-gcc.tar.xz"

curl -L \
  -o "$RISCV_CORE_TOOLS/downloads/get-pip.py" \
  "https://bootstrap.pypa.io/get-pip.py"
```

校验下载文件的完整性：

```sh
sha256sum \
  "$RISCV_CORE_TOOLS/downloads/oss-cad-suite-linux-x64-20260617.tgz" \
  "$RISCV_CORE_TOOLS/downloads/verible-v0.0-4080-ga0a8d8eb-linux-static-x86_64.tar.gz" \
  "$RISCV_CORE_TOOLS/downloads/riscv64-elf-ubuntu-24.04-gcc.tar.xz" \
  "$RISCV_CORE_TOOLS/downloads/get-pip.py"
```

将输出与上方 SHA256 表格比对，确认无误后再进行解压。

### 4. 解压工具

```sh
mkdir -p \
  "$RISCV_CORE_TOOLS/opt/oss-cad-suite/2026-06-17" \
  "$RISCV_CORE_TOOLS/opt/verible/v0.0-4080-ga0a8d8eb" \
  "$RISCV_CORE_TOOLS/opt/riscv-gnu-toolchain/2026.06.06-riscv64-elf-ubuntu-24.04-gcc"

tar -xzf \
  "$RISCV_CORE_TOOLS/downloads/oss-cad-suite-linux-x64-20260617.tgz" \
  -C "$RISCV_CORE_TOOLS/opt/oss-cad-suite/2026-06-17" \
  --strip-components=1

tar -xzf \
  "$RISCV_CORE_TOOLS/downloads/verible-v0.0-4080-ga0a8d8eb-linux-static-x86_64.tar.gz" \
  -C "$RISCV_CORE_TOOLS/opt/verible/v0.0-4080-ga0a8d8eb" \
  --strip-components=1

tar -xJf \
  "$RISCV_CORE_TOOLS/downloads/riscv64-elf-ubuntu-24.04-gcc.tar.xz" \
  -C "$RISCV_CORE_TOOLS/opt/riscv-gnu-toolchain/2026.06.06-riscv64-elf-ubuntu-24.04-gcc" \
  --strip-components=1
```

创建版本选择符号链接：

```sh
ln -sfn 2026-06-17 \
  "$RISCV_CORE_TOOLS/opt/oss-cad-suite/current"

ln -sfn v0.0-4080-ga0a8d8eb \
  "$RISCV_CORE_TOOLS/opt/verible/current"

ln -sfn 2026.06.06-riscv64-elf-ubuntu-24.04-gcc \
  "$RISCV_CORE_TOOLS/opt/riscv-gnu-toolchain/current"
```

### 5. 创建 cocotb 虚拟环境

如果目标机器上 `python3 -m venv "$RISCV_CORE_TOOLS/python/cocotb-venv"` 能够正常工作，则直接使用。在本主机上，`ensurepip` 不可用，因此先创建了不带 pip 的虚拟环境，再引导安装 pip：

```sh
python3 -m venv --clear --without-pip \
  "$RISCV_CORE_TOOLS/python/cocotb-venv"

"$RISCV_CORE_TOOLS/python/cocotb-venv/bin/python" \
  "$RISCV_CORE_TOOLS/downloads/get-pip.py"

"$RISCV_CORE_TOOLS/python/cocotb-venv/bin/python" \
  -m pip install cocotb
```

已解析的 Python 包为：

```text
cocotb==2.0.1
find_libpython==0.5.1
```

为了在 PyPI 版本更新后仍能精确复现，请安装指定的版本：

```sh
"$RISCV_CORE_TOOLS/python/cocotb-venv/bin/python" \
  -m pip install cocotb==2.0.1 find_libpython==0.5.1
```

### 6. 安装环境入口脚本

仓库中的环境脚本为：

```text
scripts/env/riscv-core-env.sh
```

如果需要，可将其复制到工具根目录：

```sh
cp scripts/env/riscv-core-env.sh \
  "$RISCV_CORE_TOOLS/env/riscv-core-env.sh"
```

在 shell 中启用工具链：

```sh
. scripts/env/riscv-core-env.sh
```

或：

```sh
. "$HOME/.local/riscv-core-tools/env/riscv-core-env.sh"
```

该脚本会导出以下变量：

```text
RISCV_CORE_TOOLS
RISCV_CORE_OSS_CAD_SUITE
RISCV_CORE_VERIBLE
RISCV_CORE_RISCV_GNU_TOOLCHAIN
RISCV
RISCV_CORE_COCOTB_VENV
PATH
VIRTUAL_ENV
```

## 冒烟测试

运行仓库中的检查脚本：

```sh
scripts/env/check-tools.sh
```

预期结果：

```text
All stage-0 tool checks passed.
```

观测到的主要输出：

```text
Verilator 5.049 devel rev v5.048-279-ga534a1d1b (mod)
Yosys 0.66+103 (git sha1 e2903c4a5, Release, Clang /usr/bin/clang++ 18.1.8)
SBY v0.66-4-gd3e72d2
Version v0.0-4080-ga0a8d8eb
riscv64-unknown-elf-gcc (g6afcc4f6d) 16.1.0
GNU objcopy (GNU Binutils) 2.46
Python 3.12.3
cocotb 2.0.1
```

此外，还在仓库外的 `/tmp/riscv-core-stage0-smoke` 下进行了一次手动冒烟测试：

- `riscv64-unknown-elf-gcc` 使用 `-march=rv32i -mabi=ilp32` 编译了一段小型 `RV32I` 汇编程序。
- `riscv64-unknown-elf-objcopy` 从 ELF 文件生成了 Intel HEX 文件。
- `riscv64-unknown-elf-objdump` 显示了 `elf32-littleriscv` 输出。
- `verilator --lint-only --sv` 接受了一个小型的 SystemVerilog 模块。
- `verible-verilog-lint` 也接受了该模块。
- `python -c 'import cocotb; print(cocotb.__version__)'` 打印出了 `2.0.1`。