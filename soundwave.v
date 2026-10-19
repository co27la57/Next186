`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
//
// This file is part of the Next186 Soc PC project
// http://opencores.org/project,next186
//
// Filename: sound_gen.v
// Description: Part of the Next186 SoC PC project, 
//		stereo 2x16bit pulse density modulated sound generator
// 	44100 samples/sec
//		Disney Sound Source and Covox Speech compatible
// Version 1.0
// Creation date: Jan2015
//
// Author: Nicolae Dumitrache 
// e-mail: ndumitrache@opencores.org
//
/////////////////////////////////////////////////////////////////////////////////
// 
// Copyright (C) 2015 Nicolae Dumitrache
// 
// This source file may be used and distributed without 
// restriction provided that this copyright statement is not 
// removed from the file and that any derivative work contains 
// the original copyright notice and the associated disclaimer.
// 
// This source file is free software; you can redistribute it 
// and/or modify it under the terms of the GNU Lesser General 
// Public License as published by the Free Software Foundation;
// either version 2.1 of the License, or (at your option) any 
// later version. 
// 
// This source is distributed in the hope that it will be 
// useful, but WITHOUT ANY WARRANTY; without even the implied 
// warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR 
// PURPOSE. See the GNU Lesser General Public License for more 
// details. 
// 
// You should have received a copy of the GNU Lesser General 
// Public License along with this source; if not, download it 
// from http://www.opencores.org/lgpl.shtml 
// 
//////////////////////////////////////////////////////////////////////////////////
// Additional Comments: 
//
//	byte write: both channels are the same (Covox emulation), the 8bit sample value is shifted by 8, the channel selector is reset to LEFT
// word write: LEFT first, the queue is updated only after RIGHT value is written
// sample rate: 44100Hz
//////////////////////////////////////////////////////////////////////////////////
`define SPKVOL	11

module soundwave(
		input CLK,
		input CLK44100x256,
		input reset,
		input CLK_I2S,
		input [15:0]data,
		input we,
		input word,
		input speaker,
		input [15:0]opl3left,
		input [15:0]opl3right,
		input [15:0]midi_left,
		input [15:0]midi_right,
		output stb44100,
		output full,	// when not full, write max 2x1152 16bit samples
		output dss_full,
		output reg AUDIO_L,
		output reg AUDIO_R,
		output wire I2S_MCLK,
		output wire I2S_SCLK,
		output wire I2S_LRCLK,
		output wire I2S_SDIN
	);

	 reg [31:0]wdata;
	 reg lr = 1'b0;
	 reg [2:0]write = 3'b000;
	 wire qempty;
	 wire [31:0]sample;
	 wire [31:0]sample1 = qempty ? 32'h00000000 : sample; // idle = true zero (silence), was 32'hc000c000 (-16384 DC -> PDM idle tone)
	 reg [31:0]lval = 0; 
	 reg [31:0]rval = 0;
	 reg [8:0]clkdiv = 0;
	 reg [15:0]r_opl3left = 0;
	 reg [15:0]r_opl3right = 0;
	 reg [15:0]r_midileft = 0;
	 reg [15:0]r_midiright = 0;
	 // ★ 2026-10-19 修：原设计 lmix/rmix 只有 **17 位**，但四路 16bit 有符号相加
	 //   最大可达 +-(32767*3 + 2048) = +-100349，17 位装不下 ⇒ **溢出回绕**，
	 //   而且回绕后的值看起来"在范围内"，下面的钳位不会生效 ⇒ 输出突跳到反相的爆音。
	 //   现在先用 19 位做完整求和，再做饱和，最后转偏移码。
	 //   （原注释写 "add 32878" 是笔误，实际是偏移码，即加 32768）
	 wire signed [18:0]lmix = {{3{sample1[15]}}, sample1[15:0]}
	                        + {{3{r_opl3left[15]}}, r_opl3left}
	                        + {{3{r_midileft[15]}}, r_midileft}
	                        + (speaker ? 19'sd2048 : 19'sd0);
	 wire signed [18:0]rmix = {{3{sample1[31]}}, sample1[31:16]}
	                        + {{3{r_opl3right[15]}}, r_opl3right}
	                        + {{3{r_midiright[15]}}, r_midiright}
	                        + (speaker ? 19'sd2048 : 19'sd0);
	 wire [15:0]lclamp = (lmix >  19'sd32767) ? 16'hFFFF :
	                     (lmix < -19'sd32768) ? 16'h0000 :
	                     {~lmix[15], lmix[14:0]};
	 wire [15:0]rclamp = (rmix >  19'sd32767) ? 16'hFFFF :
	                     (rmix < -19'sd32768) ? 16'h0000 :
	                     {~rmix[15], rmix[14:0]};
	 wire lsign = lval[31:16] < lclamp;
	 wire rsign = rval[31:16] < rclamp;
	 wire [11:0]wrusedw;
	 wire [11:0]rdusedw;
	 assign full = wrusedw >= 12'd2940;
	 assign dss_full = rdusedw > 12'd90;	// Disney sound source queue full
	 assign stb44100 = clkdiv[8];
	 
	 sndfifo sndfifo_inst 
	 (
	  .rst(reset),
	  .wrclk(CLK), // input wr_clk
	  .rdclk(CLK44100x256), // input rd_clk
	  .data(wdata), // input [31 : 0] din
	  .wrreq(|write), // input wr_en
	  .rdreq(clkdiv[8]), // input rd_en
	  .q(sample), // output [31 : 0] dout
	  .wrusedw(wrusedw),
	  .rdusedw(rdusedw),
	  .rdempty(qempty) // output empty
	);
	 

	 always @(posedge CLK44100x256) begin
		clkdiv[8:0] <= clkdiv[7:0] + 1'b1;
		if(clkdiv[8]) begin
	       r_opl3left <= opl3left;
          r_opl3right <= opl3right;
			 r_midileft <= midi_left;
          r_midiright <= midi_right;
		end
		
		lval <= lval - lval[31:7] + (lsign << 25);
		AUDIO_L <= lsign;

		rval <= rval - rval[31:7] + (rsign << 25);
		AUDIO_R <= rsign;
	 end


	always @(posedge CLK) begin
		if(we) 
			if(word) begin
				lr <= !lr;
				write <= {2'b00, lr};
				if(lr) wdata[31:16] <= data;
				else wdata[15:0] <= data;
			end else begin
				lr <= 1'b0;		// left
				write <= 3'b110;
				wdata <= {1'b1, data[7:0], 8'b00000001, data[7:0], 7'b0000000};
			end
		else write <= write - |write;
	end


  	audio_top audio_top  
	(
	  .clk_50MHz (CLK_I2S),
	  .dac_MCLK  (I2S_MCLK),
	  .dac_LRCK  (I2S_LRCLK),
	  .dac_SCLK  (I2S_SCLK),
	  .dac_SDIN  (I2S_SDIN),
	  .L_data    (lclamp),
	  .R_data    (rclamp)
	); 
endmodule
