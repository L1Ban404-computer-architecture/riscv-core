# 小容量 RAS：当前配置的离线评估

2026-10-30。RTL 保持不变；实现位于 branchsim。

后续将 BRANCH 与 JAL/RET 拆表的实验见 [双 BTB 研究](split-study.md)。

4/2/1 已在后续工作中接入 RTL，见 [当前实现与验证](../rtl/README.md)；本页保留离线实验记录。

当前 CPU 为 RV32E、无压缩指令，预测器是 1 组 4 路 RR BTB、P10/T16、Bimodal[16]，紧凑存储为 142 位。**microbench train 上，增加 1 项 RAS 和 1 项独立 return PC 标签，总存储增至 168 位，误预测减少 7.75%。共享现有 BTB 识别 return 会因容量竞争而退化。已有 RT-Thread 轨迹中，小标签表几乎没有收益，因此还不能据此选定通用 RTL 配置。**

## 模型与比较口径

- 每条退休指令先查询、再统计、最后训练。硬件方案的预测阶段只读 PC 和历史状态；当前指令及实际目标只进入训练和统计。
- `--ras-entries 0` 默认关闭，保持原模型的统计。容量支持 1/2/4/8/16/32/64 项。环形栈满时覆盖最老项，空 pop 不改变状态；有效项耗尽后不重复使用旧数据。
- 按 [RISC-V RV32I 规范的 RAS 提示表](https://docs.riscv.org/reference/isa/v20260120/unpriv/rv32.html)处理 x1/x5：JAL 的 rd 为 link 寄存器时 push；JALR 根据 rd/rs1 做 pop、push、pop+push 或不操作；相同 link 寄存器只 push。push 保存 PC+4，pop+push 先读旧顶、训练时先 pop 再 push。尾调用不额外 push。
- 仅把需要 pop 且立即数为零的 JALR 识别为可直接用栈顶预测的 return。非零立即数仍按提示更新栈，但不分配 return 标签。间接 call 可 push，其他 JALR 仍按原模型处理。
- `btb`：增加 `kReturn` 类型，与 B/J 竞争现有 BTB；return 不受 BHT 控制，目标来自 RAS，空栈时顺序预测。均匀 BTB 格式的 kind 从 1 位增为 2 位。
- `filter`：独立的全相联 RR return 标签表，标签仍为 `(PC >> 2)` 低 P 位，只有 return 训练。命中时优先选择 RAS，空栈时顺序预测；未命中使用原 BTB。标签表没有隐藏完整地址、目标字段或 LRU 状态。普通指令、分支及 JAL 的标签假命中全部计入误预测，查询本身不改栈。
- `ideal`：使用当前指令译码识别 return，不训练 return BTB/标签。它隔离栈深度和地址压缩的限制，属于理想识别对照；当前 IF 在请求时只有 PC，不能直接实现该对照。

统一主指标为 `MPKI = 全部误预测 / 全部退休指令 × 1000`，跳转时同时核对完整目标。日志另给出 return、其他 JALR、条件分支、JAL 和普通指令的分项计数，以及 RAS 可用次数、溢出/下溢、预测数。

当前 RTL 强制所有 JALR 改道，即使 BTB 别名碰巧猜对。新增 `redirects` 按“非 RAS 来源的 JALR 仍强制改道”另计；两条轨迹的全部配置中，它与总误预测数一致。这里的改道数仍是顺序回放估计。

## 存储成本

本研究按当前 RTL 的紧凑格式计费，区别于原 DSE 保留 backward 和目标 bit 0 的统一格式。设 BTB 条目数为 N，RAS 深度为 D，地址宽度为 W，独立标签项数为 K：

```text
基础 BTB+BHT = N × (valid 1 + P + target[15:1] 15 + kind 1)
              + sets × ceil(log2(ways)) + 2 × BHT_entries
共享 BTB 的额外类型位 = N                  # 仅 btb 模式且 D>0
RAS = D × (W-2) + ceil(log2(D)) + ceil(log2(D+1))
标签表 = K × (P+1) + ceil(log2(K))
```

RAS 两项状态分别是环形写指针和有效项计数；D=1 无指针，计数退化为 valid。无 C 扩展时 PC+4 低两位恒零，因此 W16 每项只存 14 位，高位取查询 PC；W32 每项存 30 位。单项标签表无替换指针。关闭的结构成本为零。`ideal` 的识别成本不计，不能作为真实面积候选。

这些是预测器内的逻辑存储位，不是综合面积。实际接入还需事件门控、比较/选择逻辑及必要的流水元数据；若增加预测来源位，当前取指元数据和 ID/EX 两处各需 1 位。未对新 RTL 做综合或整机 IPC 测量。

## microbench train

按现有 Makefile、当前契约重新由 NEMU 采集，程序 `a0=0` 正常结束。共 **191,477,451** 条退休指令；控制流 56,486,890 条，其中可用栈顶预测的 return 为 **1,487,646** 条。基线误预测 **13,982,625** 次，与此前 P10 独立回放一致。

| 方案 | 总存储位 | 相对基线增加 | MPKI | 误预测减少 |
| --- | ---: | ---: | ---: | ---: |
| 当前配置 | 142 | 0 | 73.024917 | — |
| 仅 BHT 扩至 32 项 | 174 | 32 | 72.959661 | 0.089% |
| 仅标签扩至 P12 | 150 | 8 | 72.756013 | 0.368% |
| 仅 BTB 扩至 2 组 4 路 | 252 | 110 | 68.878706 | 5.678% |
| 1 项 RAS＋1 项标签 | **168** | **26** | **67.362041** | **7.755%** |
| 2 项 RAS＋1 项标签 | 184 | 42 | 67.148345 | 8.047% |
| 2 项 RAS＋2 项标签 | 196 | 54 | 66.837400 | 8.473% |
| 2 项 RAS＋4 项标签 | 219 | 77 | 65.767332 | 9.939% |
| 4 项 RAS＋4 项标签 | 249 | 107 | 65.792457 | 9.904% |
| 8 项 RAS＋4 项标签 | 307 | 165 | 65.672490 | 10.068% |
| 2 项 RAS、共享 BTB | 177 | 35 | 82.599000 | -13.111% |

1 项 RAS＋1 项标签预测对了 1,084,433 次 return，额外引入 117 次条件分支错误和 3 次普通指令假跳转，净减少 **1,084,313** 次错误。第二项 RAS 再增加 16 位，净多消除 40,918 次错误；固定小标签表后，继续增加栈深度的收益较小。

共享 BTB 的 2 项 RAS 虽修复了 313,163 次 return，却增加 **1,410,624** 次条件分支错误、**735,758** 次 JAL 错误及 2 次普通指令错误，净增加 1,833,221 次错误。小 BTB 容量竞争是该方案退化的直接计数来源。

理想识别时，1/2/4/8/16 项 RAS 的 MPKI 分别为 **66.385702 / 65.631112 / 65.380931 / 65.260494 / 65.255673**，误预测减少 **9.092% / 10.125% / 10.468% / 10.633% / 10.639%**。本负载中，2 项已经覆盖了理想识别下绝大部分可获得收益。

收益并不随容量严格单调：例如 4 项标签时，RAS 从 2 项增至 4 项，普通指令错误从 54,263 增至 106,688，抵消了新增的正确 return。短标签假命中只有在栈非空时才会给出错误跳转，栈深度会改变这些事件。

W16 换成 W32 的 4 项对照中，共享 BTB 和 2 项标签方案的总错误数都不变，理想识别只多预测对 1 次。固定 4 项 RAS＋2 项标签，将整个预测器 P10 扩至 P12/P16，MPKI 从 66.856112 降至 66.304340/66.304162，主要改善短标签混叠；P12 与 P16 的差异已很小。

## RT-Thread 交叉检查

复用工作区已有 `insttrace-review/runner-insttrace.bin`，RV32E、相同 platform_id，**15,882,856** 条记录，其中 return **507,458** 条。关联 runner 日志为 `DUT=npc`、用户中断结束；本次没有重新执行 RT-Thread。分母使用实际记录数，`instid` 是模型不透明标识，不是退休计数。

| 方案 | MPKI | 误预测减少 |
| --- | ---: | ---: |
| 当前配置 | 127.767260 | — |
| 1 项 RAS＋1 项标签 | 127.764301 | 0.002% |
| 2 项 RAS＋2 项标签 | 127.673700 | 0.073% |
| 2 项 RAS＋4 项标签 | 127.674267 | 0.073% |
| 4 项 RAS＋4 项标签 | 134.032884 | -4.904% |
| 2 项 RAS、共享 BTB | 127.781867 | -0.011% |
| 理想识别、2 项 RAS | 108.569202 | 15.026% |
| 理想识别、4 项 RAS | 95.845294 | 24.984% |

2 项栈在理想识别时预测对 304,920 次 return，而 2 项标签方案仅预测对 1,513 次；小 return 标签表是主要瓶颈。将 4 项 RAS 的标签从 P10 加宽为 P12/P16，也只能改善到 MPKI 127.671938/127.671686，不能补足识别容量。4 项 RAS＋4 项 P10 标签另有 101,199 次普通指令错误，是必须保留的退化结果。

4 项理想识别模型从 W16 改为 W32 后额外修复 405 次，MPKI 为 95.819795；这一差额远小于实际标签表的识别损失。

## 建议的 RTL 边界与更新逻辑

面积优先且主要运行该 microbench 时，先考虑 **1 项 RAS＋1 项独立标签**，再考虑 2 项 RAS；1 项结构只需地址寄存器、valid 和一个标签比较器，容易检查。面向 RT-Thread 时，应先解决 return 的识别覆盖，再决定是否增加栈深度。

建议新增一个小 `return_predictor`，与现有 `branch_predictor` 并列，内部封装 return 标签表和 RAS。保留 B/J 的 BTB、BHT、RR 和训练语义；IF 只增加一次预测选择。这比在 4 项 BTB 中混入第三种类型更符合实测结果。

1. **ID 译码一次。** 从 JAL/JALR、rd/rs1 的 x1/x5 关系生成 `ras_pop/ras_push`，非零立即数不标记 return site。当前 ID/EX 已保留 rd、rs1 地址和立即数，也可在 EX 用现有字段做这组小比较，避免再传整条指令。
2. **EX 形成一次性更新事件。** 在 `id_ex.fire && !最终异常` 时传 pop/push、return-site、PC 标签和 PC+4 低位，采用独立于 B/J 的小 payload。握手停顿不能重复更新；不能复用现有仅允许 B/J 的 `branch_update.valid` 作为 RAS 总门控。
3. **IF 只读。** 请求被接受时，先查 return 标签：命中且非空选择栈顶；命中但空栈选择顺序；未命中走原 BTB。W16 可复用现有 `target[15:1]` 快照格式。查询不修改标签替换指针或栈，已采纳预测继续随元数据送至 EX。
4. **EX 正常纠错。** 目前 `branch_unit` 对 JALR 固定返回“不匹配”；接入 RAS 时必须恢复 RAS 来源 JALR 的完整目标比较，否则预测成功仍会被强制改道。用真实 JALR 目标核对预测快照，其他指令继续检查假跳转。若维持“其他来源 JALR 一律改道”，需在快照增加一个来源位。
5. **顺序更新。** 状态转移按 clear、pop、push 的固定优先级描述，pop+push 使用同一旧状态统一算 next-state；溢出覆盖最老项、下溢保持空。仅复位有效状态和指针，数据不必复位。FENCE.I 随现有预测器失效；异常/上下文变化时明确保留还是清空，统一优先于训练。普通 EX 纠错无需回滚：RAS 没有被预测查询修改。

这种接法不增加推测检查点或栈恢复网络。它依赖 EX 更新与下一次 IF 查询的实际时序：紧邻 call/return、流水线停顿以及同拍更新/查询要通过定向测试核对；离线回放先前指令即时训练，不能证明这些时序收益。当前 trace 也没有独立异常/失效事件，模型没有复现异常清栈、错误路径或训练延迟，因此结果用于预测器取舍，不换算为 IPC 百分比。

## 复现与产物

从 `branchsim/` 执行：

```sh
make check-model check-dse
# 轨迹缺失时按当前契约采集 microbench train
make build/runner-insttrace.bin
python3 -m dse.ras --trace build/runner-insttrace.bin --output build/ras-microbench
python3 -m dse.ras \
  --trace ../../am-kernels/rt-thread-am/bsp/abstract-machine/build/insttrace-review/runner-insttrace.bin \
  --output build/ras-rtthread

# 单独回放最小配置
make sim BHT=bimodal BHT_ENTRIES=16 BTB_SETS=1 BTB_WAYS=4 PC_BITS=10 \
  RAS_ENTRIES=1 RAS_MODE=filter RAS_FILTER_ENTRIES=1
```

每条轨迹完成 **35 个配置**。`dse.ras` 保留逐点日志、`results.csv`、`results.md` 和带输入/二进制 SHA-256 的 `inputs.json`；发布汇总前核对所有输入计数分组和扫描前后文件指纹。原 BTB/BHT DSE 默认网格不变。

| 轨迹 | SHA-256 |
| --- | --- |
| microbench train | `413fc992cf846464a30cbeef80ddfde906f5efe3e8e418c966e9fe670f2456bf` |
| RT-Thread 既有记录 | `0f5b7e62c6ab4bf424f3be7c20b70fe1bbfae0ba781f825aed28436a7a3dd35b` |

完整本地产物：[microbench 汇总](build/ras-microbench/results.md)、[CSV](build/ras-microbench/results.csv)、[RT-Thread 汇总](build/ras-rtthread/results.md)、[CSV](build/ras-rtthread/results.csv)、[采集日志](build/ras-trace-build.log)。回归包括 12 组模型测试、真实 CLI 的 return 冷启动/别名/跨段目标/关闭行为与扫描用例，以及原有 12 项 DSE 测试。未修改 RTL，因此本次不运行硬件差分、综合或 SoC lint。
