`timescale 1ns/1ps
// Self-checking Verilog-2005 testbench for gddr5_bank_fsm.
// Small timing values keep the expected cycle numbers easy to derive by hand:
//   tRCDRD=4 tRCDWR=3 tRAS=8 tRC=14 tRP=4 tRTP=2 tW2PRE=6 tRFCPB=10
// "cycle k" means k cycles after the cycle in which the ACT was issued (k=0).
module tb_gddr5_bank_fsm;

    localparam ROW_W = 14;

    reg              clk;
    reg              rst_n;
    reg              act, rd, wr, ap, pre, refpb;
    reg  [ROW_W-1:0] row;
    wire [2:0]       state;
    wire [ROW_W-1:0] open_row;
    wire             row_valid, row_hit;
    wire             can_act, can_rd, can_wr, can_pre, can_refpb, idle, cmd_err;

    gddr5_bank_fsm #(
        .ROW_W(ROW_W), .TRCDRD(4), .TRCDWR(3), .TRAS(8), .TRC(14),
        .TRP(4), .TRTP(2), .TW2PRE(6), .TRFCPB(10)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .act(act), .rd(rd), .wr(wr), .ap(ap), .pre(pre), .refpb(refpb),
        .row(row),
        .state(state), .open_row(open_row), .row_valid(row_valid),
        .row_hit(row_hit), .can_act(can_act), .can_rd(can_rd),
        .can_wr(can_wr), .can_pre(can_pre), .can_refpb(can_refpb),
        .idle(idle), .cmd_err(cmd_err)
    );

    localparam [2:0] S_IDLE = 3'd0, S_ACTIVATING = 3'd1, S_ACTIVE = 3'd2,
                     S_PRECHARGE = 3'd3, S_REFRESH = 3'd4;

    initial clk = 1'b0;
    always #5 clk = ~clk;

    integer errors;
    integer checks;
    integer cyc;         // cycles since the last reset release

    always @(posedge clk) cyc <= rst_n ? cyc + 1 : 0;

    // Advance one clock; inputs change 1 ns after the edge.
    task tick;
        begin
            @(posedge clk);
            #1;
            act = 1'b0; rd = 1'b0; wr = 1'b0; ap = 1'b0; pre = 1'b0; refpb = 1'b0;
        end
    endtask

    task idle_cycles;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) tick;
        end
    endtask

    task do_act;  input [ROW_W-1:0] r; begin act = 1'b1; row = r; tick; end endtask
    task do_rd;   input apv;           begin rd = 1'b1; ap = apv; tick; end endtask
    task do_wr;   input apv;           begin wr = 1'b1; ap = apv; tick; end endtask
    task do_pre;  begin pre = 1'b1; tick; end endtask
    task do_ref;  begin refpb = 1'b1; tick; end endtask

    task check;
        input [255:0] name;
        input integer got;
        input integer exp;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL %0s: got %0d expected %0d (time %0t)", name, got, exp, $time);
            end
        end
    endtask

    task reset_dut;
        begin
            act = 0; rd = 0; wr = 0; ap = 0; pre = 0; refpb = 0; row = 0;
            rst_n = 1'b0;
            @(posedge clk); #1;
            @(posedge clk); #1;
            rst_n = 1'b1;
            // The first cycle after reset release is cycle 0 (ACT goes here).
        end
    endtask

    initial begin
        errors = 0; checks = 0; cyc = 0;
        rst_n = 1'b0;
        reset_dut;

        // ---- T1: ACT -> RD/WR/PRE -> ACT spacing ------------------------
        check("T1 reset idle",       state, S_IDLE);
        check("T1 reset can_act",    can_act, 1);
        check("T1 reset can_rd",     can_rd, 0);
        do_act(14'h155);                     // ACT in cycle 0; now cycle 1
        check("T1 c1 state",         state, S_ACTIVATING);
        check("T1 c1 can_act",       can_act, 0);
        check("T1 c1 row_valid",     row_valid, 1);
        check("T1 c1 open_row",      open_row, 14'h155);
        idle_cycles(1);                      // cycle 2
        check("T1 c2 can_wr",        can_wr, 0);
        idle_cycles(1);                      // cycle 3
        check("T1 c3 can_wr",        can_wr, 1);
        check("T1 c3 can_rd",        can_rd, 0);
        idle_cycles(1);                      // cycle 4
        check("T1 c4 can_rd",        can_rd, 1);
        check("T1 c4 state",         state, S_ACTIVE);
        idle_cycles(3);                      // cycle 7
        check("T1 c7 can_pre",       can_pre, 0);
        idle_cycles(1);                      // cycle 8
        check("T1 c8 can_pre",       can_pre, 1);
        do_pre;                              // PRE in cycle 8; now cycle 9
        check("T1 c9 state",         state, S_PRECHARGE);
        check("T1 c9 row_valid",     row_valid, 0);
        idle_cycles(3);                      // cycle 12: tRP met, tRC not
        check("T1 c12 can_act",      can_act, 0);
        idle_cycles(1);                      // cycle 13
        check("T1 c13 can_act",      can_act, 0);
        idle_cycles(1);                      // cycle 14: tRC met
        check("T1 c14 can_act",      can_act, 1);
        check("T1 c14 state",        state, S_IDLE);

        // ---- T2: late PRE, tRP dominates tRC ----------------------------
        reset_dut;
        do_act(14'h001);
        idle_cycles(11);                     // cycle 12
        do_pre;                              // PRE in cycle 12; now cycle 13
        idle_cycles(2);                      // cycle 15
        check("T2 c15 can_act",      can_act, 0);
        idle_cycles(1);                      // cycle 16 = 12 + tRP
        check("T2 c16 can_act",      can_act, 1);

        // ---- T3: tRTP dominates tRAS ------------------------------------
        reset_dut;
        do_act(14'h002);
        idle_cycles(6);                      // cycle 7
        do_rd(1'b0);                         // RD in cycle 7; now cycle 8
        check("T3 c8 tRAS ok, tRTP not", can_pre, 0);
        idle_cycles(1);                      // cycle 9 = 7 + tRTP
        check("T3 c9 can_pre",       can_pre, 1);

        // ---- T4: write-to-precharge dominates tRAS ----------------------
        reset_dut;
        do_act(14'h003);
        idle_cycles(2);                      // cycle 3
        do_wr(1'b0);                         // WR in cycle 3; now cycle 4
        idle_cycles(4);                      // cycle 8
        check("T4 c8 can_pre",       can_pre, 0);
        idle_cycles(1);                      // cycle 9 = 3 + tW2PRE
        check("T4 c9 can_pre",       can_pre, 1);

        // ---- T5: READ with auto-precharge -------------------------------
        reset_dut;
        do_act(14'h0AA);
        idle_cycles(3);                      // cycle 4
        do_rd(1'b1);                         // RD+AP in cycle 4; now cycle 5
        check("T5 c5 no more columns", can_rd, 0);
        check("T5 c5 still open",    row_valid, 1);
        idle_cycles(3);                      // cycle 8: auto-PRE fires
        check("T5 c8 state",         state, S_ACTIVE);
        idle_cycles(1);                      // cycle 9
        check("T5 c9 state",         state, S_PRECHARGE);
        check("T5 c9 row_valid",     row_valid, 0);
        idle_cycles(4);                      // cycle 13
        check("T5 c13 can_act",      can_act, 0);
        idle_cycles(1);                      // cycle 14 (tRC)
        check("T5 c14 can_act",      can_act, 1);

        // ---- T6: per-bank refresh ---------------------------------------
        reset_dut;
        do_ref;                              // REFPB in cycle 0; now cycle 1
        check("T6 c1 state",         state, S_REFRESH);
        check("T6 c1 can_act",       can_act, 0);
        idle_cycles(8);                      // cycle 9
        check("T6 c9 can_act",       can_act, 0);
        idle_cycles(1);                      // cycle 10 = tRFCPB
        check("T6 c10 can_act",      can_act, 1);
        check("T6 c10 state",        state, S_IDLE);

        // ---- T7: illegal strobes are ignored and flagged ----------------
        reset_dut;
        do_act(14'h010);
        rd = 1'b1; tick;                     // RD in cycle 1, before tRCDRD
        check("T7 early RD flagged", cmd_err, 1);
        check("T7 state unchanged",  state, S_ACTIVATING);
        tick;
        check("T7 flag is one cycle", cmd_err, 0);
        refpb = 1'b1; tick;                  // REFPB on an open bank
        check("T7 REFPB flagged",    cmd_err, 1);
        act = 1'b1; row = 14'h011; tick;     // second ACT on an open bank
        check("T7 ACT flagged",      cmd_err, 1);
        check("T7 row kept",         open_row, 14'h010);

        // ---- T8: row hit ------------------------------------------------
        reset_dut;
        row = 14'h155;
        #1;
        check("T8 no hit when idle", row_hit, 0);
        do_act(14'h155);
        row = 14'h155;
        #1;
        check("T8 hit",              row_hit, 1);
        row = 14'h154;
        #1;
        check("T8 miss",             row_hit, 0);
        row = 14'h2155;
        #1;
        check("T8 miss on high bit", row_hit, 0);

        // ---- T9: reset in the middle of an operation --------------------
        reset_dut;
        do_act(14'h3FFF);
        reset_dut;
        check("T9 idle after reset", state, S_IDLE);
        check("T9 row cleared",      row_valid, 0);
        check("T9 can_act",          can_act, 1);

        if (errors == 0) begin
            $display("%0d checks", checks);
            $display("PASS");
        end else begin
            $display("%0d of %0d checks FAILED", errors, checks);
            $display("FAIL");
        end
        $finish;
    end

    // Safety net against a hung simulation.
    initial begin
        #200000;
        $display("TIMEOUT");
        $display("FAIL");
        $finish;
    end

endmodule
