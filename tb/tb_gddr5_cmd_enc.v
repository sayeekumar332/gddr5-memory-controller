// tb_gddr5_cmd_enc.v - directed self-checking testbench (Verilog-2005)
//
// Expected values were derived by hand from JESD212C.01 Table 17 (command
// pins and A8/A10/A11 qualifiers) and Table 6 (address pin order), not
// produced by the same logic as the RTL. Pin order:
//   phase 1: {BA3 BA2 BA1 BA0 A12 A11 A10 A9 A8}
//   phase 2: {A3  A4  A5  A2  A13 A6  A0  A1 A7}
// "Don't care" pins are driven high by the encoder.

`timescale 1ns/1ps
`include "gddr5_cmds.vh"

module tb_gddr5_cmd_enc;

    reg         clk;
    reg         rst_n;
    reg         cmd_valid;
    reg  [4:0]  cmd;
    reg  [3:0]  bank;
    reg  [13:0] addr;
    reg         abi_enable;
    reg         cke_n_in;

    wire        cke_n, cs_n, ras_n, cas_n, we_n;
    wire [8:0]  addr_ph1, addr_ph2;
    wire        abi_n_ph1, abi_n_ph2, cmd_err;

    integer errors;
    integer checks;

    gddr5_cmd_enc #(.HAS_A12A13(1), .ABI_MAX_LOW(5)) dut (
        .clk(clk), .rst_n(rst_n),
        .cmd_valid(cmd_valid), .cmd(cmd), .bank(bank), .addr(addr),
        .abi_enable(abi_enable), .cke_n_in(cke_n_in),
        .cke_n(cke_n), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
        .addr_ph1(addr_ph1), .addr_ph2(addr_ph2),
        .abi_n_ph1(abi_n_ph1), .abi_n_ph2(abi_n_ph2), .cmd_err(cmd_err)
    );

    initial clk = 1'b0;
    always #1 clk = ~clk;

    // Drive one command for one cycle and compare the registered outputs.
    task run;
        input [8*10-1:0] name;
        input            v;
        input [4:0]      c;
        input [3:0]      b;
        input [13:0]     a;
        input            abi;
        input            e_cs, e_ras, e_cas, e_we;
        input [8:0]      e_ph1, e_ph2;
        input            e_abi1, e_abi2;
        input            e_err;
        begin
            @(negedge clk);
            cmd_valid = v; cmd = c; bank = b; addr = a; abi_enable = abi;
            @(posedge clk);
            #0.2;
            checks = checks + 1;
            if ({cs_n, ras_n, cas_n, we_n} !== {e_cs, e_ras, e_cas, e_we} ||
                addr_ph1 !== e_ph1 || addr_ph2 !== e_ph2 ||
                abi_n_ph1 !== e_abi1 || abi_n_ph2 !== e_abi2 ||
                cmd_err !== e_err) begin
                errors = errors + 1;
                $display("FAIL %0s: pins=%b%b%b%b ph1=%b ph2=%b abi=%b%b err=%b",
                         name, cs_n, ras_n, cas_n, we_n, addr_ph1, addr_ph2,
                         abi_n_ph1, abi_n_ph2, cmd_err);
                $display("     expected  pins=%b%b%b%b ph1=%b ph2=%b abi=%b%b err=%b",
                         e_cs, e_ras, e_cas, e_we, e_ph1, e_ph2, e_abi1, e_abi2, e_err);
            end
        end
    endtask

    initial begin
        errors = 0; checks = 0;
        rst_n = 1'b0; cmd_valid = 1'b0; cmd = 5'd0; bank = 4'd0; addr = 14'd0;
        abi_enable = 1'b0; cke_n_in = 1'b0;
        repeat (3) @(negedge clk);

        // Reset state: DESELECT, all pins high, CKE_n high.
        @(posedge clk); #0.2;
        checks = checks + 1;
        if ({cke_n, cs_n, ras_n, cas_n, we_n} !== 5'b11111 ||
            addr_ph1 !== 9'h1FF || addr_ph2 !== 9'h1FF) begin
            errors = errors + 1; $display("FAIL reset state");
        end
        @(negedge clk); rst_n = 1'b1;

        //   name       v  cmd                 bank   addr          abi  cs ras cas we  ph1          ph2          abi1 abi2 err
        run("DES",      1, `GDDR5_CMD_DES,     4'h0, 14'h0000,     1'b0, 1, 1, 1, 1, 9'b111111111, 9'b111111111, 1, 1, 0);
        run("NOP",      1, `GDDR5_CMD_NOP,     4'h0, 14'h0000,     1'b0, 0, 1, 1, 1, 9'b111111111, 9'b111111111, 1, 1, 0);
        run("idle",     0, `GDDR5_CMD_ACT,     4'hA, 14'h2A5B,     1'b0, 1, 1, 1, 1, 9'b111111111, 9'b111111111, 1, 1, 0);

        // ACTIVE bank 1010, row 0x2A5B
        run("ACT",      1, `GDDR5_CMD_ACT,     4'hA, 14'h2A5B,     1'b0, 0, 0, 1, 1, 9'b101001010, 9'b110011110, 1, 1, 0);
        // same with ABI enabled: 5 and 3 pins low, no inversion needed
        run("ACT abi",  1, `GDDR5_CMD_ACT,     4'hA, 14'h2A5B,     1'b1, 0, 0, 1, 1, 9'b101001010, 9'b110011110, 1, 1, 0);

        // ABI cases (limit 5 low pins per phase)
        run("ACT 0/0",  1, `GDDR5_CMD_ACT,     4'h0, 14'h0000,     1'b0, 0, 0, 1, 1, 9'b000000000, 9'b000000000, 1, 1, 0);
        run("ACT 0/0 i",1, `GDDR5_CMD_ACT,     4'h0, 14'h0000,     1'b1, 0, 0, 1, 1, 9'b111111111, 9'b111111111, 0, 0, 0);
        // phase 1 has exactly 5 low pins (not inverted), phase 2 has 9 (inverted)
        run("ACT F/0 i",1, `GDDR5_CMD_ACT,     4'hF, 14'h0000,     1'b1, 0, 0, 1, 1, 9'b111100000, 9'b111111111, 1, 0, 0);
        // phase 1 has 6 low pins (inverted)
        run("ACT E/0 i",1, `GDDR5_CMD_ACT,     4'hE, 14'h0000,     1'b1, 0, 0, 1, 1, 9'b000111111, 9'b111111111, 0, 0, 0);

        // PRECHARGE bank 0110 / PRECHARGE ALL
        run("PRE",      1, `GDDR5_CMD_PRE,     4'h6, 14'h0000,     1'b0, 0, 0, 1, 0, 9'b011011110, 9'b111111111, 1, 1, 0);
        run("PREALL",   1, `GDDR5_CMD_PREALL,  4'h6, 14'h0000,     1'b0, 0, 0, 1, 0, 9'b111111111, 9'b111111111, 1, 1, 0);

        // READ bank 0011, column 0x35
        run("RD",       1, `GDDR5_CMD_RD,      4'h3, 14'h0035,     1'b0, 0, 1, 0, 1, 9'b001110010, 9'b011110100, 1, 1, 0);
        run("RDA",      1, `GDDR5_CMD_RDA,     4'h3, 14'h0035,     1'b0, 0, 1, 0, 1, 9'b001110011, 9'b011110100, 1, 1, 0);

        // WRITE variants: A11/A10 select the mask type, A8 = auto-precharge
        run("WOM",      1, `GDDR5_CMD_WOM,     4'h3, 14'h0035,     1'b0, 0, 1, 0, 0, 9'b001110010, 9'b011110100, 1, 1, 0);
        run("WOMA",     1, `GDDR5_CMD_WOMA,    4'h3, 14'h0035,     1'b0, 0, 1, 0, 0, 9'b001110011, 9'b011110100, 1, 1, 0);
        run("WSM",      1, `GDDR5_CMD_WSM,     4'h3, 14'h0035,     1'b0, 0, 1, 0, 0, 9'b001110110, 9'b011110100, 1, 1, 0);
        run("WSMA",     1, `GDDR5_CMD_WSMA,    4'h3, 14'h0035,     1'b0, 0, 1, 0, 0, 9'b001110111, 9'b011110100, 1, 1, 0);
        run("WDM",      1, `GDDR5_CMD_WDM,     4'h3, 14'h0035,     1'b0, 0, 1, 0, 0, 9'b001111010, 9'b011110100, 1, 1, 0);
        run("WDMA",     1, `GDDR5_CMD_WDMA,    4'h3, 14'h0035,     1'b0, 0, 1, 0, 0, 9'b001111011, 9'b011110100, 1, 1, 0);

        // Training commands: A11=A10=H, A8=L
        run("RDTR",     1, `GDDR5_CMD_RDTR,    4'h3, 14'h0035,     1'b0, 0, 1, 0, 1, 9'b111111110, 9'b111111111, 1, 1, 0);
        run("WRTR",     1, `GDDR5_CMD_WRTR,    4'h3, 14'h0035,     1'b0, 0, 1, 0, 0, 9'b111111110, 9'b111111111, 1, 1, 0);

        // REFRESH family: A8 high = all banks, A8 low = per bank
        run("REF",      1, `GDDR5_CMD_REF,     4'h5, 14'h0000,     1'b0, 0, 0, 0, 1, 9'b111111111, 9'b111111111, 1, 1, 0);
        run("REFPB",    1, `GDDR5_CMD_REFPB,   4'h5, 14'h0000,     1'b0, 0, 0, 0, 1, 9'b010111110, 9'b111111111, 1, 1, 0);
        run("SRE",      1, `GDDR5_CMD_SRE,     4'h5, 14'h0000,     1'b0, 0, 0, 0, 1, 9'b111111111, 9'b111111111, 1, 1, 0);

        // MODE REGISTER SET: MR3, opcode 0xABC (A12/A13 driven low)
        run("MRS",      1, `GDDR5_CMD_MRS,     4'h3, 14'h0ABC,     1'b0, 0, 0, 0, 0, 9'b001101010, 9'b111100001, 1, 1, 0);

        // MRS must ignore addr[13:12] (A12/A13 are not used for mode registers)
        run("MRS hi",   1, `GDDR5_CMD_MRS,     4'h3, 14'h3ABC,     1'b0, 0, 0, 0, 0, 9'b001101010, 9'b111100001, 1, 1, 0);

        // Unsupported / undefined codes: DESELECT pins and cmd_err
        run("LDFF",     1, 5'd19,              4'h0, 14'h0000,     1'b0, 1, 1, 1, 1, 9'b111111111, 9'b111111111, 1, 1, 1);
        run("undef",    1, 5'd31,              4'h0, 14'h0000,     1'b0, 1, 1, 1, 1, 9'b111111111, 9'b111111111, 1, 1, 1);

        // CKE_n pass-through (registered, aligned with the command)
        @(negedge clk); cke_n_in = 1'b1; cmd_valid = 1'b1; cmd = `GDDR5_CMD_SRE;
        @(posedge clk); #0.2;
        checks = checks + 1;
        if (cke_n !== 1'b1) begin errors = errors + 1; $display("FAIL cke_n pass-through"); end

        // Reset in the middle of operation returns to DESELECT
        @(negedge clk); rst_n = 1'b0; cmd_valid = 1'b1; cmd = `GDDR5_CMD_ACT;
        @(posedge clk); #0.2;
        checks = checks + 1;
        if ({cs_n, ras_n, cas_n, we_n} !== 4'b1111 || cke_n !== 1'b1) begin
            errors = errors + 1; $display("FAIL reset during operation");
        end

        $display("tb_gddr5_cmd_enc: %0d checks, %0d errors", checks, errors);
        if (errors == 0) $display("PASS");
        else             $display("FAIL");
        $finish;
    end

endmodule
