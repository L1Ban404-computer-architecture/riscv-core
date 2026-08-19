# CoreBus 接口

CoreBus 是核心内部连接取指、访存和总线适配器的轻量级顺序事务接口。参数化信号定义
以 `rtl/bus/riscv_bus_if.sv` 中的 `core_bus_if` 为准；协议枚举和常量由
`rtl/bus/riscv_bus_pkg.sv` 拥有。interface 不包含时钟和复位，行为模块仍显式接收
`clk_i/rst_ni`。

`core_bus_if` 的 `AddrWidth`、`DataWidth` 默认均为 32，`StrbWidth=DataWidth/8` 且不可
从实例外覆盖。`master`、`slave` 和 `monitor` modport 分别用于发起端、接收端和只读
scoreboard；跨模块端口必须声明合适的 modport。

## Payload 与握手边界

CoreBus 将请求和响应分别封装成 typed payload；`valid/ready` 独立存在，不放入
payload，也不在 interface 中保留同一字段的兼容别名：

```systemverilog
core_bus.req_payload.addr
core_bus.req_payload.wdata
core_bus.rsp_payload.rdata
core_bus.rsp_payload.error
core_bus.req_valid, core_bus.req_ready
core_bus.rsp_valid, core_bus.rsp_ready
```

| payload | 字段 |
| --- | --- |
| `req_payload_t` | `addr`、`write`、`size`、`wdata`、`wstrb` |
| `rsp_payload_t` | `rdata`、`error` |

接口参数决定 payload 内字段宽度；请求或响应整体赋值适用于同一几何的总线连接。
只有在 `mem_size_e` 与 `core_bus_size_e` 等不同协议类型之间才保留显式字段转换。

## 信号方向

| 方向 | 主要字段 |
| --- | --- |
| master -> slave | `req_payload`、`req_valid`、`rsp_ready` |
| slave -> master | `req_ready`、`rsp_payload`、`rsp_valid` |

请求和响应各自使用 ready/valid：

```systemverilog
req_fire = req_valid && req_ready;
rsp_fire = rsp_valid && rsp_ready;
```

协议约束如下：

1. 等待 `req_ready` 时，master 保持请求 valid 和 payload 稳定。
2. 等待 `rsp_ready` 时，slave 保持响应 valid 和 payload 稳定。
3. 每个请求恰好产生一个响应，写请求也不例外。
4. 响应严格按请求接受顺序返回，不使用事务 ID。
5. 允许请求与对应响应在同一周期完成握手。

## 编码

`write=0` 表示读，`write=1` 表示写。`size` 使用固定 2-bit 的 `core_bus_size_e`，分别
表示 byte、halfword、word 和 doubleword，编码与 AXI `AxSIZE` 一致。该类型属于
CoreBus ABI，与核心内部
`mem_size_e` 相互独立；MEM stage 在产生数据请求时逐项完成两者转换。地址必须保留
byte offset，并按访问宽度自然对齐。

读请求的 `wdata` 和 `wstrb` 必须为零。写请求的 `wdata` 按地址低位移动到目标
lane，`wstrb` 标识有效 byte。写响应的 `rdata` 为零；`error=1` 表示访问失败。

## 核心内使用

- IF 只发送对齐的 word 读请求。当前 I-cache 为阻塞式实现，IF 固定只保留一笔
  已接受且待响应的请求元数据；已返回指令进入独立的响应 FIFO。
- MEM 在请求前完成地址对齐检查、store lane 生成和 load 元数据保存。
- `corebus_addr_router` 在 D-cache 前按地址选择内部设备或外部存储路径。
- `icache` 和 `dcache` 分别把 CoreBus 事务转换为单拍 AXI4 事务。
- `cache_axi4_mux` 汇聚两路 AXI4 请求，并按 AXI ID 返回读响应。

协议不限制 outstanding 深度，但使用方必须保存每个已接受请求的元数据，并确保
响应仍按顺序匹配。当前数据侧与取指侧深度均固定为 1；IF 的
`FetchOutstandingDepth` 参数仅为接口兼容性保留，并由 assertion 约束为 1。

RTL 中保留请求、响应稳定性和关键编码约束的仿真 assertion。

## AXI4 interface

同文件中的 `axi4_if` 保存项目使用的 AXI4 五通道子集，提供相同的
`master/slave/monitor` modport。`AddrWidth=32`、`DataWidth=32`、`IdWidth=4` 为默认值，
strobe 宽度由数据宽度自动派生；LEN、SIZE、BURST 和 RESP 等协议字段保持 AXI 固定
宽度。每个通道的数据字段也分别组成 payload，握手仍是独立的标量：

| 通道 | payload 字段 |
| --- | --- |
| AW | `addr`、`id`、`len`、`size`、`burst` |
| W | `data`、`strb`、`last` |
| B | `resp`、`id` |
| AR | `addr`、`id`、`len`、`size`、`burst` |
| R | `resp`、`data`、`last`、`id` |

例如 `axi.aw_payload.addr` 与 `axi.awvalid` 配套使用。AXI ID 常量是 package 中的
整数，在连接具体 interface 时按 `IdWidth` 显式转换，拥有行为的模块同时检查常量
可表示性。AXI mux 在通道边界整体转移 payload；读响应 FIFO 可以使用局部等价类型，
但只在 FIFO 边界做一次结构转换。

通用 `corebus_addr_router` 和 `cache_axi4_mux` 支持非默认几何，包括高地址位、8-bit
strobe、ID 路由和背压。RV32 core、CLINT 及当前 cache endpoint 仍使用默认 32-bit
数据配置，这不代表 RV64 支持。
