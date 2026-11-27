`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// gddr5_bank_fsm - per-bank state machine and per-bank timing counters
//
// One instance per bank. It tracks the state the device believes the bank is
// in (JESD212C.01 Table 33), the open row, and the timers that only concern
// this bank. Timings that span banks (tRRD, tCCD, tWTR, tFAW, t32AW) belong to
// gddr5_timing.
//
// Timing parameters are in clock cycles (ceil(T_ps / tCK_ps), computed by the
// caller). The defaults are illustrative placeholders, not vendor data:
// JESD212C.01 Table 54 leaves AC values to the device datasheet.
//
// Each parameter is a minimum command-to-command spacing: a command issued in
// cycle t makes the dependent command legal in cycle t + N.
//
// Command strobes (act, rd, wr, pre, refpb) must only be asserted when the
// matching can_* output is high. An illegal strobe is ignored and flagged on
// cmd_err for one cycle.
// -----------------------------------------------------------------------------
module gddr5_bank_fsm #(
    parameter ROW_W   = 14,
    parameter TRCDRD  = 12,   // ACT -> READ
    parameter TRCDWR  = 8,    // ACT -> WRITE
    parameter TRAS    = 28,   // ACT -> PRE (minimum row-open time)
    parameter TRC     = 40,   // ACT -> ACT, same bank
    parameter TRP     = 12,   // PRE -> ACT / REFPB
    parameter TRTP    = 2,    // READ -> PRE, same bank
    parameter TW2PRE  = 16,   // WRITE -> PRE: WL + burst + tWR
    parameter TRFCPB  = 60    // REFPB -> ACT / REFPB
) (
    input  wire              clk,
    input  wire              rst_n,

    // Command strobes (one-cycle pulses from the scheduler).
    input  wire              act,
    input  wire              rd,
    input  wire              wr,
    input  wire              ap,        // with rd/wr: auto-precharge
    input  wire              pre,
    input  wire              refpb,
    input  wire [ROW_W-1:0]  row,       // row for act; row to test for row_hit

    // State and legality, valid in the current cycle.
    output wire [2:0]        state,
    output reg  [ROW_W-1:0]  open_row,
    output reg               row_valid,
    output wire              row_hit,   // row_valid and row == open_row
    output wire              can_act,
    output wire              can_rd,
    output wire              can_wr,
    output wire              can_pre,
    output wire              can_refpb,
    output wire              idle,      // bank precharged and tRP/tRFC elapsed
    output reg               cmd_err
);

    localparam [2:0] S_IDLE       = 3'd0;
    localparam [2:0] S_ACTIVATING = 3'd1;
    localparam [2:0] S_ACTIVE     = 3'd2;
    localparam [2:0] S_PRECHARGE  = 3'd3;
    localparam [2:0] S_REFRESH    = 3'd4;

    localparam CW = 8;   // counter width; every parameter must be < 2**CW

    // A spacing of N cycles loads N-1: the counter reads 0 in cycle t+N.
    function [CW-1:0] load_val;
        input integer n;
        begin
            if (n > 1) load_val = n[CW-1:0] - 1'b1;
            else       load_val = {CW{1'b0}};
        end
    endfunction

    reg [2:0]    state_q;
    reg          ap_pending;
    reg [CW-1:0] c_rcdrd;
    reg [CW-1:0] c_rcdwr;
    reg [CW-1:0] c_ras;
    reg [CW-1:0] c_rc;
    reg [CW-1:0] c_rp;
    reg [CW-1:0] c_pre;     // earliest PRE after the last READ/WRITE
    reg [CW-1:0] c_rfc;

    // Resolve state changes that are due this cycle, so state and the can_*
    // outputs are exact in the cycle they take effect.
    wire act_done = (c_rcdrd == 0) && (c_rcdwr == 0);
    assign state =
        (state_q == S_ACTIVATING && act_done) ? S_ACTIVE :
        (state_q == S_PRECHARGE  && c_rp == 0) ? S_IDLE   :
        (state_q == S_REFRESH    && c_rfc == 0) ? S_IDLE  :
        state_q;

    wire is_open = (state == S_ACTIVATING) || (state == S_ACTIVE);

    assign idle      = (state == S_IDLE);
    assign can_act   = idle && (c_rc == 0) && (c_rp == 0) && (c_rfc == 0);
    // No further column command once an auto-precharge is pending.
    assign can_rd    = is_open && (c_rcdrd == 0) && !ap_pending;
    assign can_wr    = is_open && (c_rcdwr == 0) && !ap_pending;
    assign can_pre   = is_open && (c_ras == 0) && (c_pre == 0);
    assign can_refpb = can_act;
    assign row_hit   = row_valid && (row == open_row);

    // Value c_pre will hold next cycle if nothing reloads it.
    wire [CW-1:0] c_pre_dec = (c_pre != 0) ? (c_pre - 1'b1) : {CW{1'b0}};

    // Auto-precharge starts as soon as PRE would be legal.
    wire ap_fire = ap_pending && can_pre;

    wire bad_cmd = (act   && !can_act)
                || (rd    && !can_rd)
                || (wr    && !can_wr)
                || (pre   && !can_pre)
                || (refpb && !can_refpb);

    always @(posedge clk) begin
        if (!rst_n) begin
            state_q    <= S_IDLE;
            ap_pending <= 1'b0;
            row_valid  <= 1'b0;
            open_row   <= {ROW_W{1'b0}};
            c_rcdrd    <= {CW{1'b0}};
            c_rcdwr    <= {CW{1'b0}};
            c_ras      <= {CW{1'b0}};
            c_rc       <= {CW{1'b0}};
            c_rp       <= {CW{1'b0}};
            c_pre      <= {CW{1'b0}};
            c_rfc      <= {CW{1'b0}};
            cmd_err    <= 1'b0;
        end else begin
            cmd_err <= bad_cmd;

            // Timers count down; command effects below override the decrement.
            if (c_rcdrd != 0) c_rcdrd <= c_rcdrd - 1'b1;
            if (c_rcdwr != 0) c_rcdwr <= c_rcdwr - 1'b1;
            if (c_ras   != 0) c_ras   <= c_ras   - 1'b1;
            if (c_rc    != 0) c_rc    <= c_rc    - 1'b1;
            if (c_rp    != 0) c_rp    <= c_rp    - 1'b1;
            if (c_pre   != 0) c_pre   <= c_pre   - 1'b1;
            if (c_rfc   != 0) c_rfc   <= c_rfc   - 1'b1;

            // Carry the resolved state forward (ACTIVATING->ACTIVE, etc.).
            state_q <= state;

            if (ap_fire) begin
                state_q    <= S_PRECHARGE;
                row_valid  <= 1'b0;
                ap_pending <= 1'b0;
                c_rp       <= load_val(TRP);
            end

            if (act && can_act) begin
                state_q    <= S_ACTIVATING;
                open_row   <= row;
                row_valid  <= 1'b1;
                ap_pending <= 1'b0;
                c_rcdrd    <= load_val(TRCDRD);
                c_rcdwr    <= load_val(TRCDWR);
                c_ras      <= load_val(TRAS);
                c_rc       <= load_val(TRC);
                c_pre      <= {CW{1'b0}};
            end

            if (rd && can_rd) begin
                if (ap) ap_pending <= 1'b1;
                if (c_pre_dec < load_val(TRTP)) c_pre <= load_val(TRTP);
            end

            if (wr && can_wr) begin
                if (ap) ap_pending <= 1'b1;
                if (c_pre_dec < load_val(TW2PRE)) c_pre <= load_val(TW2PRE);
            end

            if (pre && can_pre) begin
                state_q    <= S_PRECHARGE;
                row_valid  <= 1'b0;
                ap_pending <= 1'b0;
                c_rp       <= load_val(TRP);
            end

            if (refpb && can_refpb) begin
                state_q <= S_REFRESH;
                c_rfc   <= load_val(TRFCPB);
            end
        end
    end

endmodule
