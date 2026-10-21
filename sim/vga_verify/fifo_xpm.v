// Use the installed Vivado XPM implementation, with production parameters.
// Extra outputs are testbench observations only.
module vga_fifo_model #(parameter DEPTH=1024) (
    input wrclk, rdclk, input [15:0] data, input wrreq, rdreq,
    output [31:0] q, output [8:0] wrusedw, input rst,
    output wr_busy, rd_busy, full, empty,
    output [10:0] level
);
    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE("auto"),
        .READ_DATA_WIDTH(32), .WRITE_DATA_WIDTH(16),
        .FIFO_WRITE_DEPTH(DEPTH),
        .RD_DATA_COUNT_WIDTH(10), .WR_DATA_COUNT_WIDTH(11),
        .USE_ADV_FEATURES("0707")
    ) impl (
        .wr_clk(wrclk), .rd_clk(rdclk), .din(data),
        .wr_en(wrreq & ~wr_busy), .rd_en(rdreq & ~rd_busy),
        .dout(q), .wr_data_count(level),
        .wr_rst_busy(wr_busy), .rd_rst_busy(rd_busy),
        .full(full), .empty(empty),
        .sleep(1'b0), .rst(rst),
        .injectsbiterr(1'b0), .injectdbiterr(1'b0)
    );
    assign wrusedw = level >= 511 ? 511 : level[8:0];
endmodule
