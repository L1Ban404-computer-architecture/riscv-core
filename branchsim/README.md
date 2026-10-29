# Branchsim：分支方向预测与存储预算扫描

BTB 支持参数化的原 PC 标签位宽 `P` 和目标 PC 低位宽度 `T`。批量扫描默认只测 **Bimodal/RR**，遍历 **BHT 4/8/16/32 项、P=8/12/16/20、T=8/12/16/20/24**，BTB、BHT 与替换状态的总逻辑存储预算为 **360 位**，比较容量分配、标签混叠及错误目标对 MPKI 的影响。单配置 `sim` 的默认参数独立于扫描网格，仍为 BTFN、P=8/T=16。

## 预测与训练

每次查询先以 `(pc >> 2) & (sets - 1)` 选择组，再比较 `(pc >> 2)` 的低 `P` 位。命中后重建目标：

```text
mask = (1 << T) - 1                     # T=32 单独处理
predicted_target = (current_pc & ~mask) | stored_target_low
```

例如 `P=8`、`T=16` 时，标签比较当前 `pc[9:2]`；目标为 `{current_pc[31:16], stored_target[15:0]}`。训练时也用截断标签匹配已有项，同标签的不同原 PC 会合并更新，模型不会额外用完整 PC 排除别名。单配置模拟器仍支持 `P=30`、`T=32` 完整地址参考，但该组合不属于当前批量扫描的位宽候选。

BTFN 的 `backward` 位在训练时由完整原 PC 和真实目标计算并保存。这样，跨地址段分支即使目标重建错误，方向规则仍保持原意；完整命中要求方向正确，且实际跳转时目标也正确。`not-taken` 只控制条件分支，命中 BTB 的 JAL 仍预测跳转。条件分支无论是否 taken 都训练，JAL 训练，JALR 不训练；LRU 在训练时更新，查询不更新替换状态。

### Bimodal 动态方向预测

`BHT=bimodal` 用 PC 字地址索引一张独立的二位饱和计数器表：

```text
index = (pc >> 2) & (M - 1)
predict_taken = counter[index] >= 2
counter[index] = taken ? min(counter[index] + 1, 3) : max(counter[index] - 1, 0)
```

计数器冷启动为 `01`（弱不跳转），`00/01` 预测不跳转，`10/11` 预测跳转。饱和状态能容忍一次相反结果，避免一次循环退出立即改变长期倾向。不同 PC 可能共享计数器，这是实际索引冲突，不会通过隐藏的完整 PC 标签区分。

预测在训练之前发生，只使用当前 PC 和此前状态。只有真实条件分支更新计数器；无论 BTB 是否命中都会训练，JAL、JALR 和普通指令均不训练。BTB 未命中时仍顺序取指，动态方向表不会凭空提供目标；命中 JAL 时仍无条件预测跳转。BTFN 和 not-taken 继续保留为显式可选的对照策略。

**每条退休指令都查询预测器。** 缩短标签后，普通指令也可能命中其他 PC 留下的跳转项，这类假跳转同样计入误预测。统计分别保留 `control_flow` 和 `non_control_flow`，两者误预测次数之和等于总数：

```text
MPKI = 全部退休指令上的误预测次数 / 全部退休指令数 × 1000
```

`total`、实际/预测 taken 与 not-taken 分组现在覆盖全部退休指令，控制流命中率单列为 `control_flow_hit_rate`。与旧版只统计控制流相比，新增的普通指令假跳转会提高 MPKI；完整地址参考不受这类截断别名影响。

## 触发器核算

横轴使用设计声明的逻辑寄存器位数，按数据字段和实际替换策略计算：

```text
N = sets × ways
每项位数 = P + T + 3                    # valid、分支/JAL 类型、backward 各 1 位
RR 替换状态 = sets × ceil(log2(ways))
LRU 替换状态 = N × ceil(log2(ways))
BTB 触发器数 = N × 每项位数 + 替换状态
BHT 触发器数 = Bimodal: 2 × M；BTFN/not-taken: 0
总触发器数 = BTB 触发器数 + BHT 触发器数
```

