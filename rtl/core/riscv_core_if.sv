// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNDRIVEN */
/* verilator lint_off UNUSEDSIGNAL */

// 核心内部接口。
//
// 定义前递、CSR、改道以及各级流水边界的信号和 modport。

// WB 确认的 GPR 写入。
interface gpr_write_if;
  logic valid;
  riscv_core_pkg::reg_addr_t rd_addr;
  riscv_core_pkg::word_t wdata;
  modport producer(output valid, rd_addr, wdata);
  modport consumer(input valid, rd_addr, wdata);
  modport monitor(input valid, rd_addr, wdata);
endinterface

// ID 到寄存器堆的两路组合读；同拍写回值由 ID 前递单元选择。
interface gpr_read_if;
  riscv_core_pkg::reg_addr_t rs1_addr;
  riscv_core_pkg::reg_addr_t rs2_addr;
  riscv_core_pkg::word_t rs1_value;
  riscv_core_pkg::word_t rs2_value;
  modport requester(output rs1_addr, rs2_addr, input rs1_value, rs2_value);
  modport responder(input rs1_addr, rs2_addr, output rs1_value, rs2_value);
endinterface

// CSR 与全局控制接口

// EX 到 CSR 单元的组合读端口，同时返回地址是否实现，供非法指令检查使用。
interface csr_read_if;
  riscv_core_pkg::csr_addr_t addr;
  riscv_core_pkg::word_t data;
  logic implemented;
  modport requester(output addr, input data, implemented);
  modport responder(input addr, output data, implemented);
endinterface

// WB 提交 CSR、trap 或 MRET 的互斥状态更新请求。
interface csr_commit_if;
  riscv_core_pkg::csr_commit_payload_t payload;
  modport producer(output payload);
  modport consumer(input payload);
endinterface

// 提交前的 trap/MRET 控制目标；与 Zicsr 组合读口分离。
interface csr_status_if;
  riscv_core_pkg::word_t mtvec;
  riscv_core_pkg::word_t mepc;
  modport producer(output mtvec, mepc);
  modport consumer(input mtvec, mepc);
endinterface

// 控制流改道事件；valid 当拍的 target_pc 是下一条应取指的架构 PC。
// FENCE.I 也走本接口做前端重取。
interface redirect_if;
  logic valid;
  riscv_core_pkg::pc_t target_pc;
  modport producer(output valid, target_pc);
  modport consumer(input valid, target_pc);
  modport monitor(input valid, target_pc);
endinterface

// 流水级 ready/valid 接口，同时连接本级计算输出与级间寄存器。

// 工具链不支持泛型 interface 端口；宏复用握手定义，payload 类型由 package 拥有。
// fire 由握手派生，所有 modport 只读。
`define RISCV_CORE_PIPELINE_STREAM_IF(__name, __payload_t) \
  interface __name; \
    logic valid; \
    logic ready; \
    logic fire; \
    __payload_t payload; \
    assign fire = valid && ready; \
    modport producer(output valid, payload, input ready, fire); \
    modport consumer(input valid, payload, fire, output ready); \
    modport monitor(input valid, ready, fire, payload); \
  endinterface

`RISCV_CORE_PIPELINE_STREAM_IF(if_id_if, riscv_core_pkg::if_id_payload_t)
`RISCV_CORE_PIPELINE_STREAM_IF(id_ex_if, riscv_core_pkg::id_ex_payload_t)
`RISCV_CORE_PIPELINE_STREAM_IF(ex_mem_if, riscv_core_pkg::ex_mem_payload_t)
`RISCV_CORE_PIPELINE_STREAM_IF(mem_wb_if, riscv_core_pkg::mem_wb_payload_t)

`undef RISCV_CORE_PIPELINE_STREAM_IF
