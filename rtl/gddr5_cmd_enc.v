// gddr5_cmd_enc.v - GDDR5 command and address encoder (Verilog-2005)
//
// Spec basis (JEDEC JESD212C.01):
//   - Table 17 (section 7.1): command truth table (pin values per command)
//   - Table 6  (section 4.1): DDR address phases (which pins carry which
//                             logical address bit on rising CK_t / CK_c)
//   - Section 4.2:            Address Bus Inversion (ABI)
//
// Operation:
//   One command per clock. Outputs are registered (1-cycle latency). When
//   cmd_valid is low, DESELECT is driven. Command pins CS_n/RAS_n/CAS_n/WE_n
//   and the first address phase (sampled by the device on rising CK_t) are
//   presented together; the second address phase is sampled on the next
//   rising CK_c. The PHY places phase 2 half a CK cycle after phase 1.
//
// Address pin order (9 physical pins, Table 6), MSB to LSB:
//   phase 1 (CK_t): BA3 BA2 BA1 BA0 A12 A11 A10 A9 A8
//   phase 2 (CK_c): A3  A4  A5  A2  A13 A6  A0  A1 A7
//
// Pins marked "V" (any valid level) in Table 17 are driven high, which
// minimizes the number of low address pins (see ABI).
//
// Not yet supported: LDFF (load FIFO). Its data-bit placement is an open item;
// it and any undefined code produce DESELECT pins and assert cmd_err.
//
// CKE_n is passed through (registered) so that the power manager can align
// it with the command pins (e.g. SELF REFRESH ENTRY needs CKE_n high).

`timescale 1ns/1ps
`include "gddr5_cmds.vh"