当前扫描总预算为 **360 位**，BTB、替换状态与动态 BHT 的合计须落在预算内；表项数随位宽、几何和 BHT 容量变化。单路替换状态为 0，关闭 BTB 为 0。各方向策略使用同一 BTB 表项格式，动态模型也保留原有 backward 位的成本。`P=8`、`T=16` 的 1 组 4 路 RR 为 `4 × 27 + 2 = 110` 位，2 组 4 路 RR 为 `8 × 27 + 4 = 220` 位；同几何 LRU 为 `8 × 27 + 16 = 232` 位。2 组 4 路、16/16 位的 BTB 占 284 位，加上 32 项 Bimodal 的 64 位后，总计 **348 位**。

核算保留标签中的组索引重合位，以及目标字段的低两位对齐位，不做综合常量或冗余消除；因此它描述逻辑存储成本，综合后的 DFF 单元数、面积和时序需要另测。软件 `Entry` 的 `uint32_t` 容器大小不计入硬件成本。

## 对应的 RTL 实现

核心默认采用 **Bimodal[16]、1 组 4 路 RR、P=10/T=16**，配置集中在 [`riscv_core_pkg.sv`](../rtl/core/riscv_core_pkg.sv)。P10 不在当前批量扫描的默认网格内；单独回放同一 microbench train 轨迹得到 MPKI **73.024917**，按扫描统一格式计费为 150 位。此前 P12 单组配置为 158 位、MPKI 72.756013。[`branch_predictor.sv`](../rtl/core/units/branch_predictor.sv) 管理 BTB、RR 指针和 BHT；IF 负责采纳并锁存预测，当前临时旁路 IF/ID 缓冲，快照随取指回应直达 ID，再经 ID/EX 送到 EX；EX 负责执行、纠错和筛选训练事件。

RTL 比扫描的通用存储格式更紧凑：移除 Bimodal 不使用的 `backward` 位，省去 B/J 目标恒零的 bit 0，保留 bit 1 以正确处理未跳转的非对齐分支目标。因此预测器存储为：

```text
BTB = 4 × (valid 1 + tag 10 + target[15:1] 15 + kind 1) + RR 2 = 110 位
BHT = 16 × 2 = 32 位
预测器合计 = 142 位
```

这与扫描模型的 **150 位逻辑预算**描述同一 P10 配置，8 位差额来自每项移除 backward 和目标 bit 0。查询接口传 10 位标签、返回 16 位预测结果（taken + target[15:1]）；EX→IF 训练 payload 为 27 位（tag 10 + target 15 + kind 1 + taken 1）。目标高位在 IF 用当前 PC 重建，不经过训练总线。

本轮补跑 P12 单组基线，再将标签缩为 P10，均使用 RV32E、完整 `ysyx_25080230` 顶层、Nangate45、1000 MHz 约束：

| 指标 | P12：1组4路、T16、BHT16 | 当前 P10：1组4路、T16、BHT16 |
| --- | ---: | ---: |
| 预测器逻辑存储位数 | 150 | 142 |
| 完整顶层 DFF_X1 数量 | 2850 | 2842 |
| 映射单元面积（µm²） | 24595.158 | 24371.984 |
| 全局最差 setup slack（ns） | -0.176 | -0.194 |
| 最长数据到达时间（ns） | 1.137 | 1.156 |
| 报告估算频率（MHz） | 850.351 | 837.703 |

P10 完整顶层面积减少 **0.91%**，报告估算频率下降 **1.49%**，最差 slack 恶化 **18 ps**；最差路径从 ID/EX 寄存器到取指请求 PC 的 `imem_bus.req_payload_51__reg_p`。标签缩短在本次综合中节省面积，但没有改善时序。两种配置均未满足 1 GHz；结果为综合后的理想连线 STA，未进行布局布线。报告和对应 package 快照保存在 [`../build/branch-config/pc12-s1-w4-h16/`](../build/branch-config/pc12-s1-w4-h16/) 与 [`../build/branch-config/pc10-s1-w4-h16/`](../build/branch-config/pc10-s1-w4-h16/)。

