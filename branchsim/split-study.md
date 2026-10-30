# BRANCH 独立 BTB、JAL/RET 共享 BTB

2026-10-30。接续 [小容量 RAS 研究](ras-study.md)，本轮只修改 branchsim，RTL 不变。

后续已按 4/2/1 接入 RTL，见 [当前实现与验证](../rtl/README.md)；下文为接入前的离线实验记录。

**这个拆分在保留足够 BRANCH 容量时有效，但直接把当前 4 项 BTB 平分会退化。** microbench 上，4 项 BRANCH＋2 项 JAL/RET＋2 项 RAS 的 MPKI 为 **65.182338**，相对当前 CPU 减少 **10.74%** 的误预测，预测器存储从 142 位增至 224 位。固定为 2＋2 项时，MPKI 为 75.396612，反而退化 3.25%。RT-Thread 上，JAL 与 RET 仍存在明显竞争；分组方式也会改变收益。

## 实现规则

新增 `--btb-layout split`，默认仍为 `unified`：

- 原 `--btb-sets/ways` 作为 BRANCH 表，只接收条件分支；BHT 仍独立训练，保持 Bimodal[16]。
- `--jump-btb-sets/ways` 配置 JAL/RET 表。JAL 保存直接目标，RET 保存类型、目标由 RAS 提供；其他 JALR 不训练 BTB，间接 call 仍按 x1/x5 提示 push。
- 两表使用相同的 P/T 和 RR 策略，查询只接收 PC，两表并行比较标签。未命中时顺序取指；RET 命中而栈空时也顺序取指。
- 两表都命中时，默认 JAL/RET 优先，可用 `--split-priority branch` 改为 BRANCH 优先。仲裁依据标签命中，不依据当前指令类型、真实结果或 BHT 是否预测 taken；胜出表预测不跳转时也不切换到另一表。
- RAS 继续仅在已确认的训练事件中更新，查询不修改栈。普通指令假跳转、短标签别名、目标高位重建错误都计入总误预测。

`Predict/Update` 通过可选的第二张 BTB 扩展；默认路径与前一轮保持一致。没有在 IF 利用退休指令译码来选择表。日志新增两表同时命中次数，回归单独覆盖优先级、空栈、分表训练及同表 JAL/RET 别名合并。

## 成本与扫描范围

按当前 RTL 可实现的紧凑存储核算：P10/T16、无 C 扩展，BRANCH 表每项为 `valid 1 + tag 10 + target[15:1] 15 = 26` 位，无需类型字段；JAL/RET 表每项另需 1 位区分两者，共 27 位。RAS 关闭时，第二张表只有 JAL，类型位可去掉。

```text
总存储 = BRANCH_items × (P+T)
       + JAL_RET_items × (P+T+1)          # 有 RAS；关闭时去掉 +1
       + 两表各自的 sets × ceil(log2(ways))
       + 2 × BHT_entries
       + RAS_depth × (RAS_width-2)
       + ceil(log2(RAS_depth)) + ceil(log2(RAS_depth+1))
```

如 4＋2 项、2 项低 16 位 RAS：`4×26 + 2×27 + 2+1 + 32 + 31 = 224` 位。位数是预测器内的逻辑存储，不含额外比较器、仲裁、多路器或流水来源位，尚未综合测面积和时序。

RAS 关闭时，其数据、写指针和有效项计数三项成本均为零。

主扫描固定 BHT16、P10/T16、单组 RR，BRANCH/JAL-RET 容量各取 1/2/4/8，RAS 深度取 0/1/2/4，总预算不超过 360 位；2 项 RAS 补测反向仲裁优先级。另含 P12/P16、原统一 BTB 及上一轮独立 return 标签方案，共 **90 个配置/轨迹**。

补充扫描固定 4 项 BRANCH、2/4 项 JAL/RET，改变组路划分，并比较 RAS 关闭与 2 项 RAS，共 **21 个配置/轨迹**。两条轨迹合计 **222 次完整回放**，重复控制点用于对齐两轮结果。

## 主要结果

两条输入与上一轮相同：microbench train 共 191,477,451 条记录，已有 RT-Thread 记录共 15,882,856 条；均为 RV32E，相同 platform_id，冷启动回放。主指标为全部退休指令上的 MPKI，越低越好。

下表中，除特别说明外，两张拆分表均为单组全相联 RR：

