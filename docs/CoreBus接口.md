# CoreBus 接口

CoreBus 是核心内部连接取指、访存和总线适配器的轻量级顺序事务接口。协议结构定义以
`rtl/bus/riscv_bus_pkg.sv` 为准；数据字和 byte enable 等共享基础类型定义在
`rtl/common/riscv_common_pkg.sv`。

## 信号方向

| 方向 | 主要字段 |
| --- | --- |
| master -> slave | `addr`、`write`、`size`、`wdata`、`wstrb`、`req_valid`、`rsp_ready` |
| slave -> master | `req_ready`、`rdata`、`error`、`rsp_valid` |

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

`write=0` 表示读，`write=1` 表示写。`size` 使用 `core_bus_size_e`，分别表示 byte、
halfword 和 word，编码与 AXI `AxSIZE` 一致。该类型属于 CoreBus ABI，与核心内部
`mem_size_e` 相互独立；MEM stage 在产生数据请求时逐项完成两者转换。地址必须保留
byte offset，并按访问宽度自然对齐。

读请求的 `wdata` 和 `wstrb` 必须为零。写请求的 `wdata` 按地址低位移动到目标
lane，`wstrb` 标识有效 byte。写响应的 `rdata` 为零；`error=1` 表示访问失败。

## 核心内使用

- IF 只发送对齐的 word 读请求，并用 FIFO 保存请求 PC。
- MEM 在请求前完成地址对齐检查、store lane 生成和 load 元数据保存。
- `corebus_addr_router` 在 D-cache 前按地址选择内部设备或外部存储路径。
- `icache` 和 `dcache` 分别把 CoreBus 事务转换为单拍 AXI4 事务。
- `cache_axi4_mux` 汇聚两路 AXI4 请求，并按 AXI ID 返回读响应。

协议不限制 outstanding 深度，但使用方必须保存每个已接受请求的元数据，并确保
响应仍按顺序匹配。当前数据侧深度固定为 1，取指侧深度由参数控制。

RTL 中保留请求、响应稳定性和关键编码约束的仿真 assertion。