P10 单独回放有 **13,982,625** 次总误预测（控制流 13,932,610，普通指令假跳转 50,015），相对 P12 的 13,931,136 次增加 **0.37%**。原始日志见 [`build/sim-p10-s1-w4-h16.log`](build/sim-p10-s1-w4-h16.log)。批量网格仍为 P8/12/16/20，报告中的单组 P12 项继续作为参考，不将其标为当前 RTL 的测量。

以下为此前在相同 RV32E、完整 `ysyx_25080230` 顶层、Nangate45、1000 MHz 约束下，对 P8 单组配置与 P12 双组配置的历史综合对照。

| 指标 | 旧配置：1组4路、P8/T16、BHT16 | 此前配置：2组4路、P12/T16、BHT16 |
| --- | ---: | ---: |
| 预测器逻辑存储位数 | 134 | 268 |
| 完整顶层 DFF_X1 数量 | 2834 | 2968 |
| 映射单元面积（µm²） | 24145.618 | 25496.898 |
| 全局最差 setup slack（ns） | -0.151 | -0.182 |
| 最长数据到达时间（ns） | 1.109 | 1.140 |
| 报告估算频率（MHz） | 868.456 | 846.337 |

该双组配置完整顶层面积增加 **5.60%**，报告估算频率下降 **2.55%**，最差 slack 恶化 **31 ps**。最差路径从 ID/EX 寄存器经过前端控制逻辑，到取指请求 PC 的 `imem_bus.req_payload_38__reg_p`；BHT 训练门控也仍有负 slack。两种配置均未满足 1 GHz。结果为综合后的理想连线 STA，未进行布局布线。原始报告位于 [`../build/branch-config/baseline/`](../build/branch-config/baseline/) 和 [`../build/branch-config/pc12-s2-w4-h16/`](../build/branch-config/pc12-s2-w4-h16/)。

取指请求被接受时锁存预测方向和压缩目标，随指令传到 EX。EX 比较方向，并在实际跳转时将快照目标与本条指令 PC 高位拼接，再核对完整实际目标，覆盖普通指令假跳转、JALR 别名及跨 64 KiB 的错误目标。BTB 后续训练、替换和前端停顿均不改变已采纳的预测快照。

每处快照为 **16 位 = taken 1 + target[15:1] 15**。保留 IF/ID 缓冲时，取指元数据、IF/ID、ID/EX 三处合计 48 位；当前直连版本仅在取指元数据和 ID/EX 保存，共 **32 位**。EX 只依赖自身 ID/EX 输入，不观察前端 PC 或缓冲占用状态。

ID 计算 B 型分支和 JAL 的 `PC+imm`，在 ID/EX 的 `exec_data.direct_target` 中独立保存完整 32 位目标。EX 不再为 B/J 重新相加；JALR 通过通用 ALU 计算 `rs1+imm`，再由 [`branch_unit.sv`](../rtl/core/units/branch_unit.sv) 清除 bit 0。分支单元只判断条件和选择目标，已移除上一轮专用 EX 分支加法器。

EX 的预测纠错、目标非对齐异常和退休分支目标使用分支单元输出。BTB/BHT 训练仅接受合法 B/J，目标直接来自 ID/EX 的 `direct_target`，使能只检查上游异常和实际跳转时的目标对齐，避开通用 EX 的访存异常及 JALR/ALU 目标选择链。

预测器只复位 valid、RR 和 BHT；标签、目标、类型由 valid 屏蔽。FENCE.I 当拍屏蔽预测，并在时钟沿清空 BTB 和复位 BHT，优先于同拍训练，同时通过正常 flush 取消旧指令及其预测快照。

回归入口：

```sh
make -C riscv-core check RVE=1
make -C mini-soc lint
make -C ysyx-soc lint
make -C riscv-core perf RVE=1 PERF_OUT=../build/branch-config/pc10-s1-w4-h16
make -C am-kernels/tests/cpu-tests ARCH=runner ALL=dummy DUT=npc REF=nemu run
make -C am-kernels/rt-thread-am/bsp/abstract-machine ARCH=runner DUT=npc REF=nemu run
make -C am-kernels/tests/cpu-tests ARCH=runner ALL=dummy DUT=soc REF=nemu run
make -C am-kernels/rt-thread-am/bsp/abstract-machine ARCH=runner DUT=soc REF=nemu run
```

