// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNDRIVEN */
/* verilator lint_off UNUSEDSIGNAL */

// 核心内部接口。
//
// 定义前递、CSR、改道、调试以及各级流水边界的信号和 modport。

/////////////////////////////
// 泛型流水 ready/valid 接口 //
/////////////////////////////

// 流水边界只拥有握手协议和一个 typed payload；具体事务字段由实例化时的
// PayloadT 决定，避免 interface 再复制一份 payload 字段列表。
interface pipeline_stream_if #(
  parameter type PayloadT = logic
);
  logic valid;
  logic ready;
  PayloadT payload;

  modport producer(output valid, payload, input ready);
  modport consumer(input valid, payload, output ready);
  modport monitor(input valid, ready, payload);
endinterface

// 通用 GPR 写回候选。valid 表示存在写回语义，data_valid 表示数据已经可前递。
interface writeback_if;
  riscv_core_pkg::writeback_payload_t payload;
  modport producer(output payload);
  modport consumer(input payload);
  modport monitor(input payload);
endinterface

// ID 到寄存器堆的两路组合读；写回旁路仍由寄存器堆在内部完成。
interface gpr_read_if;
  typedef struct packed {
    riscv_core_pkg::reg_addr_t rs1_addr;
    riscv_core_pkg::reg_addr_t rs2_addr;
  } req_payload_t;

  typedef struct packed {
    riscv_common_pkg::word_t rs1_value;
    riscv_common_pkg::word_t rs2_value;
  } rsp_payload_t;

  req_payload_t req_payload;
  rsp_payload_t rsp_payload;
  modport requester(output req_payload, input rsp_payload);
  modport responder(input req_payload, output rsp_payload);
  modport monitor(input req_payload, rsp_payload);
endinterface

////////////////////////
// CSR 与全局控制接口 //
////////////////////////

// EX 到 CSR 单元的组合读端口，同时返回地址是否实现，供非法指令检查使用。
interface csr_read_if #(
  parameter int unsigned DataWidth = riscv_common_pkg::XLen,
  parameter int unsigned CsrAddrWidth = 12
);
  typedef struct packed {logic [CsrAddrWidth-1:0] addr;} req_payload_t;

  typedef struct packed {
    logic valid;
    logic [DataWidth-1:0] data;
  } rsp_payload_t;

  req_payload_t req_payload;
  rsp_payload_t rsp_payload;
  modport requester(output req_payload, input rsp_payload);
  modport responder(input req_payload, output rsp_payload);
  modport monitor(input req_payload, rsp_payload);
endinterface

// WB 提交 CSR、trap 或 MRET 的互斥状态更新请求；提交优先级由 CSR 单元实现。
interface csr_commit_if;
  riscv_core_pkg::csr_commit_payload_t payload;
  modport producer(output payload);
  modport consumer(input payload);
  modport monitor(input payload);
endinterface

// 提交前的 trap/MRET 控制目标；与 Zicsr 组合读口分离。
interface csr_status_if;
  riscv_common_pkg::word_t mtvec;
  riscv_common_pkg::word_t mepc;
  modport producer(output mtvec, mepc);
  modport consumer(input mtvec, mepc);
  modport monitor(input mtvec, mepc);
endinterface

// 控制流改道事件；valid 当拍的 target_pc 是下一条应取指的架构 PC。
// FENCE.I 也走本接口做前端重取；架构提交类别由 commit_event_if 单独给出。
interface redirect_if #(
  parameter int unsigned AddrWidth = riscv_common_pkg::XLen
);
  typedef struct packed {logic [AddrWidth-1:0] target_pc;} payload_t;

  logic valid;
  payload_t payload;
  modport producer(output valid, payload);
  modport consumer(input valid, payload);
  modport monitor(input valid, payload);
endinterface

// WB 唯一提交点给出的退休类别。valid 与 MEM/WB fire 同拍；kind 仅在 valid 时有意义。
interface commit_event_if;
  logic valid;
  riscv_core_pkg::commit_kind_e kind;
  modport producer(output valid, kind);
  modport consumer(input valid, kind);
  modport monitor(input valid, kind);
endinterface

////////////////////////
// 调试与性能观测接口 //
////////////////////////

`ifndef SYNTHESIS
// 提交后的 CSR 架构状态快照，仅用于退休调试观察，不参与流水控制。
interface csr_state_if;
  riscv_core_pkg::csr_state_payload_t payload;
  modport producer(output payload);
  modport consumer(input payload);
  modport monitor(input payload);
endinterface

// 单条退休事件及其架构副作用快照。valid 仅在退休当拍拉高；valid 为零时其余
// 字段无效，生产者可以将其清零。
interface retire_debug_if;
  logic valid;
  riscv_core_pkg::retire_debug_payload_t payload;
  modport producer(output valid, payload);
  modport consumer(input valid, payload);
  modport monitor(input valid, payload);
endinterface

// 实时性能计数快照。所有计数器只供仿真分析，不参与核心功能控制。
interface performance_debug_if;
  riscv_core_pkg::performance_debug_payload_t payload;
  modport producer(output payload);
  modport consumer(input payload);
  modport monitor(input payload);
endinterface
`endif

/////////////////////////////
// 流水级 ready/valid 接口 //
/////////////////////////////

// 当前目标工具对 parameterized interface port 的 modport 语法和
// interface clone 支持不完整。pipeline_stream_if 保留为理想泛型；实际端口
// 使用下面的 typed wrapper。宏只生成协议壳，不重复 payload 字段。
`define RISCV_CORE_PIPELINE_STREAM_IF(__name, __payload_t) \
  interface __name; \
    logic valid; \
    logic ready; \
    __payload_t payload; \
    modport producer(output valid, payload, input ready); \
    modport consumer(input valid, payload, output ready); \
    modport monitor(input valid, ready, payload); \
  endinterface

`RISCV_CORE_PIPELINE_STREAM_IF(if_id_if, riscv_core_pkg::if_id_payload_t)
`RISCV_CORE_PIPELINE_STREAM_IF(id_ex_if, riscv_core_pkg::id_ex_payload_t)
`RISCV_CORE_PIPELINE_STREAM_IF(ex_mem_if, riscv_core_pkg::ex_mem_payload_t)
`RISCV_CORE_PIPELINE_STREAM_IF(mem_wb_if, riscv_core_pkg::mem_wb_payload_t)

`undef RISCV_CORE_PIPELINE_STREAM_IF
