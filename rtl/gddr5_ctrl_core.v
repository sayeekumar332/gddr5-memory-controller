`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// gddr5_ctrl_core - request-to-pins command path
//
// Wires the command-path modules together:
//
//   request -> gddr5_sched -> (16 x gddr5_bank_fsm, gddr5_timing) -> gddr5_cmd_enc -> pins
//
// The scheduler reads every bank's state and legality and the cross-bank
// legality, chooses one command per cycle, and strobes it into the bank state
// machines and the timing tracker. The same command goes to gddr5_cmd_enc,
// which produces the device pin values one cycle later.
//
// Not included yet (later steps): address mapping, request queue, refresh,
// initialization and mode registers, training, data paths, PHY. The per-bank
// refresh strobe of every bank is tied low until the refresh module exists.
//
// Timing parameters are in clock cycles; see the module specifications of
// gddr5_bank_fsm and gddr5_timing. Defaults are illustrative placeholders.
// -----------------------------------------------------------------------------
module gddr5_ctrl_core #(
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

    // Request (valid/ready), address already decoded.
    input  wire        req_valid,
    output wire        req_ready,
    input  wire        req_write,
    input  wire [3:0]  req_bank,
    input  wire [13:0] req_row,
    input  wire [6:0]  req_col,

    // Another sequencer owns the command bus.
    input  wire        hold,

    // Encoder controls.
    input  wire        abi_enable,
    input  wire        cke_n_in,

    // Device pins (one cycle after the command is issued).
    output wire        cke_n,
    output wire        cs_n,
    output wire        ras_n,
    output wire        cas_n,
    output wire        we_n,
    output wire [8:0]  addr_ph1,
    output wire [8:0]  addr_ph2,
    output wire        abi_n_ph1,
    output wire        abi_n_ph2,

    // The command issued this cycle, before encoding (for observation).
    output wire        cmd_valid,
    output wire [4:0]  cmd,
    output wire [3:0]  cmd_bank,
    output wire [13:0] cmd_addr,

    // Status.
    output wire        busy,          // a request is being worked on
    output wire        req_done,      // its column command issues this cycle
    output wire [15:0] bank_idle,
    output wire        err_bank,      // some bank state machine saw an illegal strobe
    output wire        err_timing,    // the timing tracker saw an illegal strobe
    output wire        err_enc        // the encoder saw an undefined command code
);

    // ---- scheduler <-> banks and timing -------------------------------------
    wire [15:0]  b_row_valid;
    wire [223:0] b_open_row;
    wire [15:0]  b_can_act, b_can_rd, b_can_wr, b_can_pre, b_idle;
    wire [15:0]  b_err;

    wire [15:0]  s_act, s_rd, s_wr, s_pre;
    wire         s_ap;
    wire         t_issue_act, t_issue_rd, t_issue_wr, t_issue_pre;
    wire [15:0]  t_act_ok, t_rd_ok, t_wr_ok;
    wire         t_pre_ok;

    gddr5_sched #(.AUTO_PRECHARGE(AUTO_PRECHARGE)) u_sched (
        .clk(clk), .rst_n(rst_n),
        .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
        .req_bank(req_bank), .req_row(req_row), .req_col(req_col),
        .hold(hold),
        .bank_row_valid(b_row_valid), .bank_open_row(b_open_row),
        .bank_can_act(b_can_act), .bank_can_rd(b_can_rd),
        .bank_can_wr(b_can_wr), .bank_can_pre(b_can_pre),
        .t_act_ok(t_act_ok), .t_rd_ok(t_rd_ok), .t_wr_ok(t_wr_ok),
        .t_pre_ok(t_pre_ok),
        .cmd_valid(cmd_valid), .cmd(cmd), .cmd_bank(cmd_bank), .cmd_addr(cmd_addr),
        .bank_act(s_act), .bank_rd(s_rd), .bank_wr(s_wr), .bank_pre(s_pre),
        .bank_ap(s_ap),
        .t_issue_act(t_issue_act), .t_issue_rd(t_issue_rd),
        .t_issue_wr(t_issue_wr), .t_issue_pre(t_issue_pre),
        .busy(busy), .done(req_done)
    );

    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : g_bank
            wire [2:0] unused_state;
            wire       unused_row_hit;
            wire       unused_can_refpb;
            gddr5_bank_fsm #(
                .ROW_W(14), .TRCDRD(TRCDRD), .TRCDWR(TRCDWR), .TRAS(TRAS),
                .TRC(TRC), .TRP(TRP), .TRTP(TRTP), .TW2PRE(TW2PRE), .TRFCPB(TRFCPB)
            ) u_bank (
                .clk(clk), .rst_n(rst_n),
                .act(s_act[i]), .rd(s_rd[i]), .wr(s_wr[i]), .ap(s_ap),
                .pre(s_pre[i]), .refpb(1'b0), .row(cmd_addr),
                .state(unused_state), .open_row(b_open_row[14*i +: 14]),
                .row_valid(b_row_valid[i]), .row_hit(unused_row_hit),
                .can_act(b_can_act[i]), .can_rd(b_can_rd[i]), .can_wr(b_can_wr[i]),
                .can_pre(b_can_pre[i]), .can_refpb(unused_can_refpb),
                .idle(b_idle[i]), .cmd_err(b_err[i])
            );
        end
    endgenerate

    assign bank_idle = b_idle;
    assign err_bank  = |b_err;

    gddr5_timing #(
        .BG_ENABLE(BG_ENABLE), .GROUP_LSB(GROUP_LSB), .TRRDS(TRRDS), .TRRDL(TRRDL),
        .TFAW(TFAW), .T32AW(T32AW), .TCCDS(TCCDS), .TCCDL(TCCDL), .TW2RS(TW2RS),
        .TW2RL(TW2RL), .TRTW(TRTW), .TPPD(TPPD)
    ) u_timing (
        .clk(clk), .rst_n(rst_n),
        .issue_act(t_issue_act), .issue_rd(t_issue_rd),
        .issue_wr(t_issue_wr), .issue_pre(t_issue_pre), .bank(cmd_bank),
        .act_ok(t_act_ok), .rd_ok(t_rd_ok), .wr_ok(t_wr_ok), .pre_ok(t_pre_ok),
        .cmd_err(err_timing)
    );

    gddr5_cmd_enc #(.HAS_A12A13(HAS_A12A13), .ABI_MAX_LOW(ABI_MAX_LOW)) u_enc (
        .clk(clk), .rst_n(rst_n),
        .cmd_valid(cmd_valid), .cmd(cmd), .bank(cmd_bank), .addr(cmd_addr),
        .abi_enable(abi_enable), .cke_n_in(cke_n_in),
        .cke_n(cke_n), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
        .addr_ph1(addr_ph1), .addr_ph2(addr_ph2),
        .abi_n_ph1(abi_n_ph1), .abi_n_ph2(abi_n_ph2),
        .cmd_err(err_enc)
    );

endmodule
