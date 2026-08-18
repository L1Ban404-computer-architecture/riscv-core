# Cache 架构

## 状态与边界

`rtl/cache_dev/` 包含一套可运行的参数化组相连 cache，使用同一个 `cache` 模块
构造只读 I-cache 和可写 D-cache：

```systemverilog
cache #(.ReadOnly(1'b1), .AxiId(ICACHE_AXI_ID)) u_icache (...);
cache #(.ReadOnly(1'b0), .AxiId(DCACHE_AXI_ID)) u_dcache (...);
```

cache 实现 write-back、write-allocate、严格有序 CoreBus 响应和单个阻塞 miss。
当前 SoC 仍使用 `rtl/cache/` 中的占位模块；cache_dev 尚未接入不支持多拍 burst 的
`cache_axi4_mux`，也不改变公开 SoC 接口。

v1 不实现 hit-under-miss、多 MSHR、I/D 一致性和 CPU `FENCE.I` 接线；`cache_dev`
已经提供独立的 clean-all/invalidate-all maintenance 机制，供后续集成使用。
所有输入地址均视为可缓存，MMIO 必须在 cache 外部完成地址旁路。

## 顶层参数和地址

| 参数 | 默认值 | 含义 |
| --- | ---: | --- |
| `AddrWidth` / `DataWidth` / `IdWidth` | 32 / 32 / 4 | 外部 interface 几何 |
| `ReadOnly` | 0 | 生成只读实例 |
| `BlockBytes` | 16 | cache line 字节数 |
| `SetCount` | 64 | 组数 |
| `WayCount` | 2 | 每组路数 |
| `LookupLatency` | 1 | array lookup 固定延迟 |
| `MaxOutstanding` | 2 | CoreBus 在途事务上限 |
| `AxiId` | `DCACHE_AXI_ID` | 固定 AXI ID |

默认容量为 `16 B * 64 * 2 = 2 KiB`。`BlockBytes`、`SetCount` 和
`WayCount` 必须为二次幂，line 包含 1 到 256 个 32 位 AXI beat。

地址分解为：

```text
byte address = {block address, block offset}
block address = {tag, set index}
block offset = {word index, byte lane}
```

CoreBus store data 和 strobe 已经按 byte lane 对齐。cache 始终返回包含目标地址的
完整 32 位 word，byte/halfword 选择和符号扩展由核心完成。

## Package 与 interface 边界

内存协议按 package 常量和参数化 interface 两层组织：

```text
riscv_common_pkg            RV32 标量和无领域依赖的公共声明
  ├── riscv_bus_pkg         CoreBus/AXI 协议枚举和常量
  ├── riscv_core_pkg        ISA、标量、流水和调试 payload 类型
  └── cache_pkg             cache 默认值和无几何依赖的函数
riscv_bus_if.sv             参数化 CoreBus/AXI4 interface
cache_if.sv                 参数化 cache 内部语义 interface
```

各 package 不保存依赖实例参数的 packed bus 类型。每个 RTL 和 testbench 显式导入
需要的 package，cache 不依赖 core 专属 package。CoreBus 和 AXI 的参数化 interface
分别提供 `req_payload/rsp_payload` 与五个 AXI channel payload；握手信号独立存在，
并通过 modport 限制方向。cache 内部协议也遵循同样的 `payload + valid/ready` 边界。

核心内部的 `mem_size_e` 表示 RISC-V load/store 执行宽度，CoreBus 的
`core_bus_size_e` 表示协议传输宽度。两者虽然都采用 `log2(字节数)` 编码，但不共享
类型所有权；仅在 MEM stage 的总线边界显式转换。cache 只使用 CoreBus 类型。

`cache_pkg` 中的 `automatic function` 只处理与实例几何无关的逻辑，例如参数合法性、
32 位 store byte merge 和合法 strobe 计算。依赖 `BlockBytes`、`SetCount`、
`WayCount` 或 `MaxOutstanding` 的类型和函数仍在对应参数作用域中定义。

CoreBus 请求和响应应整体传递：请求字段从 `core_bus.req_payload` 读取，响应字段从
`core_bus.rsp_payload` 读取；AXI mux 和 line AXI engine 对 AW/W/B/AR/R 分别整体传递
对应 channel payload。跨协议的 `mem_size_e` 到 `core_bus_size_e` 转换仍只在 MEM
边界逐项完成，不通过强制类型转换隐藏编码假设。

## 模块分工

