// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

`ifndef SYNTHESIS
package riscv_debug_pkg;
  import riscv_bus_pkg::*;
  import riscv_core_pkg::*;

  // 调试接口中的退休访存事件编码；相关调试 payload 类型同样由本 package 定义。
  typedef enum logic [1:0] {
    RETIRE_MEM_NONE = 2'd0,
    RETIRE_MEM_READ = 2'd1,
    RETIRE_MEM_WRITE = 2'd2
  } retire_mem_op_e;

  typedef struct packed {
    pc_t pc;
    instr_t instr;
    logic [63:0] instid;
  } instruction_debug_payload_t;

  // 退休观察器从功能 mem_req 与数据响应推导访存事件；功能通路不携带这些字段。
  typedef struct packed {
    retire_mem_op_e mem_op;
    mem_size_e mem_size;
    word_t mem_addr;
    word_t mem_data;
  } retire_mem_payload_t;

  typedef struct packed {
    logic valid;
    pc_t target_pc;
  } retire_redirect_payload_t;

  // 完整退休快照由核心顶层观察器生成，不随流水级功能事务传播。
  // 独立 valid 仅在退休当拍拉高；无效时这些字段不具有事件语义。
  typedef struct packed {
    instruction_debug_payload_t meta;
    logic gpr_we;
    reg_addr_t gpr_waddr;
    word_t gpr_wdata;
    retire_mem_payload_t mem;
    retire_redirect_payload_t redirect;
    csr_state_payload_t csr;
  } retire_debug_payload_t;

  // 仅供性能观测；顺序与仿真端的类别数组一致。
  localparam int unsigned PerfClassCount = 7;
  typedef enum logic [2:0] {
    PERF_COMPUTE, PERF_LOAD, PERF_STORE, PERF_BRANCH,
    PERF_JUMP, PERF_SYSTEM, PERF_OTHER
  } perf_class_e;

  typedef struct packed {
    logic [63:0] instret_count;
    logic [63:0] id_local_stall_cycle_count;
    logic [63:0] ex_local_stall_cycle_count;
    logic [63:0] mem_local_stall_cycle_count;
    logic [63:0] wb_local_stall_cycle_count;
  } class_performance_payload_t;

  // 响应首次有效时累计服务延迟；未响应的请求和取消不形成样本。
  typedef struct packed {
    logic [63:0] response_count;
    logic [63:0] latency_cycle_sum;
    logic [63:0] request_stall_cycle_count;
    logic [63:0] response_stall_cycle_count;
  } memory_performance_payload_t;

  // 局部阻塞按被挡在阶段入口的指令分类；IF 未译码，只统计总体。
  typedef struct packed {
    logic [63:0] cycle_count;
    logic [63:0] instret_count;
    // 最终送到 IF 的 redirect 事件总数，包含 EX 分支/FENCE.I 改道和 WB trap/MRET。
    logic [63:0] redirect_count;
    logic [63:0] if_local_stall_cycle_count;
    class_performance_payload_t [PerfClassCount-1:0] classes;
    memory_performance_payload_t imem;
    memory_performance_payload_t dmem;
  } performance_debug_payload_t;

  typedef struct packed {
    logic valid;
    logic ready;
  } stage_debug_payload_t;

  typedef struct packed {
    logic request_fire;
    logic response_fire;
    pc_t request_pc;
    logic result_valid;
    instr_t instr;
    logic access_fault;
    logic imem_flush;
    bus_debug_payload_t bus;
  } fetch_debug_payload_t;

  typedef struct packed {
    logic valid;
    logic ready;
    // 实际前端纠错/FENCE.I 事件与架构跳转语义分离。
    logic redirect;
    retire_redirect_payload_t branch;
  } execute_debug_payload_t;

  typedef struct packed {
    logic valid;
    logic ready;
    retire_mem_payload_t mem;
    bus_debug_payload_t bus;
  } memory_debug_payload_t;

  typedef struct packed {
    logic valid;
    logic ready;
    commit_kind_e kind;
    logic gpr_we;
    reg_addr_t gpr_waddr;
    word_t gpr_wdata;
    retire_redirect_payload_t redirect;
  } writeback_debug_payload_t;

  typedef struct packed {
    perf_class_e id_class;
    perf_class_e ex_class;
    perf_class_e mem_class;
    perf_class_e wb_class;
  } pipeline_perf_classes_t;

  function automatic perf_class_e classify_opcode(input logic [6:0] opcode,
                                                  input logic fetch_access_fault);
    if (fetch_access_fault) return PERF_OTHER;
    case (opcode)
      OPC_OP, OPC_OP_IMM, OPC_LUI, OPC_AUIPC: return PERF_COMPUTE;
      OPC_LOAD: return PERF_LOAD;
      OPC_STORE: return PERF_STORE;
      OPC_BRANCH: return PERF_BRANCH;
      OPC_JAL, OPC_JALR: return PERF_JUMP;
      OPC_SYSTEM, OPC_MISC_MEM: return PERF_SYSTEM;
      default: return PERF_OTHER;
    endcase
  endfunction
endpackage
`endif
