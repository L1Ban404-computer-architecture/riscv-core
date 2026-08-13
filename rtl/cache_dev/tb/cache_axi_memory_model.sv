// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// Blocking AXI4 burst memory used by the cache self-checking testbench.  The
// five channels can be delayed independently, and write/read errors are
// captured with their corresponding address handshake.
module cache_axi_memory_model
  import riscv_common_pkg::*;
  import riscv_bus_pkg::*;
#(
  parameter int unsigned MemoryBytes = 64 * 1024,
  parameter axi4_id_t AxiId = DCACHE_AXI_ID
) (
  input logic clk_i,
  input logic rst_ni,

  input axi4_req_t axi_req_i,
  output axi4_resp_t axi_resp_o,

  input logic random_backpressure_i,
  input logic [4:0] random_bits_i,
  input logic inject_b_error_i,
  input logic inject_r_error_i,

  input word_t inspect_address_i,
  output word_t inspect_data_o,

  output int unsigned aw_count_o,
  output int unsigned ar_count_o,
  output int unsigned writeback_count_o,
  output int unsigned refill_count_o
);

  logic [7:0] memory[MemoryBytes];

  logic write_active_q;
  word_t write_address_q;
  logic [7:0] write_len_q;
  logic [7:0] write_beat_q;
  logic write_error_q;
  logic write_response_pending_q;
  logic bvalid_q;
  logic [1:0] bresp_q;

  logic read_active_q;
  word_t read_address_q;
  logic [7:0] read_len_q;
  logic [7:0] read_beat_q;
  logic read_error_q;
  logic rvalid_q;
  word_t rdata_q;
  logic [1:0] rresp_q;
  logic rlast_q;

  function automatic word_t read_word(input word_t address);
    word_t result;

    result = '0;
    for (int unsigned lane = 0; lane < StrbW; lane++) begin
      result[lane * ByteW +: ByteW] =
          memory[int'(address) + lane];
    end
    return result;
  endfunction

  assign inspect_data_o = read_word(inspect_address_i);

  always_comb begin
    axi_resp_o = '0;
    axi_resp_o.awready = rst_ni && !write_active_q &&
        !write_response_pending_q && !bvalid_q &&
        (!random_backpressure_i || random_bits_i[0]);
    axi_resp_o.wready = rst_ni && write_active_q &&
        (!random_backpressure_i || random_bits_i[1]);
    axi_resp_o.bvalid = bvalid_q;
    axi_resp_o.bresp = bresp_q;
    axi_resp_o.bid = AxiId;

    axi_resp_o.arready = rst_ni && !read_active_q && !rvalid_q &&
        (!random_backpressure_i || random_bits_i[2]);
    axi_resp_o.rvalid = rvalid_q;
    axi_resp_o.rdata = rdata_q;
    axi_resp_o.rresp = rresp_q;
    axi_resp_o.rlast = rlast_q;
    axi_resp_o.rid = AxiId;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      write_active_q <= 1'b0;
      write_address_q <= '0;
      write_len_q <= '0;
      write_beat_q <= '0;
      write_error_q <= 1'b0;
      write_response_pending_q <= 1'b0;
      bvalid_q <= 1'b0;
      bresp_q <= AXI4_RESP_OKAY;
      aw_count_o <= 0;
      writeback_count_o <= 0;
    end else begin
      if (axi_req_i.awvalid && axi_resp_o.awready) begin
        if (axi_req_i.awid != AxiId || axi_req_i.awsize != 3'd2 ||
            axi_req_i.awburst != AXI4_BURST_INCR)
          $fatal(1, "Invalid AXI write address attributes.");
        write_active_q <= 1'b1;
        write_address_q <= axi_req_i.awaddr;
        write_len_q <= axi_req_i.awlen;
        write_beat_q <= '0;
        write_error_q <= inject_b_error_i;
        aw_count_o <= aw_count_o + 1;
      end

      if (axi_req_i.wvalid && axi_resp_o.wready) begin
        if (axi_req_i.wlast != (write_beat_q == write_len_q))
          $fatal(1, "AXI WLAST does not match AWLEN.");
        for (int unsigned lane = 0; lane < StrbW; lane++) begin
          if (axi_req_i.wstrb[lane]) begin
            memory[int'(write_address_q) +
                   int'(write_beat_q) * StrbW + lane] <=
                axi_req_i.wdata[lane * ByteW +: ByteW];
          end
        end
        if (axi_req_i.wlast) begin
          write_active_q <= 1'b0;
          write_response_pending_q <= 1'b1;
          bresp_q <= write_error_q ? 2'b10 : AXI4_RESP_OKAY;
          writeback_count_o <= writeback_count_o + 1;
        end else begin
          write_beat_q <= write_beat_q + 8'd1;
        end
      end

      if (write_response_pending_q &&
          (!random_backpressure_i || random_bits_i[4])) begin
        write_response_pending_q <= 1'b0;
        bvalid_q <= 1'b1;
      end

      if (bvalid_q && axi_req_i.bready) begin
        bvalid_q <= 1'b0;
        bresp_q <= AXI4_RESP_OKAY;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      read_active_q <= 1'b0;
      read_address_q <= '0;
      read_len_q <= '0;
      read_beat_q <= '0;
      read_error_q <= 1'b0;
      rvalid_q <= 1'b0;
      rdata_q <= '0;
      rresp_q <= AXI4_RESP_OKAY;
      rlast_q <= 1'b0;
      ar_count_o <= 0;
      refill_count_o <= 0;
    end else begin
      if (axi_req_i.arvalid && axi_resp_o.arready) begin
        if (axi_req_i.arid != AxiId || axi_req_i.arsize != 3'd2 ||
            axi_req_i.arburst != AXI4_BURST_INCR)
          $fatal(1, "Invalid AXI read address attributes.");
        read_active_q <= 1'b1;
        read_address_q <= axi_req_i.araddr;
        read_len_q <= axi_req_i.arlen;
        read_beat_q <= '0;
        read_error_q <= inject_r_error_i;
        ar_count_o <= ar_count_o + 1;
      end

      if (read_active_q && !rvalid_q &&
          (!random_backpressure_i || random_bits_i[3])) begin
        rvalid_q <= 1'b1;
        rdata_q <= read_word(
            read_address_q + word_t'(int'(read_beat_q) * StrbW));
        rresp_q <= read_error_q ? 2'b10 : AXI4_RESP_OKAY;
        rlast_q <= read_beat_q == read_len_q;
      end

      if (rvalid_q && axi_req_i.rready) begin
        rvalid_q <= 1'b0;
        if (rlast_q) begin
          read_active_q <= 1'b0;
          refill_count_o <= refill_count_o + 1;
        end else begin
          read_beat_q <= read_beat_q + 8'd1;
        end
      end
    end
  end

  initial begin
    for (int unsigned address = 0; address < MemoryBytes; address++) begin
      memory[address] = 8'((address * 17) ^ (address >> 3) ^ 8'h5a);
    end
  end

endmodule
