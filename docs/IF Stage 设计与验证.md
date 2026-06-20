# IF Stage 设计与验证

本文档说明当前 `if_stage` 的微架构设计，以及对应的模块级 cocotb
验证方案。

## 范围

`if_stage` 是顺序执行核心的取指前端。它负责：

- 维护下一次取指 PC。
- 发起 AXI4-Lite 指令读请求。
- 记录 outstanding 读请求对应的 PC，用于和读响应配对。
- 维护 IF/ID 边界上的已返回指令 FIFO。
- 处理来自后级的 redirect。

该模块不做指令译码，也不产生数据存储器访问。模块边界暴露完整
AXI4-Lite request/response 结构，但取指只使用 AR/R 读通道。

## 参数

| 参数 | 默认值 | 作用 |
| --- | ---: | --- |
| `FetchOutstandingDepth` | 4 | 已完成 AR 握手、但尚未消费 R 响应的最大读请求数量。 |
| `IfIdQueueDepth` | 2 | IF 到 ID 之间的已返回指令 FIFO 深度。 |

这两个深度刻意保持独立。`FetchOutstandingDepth` 主要用于隐藏外部指令存储器
延迟；`IfIdQueueDepth` 主要用于吸收 ID stage 的短暂停顿。

## 接口

### Boot PC

`boot_pc_i` 通过 `boot_pending_q` 在复位释放后采样。PC 寄存器复位值为 0，
复位释放后的第一个正常周期加载 `boot_pc_i`。这样 `boot_pc_i` 是运行时输入，
而不是静态参数。

### Redirect

`redirect_i.valid` 有三个效果：

- 将下一次取指 PC 更新为 `redirect_i.target_pc`。
- flush 已返回指令 FIFO。
- 翻转内部 `fetch_epoch_q`。

redirect 是前端改道机制：它用于丢弃尚未进入 EX 的年轻指令，但不会尝试取消
已经被 AXI 总线接受的读请求。

### AXI4-Lite 指令接口

IF 只使用读地址和读数据通道：

- `imem_req_o.ar_valid`
- `imem_req_o.ar.addr`
- `imem_req_o.ar.prot`
- `imem_req_o.r_ready`
- `imem_resp_i.ar_ready`
- `imem_resp_i.r_valid`
- `imem_resp_i.r.data`

写通道保持空闲：

- `aw_valid = 0`
- `w_valid = 0`
- `b_ready = 0`
- `aw.addr = 0`
- `aw.prot = 3'b100`
- `w.data = 0`
- `w.strb = 0`

其中 `prot[2] = 1` 表示 instruction access。

### IF/ID 接口

IF/ID 是 ready/valid 流接口，payload 类型为 `if_id_bus_t`。payload 包含：

- `fetch.pc`
- `fetch.instr`
- `debug.fetch.pc`
- `debug.fetch.instr`

`if_id_valid_o` 在 redirect 周期会被屏蔽，避免旧路径指令在 redirect 同周期
继续交给 ID。

## 微架构

当前 `if_stage` 由三个解耦的寄存器/FIFO 组成。

### AR Holding Register

请求生成端形成：

```systemverilog
fetch_req_data = {pc_q, fetch_epoch_q}
```

然后通过 `common_cells::fall_through_register` 驱动 AXI AR 通道。

这里刻意使用 fall-through register：

- 当下游 AR 通道 ready 时，新请求可以无额外周期地直通。
- 当 `ar_valid` 已经在时钟沿被采样为 1 且 `ar_ready` 为 0 时，该 register
  会锁住 valid 和 payload，直到握手完成。

redirect 只阻止新请求进入 holding register。对于已经在 AXI 时钟沿被采样到
的等待中 AR 请求，redirect 不能撤销它。

### Outstanding PC FIFO

`u_pc_fifo` 是 `common_cells::stream_fifo`，配置为 `FALL_THROUGH=1`。它记录
每个已完成 AR 握手请求的 PC 和 epoch，并在对应 R 响应被接受时弹出。

这里需要 fall-through 模式，因为 AXI4-Lite slave 可以在 AR 握手同周期返回
R 响应。此时刚完成握手的 PC 必须能立刻被 R 通道配对逻辑看到。

### Fetch FIFO

`u_fetch_fifo` 是 `common_cells::stream_fifo`，配置为 `FALL_THROUGH=0`。它保存
保留下来的完整 IF/ID payload，并在 redirect 周期 flush。

R 通道 ready 的条件是：

- PC FIFO 中存在可配对的 outstanding PC。
- 并且该响应要么属于旧 epoch、会被直接丢弃；要么 fetch FIFO 可以接收这个
  保留下来的响应。

## PC 与 Epoch 规则

`pc_q` 表示下一次准备分配给新取指请求的 PC。更新优先级如下：

1. redirect 优先级最高，加载 `redirect_i.target_pc`。
2. boot pending 周期加载 `boot_pc_i`。
3. 新取指请求被分配时，PC 加 4。
4. 其它情况保持不变。

