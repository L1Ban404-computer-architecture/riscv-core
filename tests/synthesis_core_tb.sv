// Identical functional ports in both preprocessing modes.
module synthesis_core_tb (
  input logic clk_i,
  input logic rst_ni,
  output logic imem_req_valid,
  input logic imem_req_ready,
  output logic [31:0] imem_addr,
  output logic imem_write,
  output logic [1:0] imem_size,
  output logic [31:0] imem_wdata,
  output logic [3:0] imem_wstrb,
  input logic imem_rsp_valid,
  output logic imem_rsp_ready,
  input logic [31:0] imem_rdata,
  input logic imem_error,
  output logic dmem_req_valid,
  input logic dmem_req_ready,
  output logic [31:0] dmem_addr,
  output logic dmem_write,
  output logic [1:0] dmem_size,
  output logic [31:0] dmem_wdata,
  output logic [3:0] dmem_wstrb,
  input logic dmem_rsp_valid,
  output logic dmem_rsp_ready,
  input logic [31:0] dmem_rdata,
  input logic dmem_error,
  output logic invalidate
);
  core_bus_if imem ();
  core_bus_if dmem ();
`ifndef SYNTHESIS
  retire_debug_if debug_retire ();
  performance_debug_if performance ();
`endif
  riscv_core_impl dut (
    .clk_i, .rst_ni, .boot_pc_i(32'h8000_0000), .imem, .dmem,
`ifndef SYNTHESIS
    .debug_retire, .performance,
`endif
    .icache_invalidate_o(invalidate)
  );
  assign imem_req_valid = imem.req_valid;
  assign imem.req_ready = imem_req_ready;
  assign imem_addr = imem.req_payload.addr;
  assign imem_write = imem.req_payload.write;
  assign imem_size = imem.req_payload.size;
  assign imem_wdata = imem.req_payload.wdata;
  assign imem_wstrb = imem.req_payload.wstrb;
  assign imem.rsp_valid = imem_rsp_valid;
  assign imem_rsp_ready = imem.rsp_ready;
  assign imem.rsp_payload = '{rdata: imem_rdata, error: imem_error};
  assign dmem_req_valid = dmem.req_valid;
  assign dmem.req_ready = dmem_req_ready;
  assign dmem_addr = dmem.req_payload.addr;
  assign dmem_write = dmem.req_payload.write;
  assign dmem_size = dmem.req_payload.size;
  assign dmem_wdata = dmem.req_payload.wdata;
  assign dmem_wstrb = dmem.req_payload.wstrb;
  assign dmem.rsp_valid = dmem_rsp_valid;
  assign dmem_rsp_ready = dmem.rsp_ready;
  assign dmem.rsp_payload = '{rdata: dmem_rdata, error: dmem_error};
endmodule
