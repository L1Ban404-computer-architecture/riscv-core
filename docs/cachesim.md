# cachesim

`cachesim` 是 I-cache 的元数据功能模型：只保存每路的 valid 和 tag，回放退休
PC 序列，统计命中/缺失次数和命中率。它不模拟数据阵列、AXI 时序、缺失代价或
`FENCE.I` 冲刷。

默认几何与 RTL 一致：4 字节行、16 组、1 路、满组 round-robin。组相联时先选最低
编号无效路；`rr` 只在 refill 时旋转，`plru` 在命中和 refill 时都更新 Tree-PLRU。

## 构建与轨迹

产物都在 `riscv-core/build/cachesim/`。默认从 `am-kernels/benchmarks/microbench`
用 NEMU 生成 `train` 规模的退休 PC 流：

```bash
make -C riscv-core/cachesim
make -C riscv-core/cachesim pctrace
```

`ARCH=runner DUT=nemu mainargs=train`。覆盖规模时传 `MAINARGS=test`。轨迹文件已
存在时不会重新跑 NEMU。

## 回放与扫参数

`sim` 在轨迹存在时直接跑 cachesim，报告写到 `build/cachesim/sim.log`。`run` 调用
`scripts/dse.py`，默认只扫超小几何，好塞进约 25000 的芯片面积（还要留给五级
流水核心）：

- sets: 4, 8, 16
- ways: 1, 2
- block_bytes: 4, 8
- policy: rr, plru

共 24 组，容量约 16B–256B。更大的 32/64 组、4 路或 16/32B 行综合后会到数万
甚至数十万，默认不扫。每组跑 cachesim 与 1GHz yosys-sta，最后按 AMT 升序
（并列按综合面积）写入 `build/cachesim/dse.csv`，并画出面积-AMT 散点图
`build/cachesim/dse.svg`。CSV 只有配置、面积、时钟频率、命中率和 AMT，不含
TMT 或 accesses/hits/misses。

```bash
make -C riscv-core/cachesim sim
make -C riscv-core/cachesim sim SETS=8 WAYS=2 BLOCK_BYTES=8 POLICY=plru
make -C riscv-core/cachesim run
```

也可以直接调用二进制：

```bash
./riscv-core/build/cachesim/cachesim --trace build/cachesim/microbench.pc \
  --sets 16 --ways 1 --block-bytes 4 --policy rr
```

cachesim 本身只输出命中率。缺失代价、AMT 和综合 PPA 都在 `scripts/dse.py` 里算。

缺失代价按 32-bit beat 放大，当前把 4 字节块的 miss lat 写死为 `beat_lat=68`：

```
miss_penalty = 68 * (block_bytes / 4)
AMT          = (1 - hit_rate) * miss_penalty
```

例如 16 字节行按独立事务计为 `68 * 4`。以后若要贴合实测，再换成读 SoC
`perf.log`。

每组参数先生成

`build/cachesim/dse/s{sets}_w{ways}_b{block}_{policy}/icache_dse.sv`

实例化对应几何的 `icache_top`，再按 `riscv-core` 的 `perf` 流程用 slang 展开，
并以 1GHz 目标跑 yosys-sta（`CLK_PORT_NAME=clk_i`）。表中 `synth_freq_mhz` 取
报告第一张表里 `core_clock` / `max` 的 `Freq(MHz)`，`synth_area` 取
`Chip area for module '\icache_dse'`。同一几何目录已有完整 STA 报告时跳过重综合。
默认 `--jobs 1`，避免多份 iEDA 抢同一套工具。首次 24 组综合会较慢；其中
8/16 组、1/2 路、4/8B 行若已有 STA 目录会跳过重综合。直接调用脚本时不传
`--sets` / `--ways` 等也会扫同一组默认配置，结果默认写到
`build/cachesim/dse.csv` 和 `dse.svg`。

## 与 RTL 性能计数器的口径差异

RTL `icache_performance_stats` 按 CoreBus 请求接受计数，包含五级流水在重定向
后已经发出、随后被丢弃的取指。cachesim 回放的是退休 PC，因此命中率适合比较
参数变化趋势，不能与 ysyx-soc `*-perf.log` 的 icache 行逐条相等。cachesim 也不
识别 `FENCE.I`，自修改代码场景会和冲刷整 cache 的 RTL 行为分叉。
