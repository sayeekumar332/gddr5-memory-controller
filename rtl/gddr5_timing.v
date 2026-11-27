`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// gddr5_timing - cross-bank timing tracker
//
// Enforces the command spacings that involve more than one bank
// (JESD212C.01 Table 9, tFAW/t32AW in section 7.x, Table 35):
//   ACT -> ACT      tRRDS / tRRDL, tFAW (4 ACT window), t32AW (32 ACT window)
//   RD  -> RD       tCCDS / tCCDL
//   WR  -> WR       tCCDS / tCCDL
//   WR  -> RD       tW2RS / tW2RL   (internal write-to-read: WL + burst + tWTR)
//   RD  -> WR       tRTW            (read-to-write bus turnaround)
//   PRE -> PRE      tPPD
// Same-bank spacings (tRC, tRCD, tRAS, tRP, ...) are in gddr5_bank_fsm.
//
// Bank groups (Table 8): for 16 banks the group is bank[3:2] (GROUP_LSB = 2);
// for 8 banks it is bank[2:1] (GROUP_LSB = 1). With BG_ENABLE = 0 the "S"
// values apply to every pair of banks.
//
// All timings are minimum spacings in cycles. Defaults are illustrative
// placeholders, not vendor data. Command strobes must be asserted only when
// the matching *_ok output for the target bank is high; an illegal strobe is
// ignored and flagged on cmd_err for one cycle.
// -----------------------------------------------------------------------------
module gddr5_timing #(
    parameter BG_ENABLE = 1,
    parameter GROUP_LSB = 2,
    parameter TRRDS     = 5,
    parameter TRRDL     = 7,
    parameter TFAW      = 23,
    parameter T32AW     = 184,
    parameter TCCDS     = 2,
    parameter TCCDL     = 4,
    parameter TW2RS     = 12,   // WRITE -> READ, different group (or BG off)
    parameter TW2RL     = 14,   // WRITE -> READ, same group
    parameter TRTW      = 14,   // READ -> WRITE
    parameter TPPD      = 2
) (
    input  wire        clk,
    input  wire        rst_n,

    // Command strobes (one-cycle pulses; at most one per cycle).
    input  wire        issue_act,
    input  wire        issue_rd,
    input  wire        issue_wr,
    input  wire        issue_pre,
    input  wire [3:0]  bank,

    // Legality per bank, valid in the current cycle.
    output wire [15:0] act_ok,
    output wire [15:0] rd_ok,
    output wire [15:0] wr_ok,
    output wire        pre_ok,
    output reg         cmd_err
);

    localparam CW = 8;   // counter width; spacing parameters must be < 2**CW

    function [CW-1:0] load_val;
        input integer n;
        begin
            if (n > 1) load_val = n[CW-1:0] - 1'b1;
            else       load_val = {CW{1'b0}};
        end
    endfunction

    // Group of the strobed bank.
    // GROUP_LSB is 2 (16 banks) or 1 (8 banks).
    wire [1:0] grp = (GROUP_LSB == 2) ? bank[3:2] : bank[2:1];

    // ---- rolling windows ---------------------------------------------------
    wire faw_full;
    wire aw32_full;
    wire act_issue_ok = act_ok[bank];

    gddr5_act_window #(.SLOTS(4),  .WIN(TFAW),  .CW(CW)) u_faw (
        .clk(clk), .rst_n(rst_n), .push(issue_act && act_issue_ok), .full(faw_full));
    gddr5_act_window #(.SLOTS(32), .WIN(T32AW), .CW(10)) u_aw32 (
        .clk(clk), .rst_n(rst_n), .push(issue_act && act_issue_ok), .full(aw32_full));

    // ---- spacing counters --------------------------------------------------
    reg [CW-1:0] c_act_s;
    reg [CW-1:0] c_rd_s;
    reg [CW-1:0] c_wr_s;
    reg [CW-1:0] c_ppd;
    reg [CW-1:0] c_act_l [0:3];
    reg [CW-1:0] c_rd_l  [0:3];
    reg [CW-1:0] c_wr_l  [0:3];

    // Value a counter holds next cycle if nothing reloads it.
    function [CW-1:0] dec;
        input [CW-1:0] c;
        begin
            if (c != {CW{1'b0}}) dec = c - 1'b1;
            else                 dec = {CW{1'b0}};
        end
    endfunction

    // Keep the larger of the decremented counter and a new load.
    function [CW-1:0] keep_max;
        input [CW-1:0] c;
        input [CW-1:0] n;
        begin
            keep_max = (dec(c) > n) ? dec(c) : n;
        end
    endfunction

    // ---- legality per bank -------------------------------------------------
    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : g_bank
            localparam integer G = (i >> GROUP_LSB) % 4;
            wire act_l_ok = (BG_ENABLE == 0) || (c_act_l[G] == {CW{1'b0}});
            wire rd_l_ok  = (BG_ENABLE == 0) || (c_rd_l[G]  == {CW{1'b0}});
            wire wr_l_ok  = (BG_ENABLE == 0) || (c_wr_l[G]  == {CW{1'b0}});
            assign act_ok[i] = (c_act_s == {CW{1'b0}}) && act_l_ok && !faw_full && !aw32_full;
            assign rd_ok[i]  = (c_rd_s  == {CW{1'b0}}) && rd_l_ok;
            assign wr_ok[i]  = (c_wr_s  == {CW{1'b0}}) && wr_l_ok;
        end
    endgenerate

    assign pre_ok = (c_ppd == {CW{1'b0}});

    wire bad_cmd = (issue_act && !act_ok[bank])
                || (issue_rd  && !rd_ok[bank])
                || (issue_wr  && !wr_ok[bank])
                || (issue_pre && !pre_ok);

    integer g;
    always @(posedge clk) begin
        if (!rst_n) begin
            c_act_s <= {CW{1'b0}};
            c_rd_s  <= {CW{1'b0}};
            c_wr_s  <= {CW{1'b0}};
            c_ppd   <= {CW{1'b0}};
            for (g = 0; g < 4; g = g + 1) begin
                c_act_l[g] <= {CW{1'b0}};
                c_rd_l[g]  <= {CW{1'b0}};
                c_wr_l[g]  <= {CW{1'b0}};
            end
            cmd_err <= 1'b0;
        end else begin
            cmd_err <= bad_cmd;

            if (c_act_s != 0) c_act_s <= c_act_s - 1'b1;
            if (c_rd_s  != 0) c_rd_s  <= c_rd_s  - 1'b1;
            if (c_wr_s  != 0) c_wr_s  <= c_wr_s  - 1'b1;
            if (c_ppd   != 0) c_ppd   <= c_ppd   - 1'b1;
            for (g = 0; g < 4; g = g + 1) begin
                if (c_act_l[g] != 0) c_act_l[g] <= c_act_l[g] - 1'b1;
                if (c_rd_l[g]  != 0) c_rd_l[g]  <= c_rd_l[g]  - 1'b1;
                if (c_wr_l[g]  != 0) c_wr_l[g]  <= c_wr_l[g]  - 1'b1;
            end

            if (issue_act && act_ok[bank]) begin
                c_act_s      <= load_val(TRRDS);
                c_act_l[grp] <= load_val(TRRDL);
            end

            if (issue_rd && rd_ok[bank]) begin
                c_rd_s      <= keep_max(c_rd_s,      load_val(TCCDS));
                c_rd_l[grp] <= keep_max(c_rd_l[grp], load_val(TCCDL));
                c_wr_s      <= keep_max(c_wr_s,      load_val(TRTW));
            end

            if (issue_wr && wr_ok[bank]) begin
                c_wr_s      <= keep_max(c_wr_s,      load_val(TCCDS));
                c_wr_l[grp] <= keep_max(c_wr_l[grp], load_val(TCCDL));
                c_rd_s      <= keep_max(c_rd_s,      load_val(TW2RS));
                c_rd_l[grp] <= keep_max(c_rd_l[grp], load_val(TW2RL));
            end

            if (issue_pre && pre_ok)
                c_ppd <= load_val(TPPD);
        end
    end

endmodule