```text
cache
  ├── cache_control
  ├── cache_maintenance
  ├── cache_array
  │     ├── cache_replacement_policy
  │     └── cache_data_bank × way × word bank
  └── cache_line_axi_engine
```

- `cache` 是稳定的集成边界，负责参数推导、内部协议连线和静态约束。
- `cache_control` 是控制面，拥有 CoreBus 协议、事务表、有序响应、store context、
  epoch、miss 上下文和 replay 调度。
- `cache_maintenance` 独立管理 CoreBus 排空、array 全局扫描和 line-write 调度，
  不进入普通 miss/replay 状态机。
- `cache_array` 是阵列面，拥有 tag、valid、dirty、data、tag compare、hit data mux、
  victim 选择、Tree-PLRU 和固定延迟 lookup 流水。
- `cache_data_bank` 是深度为 `SetCount` 的 32 位同步 1R1W 存储体。
- `cache_replacement_policy` 位于阵列边界内，保存每组 Tree-PLRU 状态。
- `cache_line_axi_engine` 是 AXI 搬运面，对上层分别提供 line-read 和 line-write，
  不理解 CPU store、txn 或替换策略。为节约资源，本轮仍使用单个阻塞式状态机，
  不并发执行读写事务。

transaction table 没有继续拆分。它需要随机完成回写、epoch replay、同周期 pop/push
以及有序 head/tail 更新，与调度状态机高度耦合；留在 control 中可以避免再引入一层
端口、仲裁和状态所有权。

## 内部协议

内部每条协议使用独立 interface 连接 `cache_control`、`cache_array` 和
`cache_line_axi_engine`。协议的字段集合固定，字段位宽在 interface 内由 `AddrWidth`、
`DataWidth`、`BlockBytes`、
`SetCount`、`WayCount` 和 `MaxOutstanding` 等基础配置推导；派生宽度均为不可覆盖的
`localparam`。模块参数中不注入 payload 类型，package 也不固定实例几何或使用最大预留
位宽。array 内部的 lookup 流水仍可使用私有 packed struct 保存状态，但该类型不属于模块
接口。lookup、victim、word write、line install、line-read 和 line-write
均各自提供 producer、consumer 和 monitor modport。

| 通道 | payload | 流控 |
| --- | --- | --- |
| lookup request | `txn_id, epoch, set, tag, word` | ready/valid |
| lookup response | `txn_id, epoch, hit, hit_way, rdata, victim snapshot` | 固定延迟，无 ready |
| victim request | `set, way` | ready/valid |
| victim response | 完整 line | ready/valid |
| word write | `set, way, word, data` | ready/valid |
| line install | `set, way, line, tag, dirty` | ready/valid；提交时同步更新 Tree-PLRU |
| maintenance request/response | clean-all 或 invalidate-all；完成 error | 双向 ready/valid |
| array maintenance | 扫描请求、dirty line 流和独立 done | ready/valid |
| line-read | 请求为 block address；响应为完整 line 和 error | 双向 ready/valid |
| line-write | 请求为 block address 和完整 line；响应为 error | 双向 ready/valid |

`valid` 和 `ready` 不属于 payload。producer 不以 consumer 的 `ready` 组合生成
`valid`，发生背压时保持 payload 稳定。CoreBus `req_ready` 也不依赖 `req_valid`；
它只反映事务 credit、store barrier、控制状态和 array 接收能力。

word write 和 line install 是两个语义独立的请求通道。word write 只提交
store hit 合并后的一个 word，不修改 tag/valid，并将目标 line 置为 dirty；
line install 原子安装完整 line、tag、valid 和 dirty。array 内部仍共享同一组
bank 写端口，并采用固定优先级
`line install > word write > victim read > lookup`。四类访问在握手沿互斥；
等待中的 victim response 会保留 bank 所有权，直到其与 control 完成握手。
word write 和 line install 在请求握手沿即完成提交，不设置多余的确认响应。

### Data array

数据阵列按 word bank 组织：

```text
data[way][word_bank][set] : logic [31:0]
```

每个 bank 都是独立的同步 1R1W 存储体：

- lookup 只激活每个 way 中的目标 word bank；
- victim read 并行激活目标 way 的所有 banks；
- refill install 并行写目标 way 的所有 banks；
- store hit 只写一个 way 中的一个 bank。

store 和 refill 通过独立的 word-write 和 line-install 通道进入 array，在 array
内部仲裁后共享同一组 bank 写端口。store 使用 lookup 返回的旧 word 进行
byte merge，然后整 32 位写回，因此 RAM 不需要 byte-enable 端口：

