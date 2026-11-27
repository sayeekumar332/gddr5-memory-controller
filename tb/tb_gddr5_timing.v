`timescale 1ns/1ps
// Self-checking Verilog-2005 testbench for gddr5_timing.
// Small timings with hand-derived expectations:
//   tRRDS=2 tRRDL=3 tFAW=10 t32AW=100 tCCDS=2 tCCDL=4
//   tW2RS=6 tW2RL=8 tRTW=5 tPPD=2
// "cycle k" = k cycles after the first command of the test (cycle 0).
// Banks 0-3 are group A, 4-7 B, 8-11 C, 12-15 D (Table 8).
module tb_gddr5_timing;

    reg         clk;
    reg         rst_n;
    reg         issue_act, issue_rd, issue_wr, issue_pre;
    reg  [3:0]  bank;

    wire [15:0] act_ok, rd_ok, wr_ok;
    wire        pre_ok, cmd_err;
    wire [15:0] act_ok2, rd_ok2, wr_ok2;
    wire        pre_ok2, cmd_err2;

    gddr5_timing #(
        .BG_ENABLE(1), .GROUP_LSB(2), .TRRDS(2), .TRRDL(3), .TFAW(10), .T32AW(100),
        .TCCDS(2), .TCCDL(4), .TW2RS(6), .TW2RL(8), .TRTW(5), .TPPD(2)
    ) dut (
        .clk(clk), .rst_n(rst_n), .issue_act(issue_act), .issue_rd(issue_rd),
        .issue_wr(issue_wr), .issue_pre(issue_pre), .bank(bank),
        .act_ok(act_ok), .rd_ok(rd_ok), .wr_ok(wr_ok), .pre_ok(pre_ok), .cmd_err(cmd_err)
    );

    // Same timings with bank groups disabled.
    gddr5_timing #(
        .BG_ENABLE(0), .GROUP_LSB(2), .TRRDS(2), .TRRDL(3), .TFAW(10), .T32AW(100),
        .TCCDS(2), .TCCDL(4), .TW2RS(6), .TW2RL(8), .TRTW(5), .TPPD(2)
    ) dut_nobg (
        .clk(clk), .rst_n(rst_n), .issue_act(issue_act), .issue_rd(issue_rd),
        .issue_wr(issue_wr), .issue_pre(issue_pre), .bank(bank),
        .act_ok(act_ok2), .rd_ok(rd_ok2), .wr_ok(wr_ok2), .pre_ok(pre_ok2), .cmd_err(cmd_err2)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    integer errors;
    integer checks;
    integer cyc;

    always @(posedge clk) cyc <= rst_n ? cyc + 1 : 0;

    task tick;
        begin
            @(posedge clk); #1;
            issue_act = 0; issue_rd = 0; issue_wr = 0; issue_pre = 0;
        end
    endtask

    task idle_cycles;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) tick;
        end
    endtask

    task do_act; input [3:0] b; begin issue_act = 1; bank = b; tick; end endtask
    task do_rd;  input [3:0] b; begin issue_rd  = 1; bank = b; tick; end endtask
    task do_wr;  input [3:0] b; begin issue_wr  = 1; bank = b; tick; end endtask
    task do_pre; begin issue_pre = 1; bank = 0; tick; end endtask

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
            issue_act = 0; issue_rd = 0; issue_wr = 0; issue_pre = 0; bank = 0;
            rst_n = 1'b0;
            @(posedge clk); #1;
            @(posedge clk); #1;
            rst_n = 1'b1;
        end
    endtask

    integer n, t_first, t_33;
    reg [3:0] b32;

    initial begin
        errors = 0; checks = 0; cyc = 0;
        rst_n = 1'b0;
        reset_dut;

        // ---- T1: tRRDS / tRRDL ----------------------------------------
        do_act(4'd0);                          // cycle 0; now cycle 1
        check("T1 c1 same group",   act_ok[1], 0);
        check("T1 c1 other group",  act_ok[4], 0);
        idle_cycles(1);                        // cycle 2
        check("T1 c2 other group",  act_ok[4], 1);
        check("T1 c2 same group",   act_ok[1], 0);
        idle_cycles(1);                        // cycle 3
        check("T1 c3 same group",   act_ok[1], 1);

        // ---- T2: tFAW (4 ACTs in a rolling window) ---------------------
        reset_dut;
        do_act(4'd0);                          // cycle 0
        idle_cycles(1);
        do_act(4'd4);                          // cycle 2
        idle_cycles(1);
        do_act(4'd8);                          // cycle 4
        idle_cycles(1);
        do_act(4'd12);                         // cycle 6; now cycle 7
        idle_cycles(2);                        // cycle 9
        check("T2 c9 window full",  act_ok[1], 0);
        idle_cycles(1);                        // cycle 10 = 0 + tFAW
        check("T2 c10 window free", act_ok[1], 1);
        do_act(4'd1);                          // 5th ACT at cycle 10; now 11
        check("T2 c11 tRRD",        act_ok[5], 0);
        idle_cycles(1);                        // cycle 12: tRRDS met, window: 2,4,6,10
        check("T2 c12 window full", act_ok[5], 1);

        // ---- T3: t32AW (32 ACTs in a rolling window) --------------------
        reset_dut;
        t_first = -1; t_33 = -1;
        for (n = 0; n < 33; n = n + 1) begin
            // Rotate groups so consecutive ACTs always use tRRDS.
            b32 = {n[1:0], n[3:2]};
            while (!act_ok[b32]) tick;
            if (n == 0)  t_first = cyc;
            if (n == 32) t_33 = cyc;
            if (n == 31) check("T3 32nd ACT cycle", cyc - t_first, 76);
            do_act(b32);
            // An illegal ACT right after this one (tRRDS not met) must not
            // take a slot in either window.
            if (n == 1) do_act(b32);
        end
        check("T3 33rd ACT at t32AW", t_33 - t_first, 100);

        // ---- T4: RD to RD -----------------------------------------------
        reset_dut;
        do_rd(4'd0);                           // cycle 0; now 1
        check("T4 c1 other group",  rd_ok[4], 0);
        idle_cycles(1);                        // cycle 2
        check("T4 c2 other group",  rd_ok[4], 1);
        check("T4 c2 same group",   rd_ok[1], 0);
        idle_cycles(1);                        // cycle 3
        check("T4 c3 same group",   rd_ok[1], 0);
        idle_cycles(1);                        // cycle 4
        check("T4 c4 same group",   rd_ok[1], 1);

        // ---- T5: WR to RD (internal write-to-read) -----------------------
        reset_dut;
        do_wr(4'd0);                           // cycle 0; now 1
        idle_cycles(4);                        // cycle 5
        check("T5 c5 other group",  rd_ok[4], 0);
        idle_cycles(1);                        // cycle 6
        check("T5 c6 other group",  rd_ok[4], 1);
        check("T5 c6 same group",   rd_ok[1], 0);
        idle_cycles(1);                        // cycle 7
        check("T5 c7 same group",   rd_ok[1], 0);
        idle_cycles(1);                        // cycle 8
        check("T5 c8 same group",   rd_ok[1], 1);

        // ---- T6: RD to WR ------------------------------------------------
        reset_dut;
        do_rd(4'd0);                           // cycle 0; now 1
        idle_cycles(3);                        // cycle 4
        check("T6 c4 RD->WR",       wr_ok[4], 0);
        check("T6 c4 RD->WR same",  wr_ok[1], 0);
        idle_cycles(1);                        // cycle 5
        check("T6 c5 RD->WR",       wr_ok[4], 1);
        check("T6 c5 RD->WR same",  wr_ok[1], 1);

        // ---- T7: WR to WR ------------------------------------------------
        reset_dut;
        do_wr(4'd0);                           // cycle 0; now 1
        check("T7 c1 other group",  wr_ok[4], 0);
        idle_cycles(1);                        // cycle 2
        check("T7 c2 other group",  wr_ok[4], 1);
        check("T7 c2 same group",   wr_ok[1], 0);
        idle_cycles(2);                        // cycle 4
        check("T7 c4 same group",   wr_ok[1], 1);

        // ---- T8: PRE to PRE ----------------------------------------------
        reset_dut;
        do_pre;                                // cycle 0; now 1
        check("T8 c1 pre_ok",       pre_ok, 0);
        idle_cycles(1);                        // cycle 2
        check("T8 c2 pre_ok",       pre_ok, 1);

        // ---- T9: bank groups disabled -------------------------------------
        reset_dut;
        do_rd(4'd0);                           // cycle 0; now 1
        idle_cycles(1);                        // cycle 2
        check("T9 BG on  same group",  rd_ok[1],  0);
        check("T9 BG off same group",  rd_ok2[1], 1);
        reset_dut;
        do_act(4'd0);                          // cycle 0; now 1
        idle_cycles(1);                        // cycle 2
        check("T9 BG on  ACT same group", act_ok[1],  0);
        check("T9 BG off ACT same group", act_ok2[1], 1);

        // ---- T10: illegal strobe is ignored and flagged ---------------------
        reset_dut;
        do_act(4'd0);                          // cycle 0; now 1
        do_act(4'd1);                          // illegal ACT in cycle 1; now 2
        check("T10 flagged",        cmd_err, 1);
        idle_cycles(1);                        // cycle 3
        check("T10 flag is one cycle", cmd_err, 0);
        check("T10 counters not reloaded", act_ok[1], 1);

        // ---- T12: an illegal ACT must not use up a window slot ---------------
        reset_dut;
        do_act(4'd0);                          // cycle 0; now 1
        do_act(4'd1);                          // illegal (tRRDL) in cycle 1; now 2
        do_act(4'd4);                          // cycle 2
        idle_cycles(1);
        do_act(4'd8);                          // cycle 4
        idle_cycles(1);                        // cycle 6
        check("T12 4th ACT allowed", act_ok[12], 1);
        do_act(4'd12);                         // cycle 6; now 7
        idle_cycles(2);                        // cycle 9
        check("T12 c9 window full",  act_ok[13], 0);
        idle_cycles(1);                        // cycle 10 = 0 + tFAW
        check("T12 c10 window free", act_ok[13], 1);

        // ---- T11: reset clears everything -----------------------------------
        reset_dut;
        do_act(4'd0);
        do_rd(4'd8);
        reset_dut;
        check("T11 act_ok",  act_ok[1], 1);
        check("T11 rd_ok",   rd_ok[1],  1);
        check("T11 wr_ok",   wr_ok[1],  1);
        check("T11 pre_ok",  pre_ok,    1);

        if (errors == 0) begin
            $display("tb_gddr5_timing: %0d checks, 0 errors", checks);
            $display("PASS");
        end else begin
            $display("%0d of %0d checks FAILED", errors, checks);
            $display("FAIL");
        end
        $finish;
    end

    initial begin
        #500000;
        $display("TIMEOUT");
        $display("FAIL");
        $finish;
    end

endmodule
