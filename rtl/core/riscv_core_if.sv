// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 核心内部接口。
//
// 定义 GPR、CSR、改道、分支预测以及各级流水边界的信号和 modport。

// 工具链不支持泛型 interface 端口；宏只复用协议，payload 类型由 package 拥有。
// STREAM_IF 有背压，fire 由握手派生，所有 modport 只读。
`define RISCV_CORE_STREAM_IF(__name, __payload_t) \
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

// VALID_IF 表示单向、无背压事件；消费者按自身复位/清除规则采样。
`define RISCV_CORE_VALID_IF(__name, __payload_t) \
  interface __name; \
    logic valid; \
    __payload_t payload; \
    modport producer(output valid, payload); \
    modport consumer(input valid, payload); \
    modport monitor(input valid, payload); \
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

// WB 到 CSR 单元的组合读端口；地址合法性已在 ID 检查。
interface csr_read_if;
  riscv_core_pkg::csr_index_e index;
  riscv_core_pkg::word_t data;
  modport requester(output index, input data);
  modport responder(input index, output data);
endinterface

// WB 提交 CSR、trap 或 MRET 的互斥状态更新请求；NONE 表示无操作，无独立 valid。
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

// 截断 PC 标签的持续组合查询，无 valid/ready；调用方决定何时采纳预测。
// 目标仅传低位，由请求方拼接当前 PC 高位；taken 为零时 target 为零。
interface branch_predict_if;
  riscv_core_pkg::btb_tag_t tag;
  riscv_core_pkg::branch_prediction_payload_t payload;
  modport requester(output tag, input payload);
  modport responder(input tag, output payload);
  modport monitor(input tag, payload);
endinterface

// WB 确认的 GPR 写入。
`RISCV_CORE_VALID_IF(gpr_write_if, riscv_core_pkg::gpr_write_payload_t)

// 控制流改道事件；valid 当拍的 payload.target_pc 是下一条应取指的架构 PC。
// FENCE.I 同时携带 imem_invalidate，由 IF 在接受改道的当拍输出失效请求。
`RISCV_CORE_VALID_IF(redirect_if, riscv_core_pkg::redirect_payload_t)

// 已确认合法的训练结果；valid 在上升沿采样，复位/失效优先。
// 条件分支无论实际 taken 如何都提供编码目标；JAL 不更新 BHT。
`RISCV_CORE_VALID_IF(branch_update_if, riscv_core_pkg::branch_update_payload_t)

// 各级计算输出与寄存后的流水边界共享相同的 stream 协议。
`RISCV_CORE_STREAM_IF(if_id_if, riscv_core_pkg::if_id_payload_t)
`RISCV_CORE_STREAM_IF(id_ex_if, riscv_core_pkg::id_ex_payload_t)
`RISCV_CORE_STREAM_IF(ex_mem_if, riscv_core_pkg::ex_mem_payload_t)
`RISCV_CORE_STREAM_IF(mem_wb_if, riscv_core_pkg::mem_wb_payload_t)

`undef RISCV_CORE_VALID_IF
`undef RISCV_CORE_STREAM_IF
