# Cache 架构

## 状态与目标

`rtl/cache_dev/` 是真实 cache 的独立开发区，不参与当前 SoC 构建，也不替换
`rtl/cache/` 中的占位 I/D cache。当前目录只固定模块层次、参数和内部接口；所有
占位子模块永久反压 CoreBus 请求且不产生 AXI 请求，不能用于运行程序。

v1 使用同一个 `cache` RTL 分别构造 I-cache 和 D-cache：

```systemverilog
cache #(.ReadOnly(1'b1), .AxiId(ICACHE_AXI_ID)) u_icache (...);
cache #(.ReadOnly(1'b0), .AxiId(DCACHE_AXI_ID)) u_dcache (...);
```

设计目标如下：

- write-back、write-allocate 的组相连 cache；
- hit 路径可流水化，并严格按照 CoreBus 请求顺序返回响应；
- 每个 cache 实例最多处理一个 miss，miss 期间不接受新请求；
- 所有 cache 内部接口以完整 cache line 为数据单位；
- 已经被 CoreBus 接受的请求不可因 redirect 或 miss 被丢弃。

v1 不实现 hit-under-miss、non-blocking cache、多 MSHR、I/D 一致性和 cache
maintenance 指令。

## 顶层与参数

`cache` 顶层只暴露一组 CoreBus slave 和一组 AXI4 master。它假定所有输入地址均可
缓存；CLINT、UART 等 MMIO 必须在 cache 外部按地址绕行。

| 参数 | 默认值 | 含义 |
| --- | ---: | --- |
| `ReadOnly` | `0` | 为 `1` 时生成只读 I-cache |
| `BlockBytes` | 16 | 每个 cache line 的字节数 |
| `SetCount` | 64 | 组数 |
| `WayCount` | 2 | 每组路数 |
| `LookupLatency` | 1 | RAM lookup 流水线延迟 |
| `MaxOutstanding` | 2 | 已接受但尚未交付响应的最大事务数 |
| `AxiId` | `DCACHE_AXI_ID` | 此实例使用的固定 AXI ID |

默认每实例容量为 `16 B * 64 * 2 = 2 KiB`，一次 refill/writeback 包含四个
32 位 AXI beat。`BlockBytes`、`SetCount` 和 `WayCount` 必须为二次幂；line 必须
包含整数个 AXI beat且不超过 AXI4 的 256 beat 上限；`MaxOutstanding` 不得小于
`LookupLatency`。

CPU 字节地址按以下方式分解：

```text
byte address = {block address, block offset}
block address = {tag, set index}
```

cache 内部总线只传递 `block address`。需要访问 AXI 时，miss handler 通过在低位补
`log2(BlockBytes)` 个零恢复 line 对齐的字节地址。

## 模块分工

```text
CoreBus
   |
   v
cache_corebus_frontend
   |  line request / line response
   v
cache_array_system
   |  compound miss request / miss response
   v
cache_miss_handler
   |
   v
AXI4
```

### CoreBus frontend

`cache_corebus_frontend` 负责协议和数据宽度转换，不负责 tag lookup：

- 请求握手时把字节地址转换为块地址；
- 将 CoreBus 的 32 位 `wdata` 和 4 位 `wstrb` 移到 line 内对应位置；
- 在深度为 `MaxOutstanding` 的 FIFO 中保存 word offset 和读写类型；
- 从 line response 中选择对应的 32 位 word，保持 CoreBus byte lane 布局；
- 写响应的 `rdata` 固定为零，错误位来自对应的 line response。

CoreBus 请求、line request 和元数据 FIFO push 必须在同一次时钟沿原子发生。只有
line request 和元数据 FIFO 都能接收时，`core_resp_o.req_ready` 才能拉高。line
response 也必须与 FIFO 队首原子 pop，因而无需事务 ID。

line request 在首次握手时携带：

```text
block_addr
write
line_wdata[BlockBytes*8-1:0]
line_wstrb[BlockBytes-1:0]
```

store 不采用“先读响应、下一周期补发写”的二阶段协议。缓存系统在收到首次请求时
就知道写意图，只有 store 数据和 dirty 位已经在顺序提交点更新后，才能产生写响应。

### Cache array system

`cache_array_system` 包含：

- 每路 tag RAM 和 data RAM；
- valid、dirty 元数据；
- 请求保留队列、lookup 流水线及顺序响应控制；
- victim 选择和可综合伪随机替换状态；
- 单 miss 的阻塞和年轻请求重放控制。

每个被接受的 line request 都必须保留到对应 line response 完成握手。任意周期都维持：

```text
accepted requests - delivered responses <= MaxOutstanding
```

`line_req_ready` 必须同时受事务队列 credit、lookup 流水容量和 miss 状态约束。
响应端背压时，已完成事务继续占用 credit，响应 valid 和 payload 保持稳定。

tag lookup 同时读取一组内的所有 way。load hit 返回命中 line；store hit 按
`line_wstrb` 更新命中 line 并设置 dirty。D-cache 的 store 提交周期暂停新的 RAM
lookup，以兼容单写端口 RAM；I-cache 没有 store，因此流水线充满后可每周期完成一条
load hit。后续若采用独立读写端口 RAM，可以在保持同地址 byte forwarding 的前提下
解除这个暂停。

替换时优先选择 invalid way。所有 way 都有效时使用全局 LFSR 的低位选择 victim；
LFSR 只在一次 refill 成功安装时推进，miss 生命周期内 victim 选择必须保持不变。

### Miss handler

array system 与 miss handler 之间只允许一个复合 miss 事务在途。请求携带：