`fetch_epoch_q` 是 1 bit epoch，每次 redirect 翻转一次。返回响应只有在以下
条件同时满足时才会进入 fetch FIFO：

- 响应携带的 epoch 等于当前 epoch。
- 当前周期没有 redirect。

1 bit epoch 依赖以下设计前提：

- IF 只使用单条有序 AXI4-Lite 读流。
- R 响应顺序必须与 AR 握手顺序一致。
- redirect 来自已进入 EX 的指令。
- 新路径指令返回并进入 EX 之前，不会从新路径再次产生 redirect。

在这些前提下，epoch 再次翻转之前，更老 epoch 的响应已经按顺序被消费掉，
不会和当前路径混淆。

## AXI 合规性

RTL 中使用 `common_cells` 断言检查 AR 通道：

- `ImemArStable`：`ar_valid` 等待 `ar_ready` 时，AR payload 必须保持稳定。
- `ImemArValidStable`：`ar_valid` 在 `ar_ready=0` 时被采样后，下一拍必须
  继续保持为 1。

这里的关键边界是 AXI 的同步握手语义。fall-through register 可能在组合路径上
短暂显示 `ar_valid`，但 AXI 的保持义务从 `ar_valid && !ar_ready` 在时钟沿
被采样之后开始。

## 验证结构

模块级验证位于 `tests/cocotb/if_stage/`。

| 文件 | 作用 |
| --- | --- |
| `if_stage_tb.sv` | SystemVerilog wrapper，将 packed struct 端口展开成 cocotb 友好的标量端口。 |
| `test_if_stage.py` | 定向测试和随机 smoke 测试。 |
| `run_if_stage.py` | 使用 cocotb runner + Verilator 的 Python 入口。 |
| `Makefile` | 传统 cocotb make 入口。 |

运行完整测试：

```sh
python tests/cocotb/if_stage/run_if_stage.py
```

runner 会构建并运行以下配置：

| 名称 | `FetchOutstandingDepth` | `IfIdQueueDepth` | 测试 |
| --- | ---: | ---: | --- |
| `default` | 4 | 2 | 全量测试 |
| `min_depth` | 1 | 1 | `parameterized_depth_smoke` |
| `mixed_depth` | 4 | 1 | `parameterized_depth_smoke` |

## 测试覆盖点

### 定向测试

`reset_boot_and_basic_fetch`

- 验证 boot PC 采样。
- 检查顺序 PC 生成。
- 检查返回指令和 debug payload。

`ar_valid_and_payload_hold_under_backpressure`

- 对 AR 通道施加 backpressure。
- 检查握手前 `ar_valid` 不会掉。
- 检查 AR 地址和 protection bits 保持稳定。

`zero_latency_memory_response`

- 建模可以在 AR 握手同周期返回 R 的指令存储器。
- 覆盖 PC FIFO 的 fall-through 路径。

`if_id_backpressure_preserves_fetch_order`

- 暂停 ID。
- 验证 fetch FIFO 的 backpressure 能传递到 R 通道。
- 检查返回指令按顺序交给 ID。

`redirect_discards_old_outstanding_responses`

- 发出旧路径请求。
- 施加 redirect。
- 验证旧路径响应被丢弃，新路径响应正常交付。

`redirect_during_ar_wait_preserves_axi_request`

- 先让 AR 请求在 `ar_ready=0` 时被时钟沿采样到。
- 再施加 redirect。
- 验证这个已采样的 AR 请求在被接受前保持 valid 和 payload 稳定。

`parameterized_depth_smoke`

- 在不同 FIFO 深度参数下执行基本取指 smoke。
- 由 runner 用于最小深度和混合深度配置。

### 随机 Smoke 测试

`randomized_ready_redirect_smoke` 随机化：

- AR ready。
- R valid 时序。
- IF/ID ready。
- 前端干净状态下的偶发 redirect。

scoreboard 跟踪已接受 AR 的 PC 和 epoch，并检查只有当前 epoch 的 fetch 会按序
到达 IF/ID。

随机 redirect 刻意只在没有 outstanding 请求、没有待输出 IF/ID fetch 时产生。
这符合当前 1 bit epoch 的设计前提，也让随机测试保持在设计契约范围内。

### 持续 Monitor

`write_channel_idle_monitor` 在 cocotb 测试中持续运行，用于检查 IF stage 永远
不会发起 AXI4-Lite 写事务。

## 已知限制

- R response error 当前会被 IF 忽略。随机 smoke 可能驱动 `SLVERR`，但当前预期
  行为仍然是对保留响应交付指令数据。未来如果支持取指异常，需要同步扩展
  `if_stage` 和测试。
- `if_stage_tb.sv` 中 redirect reason 固定为 `REDIR_BRANCH`。当前 IF 逻辑只使用
  `valid` 和 `target_pc`。
- 随机 redirect 测试不会刻意违反 1 bit epoch 前提。更激进的 redirect 测试应
  先把设计改为携带更宽的事务 tag，或使用精确 outstanding flush 计数。
