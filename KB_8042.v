//////////////////////////////////////////////////////////////////////////////////
//
// This file is part of the Next186 Soc PC project
// http://opencores.org/project,next186
//
// Filename: KB_8042.v
// Description: Part of the Next186 SoC PC project, keyboard/mouse PS2 controller
//		Simplified 8042 implementation
// Version 1.0
// Creation date: Jan2013
//
// Author: Nicolae Dumitrache 
// e-mail: ndumitrache@opencores.org
//
/////////////////////////////////////////////////////////////////////////////////
// 
// Copyright (C) 2013 Nicolae Dumitrache
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
///////////////////////////////////////////////////////////////////////////////////
// Additional Comments: 
//
// http://www.computer-engineering.org/ps2keyboard/
// http://wiki.osdev.org/%228042%22_PS/2_Controller
// http://wiki.osdev.org/Mouse_Input
//
//	Primary connection
//		NET "PS2_CLK1" LOC = "W12" | IOSTANDARD = LVCMOS33 | DRIVE = 8 | SLEW = SLOW ;
//		NET "PS2_DATA1" LOC = "V11" | IOSTANDARD = LVCMOS33 | DRIVE = 8 | SLEW = SLOW ;
//	Secondary connection (requires Y-splitter cable)
//		NET "PS2_CLK2" LOC = "U11" | IOSTANDARD = LVCMOS33 | DRIVE = 8 | SLEW = SLOW ;
//		NET "PS2_DATA2" LOC = "Y12" | IOSTANDARD = LVCMOS33 | DRIVE = 8 | SLEW = SLOW ;
//////////////////////////////////////////////////////////////////////////////////
// 12Feb2018 - fix KB connection issue
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps

module KB_Mouse_8042(
    input CS,
	 input WR,
    input cmd,			// 0x60 = data, 0x64 = cmd
	 input [7:0]din,
	 output [7:0]dout, 
	 input clk,			// cpu CLK
	 output I_KB,		// interrupt keyboard
	 output I_MOUSE,  // interrupt mouse
	 output reg CPU_RST = 0,
	 inout PS2_CLK1,
	 inout PS2_CLK2,
	 inout PS2_DATA1,
	 inout PS2_DATA2,
	 // ---- 虚拟键盘(PS EMIO GPIO 送来的 scancode, clk 域) ----
	 input      vk_enable,      // 1 = 启用虚拟键盘(屏蔽物理PS/2并代答自检)
	 input      vk_valid,       // 1 拍: vk_data 为一个待注入字节
	 input [7:0]vk_data,
	 output     vk_ready        // 1 = 输出缓冲空, 可接收一个字节
    );
	 