```text
refill_block_addr
writeback_valid
writeback_block_addr
writeback_line_data
```

`writeback_valid` 表示 victim 同时 valid 且 dirty。array system 在请求握手前锁存
victim tag 和完整 line，等待 miss response 期间不得覆盖该 way。

miss handler 使用多周期 FSM：

```text
Idle
  -> optional WritebackAddress
  -> optional WritebackData
  -> optional WritebackResponse
  -> RefillAddress
  -> RefillData
  -> Response
```

v1 先完成 AW 握手，再顺序发送所有 W beat并等待 B，随后才发送 AR。AXI 地址按 line
对齐，`AxLEN=LineBeats-1`、`AxSIZE=2`、`AxBURST=INCR`，所有通道使用参数 `AxiId`。
refill 逐 beat 写入内部 line buffer，并检查 RID、RRESP、beat 数量和 RLAST；只有
最后一个合法 beat 接收后才产生完整 line response。

## 请求生命周期与顺序

### Load hit

1. frontend 原子接受 CoreBus 请求、发送 line request 并保存 offset。
2. array system 按顺序完成 tag/data lookup。
3. 命中 line 进入有序 response 队列。
4. frontend 选择 32 位 word并完成 CoreBus 响应。

### Store hit

1. frontend 在首次 line request 中发送写意图、扩展后的 line data 和 byte strobe。
2. array system lookup 命中 way。
3. store 在队首提交点更新 data 和 dirty，且只执行一次。
4. 更新不可撤销后产生写完成响应；CoreBus `rdata` 为零。

### Load/store miss

1. 最老的未解决请求发现 miss，立即停止接受新请求并锁定 victim。
2. 所有更年轻的 lookup 结果作废，但原始 line request 仍保留在事务队列中。
3. dirty victim 先由 miss handler 完整写回；随后读取 refill line。
4. refill 成功时，load 以 clean line 安装；store 先合并 byte strobe，再以 dirty line
   安装。当前 miss 请求由 refill 数据完成。
5. 解除 miss 阻塞，并按照原顺序重新 lookup 队列中的年轻请求。

年轻请求不能直接复用 miss 发生前的 lookup 结果，因为 refill 可能淘汰其命中行，
也可能使同一块地址从 miss 变成 hit。内部 replay 只取消推测性 lookup，不取消已经
接受的 CoreBus 事务。

另一个 miss 只能在当前 miss response 被 array system 接受后开始。miss 结束后不需要
额外降低在途数：所有事务始终占用同一个 `MaxOutstanding` credit，队列容量约束在
miss 前后都成立。

## 错误、复位与只读实例

- writeback 的 BID/BRESP 错误会终止本次 miss，victim 的 valid、dirty 和 data 保持
  不变，当前 CoreBus 请求返回错误；
- refill 的 RID/RRESP/RLAST 或 beat 数错误会使 refill 失败，不安装部分 line，victim
  仍保持原状态，当前请求返回错误；
- 成功安装新 line 的时钟沿才允许覆盖 victim tag/data/valid/dirty；
- reset 清除 valid、dirty、事务队列和 miss 状态，data/tag RAM 内容无需复位；
- redirect 不进入 cache，也不刷新已接受请求；IF stage 继续负责接收并丢弃旧路径的
  顺序响应。

`ReadOnly=1` 使用 generate 从结构上移除 store merge、dirty RAM、victim writeback 和
AXI 写状态，并通过 assertion 禁止 CoreBus 写请求。不能只依赖上层把 `write` 接成零后
由综合器跨层次猜测优化。

## SoC 集成约束

开发完成并替换现有占位 cache 时，还需要同步处理以下边界：

1. 当前 IF 默认只有一个 outstanding 请求。要利用流水化 I-cache，需要把
   `FetchOutstandingDepth` 提高到不小于所选 cache 在途深度。
2. 当前 MEM stage 固定单 outstanding，因此 D-cache 的多在途能力暂时不会被核心使用。
3. 当前 `cache_axi4_mux` 按单拍响应管理 credit。支持 burst 后必须按完整 AR 事务分配
   credit，并只在匹配 RID 的 `RLAST` beat 被接收时释放。
4. D-cache 之前必须覆盖完整的 MMIO/不可缓存地址图，不能只绕过当前 CLINT 区域。
5. 独立 I/D 实例不保持一致。当前核心不支持 `FENCE.I`，因此 v1 明确不支持自修改
   代码；后续应在实现 I-cache invalidate 与请求排空后再启用 Zifencei。

## 开发与验证顺序

建议按 frontend、只读 hit array、miss refill、D-cache store、dirty writeback 的顺序
替换占位子模块。每个阶段都保留 ready/valid 稳定性、事务计数、响应顺序、单 miss、
refill 原子安装和只读实例不写 AXI 的 assertion。

当前接口骨架可独立 lint：

```bash
verilator --lint-only --sv --Wall \
  -Wno-PINCONNECTEMPTY -Wno-IMPORTSTAR -Wno-SYNCASYNCNET -Wno-UNOPTFLAT \
  -f rtl/cache_dev/cache_dev.f

verilator --lint-only --sv --Wall \
  -Wno-PINCONNECTEMPTY -Wno-IMPORTSTAR -Wno-SYNCASYNCNET -Wno-UNOPTFLAT \
  -GReadOnly=1 -GAxiId=0 -f rtl/cache_dev/cache_dev.f
```

`cache_dev.f` 屏蔽独立顶层无法使用完整 `riscv_core_pkg` 时产生的 package
`UNUSEDPARAM` 告警；其他告警仍保持开启。主工程继续通过 `make lint` 验证，且不包含
`rtl/cache_dev/`。