| 方案 | 存储位 | microbench MPKI | 相对基线误预测减少 | RT-Thread MPKI | 相对基线误预测减少 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 当前统一 BTB4、无 RAS | 142 | 73.024917 | — | 127.767260 | — |
| 统一 BTB4＋RAS2 | 177 | 82.599000 | -13.111% | 127.781867 | -0.011% |
| BRANCH2＋JAL/RET2＋RAS2 | 171 | 75.396612 | -3.248% | 127.776956 | -0.008% |
| BRANCH4＋JAL/RET2＋RAS1 | **208** | **65.397565** | **10.445%** | 127.723566 | 0.034% |
| BRANCH4＋JAL/RET2＋RAS2 | 224 | 65.182338 | 10.740% | 127.723692 | 0.034% |
| BRANCH4＋JAL/RET4，无 RAS | 244 | 68.707474 | 5.912% | **114.918312** | **10.057%** |
| BRANCH4＋JAL/RET4＋RAS2 | 279 | 63.566895 | 12.952% | 133.916092 | -4.813% |
| BRANCH8＋JAL/RET2＋RAS2 | 329 | 62.624805 | 14.242% | 128.700216 | -0.730% |
| 旧方案：BTB4＋独立 RET 标签4＋RAS2 | 219 | 65.767332 | 9.939% | 127.674267 | 0.073% |

### 为什么 2＋2 不合适

microbench 的当前基线有 11,240,519 次条件分支错误。采用 BRANCH2＋JAL/RET2＋RAS2 后，条件分支错误增至 **12,929,354**，增加 1,688,835 次；虽然 JAL 和 RET 分别少错 159,119 和 1,077,066 次，但不足以抵消 BRANCH 容量缩小的损失，另有 1,476 次新增普通指令错误。

保留 BRANCH4 后，其错误数为 **10,972,074**，比当前统一 BTB4 还减少 268,445 次。这一差额来自移出 JAL 后的容量隔离。4＋2 项、RAS2 总计少错 **1,501,677** 次，其中包括 JAL 少错 159,119 次、RET 少错 1,077,066 次，并增加 2,953 次普通指令错误。

### JAL 与 RET 的竞争仍在

microbench 中，BRANCH4＋JAL/RET4 从关闭 RAS 改为 RAS2 后，RET 错误从 1,487,646 降至 319,056，但 JAL 错误从 **40,661 增至 276,116**。返回预测仍然带来净收益，但共享表的竞争没有消失。

RT-Thread 的同一对照更明显：JAL 错误从 **203,479 增至 506,552**，而 RET 只少错 **1,340** 次；这使 MPKI 从 114.918312 升至 133.916092。该表还存在约 101,000 次普通指令假跳转，均包含在总指标内。

因此，“条件分支不再被 RET 挤占”已经由实验验证；“RET 和 JAL 可以在很小的表中良好共存”则不适用于这条 RT-Thread 轨迹。

## 组相联与仲裁

固定 BRANCH4＋JAL/RET4＋RAS2，组索引会改变 JAL/RET 的竞争方式：

| BRANCH 表 | JAL/RET 表 | 位数 | microbench MPKI | RT-Thread MPKI |
| --- | --- | ---: | ---: | ---: |
| 1 组 4 路 | 1 组 4 路 | 279 | 63.566895 | 133.916092 |
| 2 组 2 路 | 1 组 4 路 | 279 | **63.483068** | 133.953994 |
| 1 组 4 路 | 2 组 2 路 | 279 | 64.034391 | 127.668349 |
| 1 组 4 路 | 4 组 1 路 | 277 | 73.261572 | **121.315398** |

JAL/RET 表改成 4 组 1 路后，RT-Thread 可预测对 **101,766** 次 return，误预测相对当前 CPU 减少 **5.050%**；相同设置在 microbench 上却退化 **0.324%**。这说明组索引可缓解一种负载的竞争，也可能引入另一种负载的冲突，不能只凭全相联结果选定组织方式。

两表命中仲裁在本轮影响很小：主扫描的 13 对优先级对照中，microbench 只有 BRANCH8＋JAL/RET2＋RAS2 相差 4 次错误，RT-Thread 只有 BRANCH4＋JAL/RET4＋RAS2 相差 3 次。主要瓶颈是各表容量、表内替换和别名；优先级仍需要明确，不能用真实指令类型消除冲突。

## 面积预算下的选择

以下为本轮实际扫描候选，不声称覆盖所有可能的标签位宽、几何或替换策略。

