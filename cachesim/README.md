# cachesim 代码导读

`cachesim` 是 I-cache 的**元数据功能模型**，外加一套对同一条 PC 轨迹做几何扫描的脚本。它只记录每组每路的 `valid` / `tag` 和替换状态，不存指令数据，也不模拟流水线、AXI 回填或背压。每个 PC 被当成一次普通取指：块已在 cache 里记一次命中，否则立刻填入该块并记一次缺失。

模型与 `rtl/icache/` 在地址划分和替换规则上同构，默认几何也与 `icache_pkg` 一致：4 字节块、16 组、1 路、轮转替换。命中率用来估算平均缺失代价（AMT）；面积和频率来自对真实 `icache_top` 的综合与静态时序分析，不来自这个 C++ 模型。

## 目录

| 路径 | 职责 |
| --- | --- |
| `include/cache.hpp` | 配置、统计和 `Cache` 接口 |
| `include/trace.hpp` | PC 轨迹读取接口 |
| `src/cache.cpp` | 地址拆分、命中判断、替换 |
| `src/trace.cpp` | 小端 `uint32` 流读取 |
| `src/main.cpp` | 命令行、回放循环、统计输出 |
| `dse/` | 几何扫描：综合、AMT、CSV 和散点图 |
| `Makefile` | 编译、采轨迹、单次仿真、扫描 |
| `build/` | 全部生成物，已 gitignore |

仓库根目录的 `Makefile` 把 `cachesim`、`pctrace`、`sim`、`run`、`clean` 转发到本目录。

## 构建与运行

在 `riscv-core/` 或 `cachesim/` 下：

```sh
make -C cachesim              # 默认目标，生成 build/cachesim
make -C cachesim pctrace      # 跑 microbench，写出 build/runner-pctrace.bin
make -C cachesim sim          # 用默认几何回放，结果同时打印并写入 build/sim.log
make -C cachesim run          # 调用 python3 -m dse，写出 build/dse.csv 和 build/dse.html
make -C cachesim clean
```

单次仿真可覆盖几何，例如 8 组、2 路、8 字节块、Tree-PLRU：

```sh
make -C cachesim sim SETS=8 WAYS=2 BLOCK_BYTES=8 POLICY=plru
```

`pctrace` 在 `am-kernels/benchmarks/microbench` 里执行 `make run`，默认 `ARCH=runner`、`DUT=nemu`、`mainargs=train`，向 runner 传入 cachesim 的 `build/` 作为 `LOG_DIR` 并用 `PCTRACE=1` 启用轨迹。文件名 `runner-pctrace.bin` 由 runner 固定。工作台根目录由 `YSYX_HOME`（默认是 `riscv-core` 的上两级）决定，`AM_HOME` 默认为 `$YSYX_HOME/abstract-machine`。轨迹文件已存在时，`sim` / `run` 只检查它在不在，不会重新生成；要重采就先删除 `build/runner-pctrace.bin` 再执行 `make pctrace`。

也可以直接调用可执行文件。`--trace` 必填，其余参数有默认值：

```text
build/cachesim --trace build/runner-pctrace.bin \
  --block-bytes 4 --sets 16 --ways 1 --policy rr
```

标准输出只有一行：

```text
accesses=123 hits=100 misses=23 hit_rate=0.813008
```

空轨迹打印 `accesses=0 hits=0 misses=0 hit_rate=-`。缺 `--trace`、未知参数或策略名错误时直接退出。`sets`、`ways`、`block-bytes` 必须是正的 2 的幂，`block-bytes >= 4`，且 tag 至少还有 1 位；`Cache` 构造时检查，不合法就打印原因并退出。

## 数据流

```text
runner --log-dir=build --pctrace
        │  小端 uint32 PC 流
        v
PcTraceReader::Next          src/trace.cpp
        │
        v
Cache::Access                src/cache.cpp
        │  命中 / 缺失计数
        v
一行 hit_rate                src/main.cpp
        │
        +—— sim：build/sim.log
        |
        v
dse
        │  每组几何各跑一次 cachesim
        │  并 make -C rtl perf TOP=icache_top
        v
build/dse.csv , build/dse.html
```