```text
byte_mask   = expand(wstrb)
merged_word = (old_word & ~byte_mask) | (wdata & byte_mask)
```

lookup、victim read、word write 和 line install 全局互斥，不依赖 RAM 的
read-first/write-first 行为。
data 和 tag payload 不复位，复位只清除 valid、dirty 和控制状态。

### Cache maintenance

顶层 maintenance 请求使用单一枚举区分 clean-all 与 invalidate-all，因而不存在两个
控制信号同时有效的非法组合。接口只允许一笔请求在途：请求可在 cache 忙时立即接收，
并从请求 valid 出现的同周期开始停止新的 CoreBus 准入；已有事务继续执行和返回，直到
事务表完全为空。维护响应完成握手前保持 quiesce，不恢复普通请求。

array 的 clean 按 set、way 升序检查元数据，只为 `valid && dirty` 的条目读取完整
line。脏行响应在 AXI 写回完成前保持稳定；B 成功后握手并清 dirty，B 失败时握手退出
但保留失败行 dirty。独立 done 通道覆盖没有脏行的空扫描。此前成功的行保持 clean，
失败行和未扫描行可由下一次 clean 安全重试。只读实例把 clean 作为成功空操作。

invalidate 每周期清除一个 set 的全部 valid 和 dirty，不读取 data、不写回内存，也不
修改 PLRU。它明确允许丢弃 dirty 数据；需要保留数据时，调用方必须先 clean、再
invalidate。

### Lookup pipeline

CoreBus 请求握手、事务槽分配和首次 lookup 发射是同一个原子事件。lookup 请求携带
`txn_id、epoch、set、tag、word`，每个 lookup 在发射前已经拥有事务槽。

array 在请求握手沿读取所有 way 的 tag/valid/dirty 和目标 word bank，在边界内部完成
tag compare、唯一命中检查、hit way/data 选择和 invalid-first/PLRU victim 选择。
`LookupLatency` 周期后只返回语义结果，不把 all-way 原始阵列数据跨模块传输。响应没有
ready，control 必须每周期消费到达的完成事件；这省去了宽响应总线和弹性 FIFO。

默认 `LookupLatency=1、MaxOutstanding=2` 时，流水充满后可以每周期接受并完成一个
load hit。CoreBus 背压只占用事务 credit，不反压 array lookup 结果。

## 事务队列和有序响应

transaction queue 使用深度为 `MaxOutstanding` 的寄存器数组及 head/tail/usage
指针，而不是普通流 FIFO。每个队列项只保存：

```text
block_addr
word_index
state
rdata
error
```

lookup 结果通过 `txn_id` 随机更新对应槽；CoreBus 只能观察队首 done 事务。响应被
反压时，队首内容保持不变并继续占用 credit。满队列支持同周期 response pop 和新
request push。

store barrier 保证同一时间最多只有一个活动 store，因此
`wdata/wstrb/store txn_id` 只保存一份，不随 `MaxOutstanding` 复制。只读实例通过
generate 完全移除这些寄存器。

## 请求生命周期

### Load hit

1. CoreBus 握手时分配事务槽并发射 lookup。
2. 当前 epoch 的 lookup 结果完成 tag 比较和 way 选择。
3. array 返回命中结果，control 将 word 写入事务槽。
4. 事务到达队首后完成 CoreBus 响应。

PLRU 在成功 install 的提交沿更新一次；stale epoch 响应、失败 miss 和仅被选择而未安装
的 victim 都不会更新替换状态。

### Store hit

store 只有在全部更老 lookup 返回后才允许握手。store 发射后禁止年轻 lookup：

1. lookup 返回命中 way 和旧 word；
2. control 锁存命中 way 及 merged word；
3. 下一独占周期通过统一写端口写入 32 位 word 并设置 dirty；
4. 提交沿将 store 事务标记为 done 并解除 barrier。

store 响应不可能早于 data 和 dirty 提交，也不会重复执行写入。

### Miss 和 replay

全局 miss 状态为：

```text
RUN
  -> MISS_DRAIN
  -> optional VICTIM_READ
  -> MISS_REQUEST
  -> MISS_WAIT
  -> INSTALL or ERROR
  -> optional REPLAY
  -> RUN
```

发现 miss 时一次性锁存 owner、set、victim way/tag/dirty 并翻转 epoch。新请求立即
停止，已经进入 lookup 流水的年轻响应因 epoch 不匹配而只用于排空，并把原事务恢复
为 replay。它们不修改结果、data、dirty 或 PLRU。