- **约 168 位以内**：microbench 仍优先上一轮的 BTB4＋RET 标签1＋RAS1（168 位、MPKI 67.362041）。拆分候选在此预算内最好为 164 位、MPKI 71.110096，且关闭了 RAS；强行缩小 BRANCH 表不划算。
- **约 219 位以内**：BRANCH4＋JAL/RET2＋RAS1（208 位、65.397565）优于上一轮 RET 标签4＋RAS2（219 位、65.767332），这是面积优先时值得保留的拆分候选。第二项 RAS 再花 16 位，只把 MPKI 降至 65.182338。
- **约 290 位**：同为 8 项 BTB，拆成 BRANCH4（2组2路）＋JAL/RET4（1组4路）＋RAS2，共 279 位、MPKI 63.483068；统一 BTB8＋RAS2 为 290 位、63.965861。拆分在本轨迹中省 11 位，并额外减少约 0.755% 的错误。
- **RT-Thread**：本轮最佳拆分候选是关闭 RAS 的 BRANCH4＋JAL4（244 位、114.918312）。若要求启用 RAS，4 组 1 路的 JAL/RET4 是有收益的候选，但它在 microbench 上没有收益，尚无同时在两条轨迹上明显占优的小容量统一配置。

## RTL 接入思路

两张表可继续采用现有 BTB 的标签、目标、RR 更新形式；BRANCH 表去掉 kind，JAL/RET 表只需一个 `is_ret` 位。BHT 保留独立训练，不因 BTB 查询或命中情况改变计数器更新。

IF 并行查询两表，按固定优先级选出一张，再由分支方向或 `is_ret` 选择目标；RET 的目标来自 RAS。已采纳预测继续随现有元数据送到 EX。EX 使用已译码类别分流训练事件，并在有效握手且无异常时更新 RAS。普通指令假命中、错误目标和两表别名都由 EX 按预测快照纠正。

RAS 来源 JALR 必须恢复目标比较，才能避免“预测正确仍强制改道”。这些接口边界与上一轮建议一致；双表查询增加的比较和仲裁，以及训练到下一次查询的延迟，仍需实际 RTL 综合和定向时序验证。

## 复现与验证

从 `branchsim/` 执行：

```sh
make check-model check-dse
python3 -m dse.split --trace build/runner-insttrace.bin --output build/split-microbench
python3 -m dse.split \
  --trace ../../am-kernels/rt-thread-am/bsp/abstract-machine/build/insttrace-review/runner-insttrace.bin \
  --output build/split-rtthread

# 补测固定容量下的组路划分；RT-Thread 也使用同一参数
python3 -m dse.split --set-sweep --trace build/runner-insttrace.bin \
  --output build/split-sets-microbench

# 单独回放 BRANCH4＋JAL/RET2＋RAS1
make sim BHT=bimodal BHT_ENTRIES=16 PC_BITS=10 TARGET_BITS=16 \
  BTB_LAYOUT=split BTB_SETS=1 BTB_WAYS=4 JUMP_BTB_SETS=1 JUMP_BTB_WAYS=2 \
  RAS_MODE=btb RAS_ENTRIES=1
```

默认全表不拆分、RAS 关闭，原 DSE 网格保持不变。`--ff-budget` 可收紧研究预算；结果只报告该预算内实际测试的候选。每轮目录保留逐配置日志、`results.csv`、`results.md` 和输入/二进制 SHA-256。汇总发布前核对所有输入计数、分项加和及扫描前后的文件指纹。

主扫描：[microbench](build/split-microbench/results.md)、[CSV](build/split-microbench/results.csv)、[RT-Thread](build/split-rtthread/results.md)、[CSV](build/split-rtthread/results.csv)。组路补测：[microbench](build/split-sets-microbench/results.md)、[RT-Thread](build/split-sets-rtthread/results.md)。

输入 SHA-256 与上一轮相同：microbench `413fc992cf846464a30cbeef80ddfde906f5efe3e8e418c966e9fe670f2456bf`，RT-Thread `0f5b7e62c6ab4bf424f3be7c20b70fe1bbfae0ba781f825aed28436a7a3dd35b`。本次没有重新采集或运行 CPU 工作负载；复用的 RT-Thread 记录以用户中断结束。

验证通过：14 组模型回归、原别名/RAS CLI 测试、新增拆表/直接映射冲突/预算扫描 CLI 测试、原有 12 项 DSE 回归。数据来自退休顺序即时训练，不含错误路径、流水线延迟和独立异常清栈事件；存储位与 MPKI 不直接换算为综合面积或 IPC。
