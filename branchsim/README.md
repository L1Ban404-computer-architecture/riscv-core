# Branchsim：分支方向预测与存储预算扫描

BTB 支持参数化的原 PC 标签位宽 `P` 和目标 PC 低位宽度 `T`。默认使用 `P=8`、`T=16`；默认只测 **BTFN/RR**，以 **8 个完整 PC 条目的总逻辑存储位数**作为资源上限，比较位宽缩减、标签混叠及错误目标对 MPKI 的影响。

## 预测与训练

每次查询先以 `(pc >> 2) & (sets - 1)` 选择组，再比较 `(pc >> 2)` 的低 `P` 位。命中后重建目标：

```text
mask = (1 << T) - 1                     # T=32 单独处理
predicted_target = (current_pc & ~mask) | stored_target_low
```

例如 `P=8`、`T=16` 时，标签比较当前 `pc[9:2]`；目标为 `{current_pc[31:16], stored_target[15:0]}`。训练时也用截断标签匹配已有项，同标签的不同原 PC 会合并更新，模型不会额外用完整 PC 排除别名。`P=30`、`T=32` 是完整地址参考：原 PC 省去固定为零的两位指令对齐位，目标保存全部 32 位。

BTFN 的 `backward` 位在训练时由完整原 PC 和真实目标计算并保存。这样，跨地址段分支即使目标重建错误，方向规则仍保持原意；完整命中要求方向正确，且实际跳转时目标也正确。`not-taken` 只控制条件分支，命中 BTB 的 JAL 仍预测跳转。条件分支无论是否 taken 都训练，JAL 训练，JALR 不训练；LRU 在训练时更新，查询不更新替换状态。

### Bimodal 动态方向预测

`BHT=bimodal` 用 PC 字地址索引一张独立的二位饱和计数器表：

```text
index = (pc >> 2) & (M - 1)
predict_taken = counter[index] >= 2
counter[index] = taken ? min(counter[index] + 1, 3) : max(counter[index] - 1, 0)
```

计数器冷启动为 `01`（弱不跳转），`00/01` 预测不跳转，`10/11` 预测跳转。饱和状态能容忍一次相反结果，避免一次循环退出立即改变长期倾向。不同 PC 可能共享计数器，这是实际索引冲突，不会通过隐藏的完整 PC 标签区分。

预测在训练之前发生，只使用当前 PC 和此前状态。只有真实条件分支更新计数器；无论 BTB 是否命中都会训练，JAL、JALR 和普通指令均不训练。BTB 未命中时仍顺序取指，动态方向表不会凭空提供目标；命中 JAL 时仍无条件预测跳转。BTFN 继续保留为默认策略和对照。

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

完整 PC 参考条目按 `P=30/T=32` 计算，每项为 `30 + 32 + 3 = 65` 位，因此总预算为 **`8 × 65 = 520` 位**。BTB、替换状态与动态 BHT 的合计须落在预算内；表项数不再固定为 8。单路替换状态为 0，关闭 BTB 为 0。各方向策略使用同一 BTB 表项格式，动态模型也保留原有 backward 位的成本。`P=8`、`T=16` 的 1 组 4 路 RR 为 `4 × 27 + 2 = 110` 位，2 组 4 路 RR 为 `8 × 27 + 4 = 220` 位；同几何 LRU 为 `8 × 27 + 16 = 232` 位。2 组 4 路、16/16 位的 BTB 占 284 位，加上 32 项 Bimodal 的 64 位后，总计 **348 位**。

核算保留标签中的组索引重合位，以及目标字段的低两位对齐位，不做综合常量或冗余消除；因此它描述逻辑存储成本，综合后的 DFF 单元数、面积和时序需要另测。软件 `Entry` 的 `uint32_t` 容器大小不计入硬件成本。

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

# 本次算法对照：同一 520 位总预算下扫描 BTFN 与 Bimodal。
make -C riscv-core/branchsim run DSE_ARGS='--bht btfn bimodal --bht-entries 16 32 64'

