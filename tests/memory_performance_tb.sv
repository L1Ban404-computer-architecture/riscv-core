module memory_performance_tb;
  import riscv_core_pkg::*;
  logic clk = 0, rst_n = 0;
  logic [63:0] cycle = 0;
  core_bus_if bus();
  memory_performance_payload_t stats, expected;
  memory_performance_stats dut(.clk_i(clk), .rst_ni(rst_n), .cycle_i(cycle),
                               .bus(bus), .stats_o(stats));
  task automatic tick(input logic [63:0] time_value,
                      input bit req_valid, req_ready, rsp_valid, rsp_ready);
    cycle = time_value;
    bus.req_valid = req_valid;
    bus.req_ready = req_ready;
    bus.rsp_valid = rsp_valid;
    bus.rsp_ready = rsp_ready;
    if (req_valid && req_ready) begin
      expected.transaction_count++;
      expected.request_cycle_sum += 128'(time_value);
    end
    if (rsp_valid && rsp_ready) expected.response_cycle_sum += 128'(time_value);
    if (req_valid && !req_ready) expected.request_stall_cycle_count++;
    if (rsp_valid && !rsp_ready) expected.response_stall_cycle_count++;
    #5; clk = 1; #5;
    assert(stats == expected) else $fatal(1, "Event aggregate mismatch");
    clk = 0;
  endtask
  initial begin
    expected = '0;
    bus.req_valid = 0; bus.req_ready = 0;
    bus.rsp_valid = 0; bus.rsp_ready = 0;
    bus.req_payload = '0; bus.rsp_payload = '0;
    #5; clk = 1; #5; clk = 0; rst_n = 1;
    tick(0, 1, 1, 1, 1); // Same-cycle transaction.
    tick(1, 1, 0, 0, 1); // Request backpressure.
    tick(2, 1, 1, 0, 1);
    tick(3, 1, 1, 1, 0); // Independent request and held response.
    tick(4, 0, 1, 1, 0);
    tick(5, 1, 1, 1, 1); // Response and replacement request.
    bus.rsp_payload.error = 1;
    tick(6, 0, 1, 1, 1); // Error responses count normally.
    tick(7, 0, 1, 1, 1);
    assert(stats.response_cycle_sum - stats.request_cycle_sum == 128'd8)
      else $fatal(1, "Incorrect total latency");
    tick(64'hfffffffffffffff0, 1, 1, 0, 0);
    tick(64'hfffffffffffffff1, 1, 1, 1, 1);
    tick(64'hfffffffffffffff2, 0, 0, 1, 1);
    assert(stats.request_cycle_sum[127:64] != 0)
      else $fatal(1, "Lost timestamp carry");
    tick(64'hfffffffffffffff3, 1, 1, 0, 0); // Pending request stays in sum.
    rst_n = 0; #5;
    assert(stats == '0) else $fatal(1, "Reset failed");
    $display("memory performance PASS");
    $finish;
  end
endmodule
