// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

module corebus_axi4_tb (
  input  logic        clock,
  input  logic        reset,
  input  logic        imem_req_valid_i,
  output logic        imem_req_ready_o,
  input  logic [31:0] imem_req_addr_i,
  output logic        imem_rsp_valid_o,
  input  logic        imem_rsp_ready_i,
  output logic [31:0] imem_rsp_rdata_o,
  output logic        imem_rsp_error_o,
  input  logic        dmem_req_valid_i,
  output logic        dmem_req_ready_o,
  input  logic [31:0] dmem_req_addr_i,
  input  logic        dmem_req_write_i,
  input  logic [1:0]  dmem_req_size_i,
  input  logic [31:0] dmem_req_wdata_i,
  input  logic [3:0]  dmem_req_wstrb_i,
  output logic        dmem_rsp_valid_o,
  input  logic        dmem_rsp_ready_i,
  output logic [31:0] dmem_rsp_rdata_o,
  output logic        dmem_rsp_error_o,
  input  logic        m_awready_i,
  output logic        m_awvalid_o,
  output logic [31:0] m_awaddr_o,
  output logic [3:0]  m_awid_o,
  output logic [7:0]  m_awlen_o,
  output logic [2:0]  m_awsize_o,
  output logic [1:0]  m_awburst_o,
  input  logic        m_wready_i,
  output logic        m_wvalid_o,
  output logic [31:0] m_wdata_o,
  output logic [3:0]  m_wstrb_o,
  output logic        m_wlast_o,
  output logic        m_bready_o,
  input  logic        m_bvalid_i,
  input  logic [1:0]  m_bresp_i,
  input  logic [3:0]  m_bid_i,
  input  logic        m_arready_i,
  output logic        m_arvalid_o,
  output logic [31:0] m_araddr_o,
  output logic [3:0]  m_arid_o,
  output logic [7:0]  m_arlen_o,
  output logic [2:0]  m_arsize_o,
  output logic [1:0]  m_arburst_o,
  output logic        m_rready_o,
  input  logic        m_rvalid_i,
  input  logic [1:0]  m_rresp_i,
  input  logic [31:0] m_rdata_i,
  input  logic        m_rlast_i,
  input  logic [3:0]  m_rid_i
);

  core_bus_req_t imem_req;
  core_bus_resp_t imem_resp;
  core_bus_req_t dmem_req;
  core_bus_resp_t dmem_resp;

  always_comb begin
    imem_req = '0;
    imem_req.addr = imem_req_addr_i;
    imem_req.size = MEM_SIZE_WORD;
    imem_req.req_valid = imem_req_valid_i;
    imem_req.rsp_ready = imem_rsp_ready_i;

    dmem_req = '0;
    dmem_req.addr = dmem_req_addr_i;
    dmem_req.write = dmem_req_write_i;
    dmem_req.size = mem_size_e'(dmem_req_size_i);
    dmem_req.wdata = dmem_req_wdata_i;
    dmem_req.wstrb = dmem_req_wstrb_i;
    dmem_req.req_valid = dmem_req_valid_i;
    dmem_req.rsp_ready = dmem_rsp_ready_i;
  end

  assign imem_req_ready_o = imem_resp.req_ready;
  assign imem_rsp_valid_o = imem_resp.rsp_valid;
  assign imem_rsp_rdata_o = imem_resp.rdata;
  assign imem_rsp_error_o = imem_resp.error;
  assign dmem_req_ready_o = dmem_resp.req_ready;
  assign dmem_rsp_valid_o = dmem_resp.rsp_valid;
  assign dmem_rsp_rdata_o = dmem_resp.rdata;
  assign dmem_rsp_error_o = dmem_resp.error;

  corebus_axi4 dut (
    .clock,
    .reset,
    .imem_req_i(imem_req),
    .imem_resp_o(imem_resp),
    .dmem_req_i(dmem_req),
    .dmem_resp_o(dmem_resp),
    .*
  );

endmodule
