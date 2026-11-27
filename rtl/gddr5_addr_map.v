`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// gddr5_addr_map - flat access address to bank, row and column
//
// Combinational. One address unit is one column access (one burst), so the
// address has COL_W + BANK_W + ROW_W bits.
//
// MODE 0, row-major:      addr = { row, bank, col }
//     Consecutive addresses stay in one row of one bank. Good for streams that
//     want row hits; every access in a row hits the same bank.
//
// MODE 1, bank-interleaved: addr = { row, col[COL_W-1:2], b[3:0], col[1:0] }
//     with  group = b[1:0]  and  in_group = b[3:2]  and  bank = {group, in_group}
//     Four consecutive columns stay together, then the next four go to another
//     bank group (bank[3:2] is the group), so back-to-back column commands use
//     the short tCCDS spacing instead of tCCDL. Bank groups follow Table 8 of
//     JESD212C.01 (open item: confirm the 16-bank grouping against the PDF).
//
// XOR_BANK = 1 XORs the low bank bits with the low row bits, so that rows
// which would collide in one bank spread over several. It is a permutation of
// the bank for each fixed row, so the map stays one to one.
//
// COL_W must be at least 2, BANK_W must be 4. Verilog-2005.
// -----------------------------------------------------------------------------
module gddr5_addr_map #(
    parameter MODE     = 1,
    parameter XOR_BANK = 0,
    parameter ROW_W    = 14,
    parameter COL_W    = 7
) (
    input  wire [ROW_W+COL_W+3:0] addr,
    output wire [3:0]             bank,
    output wire [ROW_W-1:0]       row,
    output wire [COL_W-1:0]       col
);

    wire [3:0] raw_bank;

    generate
        if (MODE == 0) begin : g_row_major
            assign col      = addr[COL_W-1:0];
            assign raw_bank = addr[COL_W+3:COL_W];
        end else begin : g_interleaved
            wire [1:0] lo = addr[1:0];
            wire [3:0] b  = addr[5:2];
            // address bits [1:0] of the bank field pick the group
            assign raw_bank = {b[1:0], b[3:2]};
            assign col      = {addr[COL_W+3:6], lo};
        end
    endgenerate

    assign row  = addr[ROW_W+COL_W+3:COL_W+4];
    assign bank = (XOR_BANK != 0) ? (raw_bank ^ {2'b00, row[1:0]}) : raw_bank;

endmodule
