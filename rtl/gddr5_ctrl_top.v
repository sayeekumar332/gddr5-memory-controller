`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// gddr5_ctrl_top - host request interface in front of gddr5_ctrl_core
//
//   host (valid/ready, write, flat address)
//        -> gddr5_addr_map -> gddr5_req_fifo -> gddr5_ctrl_core -> pins
//
// The address is mapped to (bank, row, column) before it enters the FIFO, so
// the FIFO holds decoded requests of {write, bank, row, col}. The core takes
// them in order. Same-address ordering is therefore preserved.
//
// Not included yet (later steps): refresh, initialization and mode registers,
// training, data paths, PHY. All timing parameters are forwarded to the core.
// -----------------------------------------------------------------------------
module gddr5_ctrl_top #(
    parameter FIFO_DEPTH = 8,
    parameter MAP_MODE   = 1,
    parameter MAP_XOR    = 0,
    parameter AUTO_PRECHARGE = 0,
    // gddr5_bank_fsm
    parameter TRCDRD = 12,
    parameter TRCDWR = 8,
    parameter TRAS   = 28,
    parameter TRC    = 40,
    parameter TRP    = 12,
    parameter TRTP   = 2,
    parameter TW2PRE = 16,
    parameter TRFCPB = 60,
    // gddr5_timing
    parameter BG_ENABLE = 1,
    parameter GROUP_LSB = 2,
    parameter TRRDS  = 5,
    parameter TRRDL  = 7,
    parameter TFAW   = 23,
    parameter T32AW  = 184,
    parameter TCCDS  = 2,
    parameter TCCDL  = 4,
    parameter TW2RS  = 12,
    parameter TW2RL  = 14,
    parameter TRTW   = 14,
    parameter TPPD   = 2,
    // gddr5_cmd_enc
    parameter HAS_A12A13 = 1,
    parameter ABI_MAX_LOW = 5
) (
    input  wire        clk,
    input  wire        rst_n,

    // Host request (valid/ready). h_addr is one burst per address unit.
    input  wire        h_valid,
    output wire        h_ready,
    input  wire        h_write,
    input  wire [24:0] h_addr,

    // Another sequencer owns the command bus.
    input  wire        hold,

    // Encoder controls.
    input  wire        abi_enable,
    input  wire        cke_n_in,

    // Device pins.
    output wire        cke_n,
    output wire        cs_n,
    output wire        ras_n,
    output wire        cas_n,
    output wire        we_n,
    output wire [8:0]  addr_ph1,
    output wire [8:0]  addr_ph2,
    output wire        abi_n_ph1,
    output wire        abi_n_ph2,

    // Observation of the issued command, before encoding.
    output wire        cmd_valid,
    output wire [4:0]  cmd,
    output wire [3:0]  cmd_bank,
    output wire [13:0] cmd_addr,

    // Status.
    output wire        busy,          // a request is queued or being worked on
    output wire        req_done,      // a column command issues this cycle
    output wire [15:0] fifo_level,
    output wire [15:0] bank_idle,
    output wire        err_bank,
    output wire        err_timing,
    output wire        err_enc
);

    // ---- address map ----------------------------------------------------------
    wire [3:0]  m_bank;
    wire [13:0] m_row;
    wire [6:0]  m_col;

    gddr5_addr_map #(.MODE(MAP_MODE), .XOR_BANK(MAP_XOR), .ROW_W(14), .COL_W(7)) u_map (
        .addr(h_addr), .bank(m_bank), .row(m_row), .col(m_col));

    // ---- request FIFO: {write, bank, row, col} --------------------------------
    wire        f_valid;
    wire        f_ready;
    wire [25:0] f_data;
    wire        f_in_ready;

    gddr5_req_fifo #(.WIDTH(26), .DEPTH(FIFO_DEPTH)) u_fifo (
        .clk(clk), .rst_n(rst_n),
        .in_valid(h_valid), .in_ready(f_in_ready),
        .in_data({h_write, m_bank, m_row, m_col}),
        .out_valid(f_valid), .out_ready(f_ready), .out_data(f_data),
        .level(fifo_level));

    assign h_ready = f_in_ready;

    // ---- core -----------------------------------------------------------------
    wire c_busy;

    gddr5_ctrl_core #(
        .AUTO_PRECHARGE(AUTO_PRECHARGE),
        .TRCDRD(TRCDRD), .TRCDWR(TRCDWR), .TRAS(TRAS), .TRC(TRC), .TRP(TRP),
        .TRTP(TRTP), .TW2PRE(TW2PRE), .TRFCPB(TRFCPB),
        .BG_ENABLE(BG_ENABLE), .GROUP_LSB(GROUP_LSB),
        .TRRDS(TRRDS), .TRRDL(TRRDL), .TFAW(TFAW), .T32AW(T32AW),
        .TCCDS(TCCDS), .TCCDL(TCCDL), .TW2RS(TW2RS), .TW2RL(TW2RL),
        .TRTW(TRTW), .TPPD(TPPD),
        .HAS_A12A13(HAS_A12A13), .ABI_MAX_LOW(ABI_MAX_LOW)
    ) u_core (
        .clk(clk), .rst_n(rst_n),
        .req_valid(f_valid), .req_ready(f_ready),
        .req_write(f_data[25]), .req_bank(f_data[24:21]),
        .req_row(f_data[20:7]), .req_col(f_data[6:0]),
        .hold(hold), .abi_enable(abi_enable), .cke_n_in(cke_n_in),
        .cke_n(cke_n), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
        .addr_ph1(addr_ph1), .addr_ph2(addr_ph2),
        .abi_n_ph1(abi_n_ph1), .abi_n_ph2(abi_n_ph2),
        .cmd_valid(cmd_valid), .cmd(cmd), .cmd_bank(cmd_bank), .cmd_addr(cmd_addr),
        .busy(c_busy), .req_done(req_done), .bank_idle(bank_idle),
        .err_bank(err_bank), .err_timing(err_timing), .err_enc(err_enc));

    assign busy = c_busy || f_valid;

endmodule