//	status bit5 = MOBF (mouse to host buffer full - with OBF), bit4=INH, bit2(1-initialized ok), bit1(IBF-input buffer full - host to kb/mouse), bit0(OBF-output buffer full - kb/mouse to host)
	reg [3:0]cmdbyte = 4'b1100; // EN2,EN,INT2,INT

	// ================= 虚拟键盘(PS EMIO GPIO) =================
	// 代答 BIOS 的键盘自检, 让 POST 认为键盘存在。否则 BIOS 走 nokb 分支:
	//   KbdFlags3=0 且发 0xAD 关闭键盘接口。
	reg [7:0] vk_cmd = 8'h00;        // 最近收到的键盘命令
	reg       vk_cmd_seen = 1'b0;    // 有新命令待应答
	reg [2:0] vk_state = 3'd0;
	reg [7:0] vk_out = 8'h00;
	reg       vk_out_v = 1'b0;
	// 0xFF 复位 -> FA,AA ; 0xF2 读ID -> FA,AB,83 ; 其它 -> FA
	localparam VK_IDLE = 3'd0, VK_ACK = 3'd1, VK_BAT = 3'd2, VK_ID1 = 3'd3, VK_ID2 = 3'd4;

	/* ★ ILA 探针 */
	reg wcfg = 1'b0;	// write config byte
	reg next_mouse = 1'b0;
	reg ctl_outb = 1'b0;
	reg [9:0]wr_data;
	reg [7:0]clkdiv128 = 0;
	reg [7:0]cnt100us = 0; // single delay counter for both kb and mouse
	reg wr_mouse = 1'b0;
	reg wr_kb = 1'b0;
	reg rd_kb = 1'b0;
	reg rd_mouse = 1'b0;
	reg OBF = 1'b0;
	reg MOBF = 1'b0;
	reg [7:0]s_data;

	wire [7:0]kb_data;
	wire [7:0]mouse_data;
	wire kb_data_out_ready;
	wire kb_data_in_ready;
	wire mouse_data_out_ready;
	wire mouse_data_in_ready;
	wire IBF = ((wr_kb | ~kb_data_in_ready) & ~cmdbyte[2]) | ((wr_mouse  | ~mouse_data_in_ready) & ~cmdbyte[3]);
	wire kb_shift;
	wire mouse_shift;
	
	assign dout = cmd ? {2'b00, MOBF, 1'b1, wcfg, 1'b1, IBF, OBF | MOBF | ctl_outb} : ctl_outb ? {2'b00, cmdbyte[3:2], 2'b00, cmdbyte[1:0]} : s_data; //MOBF ? mouse_data : kb_data;
	assign I_KB = cmdbyte[0] & OBF; 			// INT & OBF
	assign I_MOUSE = cmdbyte[1] & MOBF; 	// INT2 & MOBF

	// 输出缓冲空: 可接受"虚拟键盘字节"(GPIO scancode 或 自检应答)
	// ★ 2026-10-10: 去掉原来的 ~ctl_outb。
	//   ctl_outb = "80186 发了 0x20 读配置命令但还没读端口 0x60"。它在启动时
	//   一旦卡住, vk_ready 就恒 0 ⇒ 配合 kbd_gpio_rx 的电平握手会把整条注入
	//   链路永久堵死(第 27 轮就是这么坏掉的)。而 OBF 空下来这件事是必然的
	//   (DOS/BIOS 一定会来读端口 0x60), 所以只用 ~OBF & ~MOBF 即可, 不会死锁。
	assign vk_ready = ~OBF & ~MOBF;

	/* ★★★ ILA 探针组 B: 8042 输出缓冲 —— 核心对比点 ★★★
	   关键判据:  dbg_vk_data(接收端发出)  vs  dbg_s_data(装入 8042 缓冲)
	              vs  dbg_dout(80186 实际从端口 0x60 读到)
	   三者一致(都应是 0x24) → 传输与 8042 均正确, 问题在 BIOS 翻译/CPU 侧
	   任一处不一致        → 直接定位到被改动的那一级 */

	// 自检应答序列发生器(与 vk_cmd_seen 置位同处一个 always 块, 避免多驱动)
	always @(posedge clk) begin
		vk_out_v <= 1'b0;
		case (vk_state)
			VK_IDLE: if (vk_enable && vk_cmd_seen) begin
						vk_out      <= 8'hFA;            // ACK
						vk_out_v    <= 1'b1;
						// ★ 不在这里清 vk_cmd_seen! 本块与主 always 块是**两个**块,
						//   同时驱动同一 reg 会触发 DRC MDRV-1(多驱动)。
						//   清标志统一放到主 always 块里(见下方 "ACK 已发出则清标志")。
						vk_state    <= (vk_cmd == 8'hFF) ? VK_BAT :
						               (vk_cmd == 8'hF2) ? VK_ID1 : VK_IDLE;
					 end
			VK_BAT:  begin vk_out <= 8'hAA; vk_out_v <= 1'b1; vk_state <= VK_IDLE; end
			VK_ID1:  begin vk_out <= 8'hAB; vk_out_v <= 1'b1; vk_state <= VK_ID2;  end
			VK_ID2:  begin vk_out <= 8'h83; vk_out_v <= 1'b1; vk_state <= VK_IDLE; end
			default: vk_state <= VK_IDLE;
		endcase
	end
	
	PS2Interface Keyboard
	(
		.PS2_CLK(PS2_CLK1),
		.PS2_DATA(PS2_DATA1),
		.clk(clk),
		.rd(rd_kb),
		.wr(wr_kb),
		.data_in(wr_data[0]),
		.data_out(kb_data),
		.data_out_ready(kb_data_out_ready),
		.data_in_ready(kb_data_in_ready),
		.delay100us(cnt100us[7]),
		.data_shift(kb_shift),
		.clk_sample(clkdiv128[7])
	);

	PS2Interface Mouse
	(
		.PS2_CLK(PS2_CLK2),
		.PS2_DATA(PS2_DATA2),
		.clk(clk),
		.rd(rd_mouse),
		.wr(wr_mouse),
		.data_in(wr_data[0]),
		.data_out(mouse_data),
		.data_out_ready(mouse_data_out_ready),
		.data_in_ready(mouse_data_in_ready),
		.delay100us(cnt100us[7]),
		.data_shift(mouse_shift),
		.clk_sample(clkdiv128[7])
	);
	
	always @(posedge clk) begin
		CPU_RST <= 0;
		if(~kb_data_in_ready) wr_kb <= 1'b0;
		if(~kb_data_out_ready) rd_kb <= 1'b0;
		if(~mouse_data_in_ready) wr_mouse <= 0;
		if(~mouse_data_out_ready) rd_mouse <= 1'b0;

		clkdiv128 <= clkdiv128[6:0] + 1'b1;
		if(CS & WR & ~cmd & ~wcfg) cnt100us <= 0; // reset 100us counter for PS2 writing
		else if(!cnt100us[7] & clkdiv128[7]) cnt100us <= cnt100us + 1'b1;
		
		
		if(~OBF & ~MOBF)
			// ★ 顺序很重要: 自检/命令应答(vk_out_v)必须**优先**。
			//   它是单拍脉冲、协议关键(BIOS 的 sendcmd 在等 0xFA);
			//   而 vk_valid 现在是电平, 会一直保持到被取走, 让路没关系。
			//   若把 vk_valid 排在前面, 一个待发扫描码就会把 ACK 挤掉,
			//   BIOS 会一直等 AckReceived ⇒ 键盘命令卡死。
			if(vk_enable & vk_out_v) begin
				OBF <= 1'b1;
				s_data <= vk_out;
			end else if(vk_enable & vk_valid) begin
				OBF <= 1'b1;
				s_data <= vk_data;
			end else if(kb_data_out_ready & ~rd_kb & ~cmdbyte[2] & ~vk_enable) begin
				OBF <= 1'b1;
				s_data <= kb_data;
			end else if(mouse_data_out_ready & ~rd_mouse & ~cmdbyte[3] & ~vk_enable) begin
				// ★ 2026-10-10 修复: 与上面键盘通路保持对称 —— 虚拟键盘启用时,
				//   鼠标通路也必须被门控。s_data 是键盘/鼠标**共用**的输出缓冲,
				//   之前只有键盘通路带 ~vk_enable, 鼠标通路没有; 于是 BIOS 只要发过
				//   0xA8(使能鼠标, 会把 cmdbyte[3] 清 0), 物理鼠标的应答字节就会被
				//   塞进同一个缓冲, 混进键盘字节流。若其中混入 0x2A/0x36/0x1D/0x38
				//   而 break 没跟上, BIOS 的 KbdFlags1 就会把 Shift/Ctrl 锁死
				//   (实测 BDA 0040:0017 = 0x8005, 即 RShfDown|CtrlDown), 之后所有
				//   按键都走 ctrl/shift 列 => 屏幕全是乱码、回车/退格失效。
	MOBF <= 1'b1;
				s_data <= mouse_data;
			end
		
		if(kb_shift | mouse_shift) wr_data <= {1'b1, wr_data[9:1]};
		
		if(CS) 
			if(WR)
				if(cmd)	// 0x64 write
					case(din)
						8'h20: ctl_outb <= 1'b1;	// read config byte
						8'h60: wcfg <= 1;			// write config byte
						8'ha7: cmdbyte[3] <= 1;	// disable mouse
						8'ha8: cmdbyte[3] <= 0;	// enable mouse
						8'had: cmdbyte[2] <= 1;	// disable kb
						8'hae: cmdbyte[2] <= 0;	// enable kb
						8'hd4: next_mouse <= 1;	//	write next byte to mouse
						/*8'hf0, 8'hf2, 8'hf4, 8'hf6, 8'hf8, 8'hfa, 8'hfc,*/ 8'hfe: CPU_RST <= 1; // CPU reset
					endcase 
				else begin	// 0x60 write
					if(wcfg) cmdbyte <= {din[5:4], din[1:0]};
					else begin
						next_mouse <= 0;
						wr_mouse <= next_mouse;
						if(vk_enable) begin
							// 虚拟键盘: 不发给物理 PS/2, 记录命令以便代答自检
							wr_kb <= 1'b0;
							if(!next_mouse) begin
								vk_cmd      <= din;
								vk_cmd_seen <= 1'b1;
							end
						end else begin
							wr_kb <= ~next_mouse;
							wr_data <= {~^din, din, 1'b0};
						end
					end
					wcfg <= 0;
				end
			else 	// read data
				if(~cmd) begin	
					ctl_outb <= 1'b0;
					if(!ctl_outb) begin
						OBF <= 1'b0;
						MOBF <= 1'b0;
						rd_kb <= OBF;
						rd_mouse <= MOBF;
					end
				end

		// ★ ACK 已发出则清自检命令标志(必须与置位同在主 always 块内, 否则多驱动)
		if (vk_out_v) vk_cmd_seen <= 1'b0;

	end
endmodule


module PS2Interface(
	 inout PS2_CLK,
	 inout PS2_DATA,
	 input clk,
	 input rd,				// enable PS2 data reading
	 input wr,				// can write data from controller to PS2
	 input data_in,		// data from controller
	 input delay100us,
	 output [7:0]data_out,	// data from PS2
	 output reg data_out_ready = 1,	// PS2 received data ready
	 output reg data_in_ready = 1,	// PS2 sent data ready
	 output data_shift,
	 input clk_sample
	);
	
	initial data_out_ready = 1;
	initial data_in_ready = 1;
	
	reg [1:0]s_clk = 2'b11;
	wire ps2_clk_fall = s_clk == 2'b10;
	reg [9:0]data = 0;
	reg rd_progress = 1'b0;
	reg s_ps2_clk = 1'b1;
	reg rclk = 1'b1;
	reg rdata = 1'b1;
	reg s_ps2_data = 1'b1;
	
	assign PS2_CLK = rclk ? 1'bz : 1'b0;
	assign PS2_DATA = rdata ? 1'bz : 1'b0;
	assign data_out = data[7:0];
	assign data_shift = ~data_in_ready && delay100us && ps2_clk_fall;

	always @(posedge clk) begin
		if(clk_sample) begin
			s_ps2_clk <= PS2_CLK; 	// debounce PS2 clock and data
			s_ps2_data <= PS2_DATA;
		end
		
		s_clk <= {s_clk[0], s_ps2_clk};
		if(data_out_ready) rd_progress <= 1'b0;

		if(~data_in_ready) begin	// send data to PS2
			if(data_shift) data_in_ready <= data_in ^ s_ps2_data;
		end else if(wr && ~rd_progress) data_in_ready <= 1'b0;	// initiate data sending to PS2
		else if(~data_out_ready) begin	// receive data from PS2
			if(ps2_clk_fall) begin
				rd_progress <= 1'b1;
				if(rd_progress) {data, data_out_ready} <= {s_ps2_data, data[9:1], ~data[0]}; // receive is ended by data[9]
				else data <= 10'b0111111111;
			end
		end else if(rd) data_out_ready <= 1'b0; // initiate data receiving from PS2

		rclk <= ((~data_out_ready & data_in_ready) | (~data_in_ready & delay100us));
		rdata <= (data_in_ready | data_in | ~delay100us);
	end
endmodule