module gddr5_cmd_enc #(
    // 1: the shared A12/A13 pin exists (2 Gb and larger). 0: 512 Mb / 1 Gb.
    parameter HAS_A12A13  = 1,
    // Maximum number of address pins driven low per phase when ABI is on
    // (4 for 512 Mb and 1 Gb, 5 for 2 Gb and larger; section 4.2).
    parameter ABI_MAX_LOW = 5
) (
    input  wire        clk,
    input  wire        rst_n,        // synchronous, active low

    input  wire        cmd_valid,
    input  wire [4:0]  cmd,          // GDDR5_CMD_* code
    input  wire [3:0]  bank,         // bank (or mode-register address for MRS)
    input  wire [13:0] addr,         // row (ACT), opcode (MRS, bits 11:0),
                                     // column in bits 7:0 (RD/WR variants)
    input  wire        abi_enable,   // 1: Address Bus Inversion in use
    input  wire        cke_n_in,

    output reg         cke_n,
    output reg         cs_n,
    output reg         ras_n,
    output reg         cas_n,
    output reg         we_n,
    output reg  [8:0]  addr_ph1,     // pins on rising CK_t
    output reg  [8:0]  addr_ph2,     // pins on rising CK_c
    output reg         abi_n_ph1,
    output reg         abi_n_ph2,
    output reg         cmd_err       // unsupported or undefined command code
);

    // ------------------------------------------------------------------
    // Decode: pin values and logical address per Table 17
    // ------------------------------------------------------------------
    reg         c_cs_n, c_ras_n, c_cas_n, c_we_n;
    reg  [3:0]  ba_l;        // logical BA3..BA0
    reg  [13:0] a_l;         // logical A13..A0
    reg         err_c;

    always @(*) begin
        // Defaults: DESELECT, all "don't care" pins high.
        c_cs_n  = 1'b1;
        c_ras_n = 1'b1;
        c_cas_n = 1'b1;
        c_we_n  = 1'b1;
        ba_l    = 4'hF;
        a_l     = 14'h3FFF;
        err_c   = 1'b0;

        if (cmd_valid) begin
            case (cmd)
                `GDDR5_CMD_DES: begin
                    // defaults
                end
                `GDDR5_CMD_NOP: begin
                    c_cs_n = 1'b0;
                end
                `GDDR5_CMD_MRS: begin
                    c_cs_n = 1'b0; c_ras_n = 1'b0; c_cas_n = 1'b0; c_we_n = 1'b0;
                    ba_l = bank;
                    a_l  = {2'b00, addr[11:0]};      // A12/A13 not used for MRS
                end
                `GDDR5_CMD_ACT: begin
                    c_cs_n = 1'b0; c_ras_n = 1'b0; c_cas_n = 1'b1; c_we_n = 1'b1;
                    ba_l = bank;
                    a_l  = addr;                      // row address A13..A0
                end
                // READ: RAS_n=H CAS_n=L WE_n=H; A11=L A10=L; A8 = auto-precharge
                `GDDR5_CMD_RD: begin
                    c_cs_n = 1'b0; c_ras_n = 1'b1; c_cas_n = 1'b0; c_we_n = 1'b1;
                    ba_l = bank;
                    a_l  = {2'b11, 1'b0, 1'b0, 1'b1, 1'b0, addr[7:0]};
                end
                `GDDR5_CMD_RDA: begin
                    c_cs_n = 1'b0; c_ras_n = 1'b1; c_cas_n = 1'b0; c_we_n = 1'b1;
                    ba_l = bank;
                    a_l  = {2'b11, 1'b0, 1'b0, 1'b1, 1'b1, addr[7:0]};
                end
                // WRITE: RAS_n=H CAS_n=L WE_n=L; mask select on A11/A10
                `GDDR5_CMD_WOM: begin     // A11=L A10=L
                    c_cs_n = 1'b0; c_ras_n = 1'b1; c_cas_n = 1'b0; c_we_n = 1'b0;
                    ba_l = bank;
                    a_l  = {2'b11, 1'b0, 1'b0, 1'b1, 1'b0, addr[7:0]};
                end
                `GDDR5_CMD_WOMA: begin
                    c_cs_n = 1'b0; c_ras_n = 1'b1; c_cas_n = 1'b0; c_we_n = 1'b0;
                    ba_l = bank;
                    a_l  = {2'b11, 1'b0, 1'b0, 1'b1, 1'b1, addr[7:0]};
                end
                `GDDR5_CMD_WSM: begin     // A11=L A10=H
                    c_cs_n = 1'b0; c_ras_n = 1'b1; c_cas_n = 1'b0; c_we_n = 1'b0;
                    ba_l = bank;
                    a_l  = {2'b11, 1'b0, 1'b1, 1'b1, 1'b0, addr[7:0]};
                end
                `GDDR5_CMD_WSMA: begin
                    c_cs_n = 1'b0; c_ras_n = 1'b1; c_cas_n = 1'b0; c_we_n = 1'b0;
                    ba_l = bank;
                    a_l  = {2'b11, 1'b0, 1'b1, 1'b1, 1'b1, addr[7:0]};
                end
                `GDDR5_CMD_WDM: begin     // A11=H A10=L
                    c_cs_n = 1'b0; c_ras_n = 1'b1; c_cas_n = 1'b0; c_we_n = 1'b0;
                    ba_l = bank;
                    a_l  = {2'b11, 1'b1, 1'b0, 1'b1, 1'b0, addr[7:0]};
                end
                `GDDR5_CMD_WDMA: begin
                    c_cs_n = 1'b0; c_ras_n = 1'b1; c_cas_n = 1'b0; c_we_n = 1'b0;
                    ba_l = bank;
                    a_l  = {2'b11, 1'b1, 1'b0, 1'b1, 1'b1, addr[7:0]};
                end
                // Training: READ/WRITE command pins with A11=H A10=H A8=L
                `GDDR5_CMD_RDTR: begin
                    c_cs_n = 1'b0; c_ras_n = 1'b1; c_cas_n = 1'b0; c_we_n = 1'b1;
                    a_l  = 14'h3EFF;                  // A8 low, others high
                end
                `GDDR5_CMD_WRTR: begin
                    c_cs_n = 1'b0; c_ras_n = 1'b1; c_cas_n = 1'b0; c_we_n = 1'b0;
                    a_l  = 14'h3EFF;
                end
                // PRECHARGE: RAS_n=L CAS_n=H WE_n=L; A8 selects one bank / all
                `GDDR5_CMD_PRE: begin
                    c_cs_n = 1'b0; c_ras_n = 1'b0; c_cas_n = 1'b1; c_we_n = 1'b0;
                    ba_l = bank;
                    a_l  = 14'h3EFF;                  // A8 low
                end
                `GDDR5_CMD_PREALL: begin
                    c_cs_n = 1'b0; c_ras_n = 1'b0; c_cas_n = 1'b1; c_we_n = 1'b0;
                    a_l  = 14'h3FFF;                  // A8 high, bank don't care
                end
                // REFRESH family: RAS_n=L CAS_n=L WE_n=H; A8 selects REF / REFPB
                `GDDR5_CMD_REFPB: begin
                    c_cs_n = 1'b0; c_ras_n = 1'b0; c_cas_n = 1'b0; c_we_n = 1'b1;
                    ba_l = bank;
                    a_l  = 14'h3EFF;                  // A8 low
                end
                `GDDR5_CMD_REF: begin
                    c_cs_n = 1'b0; c_ras_n = 1'b0; c_cas_n = 1'b0; c_we_n = 1'b1;
                    a_l  = 14'h3FFF;                  // A8 high
                end
                `GDDR5_CMD_SRE: begin
                    // Same command pins as REFRESH; the power manager drives
                    // CKE_n high in the same cycle.
                    c_cs_n = 1'b0; c_ras_n = 1'b0; c_cas_n = 1'b0; c_we_n = 1'b1;
                    a_l  = 14'h3FFF;
                end
                default: begin
                    err_c = 1'b1;                     // includes reserved LDFF
                end
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Pack logical bits onto the two address phases (Table 6)
    // ------------------------------------------------------------------
    wire [8:0] ph1_raw = {ba_l[3], ba_l[2], ba_l[1], ba_l[0],
                          a_l[12], a_l[11], a_l[10], a_l[9], a_l[8]};
    wire [8:0] ph2_raw = {a_l[3], a_l[4], a_l[5], a_l[2],
                          a_l[13], a_l[6], a_l[0], a_l[1], a_l[7]};

    // ------------------------------------------------------------------
    // Address Bus Inversion (section 4.2): if more than ABI_MAX_LOW pins
    // would be low, invert the phase and drive ABI_n low.
    // Bit 4 is the shared A12/A13 pin, absent on 512 Mb and 1 Gb devices.
    // ------------------------------------------------------------------
    localparam [8:0] PIN_MASK = (HAS_A12A13 != 0) ? 9'b1_1111_1111
                                                  : 9'b1_1110_1111;

    function [3:0] count_low;
        input [8:0] v;
        input [8:0] m;
        integer i;
        begin
            count_low = 4'd0;
            for (i = 0; i < 9; i = i + 1)
                if (m[i] && !v[i])
                    count_low = count_low + 4'd1;
        end
    endfunction

    wire inv1 = abi_enable && (count_low(ph1_raw, PIN_MASK) > ABI_MAX_LOW);
    wire inv2 = abi_enable && (count_low(ph2_raw, PIN_MASK) > ABI_MAX_LOW);

    // ------------------------------------------------------------------
    // Output registers
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            cke_n     <= 1'b1;
            cs_n      <= 1'b1;
            ras_n     <= 1'b1;
            cas_n     <= 1'b1;
            we_n      <= 1'b1;
            addr_ph1  <= 9'h1FF;
            addr_ph2  <= 9'h1FF;
            abi_n_ph1 <= 1'b1;
            abi_n_ph2 <= 1'b1;
            cmd_err   <= 1'b0;
        end else begin
            cke_n     <= cke_n_in;
            cs_n      <= c_cs_n;
            ras_n     <= c_ras_n;
            cas_n     <= c_cas_n;
            we_n      <= c_we_n;
            addr_ph1  <= inv1 ? ~ph1_raw : ph1_raw;
            addr_ph2  <= inv2 ? ~ph2_raw : ph2_raw;
            abi_n_ph1 <= ~inv1;
            abi_n_ph2 <= ~inv2;
            cmd_err   <= err_c;
        end
    end

endmodule
