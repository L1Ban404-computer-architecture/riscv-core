// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// Serialize the instruction and data CoreBus ports onto one single-beat AXI4
// master.  Data traffic wins arbitration.  AXI IDs preserve the request source:
// ID 0 is instruction fetch and ID 1 is data access.
`include "common/assertions.svh"

import riscv_core_pkg::*;

module corebus_axi4 (
  input logic clock,
  input logic reset,

  input  core_bus_req_t  imem_req_i,
  output core_bus_resp_t imem_resp_o,
  input  core_bus_req_t  dmem_req_i,
  output core_bus_resp_t dmem_resp_o,

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

  typedef enum logic [2:0] {
    StateIdle,
    StateReadAddress,
    StateReadResponse,
    StateWriteData,
    StateWriteResponse
  } state_e;

  state_e state_q;
  logic owner_dmem_q;
  logic [31:0] addr_q;
  logic [1:0] size_q;
  logic [31:0] wdata_q;
  logic [3:0] wstrb_q;
  logic aw_sent_q;
  logic w_sent_q;
  logic selected_rsp_ready;
  logic read_error;
  logic write_error;

  function automatic logic naturally_aligned(
    input logic [1:0] addr_offset,
    input logic [1:0] size
  );
    unique case (size)
      2'd0: naturally_aligned = 1'b1;
      2'd1: naturally_aligned = !addr_offset[0];
      2'd2: naturally_aligned = (addr_offset == 2'b00);
      default: naturally_aligned = 1'b0;
    endcase
  endfunction

  assign selected_rsp_ready = owner_dmem_q ? dmem_req_i.rsp_ready : imem_req_i.rsp_ready;
  assign read_error = (m_rresp_i != 2'b00) || !m_rlast_i ||
                      (m_rid_i != (owner_dmem_q ? 4'd1 : 4'd0));
  assign write_error = (m_bresp_i != 2'b00) || (m_bid_i != 4'd1);

  assign dmem_resp_o.req_ready = (state_q == StateIdle);
  assign imem_resp_o.req_ready = (state_q == StateIdle) && !dmem_req_i.req_valid;

  assign m_awvalid_o = (state_q == StateWriteData) && !aw_sent_q;
  assign m_awaddr_o = addr_q;
  assign m_awid_o = 4'd1;
  assign m_awlen_o = 8'd0;
  assign m_awsize_o = {1'b0, size_q};
  assign m_awburst_o = 2'b01;

  assign m_wvalid_o = (state_q == StateWriteData) && !w_sent_q;
  assign m_wdata_o = wdata_q;
  assign m_wstrb_o = wstrb_q;
  assign m_wlast_o = 1'b1;
  assign m_bready_o = (state_q == StateWriteResponse) && selected_rsp_ready;

  assign m_arvalid_o = (state_q == StateReadAddress);
  assign m_araddr_o = addr_q;
  assign m_arid_o = owner_dmem_q ? 4'd1 : 4'd0;
  assign m_arlen_o = 8'd0;
  assign m_arsize_o = {1'b0, size_q};
  assign m_arburst_o = 2'b01;
  assign m_rready_o = (state_q == StateReadResponse) && selected_rsp_ready;

  assign imem_resp_o.rsp_valid = !owner_dmem_q &&
                                 (((state_q == StateReadResponse) && m_rvalid_i) ||
                                  ((state_q == StateWriteResponse) && m_bvalid_i));
  assign dmem_resp_o.rsp_valid = owner_dmem_q &&
                                 (((state_q == StateReadResponse) && m_rvalid_i) ||
                                  ((state_q == StateWriteResponse) && m_bvalid_i));
  assign imem_resp_o.rdata = (state_q == StateReadResponse) ? m_rdata_i : 32'b0;
  assign dmem_resp_o.rdata = (state_q == StateReadResponse) ? m_rdata_i : 32'b0;
  assign imem_resp_o.error = !owner_dmem_q &&
                             (((state_q == StateReadResponse) && m_rvalid_i && read_error) ||
                              ((state_q == StateWriteResponse) && m_bvalid_i && write_error));
  assign dmem_resp_o.error = owner_dmem_q &&
                             (((state_q == StateReadResponse) && m_rvalid_i && read_error) ||
                              ((state_q == StateWriteResponse) && m_bvalid_i && write_error));

  always_ff @(posedge clock or posedge reset) begin
    if (reset) begin
      state_q <= StateIdle;
      owner_dmem_q <= 1'b0;
      addr_q <= 32'b0;
      size_q <= 2'b0;
      wdata_q <= 32'b0;
      wstrb_q <= 4'b0;
      aw_sent_q <= 1'b0;
      w_sent_q <= 1'b0;
    end else begin
      case (state_q)
        StateIdle: begin
          aw_sent_q <= 1'b0;
          w_sent_q <= 1'b0;
          if (dmem_req_i.req_valid) begin
            owner_dmem_q <= 1'b1;
            addr_q <= dmem_req_i.addr;
            size_q <= dmem_req_i.size;
            wdata_q <= dmem_req_i.wdata;
            wstrb_q <= dmem_req_i.wstrb;
            state_q <= dmem_req_i.write ? StateWriteData : StateReadAddress;
          end else if (imem_req_i.req_valid) begin
            owner_dmem_q <= 1'b0;
            addr_q <= imem_req_i.addr;
            size_q <= 2'd2;
            wdata_q <= '0;
            wstrb_q <= '0;
            state_q <= StateReadAddress;
          end
        end
        StateReadAddress: begin
          if (m_arready_i) state_q <= StateReadResponse;
        end
        StateReadResponse: begin
          if (m_rvalid_i && selected_rsp_ready) state_q <= StateIdle;
        end
        StateWriteData: begin
          if (m_awready_i && m_awvalid_o) aw_sent_q <= 1'b1;
          if (m_wready_i && m_wvalid_o) w_sent_q <= 1'b1;
          if ((aw_sent_q || (m_awready_i && m_awvalid_o)) &&
              (w_sent_q || (m_wready_i && m_wvalid_o)))
            state_q <= StateWriteResponse;
        end
        StateWriteResponse: begin
          if (m_bvalid_i && selected_rsp_ready) state_q <= StateIdle;
        end
        default: state_q <= StateIdle;
      endcase
    end
  end

  // verilog_format: off
  `ASSERT(CoreBusImemReadOnly,
          imem_req_i.req_valid && imem_resp_o.req_ready |->
              !imem_req_i.write && (imem_req_i.size == MEM_SIZE_WORD) &&
              (imem_req_i.wdata == '0) && (imem_req_i.wstrb == '0),
          clock, reset, "Instruction CoreBus requests must be word reads.")
  `ASSERT(CoreBusDmemAligned,
          dmem_req_i.req_valid && dmem_resp_o.req_ready |->
              naturally_aligned(dmem_req_i.addr[1:0], dmem_req_i.size),
          clock, reset, "Data CoreBus requests must be naturally aligned.")
  `ASSERT_STABLE(AxiAwStable, m_awvalid_o, m_awready_i,
                 {m_awaddr_o, m_awid_o, m_awlen_o, m_awsize_o, m_awburst_o},
                 '0, clock, reset, "AXI AW payload must remain stable while blocked.")
  `ASSERT_STABLE(AxiWStable, m_wvalid_o, m_wready_i,
                 {m_wdata_o, m_wstrb_o, m_wlast_o},
                 '0, clock, reset, "AXI W payload must remain stable while blocked.")
  `ASSERT_STABLE(AxiArStable, m_arvalid_o, m_arready_i,
                 {m_araddr_o, m_arid_o, m_arlen_o, m_arsize_o, m_arburst_o},
                 '0, clock, reset, "AXI AR payload must remain stable while blocked.")
  `ASSERT_STABLE(AxiRStable, m_rvalid_i, m_rready_o,
                 {m_rdata_i, m_rresp_i, m_rlast_i, m_rid_i},
                 '0, clock, reset, "AXI R payload must remain stable while blocked.")
  `ASSERT_STABLE(AxiBStable, m_bvalid_i, m_bready_o,
                 {m_bresp_i, m_bid_i},
                 '0, clock, reset, "AXI B payload must remain stable while blocked.")
  `ASSERT_STABLE(CoreBusImemRspStable, imem_resp_o.rsp_valid, imem_req_i.rsp_ready,
                 {imem_resp_o.rdata, imem_resp_o.error},
                 '0, clock, reset,
                 "Instruction CoreBus response must remain stable while blocked.")
  `ASSERT_STABLE(CoreBusDmemRspStable, dmem_resp_o.rsp_valid, dmem_req_i.rsp_ready,
                 {dmem_resp_o.rdata, dmem_resp_o.error},
                 '0, clock, reset,
                 "Data CoreBus response must remain stable while blocked.")
  `ASSERT(AxiReadErrorPropagated,
          (state_q == StateReadResponse) && m_rvalid_i && read_error |->
              (owner_dmem_q ? dmem_resp_o.error : imem_resp_o.error),
          clock, reset, "Malformed AXI read responses must reach CoreBus as errors.")
  `ASSERT(AxiWriteErrorPropagated,
          (state_q == StateWriteResponse) && m_bvalid_i && write_error |->
              (owner_dmem_q ? dmem_resp_o.error : imem_resp_o.error),
          clock, reset, "Malformed AXI write responses must reach CoreBus as errors.")
  // verilog_format: on

endmodule
