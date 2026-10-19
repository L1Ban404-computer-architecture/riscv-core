# branchsim 代码导读

branchsim 回放 runner 的控制流轨迹，用 BHT、BTB 和 RAS 评估分支预测。
它是按退休顺序训练的功能模型：每条记录先预测、再统计、最后更新，下一条记录
可以立即看到更新结果。所有状态从空开始，冷启动纳入统计，不模拟时钟周期、
推测执行、预测延迟或错误路径，也不估算 CPI。

## 构建与运行

从本目录执行：

```sh
make                       # build/branchsim
make btrace                # NEMU 跑 microbench train，生成 build/runner-btrace.bin
make sim                   # 仅回放已有轨迹，打印并保存 build/sim.log
make run                   # 轨迹缺失时先采集，再回放
make sim BHT=not-taken      # 对同一条轨迹比较另一种 BHT
make sim BTB_SETS=32 BTB_WAYS=4 BTB_POLICY=lru RAS_DEPTH=8
make clean
```

父目录提供 `make branchsim`、`make btrace`、`make branchsim-sim`；原有 `sim/run`
仍属于 cachesim。构建产物、采集日志和报告均位于本目录的 `build/`。

采集默认 `ARCH=runner`、`DUT=nemu`、`MAINARGS=train`，通过 AM 的 `make run`
传入 `BTRACE=1`，保留工作区 Makefile 的自动追踪流程。可覆盖 `YSYX_HOME`、
`AM_HOME`、`MICROBENCH_DIR`、`DUT` 和 `MAINARGS`。沿用 runner 当前契约，不重置配置。
轨迹存在时不重新采集；更换工作负载、采集配置或文件格式后，先删除旧轨迹再执行
`make btrace`。`TRACE=/path/to/file.bin` 可指定其他轨迹，`BUILD_DIR` 可改变产物目录。

可执行文件也能独立调用，无需加载模型：

```sh
build/branchsim --trace build/runner-btrace.bin \
  --bht btfn --btb table --btb-sets 64 --btb-ways 2 --btb-policy rr \
  --ras stack --ras-depth 16
```

选项同时接受 `--name value` 和 `--name=value`，`--trace` 必填，其余默认如上。
非法参数返回 2，文件/协议错误返回 1，成功返回 0。读取错误不会输出成功统计。

## 三个组件与控制流程

| 模块 | 职责 |
| --- | --- |
| `include/branch.hpp` | PC/指令输入、真实结果和常规调用/返回识别 |
| `bht.hpp` / `bht.cpp` | 方向预测接口和两种独立算法 |
| `btb.hpp` / `btb.cpp` | 目标、条件分支/JAL 类型和替换状态 |
| `ras.hpp` / `ras.cpp` | 返回地址与有效深度 |
| `predictor.hpp` / `predictor.cpp` | 组件协调和统一统计 |
| `trace.hpp` / `trace.cpp` | 校验文件头，读取二进制记录 |
| `main.cpp` | 参数解析、对象创建、回放循环、结果输出 |

主循环只有三个步骤：

```cpp
const Prediction prediction = Predict(record.input, *bht, btb, ras);
stats.Observe(prediction, record.outcome);
Update(record, *bht, btb, ras);
```

`input` 只有 PC 和指令；`outcome` 保存真实方向和目标。预测函数没有真实结果参数，
不能提前用答案预测。控制程序先从指令识别 RET 和其他 JALR，其余通过 BTB 查询：

| 情况 | 行为 |
| --- | --- |
| RET | 直接查 RAS，有栈顶则跳转，无有效栈顶则不跳转，不回退 BTB |
| 其他 JALR | 不跳转，不访问 BTB/BHT |
| BTB 未命中 | 不跳转 |
| BTB 命中条件分支 | BHT 判断方向，使用 BTB 保存的目标 |
| BTB 命中 JAL | 跳转，使用 BTB 保存的目标，不查询 BHT |

即使指令编码足以计算直接目标，预测阶段也不会用它绕过 BTB。

### BHT：相同操作，不同内部实现

`Bht` 是唯一的抽象接口。`virtual` 让 `Bht` 指针调用实际算法的函数；
`MakeBht` 创建所选算法，返回的 `unique_ptr` 在退出时自动释放它。
控制程序只需知道 `Predict(pc, target)` 和 `Update(pc, target, taken)`，
不需要知道算法内部有没有表或历史。