## PC 轨迹

`PcTraceReader`（`include/trace.hpp`、`src/trace.cpp`）按二进制读 runner `--pctrace` 的输出。`Open` 以 `"rb"` 打开文件，打不开就退出。对象不可复制，析构时关闭文件。

`Next` 每次读 4 字节，按小端拼成 `uint32`：

```text
pc = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
```

读到文件末尾返回 `false`。读出错或最后剩下不足 4 字节时，读取器自己报告并退出，回放循环不用再看一份错误码。

模型不解释 PC 的含义。压缩指令、不对齐地址或非取指地址都会原样参与块映射。

## Cache 模型

类型定义在 `include/cache.hpp`。`src/cache.cpp` 按一次访问的顺序写：`Access`，地址拆分，牺牲路与填入，Tree-PLRU，最后才是构造。

### 配置与存储

```cpp
struct CacheConfig {
  std::uint32_t block_bytes = 4;
  std::uint32_t sets = 16;
  std::uint32_t ways = 1;
  ReplacementPolicy policy = ReplacementPolicy::kRoundRobin;
};
```

`fixed`、`rr`、`plru` 分别对应 `kFixed`、`kRoundRobin`、`kTreePlru`，字符串解析在 `ParseReplacementPolicy`。

构造时算出三个宽度，并按组×路摊平存储：

| 成员 | 含义 |
| --- | --- |
| `block_offset_w_` | `log2(block_bytes)`，块内字节偏移位宽 |
| `set_index_bits_` | 组数大于 1 时为 `log2(sets)`，否则为 0 |
| `tree_levels_` | 路数大于 1 时为 `log2(ways)`，否则为 0 |
| `valid_`、`tag_` | 长度 `sets * ways`，下标 `set * ways + way` |
| `rr_next_` | 每组下一次轮转候选路，初值 0 |
| `plru_tree_` | 每组一棵 PLRU 树，打包在一个 `uint32` 里，初值 0 |

`valid_` 用 `uint8_t`，0 无效、1 有效。没有数据阵列，tag 比较成立就认为整块命中。

### 地址划分

与 `icache_array` 的 `set_from_addr` / `tag_from_addr` 相同，布局是 `{ tag, set, block offset }`：

```text
31                        block_offset_w+set_index_bits    block_offset_w          0
+----------------------------------+---------------------------+-------------------+
|               tag                |           set             |   block offset    |
+----------------------------------+---------------------------+-------------------+
```

```cpp
set = (addr >> block_offset_w_) & (sets - 1)   // sets == 1 时恒为 0
tag =  addr >> (block_offset_w_ + set_index_bits_)
```

块内偏移不参与比较。`block_bytes == 4` 时每条 32 位指令独占一块，只有同一 PC 再次出现才会命中。块加大后，落在同一块里的连续 PC 共享一个 tag，第一次缺失会让后续取指命中。这是用本模型观察空间局部性的方式。

### 一次访问

`Cache::Access` 对每个地址做下面这些事，命中返回 `true`。

1. 拆出 `set` 和 `tag`，`accesses++`。
2. 从 way 0 扫到最后一路。某一路 `valid && tag` 相等则 `hits++`。路数大于 1 且策略是 PLRU 时，用命中路更新该组的树。轮转和固定策略在命中时不改状态。
3. 全未命中则 `misses++`，选出牺牲路，把该路标为有效并写入新 tag，再按策略记下这次填充。

组内只要还有无效路，三种策略都先选**编号最小的无效路**，满组后才用策略给出的牺牲路。`SelectVictim` 里 `full_victim` 在 `ways == 1` 时保持 0，直接映射不看 `policy`。

### 替换策略

实现故意与 `rtl/icache/icache_replacement_policy.sv` 对齐。RTL 用 `select_en` 脉冲分配牺牲路、用 `hit_valid` 更新命中；本模型没有拍的概念，一次 `Access` 里要么命中要么缺失，更新立刻生效。

**fixed。** 满组时牺牲路永远是 0。不保存状态。

