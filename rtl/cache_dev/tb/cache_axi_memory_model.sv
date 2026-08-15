// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// Cache Testbench AXI4 存储模型。
//
// 提供支持 burst 的阻塞式字节存储，并对五个 AXI 通道独立注入随机延迟和错误。
// 一次只处理一笔读和一笔写；错误在地址握手时锁存并归属于对应事务；
// 地址属性、burst 类型、ID 与末拍标志不合法时立即终止测试。
module cache_axi_memory_model
  import riscv_common_pkg::*;
  import riscv_bus_pkg::*;
#(
  parameter int unsigned MemoryBytes = 64 * 1024,
  parameter int unsigned IdWidth = 4,
  parameter int unsigned AxiId = DCACHE_AXI_ID
) (
  // 全局控制
  input logic clk_i,
  input logic rst_ni,

  // AXI4 从接口
  axi4_if.slave axi,

  // 延迟与错误注入
  input logic random_backpressure_i,
  input logic [4:0] random_bits_i,
  input logic inject_b_error_i,
  input logic inject_r_error_i,

  // 后门观察
  input word_t inspect_address_i,
  output word_t inspect_data_o,

  // 事务计数
  output int unsigned aw_count_o,
  output int unsigned ar_count_o,
  output int unsigned writeback_count_o,
  output int unsigned refill_count_o
);

  ////////////////////////
  // 存储阵列与通道状态 //
  ////////////////////////

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

  //////////////////////////////
  // 后门读取与 AXI4 组合驱动 //
  //////////////////////////////

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
    axi.awready = 1'b0;
    axi.wready = 1'b0;
    axi.bvalid = 1'b0;
    axi.b_payload = '0;
    axi.arready = 1'b0;
    axi.rvalid = 1'b0;
    axi.r_payload = '0;
    axi.awready = rst_ni && !write_active_q &&
        !write_response_pending_q && !bvalid_q &&
        (!random_backpressure_i || random_bits_i[0]);
    axi.wready = rst_ni && write_active_q &&
        (!random_backpressure_i || random_bits_i[1]);
    axi.bvalid = bvalid_q;
    axi.b_payload.resp = bresp_q;
    axi.b_payload.id = IdWidth'(AxiId);

    axi.arready = rst_ni && !read_active_q && !rvalid_q &&
        (!random_backpressure_i || random_bits_i[2]);
    axi.rvalid = rvalid_q;
    axi.r_payload.data = rdata_q;
    axi.r_payload.resp = rresp_q;
    axi.r_payload.last = rlast_q;
    axi.r_payload.id = IdWidth'(AxiId);
  end

  ////////////////////////////
  // 写地址、写数据与写响应 //
  ////////////////////////////

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
      if (axi.awvalid && axi.awready) begin
        if (axi.aw_payload.id != IdWidth'(AxiId) ||
            axi.aw_payload.size != 3'd2 ||
            axi.aw_payload.burst != AXI4_BURST_INCR)
          $fatal(1, "Invalid AXI write address attributes.");
        write_active_q <= 1'b1;
        write_address_q <= axi.aw_payload.addr;
        write_len_q <= axi.aw_payload.len;
        write_beat_q <= '0;
        write_error_q <= inject_b_error_i;
        aw_count_o <= aw_count_o + 1;
      end

      if (axi.wvalid && axi.wready) begin
        if (axi.w_payload.last != (write_beat_q == write_len_q))
          $fatal(1, "AXI WLAST does not match AWLEN.");
        for (int unsigned lane = 0; lane < StrbW; lane++) begin
          if (axi.w_payload.strb[lane]) begin
            memory[int'(write_address_q) +
                   int'(write_beat_q) * StrbW + lane] <=
                axi.w_payload.data[lane * ByteW +: ByteW];
          end
        end
        if (axi.w_payload.last) begin
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

      if (bvalid_q && axi.bready) begin
        bvalid_q <= 1'b0;
        bresp_q <= AXI4_RESP_OKAY;
      end
    end
  end

  ////////////////////
  // 读地址与读数据 //
  ////////////////////

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
      if (axi.arvalid && axi.arready) begin
        if (axi.ar_payload.id != IdWidth'(AxiId) ||
            axi.ar_payload.size != 3'd2 ||
            axi.ar_payload.burst != AXI4_BURST_INCR)
          $fatal(1, "Invalid AXI read address attributes.");
        read_active_q <= 1'b1;
        read_address_q <= axi.ar_payload.addr;
        read_len_q <= axi.ar_payload.len;
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

      if (rvalid_q && axi.rready) begin
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

  ////////////////////
  // 存储器初始内容 //
  ////////////////////

  initial begin
    for (int unsigned address = 0; address < MemoryBytes; address++) begin
      memory[address] = 8'((address * 17) ^ (address >> 3) ^ 8'h5a);
    end
  end

endmodule
