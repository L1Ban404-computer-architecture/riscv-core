# CPU 核心整体架构

本文档是跨流水级行为的单一事实源。各 stage 的组合数据通路、局部寄存器和测试
细节由对应设计文档说明。

## 1. 范围与顶层

核心是单发射、顺序执行、顺序退休的 RV32I 五级流水线：

```text
IF -> ID -> EX -> MEM -> WB
```

- `riscv_core_impl`：双 CoreBus 内部核心。
- `ysyx_25080230`：公开 SoC 顶层，串行到单路 AXI4 Master。
- IF/ID、ID/EX、EX/MEM、MEM/WB 状态分别归 IF、ID、EX、MEM 所有。
- WB 是 GPR、CSR、trap 和 MRET 的唯一架构提交点。

公开 AXI 和 Verilator 调试信号属于集成 ABI；内部流水类型不是稳定 API。

## 2. 事务与 payload

所有级间边界遵循 ready/valid：

```text
fire = valid && ready
```

producer 在 `valid && !ready` 时保持 valid 和 payload；consumer 可组合产生 ready。
清除 valid 后 payload 可以保留旧值，任何旁路或副作用都必须用所属 stage valid
门控。

每条指令只携带一份 `instruction_bus_t {pc, instr}`。ID 将 decoder 的 legality
转换为 `exception_bus_t`，ID/EX 之后的执行控制不再携带重复的非法标志。
EX 构造一次 `retire_meta_bus_t`，MEM 和 WB 继续使用同一类型。

| 边界 | 主要内容 |
| --- | --- |
| IF/ID | instruction、取指异常 |
| ID/EX | instruction、寄存器地址和值、立即数、执行控制、异常 |
| EX/MEM | 访存请求、写回候选、异常、提交控制、退休元数据 |
| MEM/WB | 最终写回候选、异常、提交控制、退休元数据 |

## 3. 背压与前递

背压从 WB 逐级传回 IF，没有全局 stall。ID/EX、EX/MEM 和 MEM/WB 使用单入口
弹性寄存器，允许满载时同拍 pop/push。

EX 的前递优先级固定为：

```text
EX/MEM > MEM pending load > MEM/WB > ID 锁存的寄存器值
```

匹配但数据尚未有效时，EX 保持当前 ID/EX 事务。若 MEM/WB 的值在停顿期间短暂
出现，forwarding unit 会保存它直到当前事务执行，避免退回旧寄存器值。

## 4. Redirect 与 flush

redirect 有两个来源：

- EX：taken branch/JAL/JALR，仅冲刷 IF 前端；
- WB：trap/MRET，优先级更高，并清除全部年轻后端事务。

EX redirect 绑定 EX/MEM 输入 fire，同周期 IF 屏蔽 IF/ID 输出并重新设定取指 PC。
已经向 CoreBus 拉高的请求不会被撤销。

CoreBus 指令响应严格有序。IF 维护“待丢弃响应数”：

1. redirect 将所有已经接受的旧路径请求计入丢弃范围；
2. 已暴露但受背压的请求继续保持，接受后也作为旧路径响应丢弃；
3. 尚未暴露的 holding request 可以直接清除；
4. 重复 redirect 重新覆盖当前 outstanding 数量，不依赖有限宽度 epoch。

## 5. 精确异常与 CSR

异常可以在 IF、ID、EX 或 MEM 检测，但只在 WB 提交。较老异常始终覆盖年轻普通
副作用和 redirect。

支持的同步异常包括取指/数据访问错误、非法指令、断点、ECALL、数据地址未对齐和
控制流目标未对齐。JALR 先清除目标 bit 0，再按 IALIGN=32 检查。

CSR/SYSTEM 指令串行化：进入 EX 前等待更老 EX/MEM、LSU 和 MEM/WB 排空，年轻
指令不能越过它。`mepc[1:0]` 恒为零；MRET 使用合法化后的 mepc，不产生额外的
目标未对齐异常。

提交优先级为：

```text
trap entry > MRET > 普通 CSR/GPR 写回
```

## 6. 访存顺序

数据侧固定单 outstanding。访存请求与元数据槽写入是同一原子事件；load/store
都等待 CoreBus 响应。pending load 标量接口只暴露尚未得到数据的目标寄存器。

在响应到达前，年轻访存和非访存事务均不能越过当前访存。错误响应进入 MEM/WB
后继续阻止年轻请求，直到 trap 提交。多 outstanding 需要另行设计 WB 提交式
store buffer，不通过恢复深度参数实现。

CoreBus 地址保留完整有效地址和 size。读请求 `write=0,wdata=0,wstrb=0`；store
在 MEM 根据地址低位生成 lane 对齐的 wdata/wstrb。

## 7. 退休与调试

`core_retire_valid_o` 表示本周期有一条指令退休；退休和状态结构保持最后一次快照。
异常指令也退休，但不产生普通 GPR/CSR/内存成功事件。顶层把结构体展平为固定的
Verilator 公共信号，功能控制不得依赖调试通路。

## 8. 已知限制与后续工作

- 不支持中断、其他特权级、M/C/F/A 扩展、缓存、MMU 和分支预测。
- AXI adapter 串行所有指令和数据事务，数据请求优先。
- 零延迟 CoreBus 与 fall-through buffer 形成有意的组合 ready 路径；STA 必须
  在目标工艺上确认。
- 更深数据 outstanding、预测取指或无序响应都需要新的提交/tag 架构。
- 流片前仍需 PDK 综合、STA、CDC/RDC、门级仿真和外部 ISS 差分签核。
