// =========================================================================
// vga_font_model.v  --  行为级字体 ROM, 原样复制自 Next186_BlackBoxes.v 的
//                       `sr_font`。纯 RTL 双口 RAM + $readmemh("font8x16.mem")。
//                       仿真时需把 font8x16.mem 放在运行目录 (make.py 会复制)。
// =========================================================================
`timescale 1 ns / 1 ps

module vga_font_model
  (
    input        clock_a,
    input        clock_b,
    input  [11:0] address_a,
    input  [11:0] address_b,
    input  [7:0]  data_a,
    input  [7:0]  data_b,
    input         wren_a,
    input         wren_b,
    output reg [7:0] q_a,
    output reg [7:0] q_b
  );

    (* ram_style = "block" *) reg [7:0] ram [4095:0];
    initial begin
        $readmemh("font8x16.mem", ram);
    end

    always @(posedge clock_a) begin
        if (wren_a) ram[address_a] <= data_a;
        q_a <= ram[address_a];
    end
    always @(posedge clock_b) begin
        if (wren_b) ram[address_b] <= data_b;
        q_b <= ram[address_b];
    end
endmodule