**rr。** 每组一个 `rr_next_`。满组时它就是牺牲路。填充结束后把它改成实际占用路的下一路，最后一路绕回 0。占用路可能是无效路优先选出的低编号路，不一定是进入函数时的 `rr_next_`。命中不推进。这与 RTL 注释一致：轮转只在锁定牺牲路时前进。

**plru。** 每组一棵完全二叉树，`ways - 1` 个状态位，存在 `plru_tree_[set]` 的低位。位 `node` 为 0 表示左子树更久未用，为 1 表示右子树更久未用。`ways` 必须是 2 的幂，层数才是整数。

选路从根 `node = 0`、`way = 0` 出发，下降 `tree_levels_` 层：

```text
direction = (tree >> node) & 1
way       = (way << 1) | direction
node      = node * 2 + 1 + direction
```

下降路径上的左右选择拼出牺牲路编号。2 路时只有根位：0 选 way 0，1 选 way 1。

更新沿着**被访问路**往下走。第 `level` 层的方向取 way 从高位起的那一位。当前节点改成指向另一侧（`direction ^ 1`），再进入被访问的子节点 `node * 2 + 1 + direction`。效果是把“更久未用”从这条路径上拨开。命中和填充都会更新；固定策略和轮转不会调用它。

4 路树的节点编号如下。位 0 是根，位 1 是左子节点，位 2 是右子节点：

```text
            [0]
           /   \
        [1]     [2]
        / \     / \
      w0  w1  w2  w3
```

初值全 0，所以第一次满组替换会一路向左，先牺牲 way 0。

RTL 的 PLRU 更新吃的是独热路掩码，并且同一拍里若命中更新和分配打在同一组，分配覆盖命中。功能模型每个 PC 单独访问，不会出现这一拍内的覆盖。替换状态在功能上与“每次访问立刻提交”的结果一致，但不是周期精确模型。

### 模型不覆盖的硬件行为

对照 `rtl/icache/` 时，下面这些没有建：

- 指令数据、字偏移、回填突发和 AXI。缺失在 `Access` 返回前就写好 tag。
- `invalidate`。模型从全无效开始，轨迹中间不会被清空。
- 请求就绪、查找流寄存器、缺失与查找的互锁。每个 PC 都算一次访问，即使硬件上同一次缺失会挡住后续请求。
- 替换状态“已分配但回填失败仍消耗候选”的情况。这里每次缺失都会完成填充。
- 性能计数里的周期和。C++ 只累计访问、命中、缺失次数。

因此 hit rate 是块级重用率，不是带流水线停顿的 IPC。

## 单次回放：`src/main.cpp`

`main` 本身只有四步：`ReadArgs` 收几何和轨迹路径，`MakeCache` 构造模型，循环里对每个 PC 调用 `Access`，`PrintStats` 打印命中率。未给出的几何留在 `CacheConfig` 的默认值上。命中率是 `hits / accesses`，打印 6 位小数；一次访问都没有时打印 `hit_rate=-`。

## 设计空间扫描：`dse/`

`make run` 在本目录下等价于 `python3 -m dse`。脚本不读命令行参数，扫描范围和路径都写在 `dse/__main__.py` 开头。数据容量是 `sets * ways * block_bytes`。`BYTES_MIN` 和 `BYTES_MAX` 给出这个容量的闭区间，脚本在区间里搜索组数、路数、块大小都是 2 的幂的全部组合，再配上 `POLICIES`。块至少 4 字节，路数至多 8。容量和地址划分也必须合法。默认 16–256 字节比原先只列几档组数、路数和块大小的笛卡尔积多出不少点。阵列按触发器综合，把上限调大以后面积会远超 nangate45 上留给核心的预算：

| 常量 | 取值 |
| --- | --- |
| `BYTES_MIN` | `16` |
| `BYTES_MAX` | `256` |
| `POLICIES` | `fixed, rr, plru` |
| `JOBS` | `1` |
| `TRACE` | `build/runner-pctrace.bin` |
| `CACHESIM` | `build/cachesim` |
| `OUTPUT` / `PLOT` | `build/dse.csv`、`build/dse.html` |

