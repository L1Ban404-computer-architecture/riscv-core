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

// MEM 中尚未返回的 load 目标寄存器，用于阻塞不能立即满足的 RAW 相关。
interface mem_pending_if;
  logic valid;
  riscv_core_pkg::mem_pending_payload_t payload;
  modport producer(output valid, payload);
  modport consumer(input valid, payload);
  modport monitor(input valid, payload);
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

// 提交后的 CSR 架构状态快照，仅用于退休调试观察，不参与流水控制。
interface csr_state_if;
  riscv_core_pkg::csr_state_payload_t payload;
  modport producer(output payload);
  modport consumer(input payload);
  modport monitor(input payload);
endinterface

// 控制流改道事件；valid 当拍的 target_pc 是下一条应取指的架构 PC。
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

////////////////////////
// 调试与性能观测接口 //
////////////////////////

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

/////////////////////////////
// 流水级 ready/valid 接口 //
/////////////////////////////

// 当前目标工具对 parameterized interface port 的 modport 语法和
// interface clone 支持不完整，实际核心使用下面的 typed wrapper；wrapper
// 只固定事务类型，不重新声明其中的字段。

// 每个边界只重复协议壳，不重复 payload 字段。payload 类型由 package 统一拥有，
// 这样既保留了 modport 方向检查，也避开目标工具对 parameterized interface port
// 的限制。
interface if_id_if;
  logic valid;
  logic ready;
  riscv_core_pkg::if_id_payload_t payload;
  modport producer(output valid, payload, input ready);
  modport consumer(input valid, payload, output ready);
  modport monitor(input valid, ready, payload);
endinterface

interface id_ex_if;
  logic valid;
  logic ready;
  riscv_core_pkg::id_ex_payload_t payload;
  modport producer(output valid, payload, input ready);
  modport consumer(input valid, payload, output ready);
  modport monitor(input valid, ready, payload);
endinterface

interface ex_mem_if;
  logic valid;
  logic ready;
  riscv_core_pkg::ex_mem_payload_t payload;
  modport producer(output valid, payload, input ready);
  modport consumer(input valid, payload, output ready);
  modport monitor(input valid, ready, payload);
endinterface

interface mem_wb_if;
  logic valid;
  logic ready;
  riscv_core_pkg::mem_wb_payload_t payload;
  modport producer(output valid, payload, input ready);
  modport consumer(input valid, payload, output ready);
  modport monitor(input valid, ready, payload);
endinterface
