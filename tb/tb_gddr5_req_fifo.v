`timescale 1ns/1ps
// Self-checking testbench for gddr5_req_fifo (WIDTH=8, DEPTH=5: not a power of two).
module tb_gddr5_req_fifo;

    reg        clk;
    reg        rst_n;
    reg        in_valid;
    wire       in_ready;
    reg  [7:0] in_data;
    wire       out_valid;
    reg        out_ready;
    wire [7:0] out_data;
    wire [15:0] level;

    gddr5_req_fifo #(.WIDTH(8), .DEPTH(5)) dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_ready(in_ready), .in_data(in_data),
        .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data),
        .level(level));

    initial clk = 1'b0;
    always #5 clk = ~clk;

    integer errors;
    integer checks;

    task tick;
        begin @(posedge clk); #1; end
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

    task push;
        input [7:0] d;
        begin in_valid = 1'b1; in_data = d; tick; in_valid = 1'b0; end
    endtask

    task pop_expect;
        input [7:0] d;
        begin
            check("pop valid", out_valid, 1);
            check("pop data", out_data, d);
            out_ready = 1'b1; tick; out_ready = 1'b0;
        end
    endtask

    integer i;

    initial begin
        errors = 0; checks = 0;
        in_valid = 0; in_data = 0; out_ready = 0; rst_n = 0;
        tick; tick; rst_n = 1; #1;

        check("empty: out_valid", out_valid, 0);
        check("empty: in_ready", in_ready, 1);
        check("empty: level", level, 0);

        // Fall-through: data is visible in the cycle after the push.
        push(8'hA1);
        check("one: out_valid", out_valid, 1);
        check("one: out_data", out_data, 8'hA1);
        check("one: level", level, 1);

        // Pop on an empty-after-pop FIFO, then a pop with nothing to pop.
        pop_expect(8'hA1);
        check("empty again", out_valid, 0);
        out_ready = 1'b1; tick; out_ready = 1'b0;       // pop request while empty
        check("empty pop level", level, 0);
        push(8'h11);
        pop_expect(8'h11);

        // Fill to full, check the stall, and check order.
        for (i = 0; i < 5; i = i + 1) push(8'h20 + i);
        check("full: level", level, 5);
        check("full: in_ready", in_ready, 0);
        in_valid = 1; in_data = 8'hEE; tick; in_valid = 0;   // push while full: ignored
        check("full push ignored: level", level, 5);
        for (i = 0; i < 5; i = i + 1) pop_expect(8'h20 + i);
        check("drained: out_valid", out_valid, 0);

        // Wrap around: five more passes through a five-deep FIFO.
        for (i = 0; i < 12; i = i + 1) begin
            push(8'h40 + i);
            pop_expect(8'h40 + i);
        end

        // Push and pop in the same cycle, FIFO half full: level holds.
        push(8'h51); push(8'h52);
        in_valid = 1; in_data = 8'h53; out_ready = 1; tick; in_valid = 0; out_ready = 0;
        check("push+pop: level", level, 2);
        pop_expect(8'h52);
        pop_expect(8'h53);

        // Push and pop in the same cycle when full: pop only (in_ready is low).
        for (i = 0; i < 5; i = i + 1) push(8'h60 + i);
        in_valid = 1; in_data = 8'h77; out_ready = 1; tick; in_valid = 0; out_ready = 0;
        check("full push+pop: level", level, 4);
        check("full push+pop: head", out_data, 8'h61);
        for (i = 1; i < 5; i = i + 1) pop_expect(8'h60 + i);

        // Reset in the middle.
        push(8'h91); push(8'h92);
        rst_n = 0; tick; tick; rst_n = 1; #1;
        check("reset: level", level, 0);
        check("reset: out_valid", out_valid, 0);
        push(8'h93);
        pop_expect(8'h93);

        $display("%0d checks, %0d errors", checks, errors);
        if (errors == 0) $display("PASS");
        else             $display("FAIL");
        $finish;
    end

    initial begin
        #200000;
        $display("TIMEOUT");
        $display("FAIL");
        $finish;
    end

endmodule