每个配置做两件独立的事。

**功能。** 调 `cachesim` 拿 hit rate。缺失代价按块传输的拍数线性放大：

```text
words        = block_bytes / 4
miss_penalty = LAT_HEAD + LAT_BEAT * (words - 1)
AMT          = (1 - hit_rate) * miss_penalty
```

`LAT_HEAD` 默认 68，`LAT_BEAT` 默认 43。4 字节块只有一个字，缺失延迟就是 68；块更大时，多出来的每个字再加 43。这两个数都不是从 RTL 仿真测出来的。空轨迹的 `hit_rate=-` 会使 AMT 记成 `-`。

**物理。** 每个几何在 `build/dse/nangate45/s{sets}_w{ways}_b{bytes}_{policy}/` 下调用 `rtl/Makefile` 的 `perf`，顶层是 `icache_top`，目标频率 1000 MHz，时钟端口 `clk_i`，工艺库沿用 `PDK`（默认 `nangate45`）。源文件由 Makefile 自己收集。几何通过 `read_slang -G` 覆盖 `BlockBytes`、`SetCount`、`WayCount` 和 `ReplacementPolicy`。替换策略传 `icache_pkg` 的枚举名，不传整数：`fixed` 是 `ICACHE_REPLACEMENT_FIXED`，`rr` 是 `ICACHE_REPLACEMENT_ROUND_ROBIN`，`plru` 是 `ICACHE_REPLACEMENT_TREE_PLRU`。

报告在该目录的 `icache_top-1000MHz/` 下。面积取 `synth_stat.txt` 里 `Chip area for module '\icache_top'`，频率取 `icache_top.rpt` 中 `core_clock` / `max` 的 Freq(MHz)。两份报告都能解析时跳过综合，只重跑 cachesim。`YOSYS` 和 `YOSYS_STA_HOME` 也沿用 `rtl/Makefile`。`make perf` 的 Yosys 和 STA 日志不打到终端；综合失败时异常里带着日志结尾。回放失败时，子进程的退出码直接结束这次扫描。

CSV 列是 `sets,ways,block_bytes,policy,synth_area,synth_freq_mhz,hit_rate,amt`。行按 AMT 升序，其次面积，再按几何参数。`build/dse.html` 是同一份结果的散点页：横轴面积、纵轴 AMT。颜色和形状各自可以选择 `sets`、`ways`、`block_bytes`、`bytes` 或 `policy`。`bytes` 是数据容量 `sets * ways * block_bytes`。默认颜色是 `policy`、形状是 `sets`。灰色虚线是 Pareto 前沿，串起面积和 AMT 不能再被其他点同时改进的配置。悬停一个点能看到它的组数、路数、块大小、容量、策略、面积、频率、命中率和 AMT。数据写在页面里，扫描结束后用浏览器打开这个文件即可，不必再跑综合。进度打在标准错误。`JOBS` 大于 1 时每个进程独占自己的几何目录，先综合再回放。

## 和 RTL 的对应

| 功能模型 | RTL |
| --- | --- |
| `CacheConfig` 默认值 | `icache_pkg` 的 `ICacheBlockBytes` / `SetCount` / `WayCount` / `ReplacementPolicy` |
| `SetIndex`、`Tag` | `icache_array` 的 `set_from_addr`、`tag_from_addr` |
| 无效路优先，再取满组牺牲路 | `icache_replacement_policy` 末尾的 `invalid_found` 扫描 |
| `kFixed` | `gen_fixed`，牺牲路 0 |
| `rr_next_`、`NoteFill` | `gen_round_robin` 的 `next_way_q` |
| `SelectPlruWay`、`UpdatePlru` | `select_plru_way`、`update_plru_tree_oh` |
| `dse` 的策略名 `fixed` / `rr` / `plru` | `icache_replacement_policy_e` |

读替换逻辑时先看 `Cache::Access`，再看 `SelectVictim` 和 `NoteFill`，最后对照 RTL 里同名注释。改其中一边的选路或更新规则时，另一边需要一起改，否则 DSE 的 hit rate 不再代表将要综合的那份策略。
