# Cache 架构

## 当前集成

顶层实现指令缓存。`rtl/icache/` 中的 `icache` 是流水线缓存，由 `ysyx_25080230`
接在 SoC 取指 CoreBus 上。需要无 interface 端口的设计可实例化
`rtl/top/icache_top.sv`，它把 CPU 侧 CoreBus 从设备和存储器侧 AXI4 主设备展开为
标量引脚。默认位宽、块大小、组数、路数和替换策略只定义在
`icache_pkg` 的 `ICacheAddrWidth` / `ICacheDataWidth` / `ICacheBlockBytes` /
`ICacheSetCount` / `ICacheWayCount` / `ICacheReplacementPolicy`；顶层实例不覆盖这些参数。
阵列用组合读 `mem_1rw` 当拍完成 tag/data 比较，结果打入一拍 `stream_register`。
命中由 `icache_rsp` 在 lookup 可见的下一拍回应 CPU；缺失由 `icache_miss` 发一次 AXI4
INCR burst，把整行写入阵列后再回应，`ARLEN` 由块内 word 数决定。先前的阻塞式实现保留在
`rtl/icache_old/`，不再接入 SoC。仿真期 `icache_performance_stats` 观察 CoreBus、lookup
和 refill，请求在接受的下一拍入账，时间戳仍用接受周期；口径见 [性能计数器](性能计数器.md)。

每个实例最多有一笔 miss 在途。回填数据直接写入最终阵列位置，缺失通路只保存 beat 计数、
错误位和目标 word；不使用缓存行暂存寄存器或 MSHR 队列。`FENCE.I` 连接到 `invalidate_i`。
已经进入 lookup 的请求照常回应，回应之后再清除全部 valid；清除完成前不接受新请求。

## 顶层总线路径

```text
CoreBus imem -> icache -> burst splitter -> AXI4 fixed-priority arbiter -> external AXI4
CoreBus dmem -> CLINT or mem_axi4 -------------------------------^
```

数据侧不是 D-cache。非 CLINT 数据访问由 `mem_axi4` 直接转换为一笔 AXI4 读或写，
并保持单 outstanding。写地址和写数据可独立握手；模块不保存请求 payload 或响应数据。

`axi4_fixed_priority_arb` 在 AR 冲突时固定选择数据侧，AR 被反压时只锁存一位授权来源。
数据侧独占 AW/W/B 通道；R 通道按固定 ID 直接分发给 I-cache 或数据侧适配器。因此仲裁器
不设置响应 FIFO、credit 计数或额外的读数据寄存器。

`axi4_burst_splitter` 只为当前外部单拍 endpoint 提供临时兼容：保存一笔突发的起始地址、
ID、SIZE、LEN 和 beat 计数，逐拍发出 `ARLEN=0` 的 INCR 读请求，R 数据直通并在原突发
末拍恢复 `RLAST`。它不处理写通道、不保存响应数据，也不允许多个子请求同时在途。

## 边界与限制

- I-cache 为只读缓存；没有 D-cache、写回、写分配或 I/D 一致性。
- 所有 CLINT 地址在进入 AXI 适配器前旁路。
- 当前不支持 hit-under-miss、多个 MSHR 或 CoreBus 无序响应。
- AXI 读响应 ID 固定为 `ICACHE_AXI_ID` 或 `MEM_AXI_ID`；其他 ID 由协议断言报告。