# 完整默认扫描。轨迹缺失时，先用 NEMU 采集 microbench train。
make -C riscv-core/branchsim run

# 只比较示例 8/16 与完整地址参考，各自遍历预算内全部几何。
make -C riscv-core/branchsim run \
  DSE_ARGS='--pc-bits 8 30 --target-bits 16 32 --jobs 4'

# 固定 8/16 位宽，复用指定轨迹。
make -C riscv-core/branchsim run TRACE=/path/to/runner-insttrace.bin \
  DSE_ARGS='--pc-bits 8 --target-bits 16 --ff-budget 260'

# 显式扩展策略对照（默认不测 not-taken/LRU）。
make -C riscv-core/branchsim run DSE_ARGS='--bht btfn not-taken --policies rr lru'

# 本次对照数据只重建报告，不重复回放。
make -C riscv-core/branchsim run \
  DSE_ARGS='--bht btfn bimodal --bht-entries 16 32 64 --report-only'

make -C riscv-core/branchsim check-model check-dse
```

默认扫描 `P=4/8/16/30`、`T=4/8/16/32`，方向策略仅 BTFN，替换策略仅 RR。两个位宽最小从 4 开始，原 PC 的 30 位是完整标签特例；组数与路数均遍历 2 的整数幂，且路数至少为 2，因此总表项数也是 2 的整数幂。每个候选都按实际位宽及替换状态核算，满足 `total_ff ≤ 520` 才纳入测试。默认网格覆盖 **15 种组路几何**，各位宽允许的几何不同，共 **140 个表配置＋1 个关闭 BTB 基线＝141 个配置**，最多 32 项。8/16 位宽可测试到 16 项，例如 1 组 16 路 RR 为 `16 × 27 + 4 = 436` 位。

`--bht bimodal` 可单测动态算法；`--bht-entries` 指定计数器个数，须为正的 2 的幂，单配置默认 32 项、批量默认比较 16/32/64 项。静态策略将此参数归一为 0，不产生重复配置。本次算法对照含 BTFN 的 140 个表配置、Bimodal 的 380 个表配置和 1 个关闭基线，共 **521 个配置**；每个候选的 BHT 存储都计入同一 520 位上限。

扫描的原 PC 位宽只能从 4/8/16/30 中选取，目标位宽只能从 4/8/16/32 中选取。`--ff-budget` 可收紧预算（1～520 位）；`--entries-max` 和 `--ways-max` 是可选的额外限制，默认不设置。指定它们时仍须满足触发器预算。单配置 Make 变量用于 `sim`，批量扫描参数通过 `DSE_ARGS` 传入，完整参数见 `cd riscv-core/branchsim && python3 -m dse --help`。`BUILD_DIR` 可覆盖产物目录；已有轨迹会直接复用，切换负载或契约时应使用新的 `TRACE` 路径采集。

## 图表与数据

输出默认保存在 `build/`，所有配置使用同一条完整退休轨迹并从空表开始：

| 文件 | 内容 |
| --- | --- |
| [dse.html](build/dse.html) | 仿照 cachesim 的全配置散点页，横轴为 BTB+BHT 总逻辑触发器数，纵轴为 MPKI |
| [dse.csv](build/dse.csv) | 全部整数计数、七类分组比率、位宽、BHT 规模及 BTB/BHT/替换状态成本 |
| [dse.md](build/dse.md) | 8/16 与完整地址的同几何对照、最优配置、Pareto 前沿、输入 SHA-256 |
| `dse/logs/*.log` | 每个配置的模拟器原始输出 |

多算法对照时图表默认以方向算法着色，单算法时按目标位宽着色；形状默认区分原 PC 位宽，BHT 计数器个数也可筛选或用作标签。也可以选择方向策略、替换策略、组数、路数、表项数等参数作为标签。点击图例或下拉框可筛选，也可以输入触发器预算和 MPKI 上下限。MPKI 边界包含端点，留空表示该方向不限制；散点、明细表和 CSV 导出同时应用筛选。帕累托前沿默认按当前筛选重新计算，还可切换全局前沿、仅看前沿点。成本和 MPKI 都越低越好；同一坐标保留一个前沿代表，重合配置可通过悬停或筛选查看。明细表支持排序和下载当前筛选 CSV。

全部配置成功且各项输入计数一致后才发布报告。输入文件在扫描期间改变会报错；失败时保留此前报告，应以命令退出状态及摘要的输入记录识别本轮结果。原 141 点 BTFN 对照保留在 `build/archive-btfn-power2/`；前一轮“520 位预算、任意整数路数”的结果已移至 `build/archive-budget-integer-ways/`；更早的“两种策略、8 项以内”结果在 `build/archive-width-entry8/`；旧版完整 PC 结果在 `build/archive-full-pc/`，更早的大范围结果在 `build/archive-wide-sweep/`。

`--report-only` 会重新核对输入文件的 SHA-256、全部计划点、CSV 与逐点原始日志，再生成报告。它要求提供与原扫描相同的参数；输入或配置不一致时会报错，不会复用未验证的数据。

## microbench train 测量

沿用 RV32E 契约和同一条完整轨迹：191,477,451 条退休指令，其中控制流 56,486,890 条、普通指令 134,990,561 条。本次 521 个配置均成功回放，141 个 BTFN 基线配置的计数与旧模型完全一致。算法对照包括固定 BTB 几何/位宽的方向预测比较，以及相同存储成本或相同预算内的最佳配置；完整数据与前沿见 [dse.md](build/dse.md) 和 [dse.csv](build/dse.csv)。

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

8 组模型回归及真实 CLI 轨迹用例通过，覆盖标签 `pc[9:2]` 的边界、同标签训练合并、目标高位取自当前 PC、跨地址段 BTFN 方向保持、方向正确但目标错误、普通指令假跳转、30/32 位移位边界和非二次幂路数；新增模型测试验证饱和、迟滞、独立索引、PC 混叠和 JAL/JALR 不训练；UBSan 检查通过。12 项扫描回归通过，核对默认 BTFN/RR、位宽最小为 4、原 PC 的 30 位特例、二次幂几何与至少两路、预算内完整几何集合、超过 8 项的候选、520 位预算、动态 BHT 的额外开销、替换状态开销、FF 公式、统计分区、空/损坏轨迹、报告重生及失败时保留旧报告。

20 条退休指令的前向分支/JAL 环测试中，BTFN 发生 11 次误预测，Bimodal 仅首个分支和 JAL 各一次冷缺失，共 2 次；对照使用同一 BTB，额外计入 4 项 BHT 的 8 位成本。报告数据按逐点原始日志和成本公式核对；HTML 的参数筛选、颜色/形状标签、当前/全局前沿、仅看前沿、重合点悬停、排序、CSV 下载和空结果状态在 Chromium 中验证。

工作区回归通过 Makefile 执行 dummy 和 RT-Thread，均使用 `ARCH=runner DUT=npc REF=nemu`。dummy 的 runner 诊断和外层汇总均 PASS；RT-Thread 完整输出启动信息、脚本 `help` 和 `msh >`，无差分错误后向本次 runner 发送 SIGINT，外层 Makefile 完成自动追踪。日志见 [bimodal-dummy.log](build/validation/bimodal-dummy.log) 和 [bimodal-rt-thread.log](build/validation/bimodal-rt-thread.log)。

本次修改归属 branchsim，未将新方向预测器或截断标签方案接入 RTL。实际落地时，执行端需要纠正普通指令假跳转和错误预测目标，不能沿用完整标签方案中仅比较方向的前提。当前回放采用退休顺序即时训练，未模拟流水线训练延迟、错误路径或失效；未测新设计的整机 IPC、`DUT=soc`、综合面积或频率。