本轮 RTL check、mini-soc lint、dummy 的外层 PASS 与 NEMU 差分通过；RT-Thread 完成启动、help 全部输出并返回 `msh >`，无差分错误，随后仅向本次 runner 发送 SIGINT，使常驻 shell 正常收尾。当前 P10 配置的日志位于 [`../build/branch-config/pc10-s1-w4-h16-validation/`](../build/branch-config/pc10-s1-w4-h16-validation/)，此前 P12 单组和双组配置的日志分别保留在 [`../build/branch-config/pc12-s1-w4-h16-validation/`](../build/branch-config/pc12-s1-w4-h16-validation/) 和 [`../build/branch-config/validation/`](../build/branch-config/validation/)。本轮未重跑完整 SoC 功能测试。离线 MPKI 对应退休轨迹顺序训练；RTL 在 EX 训练，流水线延迟和推测执行会影响实际统计。

当前保留 `fetch_result` 直连 ID，功能 IF/ID 缓冲与退休观察侧的对应缓冲继续注释。ID 的背压直接传给取指回应；IF 仍在改道当拍取消错误路径输出，ID/EX 的预测快照和原有刷新规则保留。

综合使用相同的 RV32E、`ysyx_25080230` 顶层（含 I-cache、AXI 适配与 CLINT）、Nangate45、1000 MHz 约束和仓库 `perf` 流程：

| 指标 | 训练控制解耦（旧预测器配置） | ALU 独立加法输出（已回退） |
| --- | ---: | ---: |
| 预测器存储位数 | 134 | 134 |
| 完整顶层 DFF_X1 数量 | 2834 | 2834 |
| 映射单元面积（µm²） | 24145.618 | 23890.258 |
| 全局最差 setup slack（ns） | -0.151 | -0.242 |
| 最长数据到达时间（ns） | 1.109 | 1.210 |
| 报告估算频率（MHz） | 868.456 | 805.193 |

已回退的实验只在 ALU 增加 `add_result_o`，ADD 指令与 JALR 共用同一加法表达式，JALR 绕过最终运算结果选择；保留原有操作数选择、预测目标比较和训练控制。综合面积下降 **1.06%**，DFF 数不变，全局最差 slack 恶化 **91 ps**，本次测量没有时序收益。新最慢路径仍从 ID/EX 的 `op_b_sel` 出发，经过 EX 纠错及前端控制，到 I-cache 的 `miss.rsp_valid` 寄存器；IF PC 路径也仍有 -0.231 ns 违例。该实验已按要求回退，RTL 恢复到训练控制解耦版本：最差 slack -0.151 ns，面积 24145.618 µm²，2834 个 DFF。1 GHz 约束仍未收敛。以上时序为综合后的理想连线 STA。

前一轮训练控制解耦将 BHT 训练门控 slack 从 -0.139 ns 改善到 -0.070 ns，面积从 24268.510 µm² 降到 24145.618 µm²，但全局 slack 从 -0.139 ns 变为 -0.151 ns；当前继续保留该修改。

上一步 B/J 目标提前到 ID，DFF 从 2802 增加到 2834，面积从 23767.100 µm² 增加到 24268.510 µm²，slack 从 -0.211 ns 改善到 -0.139 ns；本轮继续保留该结构。

前次旁路 IF/ID 将 DFF 从 2916 降到 2802，面积从 24584.518 µm² 降到 23767.100 µm²，slack 从 -0.206 ns 变为 -0.211 ns；当前继续保留该直连结构。上一轮专用 EX 分支加法器的 slack 为 -0.217 ns、面积为 24292.716 µm²，未显示收益，已按要求撤销。

ID 目标预计算版本的 mini-soc 与完整 SoC 的 dummy 外层汇总及 NEMU 差分均为 PASS；两种 DUT 的 RT-Thread 均完成启动、help 全部输出并返回 `msh >`，无差分错误。完整 SoC 验证覆盖实际 I-cache 取指与背压路径。RT-Thread 在看到完整 shell 输出后仅向本次 sim-runner 发送 SIGINT，保留外层 make 完成自动追踪；退出码 130 是主动结束常驻 shell 的结果。

