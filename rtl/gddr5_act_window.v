`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// gddr5_act_window - rolling activate-window limiter
//
// Enforces "no more than SLOTS activates in any rolling window of WIN cycles"
// (tFAW with SLOTS=4, t32AW with SLOTS=32; JESD212C.01 section 7.x, Figures 45
// and 46). Each slot is a down-counter. An ACTIVE (push) loads the lowest free
// slot with WIN; the slot frees again WIN cycles later. When every slot is
// busy, `full` is high and a further ACTIVE is not allowed.
//
// A push in cycle t frees its slot in cycle t + WIN, so the (SLOTS+1)th
// ACTIVE may issue exactly WIN cycles after the first of the last SLOTS.
// -----------------------------------------------------------------------------
module gddr5_act_window #(
    parameter SLOTS = 4,
    parameter WIN   = 23,
    parameter CW    = 10      // counter width; WIN must be < 2**CW
) (
    input  wire clk,
    input  wire rst_n,
    input  wire push,         // an ACTIVE was issued this cycle
    output reg  full          // no free slot: an ACTIVE is not allowed
);

    function integer clog2;
        input integer v;
        integer n;
        begin
            clog2 = 1;
            for (n = 2; n < v; n = n * 2) clog2 = clog2 + 1;
        end
    endfunction

    localparam IW = clog2(SLOTS);   // slot index width (at least 1)

    reg [CW-1:0] slot [0:SLOTS-1];

    integer k;
    integer j;
    reg [IW-1:0] free_idx;    // lowest slot whose counter is 0
    reg        any_free;

    // Combinational view of the slots, valid in the current cycle.
    always @* begin
        any_free = 1'b0;
        free_idx = {IW{1'b0}};
        for (k = SLOTS - 1; k >= 0; k = k - 1)
            if (slot[k] == {CW{1'b0}}) begin
                any_free = 1'b1;
                free_idx = k[IW-1:0];
            end
        full = !any_free;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            for (j = 0; j < SLOTS; j = j + 1) slot[j] <= {CW{1'b0}};
        end else begin
            for (j = 0; j < SLOTS; j = j + 1)
                if (slot[j] != {CW{1'b0}}) slot[j] <= slot[j] - 1'b1;

            // The load overrides the decrement of the freed slot (reads 0 in t+WIN).
            if (push && any_free)
                slot[free_idx] <= WIN[CW-1:0] - 1'b1;
        end
    end

endmodule
