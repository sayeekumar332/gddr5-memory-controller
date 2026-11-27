`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// gddr5_req_fifo - synchronous request FIFO, first-word fall-through
//
// Sits between the request source and gddr5_ctrl_core. Both sides use
// valid/ready. The oldest entry is always on out_data while out_valid is high,
// so the output can feed the controller core directly.
//
//   in_ready  = level != DEPTH        (a push is accepted when valid and ready)
//   out_valid = level != 0            (a pop happens when valid and ready)
//
// A push and a pop in the same cycle are both taken, also when the FIFO is full
// (the pop frees the slot, but in_ready is low while full, so no push is
// accepted then: in_ready does not look at out_ready, which keeps the ready
// path free of a combinational loop through the consumer).
//
// DEPTH may be any value of 1 or more; it need not be a power of two.
// Verilog-2005.
// -----------------------------------------------------------------------------
module gddr5_req_fifo #(
    parameter WIDTH = 26,
    parameter DEPTH = 8
) (
    input  wire             clk,
    input  wire             rst_n,

    input  wire             in_valid,
    output wire             in_ready,
    input  wire [WIDTH-1:0] in_data,

    output wire             out_valid,
    input  wire             out_ready,
    output wire [WIDTH-1:0] out_data,

    output wire [15:0]      level        // entries held
);

    // Index width: enough bits for 0 .. DEPTH-1 (at least one).
    function integer idx_w;
        input integer n;
        integer i;
        begin
            idx_w = 1;
            for (i = 2; i < n; i = i * 2) idx_w = idx_w + 1;
        end
    endfunction

    localparam AW = idx_w(DEPTH);
    localparam [31:0] LAST = DEPTH - 1;

    reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [AW-1:0]    wr_ptr;
    reg [AW-1:0]    rd_ptr;
    reg [15:0]      count;

    wire push = in_valid  && in_ready;
    wire pop  = out_valid && out_ready;

    assign in_ready  = ({16'd0, count} != DEPTH);
    assign out_valid = (count != 16'd0);
    assign out_data  = mem[rd_ptr];
    assign level     = count;

    wire [AW-1:0] wr_next = ({{(32-AW){1'b0}}, wr_ptr} == LAST) ? {AW{1'b0}} : wr_ptr + 1'b1;
    wire [AW-1:0] rd_next = ({{(32-AW){1'b0}}, rd_ptr} == LAST) ? {AW{1'b0}} : rd_ptr + 1'b1;

    always @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr <= {AW{1'b0}};
            rd_ptr <= {AW{1'b0}};
            count  <= 16'd0;
        end else begin
            if (push) begin
                mem[wr_ptr] <= in_data;
                wr_ptr      <= wr_next;
            end
            if (pop) rd_ptr <= rd_next;
            if (push && !pop)      count <= count + 16'd1;
            else if (!push && pop) count <= count - 16'd1;
        end
    end

endmodule