训练控制解耦和已回退的 ALU 独立加法输出实验均按要求只运行综合和 STA，未重复运行功能验证；上述功能回归对应训练控制解耦之前的 ID 目标预计算版本。本次回退逐字节核对了三个 RTL 文件与该实验前的备份，未重新综合或运行功能验证。

## 运行

在工作区根目录执行，使用当前 runner 契约和 Python 3.11+，无需额外 Python 包：

```sh
export YSYX_HOME="$PWD"
export AM_HOME="$PWD/abstract-machine"
export RISCV_CORE_HOME="$PWD/riscv-core"

# 单配置回放；sim 要求轨迹已经存在。
make -C riscv-core/branchsim sim BHT=btfn BTB_SETS=1 BTB_WAYS=4 \
  BTB_POLICY=rr PC_BITS=8 TARGET_BITS=16

# 动态预测单配置回放。
make -C riscv-core/branchsim sim BHT=bimodal BHT_ENTRIES=32 \
  BTB_SETS=2 BTB_WAYS=4 PC_BITS=16 TARGET_BITS=16

# 显式增加 BTFN 对照，仍使用 360 位预算及当前位宽网格。
make -C riscv-core/branchsim run DSE_ARGS='--bht btfn bimodal'

# 完整默认扫描。轨迹缺失时，先用 NEMU 采集 microbench train。
make -C riscv-core/branchsim run

# 只比较部分位宽，各自遍历预算内全部几何和 BHT 容量。
make -C riscv-core/branchsim run \
  DSE_ARGS='--pc-bits 8 12 --target-bits 16 20 --jobs 4'

# 固定 8/16 位宽，复用指定轨迹。
make -C riscv-core/branchsim run TRACE=/path/to/runner-insttrace.bin \
  DSE_ARGS='--pc-bits 8 --target-bits 16 --ff-budget 260'

# 显式扩展策略对照（默认不测 not-taken/LRU）。
make -C riscv-core/branchsim run DSE_ARGS='--bht btfn not-taken --policies rr lru'

# 默认扫描数据只重建报告，不重复回放。
make -C riscv-core/branchsim run DSE_ARGS='--report-only'

make -C riscv-core/branchsim check-model check-dse
```

默认扫描 `P=8/12/16/20`、`T=8/12/16/20/24`，方向策略仅 Bimodal，BHT 为 4/8/16/32 项，替换策略仅 RR。组数与路数均遍历 2 的整数幂，且路数至少为 2。每个候选都按实际位宽、替换状态及 BHT 核算，满足 `total_ff ≤ 360` 才纳入测试。默认网格覆盖 **10 种组路几何**，各位宽和 BHT 容量允许的几何不同，共 **453 个表配置＋1 个关闭 BTB 基线＝454 个配置**，最多 16 项。16 项仅在窄位宽下可行，例如 1 组 16 路 RR、P=8/T=8、BHT4 的总成本为 `16 × 19 + 4 + 8 = 316` 位。

`--bht-entries` 指定计数器个数，须为正的 2 的幂，单配置默认 32 项、批量默认比较 4/8/16/32 项。预算过滤后，BHT4/8/16/32 分别有 **121/115/115/102** 个表配置。静态策略将此参数归一为 0，不产生重复配置；所有算法共用一个关闭 BTB 基线。

扫描的原 PC 位宽只能从 8/12/16/20 中选取，目标位宽只能从 8/12/16/20/24 中选取。`--ff-budget` 可收紧预算（1～360 位）；`--entries-min`、`--entries-max` 和 `--ways-max` 可额外限制总条目数和路数，默认不设置上限。指定它们时仍须满足存储预算。单配置 Make 变量用于 `sim`，批量扫描参数通过 `DSE_ARGS` 传入，完整参数见 `cd riscv-core/branchsim && python3 -m dse --help`。`BUILD_DIR` 可覆盖产物目录；已有轨迹会直接复用，切换负载或契约时应使用新的 `TRACE` 路径采集。

## 图表与数据

输出默认保存在 `build/`，所有配置使用同一条完整退休轨迹并从空表开始：

