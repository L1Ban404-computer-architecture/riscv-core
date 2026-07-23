import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


async def settle():
    await Timer(1, unit="ns")


async def initialize(dut):
    dut.reset.value = 1
    dut.imem_req_valid_i.value = 0
    dut.imem_req_addr_i.value = 0
    dut.imem_req_write_i.value = 0
    dut.imem_req_size_i.value = 2
    dut.imem_req_wdata_i.value = 0
    dut.imem_req_wstrb_i.value = 0
    dut.imem_rsp_ready_i.value = 0
    dut.dmem_req_valid_i.value = 0
    dut.dmem_req_addr_i.value = 0
    dut.dmem_req_write_i.value = 0
    dut.dmem_req_size_i.value = 2
    dut.dmem_req_wdata_i.value = 0
    dut.dmem_req_wstrb_i.value = 0
    dut.dmem_rsp_ready_i.value = 0
    dut.m_awready_i.value = 0
    dut.m_wready_i.value = 0
    dut.m_bvalid_i.value = 0
    dut.m_bresp_i.value = 0
    dut.m_bid_i.value = 0
    dut.m_arready_i.value = 0
    dut.m_rvalid_i.value = 0
    dut.m_rresp_i.value = 0
    dut.m_rdata_i.value = 0
    dut.m_rlast_i.value = 0
    dut.m_rid_i.value = 0
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    for _ in range(2):
        await RisingEdge(dut.clock)
    dut.reset.value = 0
    await RisingEdge(dut.clock)


@cocotb.test()
async def arbitration_channels_ids_and_errors(dut):
    await initialize(dut)

    # Simultaneous requests select data traffic and start a write with ID 1.
    dut.imem_req_valid_i.value = 1
    dut.imem_req_addr_i.value = 0x30000000
    dut.dmem_req_valid_i.value = 1
    dut.dmem_req_addr_i.value = 0x80000000
    dut.dmem_req_write_i.value = 1
    dut.dmem_req_size_i.value = 2
    dut.dmem_req_wdata_i.value = 0xAABBCCDD
    dut.dmem_req_wstrb_i.value = 0x5
    dut.dmem_rsp_ready_i.value = 1
    await settle()
    assert dut.dmem_req_ready_o.value == 1
    assert dut.imem_req_ready_o.value == 0
    await RisingEdge(dut.clock)
    dut.dmem_req_valid_i.value = 0
    dut.imem_req_valid_i.value = 0
    await settle()
    assert dut.m_awvalid_o.value == 1
    assert dut.m_wvalid_o.value == 1
    assert dut.m_awid_o.value == 1
    assert dut.m_awlen_o.value == 0
    assert dut.m_awsize_o.value == 2
    assert dut.m_awburst_o.value == 1
    assert dut.m_wlast_o.value == 1

    # AW and W complete independently; the unaccepted channel remains stable.
    dut.m_awready_i.value = 1
    held_data = int(dut.m_wdata_o.value)
    held_strb = int(dut.m_wstrb_o.value)
    await RisingEdge(dut.clock)
    dut.m_awready_i.value = 0
    await settle()
    assert dut.m_awvalid_o.value == 0
    assert dut.m_wvalid_o.value == 1
    assert int(dut.m_wdata_o.value) == held_data
    assert int(dut.m_wstrb_o.value) == held_strb
    dut.m_wready_i.value = 1
    await RisingEdge(dut.clock)
    dut.m_wready_i.value = 0

    # A mismatched BID is surfaced as a CoreBus error.
    dut.m_bvalid_i.value = 1
    dut.m_bid_i.value = 0
    await settle()
    assert dut.dmem_rsp_valid_o.value == 1
    assert dut.dmem_rsp_error_o.value == 1
    assert dut.m_bready_o.value == 1
    await RisingEdge(dut.clock)
    dut.m_bvalid_i.value = 0

    # Instruction reads use ID 0 and hold AR stable under backpressure.
    dut.imem_req_valid_i.value = 1
    dut.imem_req_addr_i.value = 0x30000004
    dut.imem_rsp_ready_i.value = 0
    await settle()
    assert dut.imem_req_ready_o.value == 1
    await RisingEdge(dut.clock)
    dut.imem_req_valid_i.value = 0
    await settle()
    assert dut.m_arvalid_o.value == 1
    assert dut.m_arid_o.value == 0
    held_addr = int(dut.m_araddr_o.value)
    await RisingEdge(dut.clock)
    await settle()
    assert dut.m_arvalid_o.value == 1
    assert int(dut.m_araddr_o.value) == held_addr
    dut.m_arready_i.value = 1
    await RisingEdge(dut.clock)
    dut.m_arready_i.value = 0

    dut.m_rvalid_i.value = 1
    dut.m_rdata_i.value = 0x00100073
    dut.m_rid_i.value = 0
    dut.m_rlast_i.value = 1
    await settle()
    assert dut.imem_rsp_valid_o.value == 1
    assert dut.imem_rsp_error_o.value == 0
    assert dut.m_rready_o.value == 0
    dut.imem_rsp_ready_i.value = 1
    await settle()
    assert dut.m_rready_o.value == 1
    await RisingEdge(dut.clock)
    dut.m_rvalid_i.value = 0

    # Reset abandons any partially issued transaction.
    dut.dmem_req_valid_i.value = 1
    dut.dmem_req_write_i.value = 1
    dut.dmem_req_wstrb_i.value = 0xF
    await RisingEdge(dut.clock)
    dut.reset.value = 1
    await RisingEdge(dut.clock)
    dut.reset.value = 0
    dut.dmem_req_valid_i.value = 0
    await settle()
    assert dut.m_awvalid_o.value == 0
    assert dut.m_wvalid_o.value == 0
    assert dut.m_arvalid_o.value == 0


@cocotb.test()
async def narrow_addresses_sizes_and_explicit_direction(dut):
    await initialize(dut)

    # A nonzero read strobe must not turn an explicitly marked read into a write.
    dut.dmem_req_valid_i.value = 1
    dut.dmem_req_addr_i.value = 0x10000003
    dut.dmem_req_write_i.value = 0
    dut.dmem_req_size_i.value = 0
    dut.dmem_req_wstrb_i.value = 0xF
    dut.dmem_rsp_ready_i.value = 1
    await RisingEdge(dut.clock)
    dut.dmem_req_valid_i.value = 0
    await settle()
    assert dut.m_arvalid_o.value == 1
    assert dut.m_awvalid_o.value == 0
    assert int(dut.m_araddr_o.value) == 0x10000003
    assert int(dut.m_arsize_o.value) == 0
    dut.m_arready_i.value = 1
    await RisingEdge(dut.clock)
    dut.m_arready_i.value = 0
    dut.m_rvalid_i.value = 1
    dut.m_rid_i.value = 1
    dut.m_rlast_i.value = 1
    await RisingEdge(dut.clock)
    dut.m_rvalid_i.value = 0

    # Explicit write remains a write even when all byte strobes are zero.
    dut.dmem_req_valid_i.value = 1
    dut.dmem_req_addr_i.value = 0x10000002
    dut.dmem_req_write_i.value = 1
    dut.dmem_req_size_i.value = 1
    dut.dmem_req_wstrb_i.value = 0
    await RisingEdge(dut.clock)
    dut.dmem_req_valid_i.value = 0
    await settle()
    assert dut.m_awvalid_o.value == 1
    assert dut.m_wvalid_o.value == 1
    assert int(dut.m_awaddr_o.value) == 0x10000002
    assert int(dut.m_awsize_o.value) == 1
    assert int(dut.m_wstrb_o.value) == 0
