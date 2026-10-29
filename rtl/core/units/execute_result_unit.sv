// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 将执行结果转换为 EX/MEM 事务：归并对齐异常、保存提交信息和访存请求。
// 不依赖握手；背压期间保持事务内容，异常同时关闭 GPR 与访存副作用。
module execute_result_unit
  import riscv_core_pkg::*;
(
  input id_ex_payload_t instruction_i,
  input word_t execution_value_i,
  input word_t address_i,
  input logic branch_taken_i,
  input pc_t branch_target_i,
  output ex_mem_payload_t result_o
);

  logic data_misaligned;
  exception_payload_t exception;

  always_comb begin
    case (instruction_i.ctrl.mem_size)
      MEM_SIZE_BYTE: data_misaligned = 1'b0;
      MEM_SIZE_HALF: data_misaligned = address_i[0];
      MEM_SIZE_WORD: data_misaligned = |address_i[1:0];
      default: data_misaligned = 1'b1;
    endcase

    // 上游异常优先；仅实际跳转时检查指令目标对齐。
    exception = instruction_i.exception;
    if (branch_taken_i && (branch_target_i[1:0] != 2'b00))
      exception = raise_exception(exception, EXC_INST_ADDR_MISALIGNED, branch_target_i);
    else if ((instruction_i.ctrl.mem_cmd != MEM_NONE) && data_misaligned)
      exception = raise_exception(exception,
          (instruction_i.ctrl.mem_cmd == MEM_STORE) ?
              EXC_STORE_ADDR_MISALIGNED : EXC_LOAD_ADDR_MISALIGNED, address_i);

    result_o = '{
      commit_ctx: '{
        pc: instruction_i.pc,
        gpr: instruction_i.gpr,
        value: execution_value_i,
        exception: exception,
        commit: instruction_i.commit
      },
      // value 共用为 GPR 结果、访存地址或 CSR 源；store 数据独立保存。
      mem_req: '{
        valid: (instruction_i.ctrl.mem_cmd != MEM_NONE) && !exception.valid,
        write: instruction_i.ctrl.mem_cmd == MEM_STORE,
        size: instruction_i.ctrl.mem_size,
        sign_ext: instruction_i.ctrl.mem_sign_ext,
        wdata: instruction_i.exec_data.rs2_value
      }
    };
    if (exception.valid) result_o.commit_ctx.gpr = '0;
  end

endmodule
