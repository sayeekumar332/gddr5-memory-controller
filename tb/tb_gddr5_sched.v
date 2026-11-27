`timescale 1ns/1ps
`include "gddr5_cmds.vh"
// Self-checking Verilog-2005 testbench for gddr5_sched.
// Bank state and timing flags are driven directly, so every legality
// combination can be set by hand.
module tb_gddr5_sched;

    reg          clk, rst_n;
    reg          req_valid, req_write;
    reg  [3:0]   req_bank;
    reg  [13:0]  req_row;
    reg  [6:0]   req_col;
    reg          hold;
    reg  [15:0]  row_valid, can_act, can_rd, can_wr, can_pre;
    reg  [223:0] open_rows;
    reg  [15:0]  t_act_ok, t_rd_ok, t_wr_ok;
    reg          t_pre_ok;

    wire         req_ready, cmd_valid, busy, done, bank_ap;
    wire [4:0]   cmd;
    wire [3:0]   cmd_bank;
    wire [13:0]  cmd_addr;
    wire [15:0]  b_act, b_rd, b_wr, b_pre;
    wire         ti_act, ti_rd, ti_wr, ti_pre;

    // Second instance with auto-precharge on.
    wire         req_ready2, cmd_valid2, busy2, done2, bank_ap2;
    wire [4:0]   cmd2;
    wire [3:0]   cmd_bank2;
    wire [13:0]  cmd_addr2;
    wire [15:0]  b_act2, b_rd2, b_wr2, b_pre2;
    wire         ti_act2, ti_rd2, ti_wr2, ti_pre2;

    gddr5_sched #(.AUTO_PRECHARGE(0)) dut (
        .clk(clk), .rst_n(rst_n),
        .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
        .req_bank(req_bank), .req_row(req_row), .req_col(req_col), .hold(hold),
        .bank_row_valid(row_valid), .bank_open_row(open_rows),
        .bank_can_act(can_act), .bank_can_rd(can_rd), .bank_can_wr(can_wr),
        .bank_can_pre(can_pre),
        .t_act_ok(t_act_ok), .t_rd_ok(t_rd_ok), .t_wr_ok(t_wr_ok), .t_pre_ok(t_pre_ok),
        .cmd_valid(cmd_valid), .cmd(cmd), .cmd_bank(cmd_bank), .cmd_addr(cmd_addr),
        .bank_act(b_act), .bank_rd(b_rd), .bank_wr(b_wr), .bank_pre(b_pre),
        .bank_ap(bank_ap),
        .t_issue_act(ti_act), .t_issue_rd(ti_rd), .t_issue_wr(ti_wr), .t_issue_pre(ti_pre),
        .busy(busy), .done(done));

    gddr5_sched #(.AUTO_PRECHARGE(1)) dut_ap (
        .clk(clk), .rst_n(rst_n),
        .req_valid(req_valid), .req_ready(req_ready2), .req_write(req_write),
        .req_bank(req_bank), .req_row(req_row), .req_col(req_col), .hold(hold),
        .bank_row_valid(row_valid), .bank_open_row(open_rows),
        .bank_can_act(can_act), .bank_can_rd(can_rd), .bank_can_wr(can_wr),
        .bank_can_pre(can_pre),
        .t_act_ok(t_act_ok), .t_rd_ok(t_rd_ok), .t_wr_ok(t_wr_ok), .t_pre_ok(t_pre_ok),
        .cmd_valid(cmd_valid2), .cmd(cmd2), .cmd_bank(cmd_bank2), .cmd_addr(cmd_addr2),
        .bank_act(b_act2), .bank_rd(b_rd2), .bank_wr(b_wr2), .bank_pre(b_pre2),
        .bank_ap(bank_ap2),
        .t_issue_act(ti_act2), .t_issue_rd(ti_rd2), .t_issue_wr(ti_wr2), .t_issue_pre(ti_pre2),
        .busy(busy2), .done(done2));

    initial clk = 1'b0;
    always #5 clk = ~clk;

    integer errors, checks;

    task tick; begin @(posedge clk); #1; end endtask

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

    // All legality flags high, no bank open, nothing requested.
    task defaults;
        begin
            req_valid = 0; req_write = 0; req_bank = 0; req_row = 0; req_col = 0;
            hold = 0;
            row_valid = 16'h0000; open_rows = 224'd0;
            can_act = 16'hFFFF; can_rd = 16'hFFFF; can_wr = 16'hFFFF; can_pre = 16'hFFFF;
            t_act_ok = 16'hFFFF; t_rd_ok = 16'hFFFF; t_wr_ok = 16'hFFFF; t_pre_ok = 1'b1;
        end
    endtask

    task reset_dut;
        begin
            defaults;
            rst_n = 1'b0; tick; tick; rst_n = 1'b1;
        end
    endtask

    // Present a request for one cycle; afterwards it is held in the scheduler.
    task send;
        input wr; input [3:0] b; input [13:0] r; input [6:0] c;
        begin
            req_valid = 1; req_write = wr; req_bank = b; req_row = r; req_col = c;
            tick;
            req_valid = 0; req_write = 0; req_bank = 0; req_row = 0; req_col = 0;
        end
    endtask

    task set_row; input [3:0] b; input [13:0] r;
        begin row_valid[b] = 1'b1; open_rows[14*b +: 14] = r; end
    endtask

    initial begin
        errors = 0; checks = 0; rst_n = 1'b0;
        reset_dut;

        // ---- T1: idle after reset ---------------------------------------
        check("T1 req_ready",    req_ready, 1);
        check("T1 busy",         busy, 0);
        check("T1 no command",   cmd_valid, 0);
        check("T1 cmd is NOP",   cmd, `GDDR5_CMD_NOP);

        // ---- T2: empty bank -> ACTIVE ------------------------------------
        send(1'b0, 4'd5, 14'h0123, 7'h2A);
        check("T2 busy",         busy, 1);
        check("T2 not ready",    req_ready, 0);
        check("T2 cmd valid",    cmd_valid, 1);
        check("T2 cmd ACT",      cmd, `GDDR5_CMD_ACT);
        check("T2 bank",         cmd_bank, 5);
        check("T2 row on addr",  cmd_addr, 14'h0123);
        check("T2 bank_act",     b_act, 16'h0020);
        check("T2 other strobes", b_rd | b_wr | b_pre, 0);
        check("T2 timing act",   ti_act, 1);
        check("T2 not done",     done, 0);
        can_act[5] = 1'b0;                  // bank says no
        #1; check("T2 bank blocks ACT",  cmd_valid, 0);
        can_act[5] = 1'b1; t_act_ok[5] = 1'b0;   // cross-bank says no
        #1; check("T2 timing blocks ACT", cmd_valid, 0);
        t_act_ok[5] = 1'b1; can_act[4] = 1'b0;   // a different bank says no
        #1; check("T2 other bank irrelevant", cmd_valid, 1);
        can_act[4] = 1'b1;

        // ---- T3: row hit read -> READ ---------------------------------------
        reset_dut;
        set_row(4'd5, 14'h0123);
        send(1'b0, 4'd5, 14'h0123, 7'h2A);
        check("T3 cmd RD",       cmd, `GDDR5_CMD_RD);
        check("T3 col on addr",  cmd_addr, 14'h002A);
        check("T3 bank_rd",      b_rd, 16'h0020);
        check("T3 timing rd",    ti_rd, 1);
        check("T3 no timing wr", ti_wr | ti_act | ti_pre, 0);
        check("T3 done",         done, 1);
        check("T3 ready on done", req_ready, 1);
        check("T3 no ACT/PRE",   b_act | b_pre, 0);
        check("T3 AP off",       bank_ap, 0);
        can_rd[5] = 1'b0;
        #1; check("T3 bank blocks RD", cmd_valid, 0);
        can_rd[5] = 1'b1; t_rd_ok[5] = 1'b0;
        #1; check("T3 timing blocks RD", cmd_valid, 0);
        t_rd_ok[5] = 1'b1; can_wr[5] = 1'b0;   // write flags are irrelevant to a read
        #1; check("T3 wr flag irrelevant", cmd_valid, 1);
        can_wr[5] = 1'b1;
        tick;
        check("T3 finished",     busy, 0);

        // ---- T4: row hit write -> WRITE ----------------------------------------
        reset_dut;
        set_row(4'd9, 14'h1ABC);
        send(1'b1, 4'd9, 14'h1ABC, 7'h7F);
        check("T4 cmd WOM",      cmd, `GDDR5_CMD_WOM);
        check("T4 col on addr",  cmd_addr, 14'h007F);
        check("T4 bank_wr",      b_wr, 16'h0200);
        check("T4 timing wr",    ti_wr, 1);
        check("T4 no timing rd", ti_rd | ti_act | ti_pre, 0);
        can_wr[9] = 1'b0;
        #1; check("T4 bank blocks WR", cmd_valid, 0);
        can_wr[9] = 1'b1; t_wr_ok[9] = 1'b0;
        #1; check("T4 timing blocks WR", cmd_valid, 0);
        t_wr_ok[9] = 1'b1; can_rd[9] = 1'b0;
        #1; check("T4 rd flag irrelevant", cmd_valid, 1);

        // ---- T5: row miss -> PRECHARGE, then ACTIVE ----------------------------
        reset_dut;
        set_row(4'd2, 14'h0124);
        send(1'b0, 4'd2, 14'h0123, 7'h01);
        check("T5 cmd PRE",      cmd, `GDDR5_CMD_PRE);
        check("T5 bank_pre",     b_pre, 16'h0004);
        check("T5 timing pre",   ti_pre, 1);
        check("T5 no ACT yet",   b_act, 0);
        check("T5 not done",     done, 0);
        can_pre[2] = 1'b0;
        #1; check("T5 bank blocks PRE", cmd_valid, 0);
        can_pre[2] = 1'b1; t_pre_ok = 1'b0;
        #1; check("T5 tPPD blocks PRE", cmd_valid, 0);
        t_pre_ok = 1'b1;
        #1;
        tick;                               // PRE issued: the bank clears its row
        row_valid[2] = 1'b0;
        #1; check("T5 then ACT", cmd, `GDDR5_CMD_ACT);
        check("T5 ACT row",      cmd_addr, 14'h0123);
        tick;                               // ACT issued: the bank opens the row
        set_row(4'd2, 14'h0123);
        #1; check("T5 then RD",  cmd, `GDDR5_CMD_RD);
        check("T5 RD col",       cmd_addr, 14'h0001);

        // ---- T6: hold stops everything ----------------------------------------
        reset_dut;
        hold = 1;
        send(1'b0, 4'd1, 14'h0010, 7'h00);
        check("T6 no command",   cmd_valid, 0);
        check("T6 request kept", busy, 1);
        check("T6 not ready",    req_ready, 0);
        hold = 0;
        #1; check("T6 issues after hold", cmd, `GDDR5_CMD_ACT);

        // ---- T7: auto-precharge instance -----------------------------------------
        reset_dut;
        set_row(4'd3, 14'h0300);
        send(1'b0, 4'd3, 14'h0300, 7'h11);
        check("T7 AP on",        bank_ap2, 1);
        check("T7 cmd RDA",      cmd2, `GDDR5_CMD_RDA);
        reset_dut;
        set_row(4'd3, 14'h0300);
        send(1'b1, 4'd3, 14'h0300, 7'h11);
        check("T7 cmd WOMA",     cmd2, `GDDR5_CMD_WOMA);

        // ---- T8: back-to-back requests --------------------------------------------
        reset_dut;
        set_row(4'd6, 14'h0600);
        send(1'b0, 4'd6, 14'h0600, 7'h01);
        check("T8 first RD",     cmd, `GDDR5_CMD_RD);
        check("T8 ready while finishing", req_ready, 1);
        // Present the next request in the cycle the first one completes.
        req_valid = 1; req_write = 1; req_bank = 4'd6; req_row = 14'h0600; req_col = 7'h02;
        tick;
        req_valid = 0;
        check("T8 second request taken", busy, 1);
        check("T8 second is WRITE",      cmd, `GDDR5_CMD_WOM);
        check("T8 second col",           cmd_addr, 14'h0002);

        // ---- T9: bank 15 and bank selection ------------------------------------------
        reset_dut;
        set_row(4'd15, 14'h3FFF);
        set_row(4'd0,  14'h1555);             // another bank holds the wanted row
        send(1'b0, 4'd15, 14'h1555, 7'h00);
        check("T9 bank 15 miss -> PRE", cmd, `GDDR5_CMD_PRE);
        check("T9 bank 15 strobe",      b_pre, 16'h8000);

        // ---- T9b: rows that differ only in one bit are a miss -------------------------
        reset_dut;
        set_row(4'd4, 14'h2123);
        send(1'b0, 4'd4, 14'h0123, 7'h00);
        check("T9b top bit differs -> PRE", cmd, `GDDR5_CMD_PRE);
        reset_dut;
        set_row(4'd4, 14'h0123);
        send(1'b0, 4'd4, 14'h2123, 7'h00);
        check("T9b top bit differs (2) -> PRE", cmd, `GDDR5_CMD_PRE);
        reset_dut;
        set_row(4'd4, 14'h0123);
        send(1'b0, 4'd4, 14'h0122, 7'h00);
        check("T9b low bit differs -> PRE", cmd, `GDDR5_CMD_PRE);

        // ---- T10: a busy scheduler takes no second request ------------------------------
        reset_dut;
        send(1'b0, 4'd7, 14'h0070, 7'h00);
        req_valid = 1; req_bank = 4'd8; req_row = 14'h0080;
        tick;
        req_valid = 0;
        check("T10 first request kept", cmd_bank, 7);
        check("T10 still busy",         busy, 1);

        if (errors == 0) begin
            $display("tb_gddr5_sched: %0d checks, 0 errors", checks);
            $display("PASS");
        end else begin
            $display("%0d of %0d checks FAILED", errors, checks);
            $display("FAIL");
        end
        $finish;
    end

    initial begin #200000; $display("TIMEOUT"); $display("FAIL"); $finish; end

endmodule
