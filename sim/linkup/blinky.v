// sim/linkup/blinky.v - minimal design used only to prove the Verilator + Zig toolchain works.
`timescale 1ns / 1ps

module blinky (
    input  wire       clk,
    input  wire       rst,
    output reg  [7:0] cnt = 8'd0
);
    always @(posedge clk) begin
        if (rst) cnt <= 8'd0;
        else     cnt <= cnt + 8'd2;
    end
endmodule
