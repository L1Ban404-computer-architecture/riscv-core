# 流水线和 cache 回退

当前保留五级结构，但从取指请求分配到 WB 提交只允许一条在途指令。SoC 取指侧
已恢复 I-cache；流水线单指令限制仍可独立恢复。若修改已形成独立提交，也可审阅后
`git revert <实际提交号>`。

## 恢复流水线

1. `rtl/core/pipeline/if_stage.sv`：删除 `instruction_active_q` 及其独立
   `always_ff`、`retire_i` 输入，恢复：
   ```systemverilog
   assign fetch_req_valid = !boot_pending_q && !frontend_flush;
   ```
   删除 `SingleInstructionAllocation/Retire/Hold` 三个断言及其局部 lint 豁免和说明。
2. `rtl/core/riscv_core_impl.sv`：删除 IF 的 `.retire_i(...)`、性能模块的
   `.if_local_stall_enable_i(...)` 及对应临时注释。
3. `rtl/core/pipeline/performance_stats.sv`：删除 `if_local_stall_enable_i` 输入和
   临时注释，恢复：
   ```systemverilog
   assign if_local_stall = if_id.ready && !if_id.valid && !redirect.valid;
   ```

保留原有前递、CSR/SYSTEM 串行化、总线请求保持、redirect/stale 和异常处理。
当前多周期模式仅排除后端执行期间的 IF starve；`cycle_count` 仍计全部非复位周期，
`instret_count` 仍包括异常提交。恢复流水线无需修改其他计数器。

## I-cache 现状

`ysyx_25080230` 取指路径已实例化 `icache`，`icache_invalidate_o` 接到
`invalidate_i`。仿真下 cache 性能计数经 `icache_performance_debug_if` 拆平为
`debug_perf_icache_*`。数据侧 `u_mem_axi4`、仲裁器和 AXI ID 保持原样。
`riscv_core_sim` 仍直连 DPI 存储器，不覆盖 cache/AXI 通路。

## 验证

```sh
make check sim-lint
make -C ../mini-soc lint build
```

回退流水线后，应在仿真中确认多条指令重叠执行。若本机 Verilator 对原版本
报告既有 `SYNCASYNCNET` 告警，可用：

```sh
make check sim-lint \
    VERILATOR_WARNINGS="-Wno-PINCONNECTEMPTY -Wno-IMPORTSTAR -Wno-SYNCASYNCNET"
```

cache 通路通过 SoC 顶层验证：重复访问应命中，FENCE.I 后重新取指。mini-soc 不覆盖
cache/AXI 通路。差分使用 runner 和 NEMU 共同支持的指令；当前 NEMU 不支持 FENCE.I，
该指令需在 SoC 仿真中单独观察提交、失效和重新取指行为。所有生成物放在 `build/`。
