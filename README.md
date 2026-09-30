# riscv-core：RV32E/RV32I 五级流水线 RTL

本项目以可综合 RTL 子集实现单发射、顺序执行/退休的 RV32E/RV32I 核心，并包含最小
M-mode 精确同步异常、Zicsr 与 Zifencei 支持。仓库提供 Verilator 模型构建，以及
基于开源工具的 ASIC 综合和布局前 STA 估算；尚未建立布局布线、CDC/RDC 与门级签核流程。

```text
CoreBus imem → IF → ID → EX → MEM → WB → retire/debug
                     ↑       │      │
                 寄存器堆  redirect  CoreBus dmem
```

`rtl/core/riscv_core_impl.sv` 是内部结构化核心，通过独立的指令和数据 CoreBus
interface 形成 Harvard 边界。流水、控制、CSR、调试、I-cache 内部协议及 AXI4 也使用
带 modport 的参数化 interface。公开顶层 `rtl/top/ysyx_25080230.sv` 在数据侧内接
CLINT（`mtime` 位于 `0x0200_bff8`），其余数据请求通过 CoreBus AXI4 适配器、取指请求
通过 I-cache 接入单路 AXI4 Master，并保持 mini-soc/Verilator 使用的
调试 ABI。

流水级之间统一使用 ready/valid 事务协议。IF 管理取指请求、旧路径响应丢弃和
IF/ID 队列；ID 负责译码、立即数和寄存器读取；EX 执行 ALU、分支、CSR 组合读取
和数据前递；MEM 用单比特在途标志管理顺序访存，背压 EX/MEM 保存元数据直到
响应进入 MEM/WB，支持同拍请求与响应；WB 是 GPR、CSR、trap 和 MRET 的
唯一架构提交点。

当前临时使用单指令多周期配置，SoC 取指侧已接入 I-cache。恢复流水线步骤见
[流水线和 cache 回退](docs/流水线和cache回退.md)。

## 实现范围

- RV32E/RV32I 整数、分支跳转、load/store、FENCE 与 Zifencei FENCE.I；
- ECALL、EBREAK、MRET 和六条 Zicsr 指令；
- `mstatus/mtvec/mepc/mcause/mtval` 及精确同步异常；
- 只读 64 位 CLINT `mtime`，每周期递增；
- CoreBus 零延迟响应及请求/响应背压；
- 单 outstanding 的数据 CoreBus 到 AXI4 转换；指令侧为流水线 I-cache；
- 暂不支持中断、其他特权级、M/C/F/A 扩展、MMU、D-cache 或分支预测。

`riscv_core_impl` 在 FENCE.I 精确退休当拍输出单周期 `icache_invalidate_o`，并从
`PC+4` 重取指。SoC 顶层将该输出接到 I-cache 的 `invalidate_i`。

仿真专用顶层 `rtl/top/riscv_core_sim.sv` 与 `ysyx_25080230` 并列，直接将核心的
imem/dmem CoreBus 连接到同文件内的 `mem_sim` 模块，通过 `IsDmem` 参数分别选择
`dpi_imem_read_sim` 或 `dpi_dmem_access_sim`。具体内存内容和地址映射由仿真环境提供。
退休调试和性能接口已展开为顶层标量及分类计数数组端口。仿真模型由 mini-soc
和 ysyx-soc 按各自 filelist 生成。

性能日志报告 IPC、退休指令数、周期数、分类局部阻塞均值和 imem/dmem 延迟、请求和响应
背压指标；ysyx-soc 额外报告 I-cache 命中率与命中/缺失延迟。统计口径见[性能计数器](docs/性能计数器.md)。

`riscv_core_sim` 提供四个仿真参数：`ImemResponseLatency`、`ImemMaxOutstanding`、
`DmemResponseLatency` 和 `DmemMaxOutstanding`，默认值分别为 `1、1、1、1`。
存储器模块内部按请求接受顺序缓存 DPI-C 返回值；响应延迟从请求握手开始计时，响应
背压不会改变已到期响应的数据。`ResponseLatency` 必须至少为 `1`，`MaxOutstanding`
必须大于零。DPI-C 函数仅在请求握手的上升沿调用，两个函数均通过输出参数返回访问错误：

```systemverilog
void dpi_imem_read_sim(addr, rdata, error)
void dpi_dmem_access_sim(addr, write, size, wdata, wstrb, rdata, error)
```

CoreBus 请求携带 `write` 与 `size`；`mem_sim` 调用 DPI-C 时据此推导 `wstrb`。
错误信号会随响应进入 `CoreBus.rsp_payload.error`；写响应的数据固定为零。

## 构建

```bash
make check # 用 yosys-slang 展开顶层，做综合语义检查
make perf  # 调用 yosys-sta，生成标准单元面积和时序报告
```

