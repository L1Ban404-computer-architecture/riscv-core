// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// I-cache 与数据侧 CoreBus AXI4 固定优先级仲裁器。
//
// 数据侧拥有 AR 固定优先级和全部写通道。读响应按固定 AXI ID 直接分路，不设置
// 响应 FIFO、在途计数或数据寄存器；仅在 AR 反压时保存一位授权来源。

module axi4_fixed_priority_arb
  import riscv_bus_pkg::*;
#(
  parameter int unsigned IdWidth = 4,
  parameter int unsigned ICacheAxiId = ICACHE_AXI_ID,
  parameter int unsigned MemAxiId = MEM_AXI_ID
) (
  // 全局控制
  input logic clk_i,
  input logic rst_ni,

  // 两路 AXI4 请求与核心外部接口
  axi4_if.slave if_axi,
  axi4_if.slave mem_axi,
  axi4_if.master core_axi
);

  // AR 选择与所有权保持

  logic ar_locked_q;
  logic ar_owner_mem_q;
  logic select_mem;

  // 选中的 AR 源在外部反压时必须保持不变；锁存的所有权阻止后来到达的数据请求
  // 改变已经展示给外部总线的请求源。
  assign select_mem = ar_locked_q ? ar_owner_mem_q : mem_axi.arvalid;

  // 写通道仅属于数据侧。
  assign core_axi.awvalid = mem_axi.awvalid;
  assign core_axi.aw_payload = mem_axi.aw_payload;
  assign core_axi.wvalid = mem_axi.wvalid;
  assign core_axi.w_payload = mem_axi.w_payload;
  assign core_axi.bready = mem_axi.bready;
  assign mem_axi.awready = core_axi.awready;
  assign mem_axi.wready = core_axi.wready;
  assign mem_axi.bvalid = core_axi.bvalid;
  assign mem_axi.b_payload = core_axi.b_payload;
  assign if_axi.awready = 1'b0;
  assign if_axi.wready = 1'b0;
  assign if_axi.bvalid = 1'b0;
  assign if_axi.b_payload = '0;

  // AR 反压时锁定来源，避免新到达的数据请求改变已展示的取指请求。
  assign core_axi.arvalid = select_mem ? mem_axi.arvalid : if_axi.arvalid;
  assign core_axi.ar_payload = select_mem ? mem_axi.ar_payload : if_axi.ar_payload;
  assign mem_axi.arready = select_mem && core_axi.arready;
  assign if_axi.arready = !select_mem && core_axi.arready;

  // R 按固定 ID 分路，无响应缓存。
  always_comb begin
    core_axi.rready = 1'b0;
    if_axi.rvalid = 1'b0;
    if_axi.r_payload = '0;
    mem_axi.rvalid = 1'b0;
    mem_axi.r_payload = '0;

    // 外部 R 通道按 ID 直接选择唯一目标；RREADY 从目标侧直通，不设置响应缓存。
    if (core_axi.rvalid) begin
      unique case (core_axi.r_payload.id)
        IdWidth'(ICacheAxiId): begin
          if_axi.rvalid = 1'b1;
          if_axi.r_payload = core_axi.r_payload;
          core_axi.rready = if_axi.rready;
        end
        IdWidth'(MemAxiId): begin
          mem_axi.rvalid = 1'b1;
          mem_axi.r_payload = core_axi.r_payload;
          core_axi.rready = mem_axi.rready;
        end
        default: ;
      endcase
    end
  end

  // AR 所有权状态更新

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ar_locked_q <= 1'b0;
      ar_owner_mem_q <= 1'b0;
    end else if (ar_locked_q) begin
      if (core_axi.ar_fire) ar_locked_q <= 1'b0;
    end else if (core_axi.arvalid && !core_axi.arready) begin
      ar_locked_q <= 1'b1;
      ar_owner_mem_q <= select_mem;
    end
  end

  // 协议检查

`ifndef SYNTHESIS
  AxiArbICacheNeverWrites: assert property (@(posedge clk_i) disable iff (!rst_ni) (
      !if_axi.awvalid && !if_axi.wvalid && !if_axi.bready));
`endif

endmodule
