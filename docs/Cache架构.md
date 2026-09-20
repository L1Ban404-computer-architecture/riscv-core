# Cache 架构

## 当前集成

顶层实现指令缓存。`rtl/icache/` 中的 `icache` 是阻塞式缓存，由 `ysyx_25080230`
接在 SoC 取指 CoreBus 上。需要无 interface 端口的设计可实例化
`rtl/top/icache_top.sv`，它把 CPU 侧 CoreBus 从设备和存储器侧 AXI4 主设备展开为
标量引脚。默认块大小、组数、路数和替换策略只定义在
`icache_pkg` 的 `ICacheBlockBytes` / `ICacheSetCount` / `ICacheWayCount` /
`ICacheReplacementPolicy`；顶层实例不覆盖这些参数。每路 tag 与 data 各一块读延迟
1 拍的 `sram_1rw`（查询当拍启动，下一拍用读出比较），valid 仍为寄存器。控制器在 Idle
启动查询，下一拍 Lookup 用读出结果判定命中或缺失；命中请求与 CoreBus 响应在 Lookup
同拍完成，miss
则以 AXI4 INCR 读回填一整行，`ARLEN` 由块内 word 数决定。仿真期
`icache_performance_stats` 观察已有
`core_bus_if.monitor`、lookup/refill monitor，按请求接受当拍的 lookup.hit 分类统计
请求数、命中数和命中/缺失延迟，不改控制器；口径见 [性能计数器](性能计数器.md)。

每个实例最多有一笔 miss 在途。回填数据直接写入最终阵列位置，控制器只保存回填组、路、
目标 word、beat 计数、错误位和旁路的响应 word；不使用缓存行暂存寄存器或 MSHR 队列。
`FENCE.I` 连接到 `invalidate_i`，I-cache 会先排空已有事务，再清除所有 valid 位。

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