- `not-taken` 对条件分支始终预测不跳转。
- `btfn`（Backward Taken, Forward Not-taken）对目标相对 PC 的负偏移预测跳转；
  正偏移和零偏移预测不跳转。差值按 RV32 模 2^32 计算，再检查符号位。

当前两种算法都无状态，`Update` 为空；不提供没有实际作用的容量参数。
添加新算法时实现一个独立的 `Bht` 派生类，并在工厂中注册名称即可；
算法可以自行维护历史、计数器及专属配置，不必统一为某种表结构。
`not-taken` 只影响条件分支，JAL 和 RET 仍按上表预测。

### BTB：组相联目标表

`BTB=table/none`；`BTB_SETS` 为正的 2 的幂，`BTB_WAYS` 为正整数。
一路就是直接映射，一组就是全相联；总条目数为组数乘路数。
每项保存 `valid`、完整 PC、目标和类型。组索引是 `(pc >> 2) & (sets - 1)`。

预测查表不修改状态。更新时，已有项更新目标/类型；未命中优先占用最低编号空路。
组满后按 `BTB_POLICY=rr/lru` 替换。RR 仅在新占用时推进下一候选路；LRU 在每次更新
时把当前项记为最新，使用有界组内名次表示新旧关系。
实际条件分支无论是否跳转，都写入编码目标并更新 BHT；JAL 也写入 BTB。
JALR 和 RET 不写 BTB。禁用 BTB 后，条件分支和 JAL 都因无目标而预测不跳转。

### RAS：有界返回地址栈

`RAS=stack/none`；启用时 `RAS_DEPTH` 必须为正整数，不要求为 2 的幂。
JAL/JALR 的 `rd=x1/x5` 视为调用，压入 `pc+4`；
`JALR x0, x1/x5, 0` 视为 RET，预测取栈顶，更新时弹栈。
普通 JALR 调用虽然预测不跳转，实际发生后仍须维护 RAS。

栈满时覆盖最早的地址，另存有效数量。返回逐层弹出后，已覆盖地址不会重新有效。
因此超出保存深度的旧返回只能预测不跳转。禁用 RAS 时也始终没有有效栈顶。
所有调用/返回都在真实结果阶段更新；预测失败或 BTB 未命中不影响训练。

## 统计口径

“命中”要求方向一致，且实际跳转时目标也正确。预测跳转但目标错误算失败。
实际跳转目标为 PC+4 时，预测不跳转仍算方向错误。

输出先列配置，再列以下各组的 `accesses`、`hits`、`misses`、`hit_rate`：

| 组 | 分母 |
| --- | --- |
| `total` | 全部控制流记录 |
| `actual_taken` | 实际跳转记录 |
| `actual_not_taken` | 实际不跳转记录 |
| `predicted_taken` | 预测跳转记录 |
| `predicted_not_taken` | 预测不跳转记录 |

每组分子都是该组中方向与目标均正确的记录数。额外的 `direction` 仅检查方向，
可用于识别目标错误带来的损失。比率范围为 0 到 1，保留六位小数；分母为零时为 `-`。
总体统计包含条件分支、JAL、JALR 和 RET，不是仅针对条件分支的 BHT 命中率，
也不包含普通指令；没有总指令数，不能据此计算 MPKI。

## 二进制轨迹与适用范围

格式契约来自 runner 的 `api/include/riscv_btrace.h`，不依赖生成的平台契约。
全部整数为小端，显式读写字节，不把 C++ 结构体直接写盘。

```text
头部 8 字节："BTRC" | uint16 version=1 | uint16 record_size=13
记录 13 字节：uint32 pc | uint32 instr | uint32 target | uint8 taken
```

条件分支即使未跳转，也保留编码目标；JAL 保存直接目标；JALR 保存已解析的目标。
JAL/JALR 的 `taken` 固定为 1。有效空轨迹仍须有文件头。
读取器拒绝旧的无头 9 字节格式、未知版本/记录大小、不完整记录、非控制流指令、
非法跳转标志，以及错误标记为未跳转的 JAL/JALR。

首版假设 RV32 的固定 32 位指令和正常控制流。异常转移、协程组合 pop+push、
线程上下文切换、软件切栈暂不建模。runner 退休 ABI 没有独立异常标志；
分支/JAL/JALR 自身触发异常的轨迹不适用于当前评估。runner 在分支目标为 PC+4
且没有 redirect 时沿用 GPR 调试读取判断条件，对应模型必须提供所需读取能力。
