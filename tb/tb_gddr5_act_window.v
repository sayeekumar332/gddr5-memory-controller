`timescale 1ns/1ps
// Self-checking testbench for gddr5_act_window (SLOTS=4, WIN=10).
// Cycle 0 is the cycle of the first push.
module tb_gddr5_act_window;

    reg  clk;
    reg  rst_n;
    reg  push;
    wire full;

    gddr5_act_window #(.SLOTS(4), .WIN(10), .CW(8)) dut (
        .clk(clk), .rst_n(rst_n), .push(push), .full(full));

    initial clk = 1'b0;
    always #5 clk = ~clk;

    integer errors;
    integer checks;

    task tick;
        begin @(posedge clk); #1; push = 1'b0; end
    endtask

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

    initial begin
        errors = 0; checks = 0; push = 1'b0; rst_n = 1'b0;
        @(posedge clk); #1; @(posedge clk); #1; rst_n = 1'b1;

        check("empty not full", full, 0);
        push = 1; tick;                    // push at cycle 0
        push = 1; tick;                    // 1
        push = 1; tick;                    // 2
        check("3 pushed, not full", full, 0);
        push = 1; tick;                    // 3 (4th push); now cycle 4
        check("c4 full", full, 1);
        push = 1; tick;                    // push while full (cycle 4): ignored; now 5
        check("c5 full", full, 1);
        repeat (4) tick;                   // cycle 9
        check("c9 full", full, 1);
        tick;                              // cycle 10: slot pushed at 0 is free
        check("c10 free (ignored push did not extend)", full, 0);
        push = 1; tick;                    // push at 10; now 11
        check("c11 slot of cycle 1 frees", full, 0);
        push = 1; tick;                    // push at 11 (uses the slot freed at 11); now 12
        check("c12 one free", full, 0);
        push = 1; tick;                    // push at 12; now 13
        check("c13 one free", full, 0);
        push = 1; tick;                    // push at 13: all four busy again; now 14
        check("c14 full again", full, 1);

        // Reset clears every slot.
        rst_n = 1'b0; tick; tick; rst_n = 1'b1;
        check("reset clears", full, 0);

        if (errors == 0) begin
            $display("tb_gddr5_act_window: %0d checks, 0 errors", checks);
            $display("PASS");
        end else begin
            $display("%0d of %0d checks FAILED", errors, checks);
            $display("FAIL");
        end
        $finish;
    end

    initial begin
        #100000; $display("TIMEOUT"); $display("FAIL"); $finish;
    end

endmodule
