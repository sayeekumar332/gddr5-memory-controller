`timescale 1ns/1ps
`include "gddr5_cmds.vh"
// -----------------------------------------------------------------------------
// gddr5_sched - command scheduler, release 1 (in order, open page)
//
// Takes one decoded request at a time, in arrival order, and chooses the next
// command it needs, at most one command per clock:
//
//   row hit    (bank has the row open)        -> READ or WRITE
//   row miss   (bank has another row open)    -> PRECHARGE, then ACTIVE, then column
//   row empty  (bank precharged)              -> ACTIVE, then column
//
// A command is chosen only when the bank's own legality flag (gddr5_bank_fsm)
// and the cross-bank flag (gddr5_timing) are both high. The request finishes
// when its column command issues. `hold` lets another sequencer (initialization,
// refresh, training) own the command bus; nothing issues while it is high.
//
// Open page: a row stays open until a request for another row needs the bank.
// With AUTO_PRECHARGE = 1 every column command also precharges the bank.
//
// Row-hit-first reordering and refresh arbitration are separate, later steps.
// -----------------------------------------------------------------------------
module gddr5_sched #(
    parameter AUTO_PRECHARGE = 0
) (
    input  wire        clk,
    input  wire        rst_n,

    // Request (valid/ready). Address fields are already decoded.
    input  wire        req_valid,
    output wire        req_ready,
    input  wire        req_write,
    input  wire [3:0]  req_bank,
    input  wire [13:0] req_row,
    input  wire [6:0]  req_col,

    // Another sequencer owns the command bus.
    input  wire        hold,

    // From the 16 bank state machines.
    input  wire [15:0]  bank_row_valid,
    input  wire [223:0] bank_open_row,     // 16 x 14 bits, bank b at [14*b +: 14]
    input  wire [15:0]  bank_can_act,
    input  wire [15:0]  bank_can_rd,
    input  wire [15:0]  bank_can_wr,
    input  wire [15:0]  bank_can_pre,

    // From the cross-bank timing tracker.
    input  wire [15:0]  t_act_ok,
    input  wire [15:0]  t_rd_ok,
    input  wire [15:0]  t_wr_ok,
    input  wire         t_pre_ok,

    // Issued command (to gddr5_cmd_enc).
    output wire         cmd_valid,
    output reg  [4:0]   cmd,
    output wire [3:0]   cmd_bank,
    output reg  [13:0]  cmd_addr,

    // Strobes to the bank state machines and the timing tracker.
    output wire [15:0]  bank_act,
    output wire [15:0]  bank_rd,
    output wire [15:0]  bank_wr,
    output wire [15:0]  bank_pre,
    output wire         bank_ap,
    output wire         t_issue_act,
    output wire         t_issue_rd,
    output wire         t_issue_wr,
    output wire         t_issue_pre,

    output wire         busy,              // a request is being worked on
    output wire         done               // column command issued this cycle
);

    // The request being worked on.
    reg         have_req;
    reg         q_write;
    reg  [3:0]  q_bank;
    reg  [13:0] q_row;
    reg  [6:0]  q_col;

    wire [13:0] open_row = bank_open_row[14*q_bank +: 14];
    wire        rv       = bank_row_valid[q_bank];
    wire        hit      = rv && (open_row == q_row);

    wire col_ok = q_write ? (bank_can_wr[q_bank] && t_wr_ok[q_bank])
                          : (bank_can_rd[q_bank] && t_rd_ok[q_bank]);

    wire go      = have_req && !hold;
    wire go_col  = go &&  hit && col_ok;
    wire go_pre  = go &&  rv && !hit && bank_can_pre[q_bank] && t_pre_ok;
    wire go_act  = go && !rv && bank_can_act[q_bank] && t_act_ok[q_bank];

    assign cmd_valid = go_col || go_pre || go_act;
    assign cmd_bank  = q_bank;
    assign done      = go_col;
    assign busy      = have_req;
    assign bank_ap   = (AUTO_PRECHARGE != 0);

    // Accept a new request when idle, or in the cycle the current one finishes.
    assign req_ready = !have_req || done;

    wire [15:0] sel = 16'd1 << q_bank;
    assign bank_act = go_act            ? sel : 16'd0;
    assign bank_rd  = (go_col && !q_write) ? sel : 16'd0;
    assign bank_wr  = (go_col &&  q_write) ? sel : 16'd0;
    assign bank_pre = go_pre            ? sel : 16'd0;

    assign t_issue_act = go_act;
    assign t_issue_rd  = go_col && !q_write;
    assign t_issue_wr  = go_col &&  q_write;
    assign t_issue_pre = go_pre;

    always @* begin
        cmd      = `GDDR5_CMD_NOP;
        cmd_addr = 14'd0;
        if (go_act) begin
            cmd      = `GDDR5_CMD_ACT;
            cmd_addr = q_row;
        end else if (go_pre) begin
            cmd      = `GDDR5_CMD_PRE;
        end else if (go_col) begin
            cmd_addr = {7'd0, q_col};
            if (q_write) cmd = (AUTO_PRECHARGE != 0) ? `GDDR5_CMD_WOMA : `GDDR5_CMD_WOM;
            else         cmd = (AUTO_PRECHARGE != 0) ? `GDDR5_CMD_RDA  : `GDDR5_CMD_RD;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            have_req <= 1'b0;
            q_write  <= 1'b0;
            q_bank   <= 4'd0;
            q_row    <= 14'd0;
            q_col    <= 7'd0;
        end else if (req_valid && req_ready) begin
            have_req <= 1'b1;
            q_write  <= req_write;
            q_bank   <= req_bank;
            q_row    <= req_row;
            q_col    <= req_col;
        end else if (done) begin
            have_req <= 1'b0;
        end
    end

endmodule
