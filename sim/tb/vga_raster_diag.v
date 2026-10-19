`timescale 1ns / 1ps
// Offline display check. VGA_SG and sr_font are production modules; the
// display gating/cadence expressions below are copied from ddr_186.v.
// Deliberately no DDR/FIFO model: fifo_word is a constant character pattern.
module vga_raster_diag (
    input wire clk,
    input wire start,
    input wire text_mode,
    input wire mode13,
    input wire half_mode,
    input wire tall_mode,
    input wire [9:0] vde,
    input wire [3:0] hrzpan,
    input wire [31:0] fifo_word,
    output wire [9:0] hcount,
    output wire [9:0] vcount,
    output wire hblnk,
    output wire vblnk,
    output wire hsync,
    output wire vsync,
    output wire vrden,
    output wire sdon,
    output wire [3:0] char_ln,
    output wire [7:0] font_row
);
    VGA_SG raster (
        .clk(clk), .ce(start),
        .tc_hsblnk(10'd639), .tc_hssync(10'd672),
        .tc_hesync(10'd768), .tc_heblnk(10'd799),
        .tc_vsblnk(tall_mode ? 10'd479 : 10'd399),
        .tc_vssync(tall_mode ? 10'd489 : 10'd411),
        .tc_vesync(tall_mode ? 10'd491 : 10'd413),
        .tc_veblnk(tall_mode ? 10'd520 : 10'd446),
        .hcount(hcount), .vcount(vcount), .hblnk(hblnk),
        .vblnk(vblnk), .hsync(hsync), .vsync(vsync)
    );
    wire [9:0] hcount_pan = hcount + hrzpan - 17;
    wire displ_on = !(hblnk | vblnk | !start);
    reg [18:0] s_displ_on = 0;
    reg [3:0] exline = 0;
    wire vrdon = s_displ_on[~hrzpan];
    assign vrden = (vrdon || exline[3]) && ((text_mode | half_mode) ?
        &hcount_pan[3:0] : mode13 ? &hcount_pan[2:0] : &hcount_pan[1:0]);
    assign sdon = s_displ_on[17 + text_mode] & (vcount <= vde);
    assign char_ln = {(vcount[3] & !half_mode), vcount[2:0]};
    wire [15:0] fifo_dout = (text_mode ? hcount_pan[3] : mode13 ?
        hcount_pan[2] : hcount_pan[1]) ? fifo_word[31:16] : fifo_word[15:0];
    sr_font font (
        .clock_a(clk), .wren_a(1'b0), .address_a({fifo_dout[7:0], char_ln}),
        .data_a(8'd0), .q_a(font_row),
        .clock_b(clk), .wren_b(1'b0), .address_b(12'd0), .data_b(8'd0), .q_b()
    );
    always @(posedge clk) begin
        s_displ_on <= {s_displ_on[17:0], displ_on};
        exline <= vrdon ? 4'b1111 : (exline - vrden);
    end
endmodule