| 文件 | 内容 |
| --- | --- |
| [dse.html](build/dse.html) | 仿照 cachesim 的全配置散点页，横轴为 BTB+BHT 总逻辑触发器数，纵轴为 MPKI |
| [dse.csv](build/dse.csv) | 全部整数计数、七类分组比率、位宽、BHT 规模及 BTB/BHT/替换状态成本 |
| [dse.md](build/dse.md) | 单组 P12 参考配置、各 BHT 容量最优配置、固定 BTB 的方向预测对照、Pareto 前沿、输入 SHA-256 |
| `dse/logs/*.log` | 每个配置的模拟器原始输出 |

多算法对照时图表默认以方向算法着色，单算法时按目标位宽着色；形状默认区分原 PC 位宽，BHT 计数器个数也可筛选或用作标签。也可以选择方向策略、替换策略、组数、路数、表项数等参数作为标签。点击图例或下拉框可筛选，也可以输入触发器预算和 MPKI 上下限。MPKI 边界包含端点，留空表示该方向不限制；散点、明细表和 CSV 导出同时应用筛选。帕累托前沿默认按当前筛选重新计算，还可切换全局前沿、仅看前沿点。成本和 MPKI 都越低越好；同一坐标保留一个前沿代表，重合配置可通过悬停或筛选查看。明细表支持排序和下载当前筛选 CSV。

全部配置成功且各项输入计数一致后才发布报告。输入文件在扫描期间改变会报错；失败时保留此前报告，应以命令退出状态及摘要的输入记录识别本轮结果。原 141 点 BTFN 对照保留在 `build/archive-btfn-power2/`；前一轮“520 位预算、任意整数路数”的结果已移至 `build/archive-budget-integer-ways/`；更早的“两种策略、8 项以内”结果在 `build/archive-width-entry8/`；旧版完整 PC 结果在 `build/archive-full-pc/`，更早的大范围结果在 `build/archive-wide-sweep/`。

`--report-only` 会重新核对输入文件的 SHA-256、全部计划点、CSV 与逐点原始日志，再生成报告。它要求提供与原扫描相同的参数；输入或配置不一致时会报错，不会复用未验证的数据。

## 当前 360 位预算的 microbench train 测量

重新通过 NEMU 采集 RV32E microbench train，得到 191,477,451 条退休指令，其中控制流 56,486,890 条、普通指令 134,990,561 条。默认 **454 个配置全部回放成功**；通过 `--report-only` 重新校验输入 SHA-256、全部计划点、CSV 与逐点日志。完整结果见 [交互散点图](build/dse.html)、[摘要](build/dse.md) 和 [CSV](build/dse.csv)。

360 位预算下，各 BHT 容量的最低 MPKI 均来自 **2 组 4 路 RR、P=16/T=16**：

| BHT 项数 | BTB 位数 | BHT 位数 | 总逻辑位数 | 总误预测次数 | MPKI |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 4 | 284 | 8 | 292 | 14,211,276 | 74.219058 |
| 8 | 284 | 16 | 300 | 13,375,381 | 69.853557 |
| 16 | 284 | 32 | 316 | 13,079,437 | 68.307975 |
| 32 | 284 | 64 | 348 | 12,968,673 | 67.729505 |

本轮最低 MPKI 相对此前 RTL 参数对应的模型配置（1 组 4 路、P=8/T=16、BHT16，142 位，MPKI 73.231307）减少 **7.51%** 的误预测。该对比同时增加了 BTB 容量、标签位宽和 BHT 容量。

若将最优配置的标签从 16 位缩为 **12 位**，其余保持 2 组 4 路、T=16、BHT32，总成本由 348 位降至 **316 位**，总误预测仅增加 **1 次**，MPKI 为 **67.729510**。这一配置在本条轨迹上节省 32 位而几乎不损失准确率；是否适合其他程序仍需相应轨迹验证。

固定此前 RTL 参数中的 BTB（1 组 4 路、P=8/T=16），BHT4/8/16/32 的 MPKI 分别为 **79.080962 / 74.810339 / 73.231307 / 73.159732**，16 项以上的方向表收益在这个小 BTB 配置下已较小。

