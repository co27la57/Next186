// sim/tb/xpm_fifo_async_stub.v
// ---------------------------------------------------------------------------
// Behavioral model of xpm_fifo_async, for OFFLINE SIMULATION ONLY.
// Not for synthesis.
//
// Why this exists: module "opl3_in" (Next186_BlackBoxes.v) instantiates the
// Xilinx IP "xpm_fifo_async", which has no plain-Verilog source, so an
// equivalent behavioral model is required for offline simulation.
//
// Only the semantics used by opl3_in are implemented:
//   * asynchronous dual-clock FIFO (write on wr_clk, read on rd_clk)
//   * 16-bit write, 16-bit read, depth 256
//   * first-word fall-through: while non-empty, dout is a combinational
//     view of mem[rptr], matching how opl3.v consumes qdata directly.
//
// Implementation note: read and write sides each keep a monotonically
// increasing counter (wcnt/rcnt); the difference is the occupancy. This
// avoids two clock domains driving the same register.
// ---------------------------------------------------------------------------
module xpm_fifo_async #(
    parameter integer FIFO_MEMORY_TYPE = "auto",
    parameter integer READ_MODE         = 1,
    parameter integer FIFO_WRITE_DEPTH  = 256,
    parameter integer WRITE_DATA_WIDTH  = 16,
    parameter integer READ_DATA_WIDTH   = 16,
    parameter integer PROG_EMPTY_THRESH = 10,
    parameter integer PROG_FULL_THRESH  = 10
)(
    input  wire                          wr_clk,
    input  wire                          rd_clk,
    input  wire [WRITE_DATA_WIDTH-1:0]   din,
    input  wire                          wr_en,
    input  wire                          rd_en,
    output wire [READ_DATA_WIDTH-1:0]    dout,
    output wire                          full,
    output wire                          empty,
    output wire                          wr_rst_busy,
    output wire                          rd_rst_busy,
    output wire [1:0]                    prog_full,
    output wire [1:0]                    prog_empty,
    output wire [((WRITE_DATA_WIDTH > 1) ? (WRITE_DATA_WIDTH+7)/8 - 1 : 0):0] sbiterr,
    output wire [((WRITE_DATA_WIDTH > 1) ? (WRITE_DATA_WIDTH+7)/8 - 1 : 0):0] dbiterr,
    input  wire                          sleep,
    input  wire                          rst,
    input  wire                          injectsbiterr,
    input  wire                          injectdbiterr
);
    localparam integer DEPTH = FIFO_WRITE_DEPTH;

    reg [WRITE_DATA_WIDTH-1:0] mem [0:DEPTH-1];
    integer wptr, rptr;
    integer wcnt, rcnt;

    initial begin
        wptr = 0; rptr = 0; wcnt = 0; rcnt = 0;
    end

    wire [31:0] occ = wcnt - rcnt;

    // write side
    always @(posedge wr_clk or posedge rst) begin
        if (rst) begin
            wptr <= 0; wcnt <= 0;
        end else if (wr_en && occ < DEPTH) begin
            mem[wptr] <= din;
            wptr <= (wptr == DEPTH-1) ? 0 : wptr + 1;
            wcnt <= wcnt + 1;
        end
    end

    // read side
    always @(posedge rd_clk or posedge rst) begin
        if (rst) begin
            rptr <= 0; rcnt <= 0;
        end else if (rd_en && occ > 0) begin
            rptr <= (rptr == DEPTH-1) ? 0 : rptr + 1;
            rcnt <= rcnt + 1;
        end
    end

    assign full   = (occ >= DEPTH);
    assign empty  = (occ == 0);
    assign dout   = mem[rptr];

    // unused ports
    assign wr_rst_busy = 1'b0;
    assign rd_rst_busy = 1'b0;
    assign prog_full   = 2'b0;
    assign prog_empty  = 2'b0;
    assign sbiterr     = 1'b0;
    assign dbiterr     = 1'b0;
endmodule