替换优先选择最低编号 invalid way；所有 way 有效时使用 Tree-PLRU。`WayCount=1`
不生成 PLRU 状态，其他二次幂路数每组保存 `WayCount-1` 位。PLRU 只在有效 load
hit、已提交 store hit 和成功 install 时更新。

dirty victim 通过 array 的整 line 响应直接进入 line-write 请求；若 AXI engine
反压，array 保持该响应，不在 control 中复制另一份 line buffer。clean 或 invalid
victim 跳过此读取。

line-read 成功时：

- load miss 直接安装 clean line，并从 refill line 选择目标 word 完成 owner；
- store miss 先进行 byte merge，再安装 dirty line 并完成 owner；
- tag、data、valid、dirty 和 Tree-PLRU 在同一个 install 提交沿更新；
- 年轻事务从保存的队列项按原顺序重新发射。

line-read/install 和 lookup 从不并发，因此不存在部分安装、同地址旁路或不确定 RAM 冲突。

## AXI line-read/line-write

control 与 AXI engine 之间使用独立 line-read 和 line-write 事务；maintenance 只产生
line-write。接口拆分后不再用 valid bit 在一个 payload 中编码读写组合：

```text
line-read : block_addr                  -> line, error
line-write: block_addr, line_data       -> error
```

为节约资源，`cache_line_axi_engine` 内部仍只包含一个 line buffer、一个 beat counter
和一个阻塞式 FSM。空闲时一次只接收一笔 read 或 write，执行路径分别为：

```text
line-write: AW -> W beats -> B -> write response
line-read : AR -> R beats -> read response
```

- 地址按 line 对齐；
- `AxLEN=LineBeats-1`、`AxSIZE=2`、`AxBURST=INCR`；
- dirty miss 由 control 显式执行 line-write，并在 B 成功后才发起 line-read；
- maintenance 只连接 line-write 路径，绝不因 clean 发出 AR；
- control 是当前唯一的 line-read 请求方，因此读路径无需顶层仲裁；
- control 与 maintenance 的 line-write 在顶层仲裁，并在请求握手时锁存响应 owner；
- 读写通道虽然分离，但当前不做 AXI 读写并发，以保持错误语义简单并避免复制资源。

BID/BRESP 错误会终止 miss 并跳过 line-read。RID/RRESP、beat 数或 RLAST 错误会完成
错误响应，但不会安装部分 line。任何失败都保留原 victim；即使 line-write 已经成功
而 line-read 失败，原 dirty line 仍可安全重试。

`ReadOnly=1` 通过 generate 移除 dirty array、store context 和 writeback 请求来源，
AXI AW/W/B 输出保持为零并由 assertion 保护。

## 验证

独立 lint 覆盖普通、只读、最小参数、4-way 和两周期 lookup 配置：

```bash
make cache-dev-lint
```

独立 cache 文件列表按顺序编译 `riscv_common_pkg`、`riscv_bus_pkg` 和
`cache_pkg`，不包含 `riscv_core_pkg`；这同时构成 package 解耦的静态检查。

自检环境按职责拆为：

- `cache_axi_memory_model.sv`：后端内存、AXI 五通道独立随机等待、错误注入和计数；
- `cache_corebus_scoreboard.sv`：在请求握手沿入队，并严格按序检查响应和 error；
- `cache_tb.sv`：driver、参考内存、定向场景和可复现随机序列。

测试入口不变：

```bash
make cache-dev-test
```

测试覆盖 cold miss、hit、连续 load、CoreBus 背压、byte/half/word store、store
miss、dirty writeback、clean/invalidate、维护排空和响应反压、maintenance B 错误
重试、invalid 优先、Tree-PLRU、年轻 lookup replay、AXI 通道背压、
writeback/refill 错误、只读实例、direct-mapped 和 4-way 配置。随机序列可通过
`+seed=<value>` 复现。`cache-dev-test` 还运行 `BlockBytes=4`、`SetCount=1`、
`WayCount=1`、`MaxOutstanding=1` 的最小边界自检，以及 `LookupLatency=2` 配置。

主工程仍使用：

```bash
make lint
make verilator
```

开发完成后若要接入 SoC，必须先扩展 `cache_axi4_mux` 的 burst credit 和每 ID 响应
缓冲，并确认 D-cache 前的完整 MMIO 地址旁路。