以上位数沿用 branchsim 的统一存储模型，包含 RTL 可优化的字段；MPKI 来自退休轨迹顺序回放，不包含流水线训练延迟和错误路径。RTL 当前采用 1 组 4 路、P10/T16、BHT16，配置及独立回放结果见上方“对应的 RTL 实现”。

## 此前 520 位预算的 microbench train 测量

以下为此前 520 位预算、旧位宽网格及 BHT16/32/64 的历史结果，不代表当前 360 位默认网格。该轮 RV32E 轨迹包含 191,477,451 条退休指令，其中控制流 56,486,890 条、普通指令 134,990,561 条。521 个配置均成功回放，141 个 BTFN 基线配置的计数与旧模型完全一致。当前扫描的数据与前沿见 [dse.md](build/dse.md) 和 [dse.csv](build/dse.csv)。

| 对照条件 | BTFN MPKI | Bimodal MPKI | 误预测减少 |
| --- | ---: | ---: | ---: |
| 相同总成本 110 位 | 97.781049 | 80.155673 | 18.03% |
| 相同总成本 142 位 | 97.342083 | 73.231307 | 24.77% |
| 相同总成本 284 位 | 93.749561 | 69.408021 | 25.96% |
| 同一 520 位预算内各取最优 | 93.716173 | 66.732333 | 28.79% |

等成本对照允许重新分配标签、目标和计数器存储。例如 142 位的 BTFN 使用 1 组 4 路、16/16 位标签/目标；Bimodal 则使用同样 1 组 4 路、8/16 位标签/目标，把省下的 32 位用于 16 项二位计数器。

固定 1 组 4 路、30/32 位且只改变方向算法时，BTFN 的 MPKI 为 97.342073，32 项 Bimodal 为 72.690742；总成本分别为 262 和 326 位。这一对照单独显示方向学习的收益。

本次网格内最低 MPKI 为 **66.732333**：1 组 16 路、PC 8 位/目标 16 位、32 项 Bimodal，BTB 占 436 位、BHT 占 64 位，合计 **500 位**。它仍有 565,246 次普通指令假跳转，已全部计入总误预测，不能只凭条件分支命中率判断收益。


## 验证与适用范围

`make -C riscv-core/branchsim check-model check-dse` 通过：8 组模型回归及真实 CLI 轨迹用例覆盖标签 `pc[9:2]` 的边界、同标签训练合并、目标高位取自当前 PC、跨地址段 BTFN 方向保持、方向正确但目标错误、普通指令假跳转、30/32 位移位边界和非二次幂路数。12 项扫描回归核对新默认网格的 454 个完整组合、BHT4/8/16/32、360 位预算、二次幂几何与至少两路、替换状态成本，以及 12 位标签/20 位目标的端到端回放、报告范围和预算显示、报告重生及失败时保留旧报告。

20 条退休指令的前向分支/JAL 环测试中，BTFN 发生 11 次误预测，Bimodal 仅首个分支和 JAL 各一次冷缺失，共 2 次；对照使用同一 BTB，额外计入 4 项 BHT 的 8 位成本。报告数据按逐点原始日志和成本公式核对；HTML 的参数筛选、颜色/形状标签、当前/全局前沿、仅看前沿、重合点悬停、排序、CSV 下载和空结果状态在 Chromium 中验证。

工作区回归通过 Makefile 执行 dummy 和 RT-Thread，均使用 `ARCH=runner DUT=npc REF=nemu`。dummy 的 runner 诊断和外层汇总均 PASS；RT-Thread 完整输出启动信息、脚本 `help` 和 `msh >`，无差分错误后向本次 runner 发送 SIGINT，外层 Makefile 完成自动追踪。日志见 [bimodal-dummy.log](build/validation/bimodal-dummy.log) 和 [bimodal-rt-thread.log](build/validation/bimodal-rt-thread.log)。

本次修改归属 branchsim，未将新方向预测器或截断标签方案接入 RTL。实际落地时，执行端需要纠正普通指令假跳转和错误预测目标，不能沿用完整标签方案中仅比较方向的前提。当前回放采用退休顺序即时训练，未模拟流水线训练延迟、错误路径或失效；未测新设计的整机 IPC、`DUT=soc`、综合面积或频率。