`make perf` 使用 [OSCPU/yosys-sta](https://github.com/OSCPU/yosys-sta) 的原生
Yosys + iSTA 流程，默认工艺为 **nangate45**（讲义 B 阶段面积预算约 25000 也按此库）。
依赖须提前安装，运行时不下载工具。本机安装位于 `~/.local/yosys-sta`，
`~/.zsh/env.zsh` 设置 `YOSYS_STA_HOME` 并将其 `bin` 加入 PATH；Yosys/slang 复用已有
OSS CAD Suite。nangate45 标准单元库从
[ysyx archive](https://ysyx.oscc.cc/slides/resources/archive/nangate45.tar.bz2)
解压到 `$YOSYS_STA_HOME/pdk/nangate45`。

本机固定版本：yosys-sta `72495ad5619a9d5053c3a2748db1b295d5df3fb4`。
其他机器请按上游 README 安装 iEDA，准备支持 slang 的 Yosys，并设置：

```sh
export YOSYS_STA_HOME="$HOME/.local/yosys-sta"
export PATH="$YOSYS_STA_HOME/bin:$PATH"
# 若尚未安装 nangate45：
#   mkdir -p "$YOSYS_STA_HOME/pdk" && cd "$YOSYS_STA_HOME/pdk" && \
#   wget -O - https://ysyx.oscc.cc/slides/resources/archive/nangate45.tar.bz2 | tar xfj -
make perf                           # 目标 5000 MHz，即 0.2 ns
make perf CLK_FREQ_MHZ=500          # 目标 500 MHz，即 2 ns
make perf PDK=icsprout55            # 对照 55nm 库（需已 clone icsprout55 PDK）
```

Makefile 只做两步：用 slang 显式传入 `-D SYNTHESIS` 读取固定的 `.slang/riscv_core.f`，通过 `proc` 将
SystemVerilog 降低，并用 `bwmuxmap` 展开内部位选择单元，导出 `build/perf/rtl.v`；
再调用上游 `make sta` 完成综合和时序分析。
每次运行都重新转换，并用 `make -B` 强制上游重新综合、分析。
参数为 `TOP=ysyx_25080230`、`CLK_PORT_NAME=clock`、
`CLK_FREQ_MHZ=5000`、`PDK=nangate45`；它们不改变固定文件列表所展开的 CPU。
第一版不提供任意模块评估接口，不再使用旧的 `PERF_*` 参数。

默认结果位于 `build/perf/ysyx_25080230-5000MHz/`，直接阅读上游输出：

- `synth_stat.txt`：标准单元面积和数量；`synth_check.txt`：综合结构检查。
- `ysyx_25080230.rpt`：时序汇总和关键路径。
- `.fanout`、`.cap`、`.trans`：扇出、电容和转换时间违例。
- `ysyx_25080230.netlist.v`：综合网表；`yosys.log`、`sta.log`：上游日志。

不另行生成摘要、JSON 或最高频率换算；目标频率不代表实现频率，负 slack 表示
未满足目标。命令失败会使 `make perf` 失败，旧版本遗留的 `build/perf/<顶层>/`
目录不属于新流程输出。阅读报告时也应检查综合警告及未约束路径。
结果是布局前估计，采用上游工艺库、映射策略和默认 SDC，不包含布线寄生。
上游功耗报告使用默认翻转率假设。nangate45 与 icsprout55 的面积/频率不可直接比较。

构建产物写入 `build/`。设计说明见 `docs/架构设计.md`，内部总线契约见
`docs/CoreBus接口.md`，编码和构建约定见 `docs/RTL开发约定.md`。复杂实现细节记录
在对应 RTL 的局部注释中。

### 综合时关闭调试与统计

`SYNTHESIS` 是统一的观测逻辑开关。未定义时保留现有退休调试接口、指令
`instid` 和性能统计，mini-soc / SoC 仿真端无需修改。定义后通过条件编译移除
调试端口和连线、IF 指令编号计数器及流水线编号、EX 之后仅供观测的指令字、
退休访存和改道记录、CSR 调试快照，以及全部流水线和访存性能计数器。
PC、译码及异常处理需要的指令字、真实 CSR 状态和 CLINT `mtime` 保留。

`make check` 和 `make perf` 在读取原始 RTL 时显式定义该宏，因此
`build/perf/rtl.v` 已不包含上述观测逻辑，不依赖后续综合优化删除它们。
仿真文件列表不定义该宏。仿真专用顶层即使裁剪观测端口，仍含 DPI 存储器模型，不能作为硬件综合顶层。

`make check` 执行 Yosys-Slang 综合语义检查。运行验证通过 AM 工作负载和 runner
差分完成，流程见工作台根目录 README。仿真模型由 mini-soc 与 ysyx-soc 构建。

## RV32E / RV32I 选择

默认 RV32E。独立构建用 `make check RVE=1` 或 `make check RVE=0`；外部 RTL
构建用 `-DRISCV_CORE_RVE=1` 或 `=0`，省略宏时默认 1。综合、仿真和 perf
使用同一选择；mini-soc、ysyx-soc 从 runner 契约推导该宏。

指令寄存器编码保持 5 位，E 模式只实现 x1–x15，x0 硬连零。实际操作数引用
x16–x31 时产生非法指令异常，mtval 保存原指令；CSR zimm、移位量和 FENCE
保留字段不受寄存器数量限制。`check` 对所选模式执行综合语义检查。
