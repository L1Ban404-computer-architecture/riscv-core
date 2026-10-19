// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNDRIVEN */
/* verilator lint_off UNUSEDSIGNAL */

`ifndef SYNTHESIS
interface core_debug_if;
  riscv_debug_pkg::fetch_debug_payload_t fetch;
  riscv_debug_pkg::stage_debug_payload_t decode;
  riscv_debug_pkg::execute_debug_payload_t execute;
  riscv_debug_pkg::memory_debug_payload_t memory;
  riscv_debug_pkg::writeback_debug_payload_t writeback;
  riscv_debug_pkg::control_debug_payload_t control;
  riscv_core_pkg::csr_state_payload_t csr;
  modport consumer(input fetch, decode, execute, memory, writeback, control, csr);
endinterface
`endif

