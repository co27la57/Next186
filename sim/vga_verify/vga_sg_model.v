// =========================================================================
// vga_sg_model.v  --  VGA_SG 时序发生器
// 原样复制自 vga.v (Next186 原版), 纯 RTL, 不依赖任何原语。
// 仅把模块名改为 vga_sg 以便在本 harness 内独立例化。
// 这是 111904f 基线用到的同一份时序逻辑。
// =========================================================================
`timescale 1 ns / 1 ps

module vga_sg
  (
  input  wire	[9:0]	tc_hsblnk,
  input  wire	[9:0]	tc_hssync,
  input  wire	[9:0]	tc_hesync,
  input  wire	[9:0]	tc_heblnk,

  output reg	[9:0]	hcount = 0,
  output reg			hsync,
  output reg			hblnk = 0,

  input  wire	[9:0]	tc_vsblnk,
  input  wire	[9:0]	tc_vssync,
  input  wire	[9:0]	tc_vesync,
  input  wire	[9:0]	tc_veblnk,

  output reg	[9:0]	vcount = 0,
  output reg			vsync,
  output reg			vblnk = 0,

  input  wire			clk,
  input  wire			ce
  );

  //******************************************************************//
  // This logic describes a 10-bit horizontal position counter.       //
  //******************************************************************//
  always @(posedge clk)
		if(ce) begin
			if(hcount >= tc_heblnk) begin
				hcount <= 0;
				hblnk <= 0;
			end else begin
				hcount <= hcount + 1;
				hblnk <= (hcount >= tc_hsblnk);
			end
			hsync <= (hcount >= tc_hssync) && (hcount < tc_hesync);
		end

  //******************************************************************//
  // This logic describes a 10-bit vertical position counter.         //
  //******************************************************************//
	always @(posedge clk)
		if(ce && hcount == tc_heblnk) begin
			if (vcount >= tc_veblnk) begin
				vcount <= 0;
				vblnk <= 0;
			end else begin
				vcount <= vcount + 1;
				vblnk <= (vcount >= tc_vsblnk);
			end
			vsync <= (vcount >= tc_vssync) && (vcount < tc_vesync);
		end

endmodule
