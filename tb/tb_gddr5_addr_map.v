`timescale 1ns/1ps
// Self-checking testbench for gddr5_addr_map. Small fields (ROW_W=3, COL_W=3,
// 10 address bits) so that every address can be tried and the map checked to
// be one to one.
module tb_gddr5_addr_map;

    localparam RW = 3;
    localparam CW = 3;
    localparam AW = RW + CW + 4;

    reg  [AW-1:0] addr;
    wire [3:0]    bank0, bank1, bank2;
    wire [RW-1:0] row0,  row1,  row2;
    wire [CW-1:0] col0,  col1,  col2;

    gddr5_addr_map #(.MODE(0), .XOR_BANK(0), .ROW_W(RW), .COL_W(CW)) m0 (
        .addr(addr), .bank(bank0), .row(row0), .col(col0));
    gddr5_addr_map #(.MODE(1), .XOR_BANK(0), .ROW_W(RW), .COL_W(CW)) m1 (
        .addr(addr), .bank(bank1), .row(row1), .col(col1));
    gddr5_addr_map #(.MODE(1), .XOR_BANK(1), .ROW_W(RW), .COL_W(CW)) m2 (
        .addr(addr), .bank(bank2), .row(row2), .col(col2));

    integer errors;
    integer checks;
    integer a;
    integer k;
    reg [(1<<AW)-1:0] seen0, seen1, seen2;
    reg [AW-1:0] key;

    task check;
        input [255:0] name;
        input integer got;
        input integer exp;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL %0s: got %0d expected %0d (addr %0d)", name, got, exp, addr);
            end
        end
    endtask

    initial begin
        errors = 0; checks = 0;
        seen0 = 0; seen1 = 0; seen2 = 0;

        for (a = 0; a < (1 << AW); a = a + 1) begin
            addr = a; #1;

            // mode 0: {row, bank, col}
            check("m0 col",  col0,  a % 8);
            check("m0 bank", bank0, (a / 8) % 16);
            check("m0 row",  row0,  a / 128);

            // mode 1: low 2 address bits are col[1:0], next 4 bits pick bank,
            // the bank group (bank[3:2]) comes from the lowest two of those bits
            check("m1 col",  col1,  ((a / 64) % 2) * 4 + (a % 4));    // col[2] is addr[6]
            check("m1 row",  row1,  a / 128);
            check("m1 group", bank1[3:2], (a / 4) % 4);
            check("m1 in-group", bank1[1:0], (a / 16) % 4);

            // XOR variant: group unchanged, in-group xor row[1:0]
            check("m2 group", bank2[3:2], (a / 4) % 4);
            check("m2 in-group", bank2[1:0], ((a / 16) % 4) ^ ((a / 128) % 4));
            check("m2 col", col2, col1);
            check("m2 row", row2, row1);

            // one to one
            key = {row0, bank0, col0}; seen0[key] = 1'b1;
            key = {row1, bank1, col1}; seen1[key] = 1'b1;
            key = {row2, bank2, col2}; seen2[key] = 1'b1;
        end

        // every address produced a different triple
        k = 0; for (a = 0; a < (1 << AW); a = a + 1) k = k + seen0[a];
        check("m0 one to one", k, 1 << AW);
        k = 0; for (a = 0; a < (1 << AW); a = a + 1) k = k + seen1[a];
        check("m1 one to one", k, 1 << AW);
        k = 0; for (a = 0; a < (1 << AW); a = a + 1) k = k + seen2[a];
        check("m2 one to one", k, 1 << AW);

        // Spot checks that a reader can verify by hand (mode 1, no XOR).
        // address 0..3: same bank, columns 0..3
        addr = 0; #1; check("a0 bank", bank1, 0); check("a0 col", col1, 0);
        addr = 3; #1; check("a3 bank", bank1, 0); check("a3 col", col1, 3);
        // address 4: next group, column 0
        addr = 4; #1; check("a4 group", bank1[3:2], 1); check("a4 col", col1, 0);
        // address 16: same group as 0, next bank in the group
        addr = 16; #1; check("a16 group", bank1[3:2], 0); check("a16 in-group", bank1[1:0], 1);

        $display("%0d checks, %0d errors", checks, errors);
        if (errors == 0) $display("PASS");
        else             $display("FAIL");
        $finish;
    end

endmodule
