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

// ============================================================================
// KB_8042.v.mouse — KB_8042.v 的副本, 新增**虚拟鼠标**(PS EMIO GPIO 注入)
// ----------------------------------------------------------------------------
// 为什么要改这一层(根因, 从 BIOS_Next186.asm 反推得到):
//   1) 原码在 vk_enable=1(虚拟键盘)时, 0x60 口写入分支仍然执行 `wr_mouse <= next_mouse`,
//      也就是 **BIOS 发 0xD4+鼠标命令时, 8042 仍然去驱动物理 PS/2 鼠标**。
//      物理鼠标没接 => PS2Interface 把 clk 拉低后等不到设备时钟 => data_in_ready 永久为 0
//      => IBF(状态口 bit1) 永久为 1 => BIOS 的 sendps2byte 等到超时 => 走 nomouse 分支
//      => 屏幕上看不到 "PS2 Mouse detected", 鼠标通路彻底死掉。
//   2) 而且虚拟通路**根本不产生任何应答**(没有 0xFA/0xAA/0x00), 就算 IBF 通了也检测不到。
//   本副本同时修掉这两点: 虚拟模式下不碰物理 PS/2, 并且**代答鼠标命令**。
//
// 鼠标初始化序列(从 BIOS_Next186.asm 第 352~376 行逐条读出来的, 不是猜的):
//     out 64h, 0A8h        ; 使能鼠标口
//     mousei0: getps2byte  ; 排空残留字节
//     mov ah, 0FFh; CF=1   ; 复位鼠标 -> sendps2byte 写 0D4h 到 64h, 再写 FFh 到 60h
//     sendcmd              ; 等 0FAh  ACK
//     getps2byte -> AAh    ; BAT
//     getps2byte -> 00h    ; 鼠标 ID(0 = 标准 3 字节包鼠标)
//     => 三项都对才置 EquipmentWord bit2, 打印 "PS2 Mouse detected"
//   之后 DOS 驱动通过 INT15h/C2h(或直驱 8042) 发 0F4h 打开数据上报,
//   鼠标包经 MOBF -> I_MOUSE -> IRQ12(INT 74h)进 BIOS 的 int74 拼包。
//
// 新增端口: vm_enable / vm_valid / vm_data / vm_ready(与 vk_* 完全对称)。
//   键盘与鼠标**共用** s_data 缓冲, 用 MOBF 区分来源(状态口 bit5),
//   读 0x60 时两者一起清 —— 与原码对物理鼠标的处理一致。
// ============================================================================
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
	 output     vk_ready,       // 1 = 输出缓冲空, 可接收一个字节
	 // ---- 虚拟鼠标(同一组 EMIO GPIO, 由接收端按通道分流后送来) ----
	 input      vm_enable,      // 1 = 启用虚拟鼠标(屏蔽物理PS/2鼠标并代答命令)
	 input      vm_valid,       // 电平: vm_data 为一个待注入的鼠标字节
	 input [7:0]vm_data,
	 output     vm_ready        // 1 = 输出缓冲空, 可接收一个鼠标字节
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

	// ================= 虚拟鼠标(PS EMIO GPIO, 与键盘共用 8 位+选通) =================
	// 与 vk_* 完全对称: 收到命令 -> 置 vm_cmd_seen -> 应答序列发生器逐拍吐出字节。
	reg [7:0] vm_cmd = 8'h00;        // 最近收到的鼠标命令(BIOS 经 0xD4 送来的那一个字节)
	reg       vm_cmd_seen = 1'b0;
	reg [3:0] vm_state = 4'd0;
	reg [7:0] vm_out = 8'h00;
	reg       vm_out_v = 1'b0;
	// 0xFF 复位 -> FA,AA,00 ; 0xF2 读ID -> FA,00 ; 0xE9 状态 -> FA,20,02,64
	// 0xEB 读数据 -> FA,08,00,00 ; 其它 -> FA
	localparam VM_IDLE = 4'd0, VM_BAT = 4'd1, VM_BATID = 4'd2, VM_ID = 4'd3,
	           VM_ST1 = 4'd4, VM_ST2 = 4'd5, VM_ST3 = 4'd6,
	           VM_PKT0 = 4'd7, VM_PKT1 = 4'd8, VM_PKT2 = 4'd9;
	// ★ 数据上报使能: 真实鼠标只有在收到 0xF4 之后才主动发包。
	//   POST 期间 BIOS 要严格按 FA->AA->00 的顺序取字节, 此时若灌进移动包,
	//   BAT/ID 就会被"顶掉" => 检测不到鼠标。所以注入必须等 0xF4 之后才放行。
	//   (想在上板第一时间做连通性冒烟测试, 可把初值改成 1'b1。)
	reg vm_reporting = 1'b0;
	// ★ 鼠标应答字节"已被装进输出缓冲"的脉冲(由主 always 块驱动, 应答器只读)。
	//   存在的理由: 若应答器自己按固定节拍吐 FA->AA->00, 那么 FA 装进缓冲后
	//   OBF/MOBF 立刻为 1, 下一拍的 AA 就因为 `if(~OBF & ~MOBF)` 不成立而**被丢掉**
	//   (实测键盘自检就是这么丢的: 单拍脉冲 vs 缓冲握手, 天然竞态)。
	//   键盘能凑合是因为 IRQ1 + int09 对序列不敏感; **鼠标初始化严格要求
	//   FA -> AA -> 00 三次都收到**, 少一个就走 nomouse。所以这里改成
	//   "电平 + 取走确认": vm_out_v 一直挂着, 收到 m_taken 才吐下一个字节。
	reg m_taken = 1'b0;
	// ★ 应答器"已开始应答某条命令"的脉冲(由应答器驱动, 主块只用来清 vm_cmd_seen)。
	//   用它的原因: 若直接 `if(vm_out_v) vm_cmd_seen <= 0`, 那么"上一条应答还没发完
	//   就来了新命令"时, 新命令会在下一拍被无条件清掉 => 命令丢失。改成按 ack 清,
	//   新命令会一直挂到当前序列发完再被应答。
	reg vm_cmd_ack = 1'b0;

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
	// 鼠标通道用的是**同一个**输出缓冲(s_data + MOBF 标记), 所以"可接收"条件与键盘一致。
	// 注意: 这里只做流量控制; 是否真正接收还要看 vm_reporting(见下方入队优先级)。
	assign vm_ready = ~OBF & ~MOBF;

	/* ★★★ ILA 探针组 B: 8042 输出缓冲 —— 三层字节对账(2026-10-10 恢复) ★★★
	   判据(干净重启后实测的错映射):
	       送 0x23 -> DOS 显示 'h'   (正确)
	       送 0x24 -> DOS 显示 '4'   (BIOS 表说该是 'j'; '4' 是 row51 = 扫描码 0x05)
	     而 `kbd_gpio_inject -V` 已证明 PS 侧写 sysfs 再读回 9 根线**逐位全对**,
	     所以字节是在 EMIO 之后被改写的。这三个探针就是定位它在哪一级被改的:

	     dbg_vk_data : kbd_gpio_rx 交给 8042 的字节 (接收端发出)
	     dbg_s_data  : 实际被装进 8042 输出缓冲的字节 (含鼠标通路/自检应答的混入)
	     dbg_dout    : 80186 真的从端口 0x60 读到的字节 (经 dout 三选一 mux 之后)

	     三者一致(都是 0x24) => 传输与 8042 都对, 问题在 CPU/BIOS 之后
	     任意两处不一致       => 立刻指出是被改动的那一级

	   附加: dbg_sel_dout 标出 dout 当前走的是哪一路
	         (0=s_data正常数据, 1=cmd状态口, 2=ctl_outb 命令字节)
	   —— 之前怀疑过 dout 的三选一 mux 会把数据口读走, 这个信号能一次性证实或排除。
	*/
	reg [7:0] dbg_vk_data = 8'h00;
	reg [7:0] dbg_s_data  = 8'h00;
	reg [7:0] dbg_dout    = 8'h00;
	reg [1:0] dbg_sel_dout = 2'd0;
	reg       dbg_vk_valid = 1'b0;
	reg       dbg_OBF      = 1'b0;
	// 该字节是由哪条通路装进缓冲的: 0=vk_valid(键盘注入) 1=vk_out_v(键盘自检应答)
	//                              2=kb_data(物理键盘)    3=mouse_data(物理鼠标)
	//                              4=vm_out_v(鼠标命令应答) 5=vm_valid(鼠标移动包)
	reg [2:0] dbg_src     = 3'd0;

	// ========================================================================
	// ★ 事件日志(2026-10-10): 16 条循环记录, 取代"靠触发条件碰运气"
	//
	//   问题: 一个字节从写入到被 80186 读走只有几微秒(几十拍), 在 2048 深度的
	//   ILA 窗口里只是一条极细的竖线, 反复调触发条件也常抓不到。实测两次抓取
	//   窗口里握手信号(dbg_OBF/dbg_vk_valid/dbg_emio_stb)全程为 0, 只看到数据
	//   通道残留着上一次的字节值 —— 那种波形没有任何判别力。
	//
	//   做法: 每往输出缓冲装一个字节, 就往 16 条循环日志里写一条
	//         { data[7:0], src[1:0], seq[5:0] }
	//   seq 每装一个字节递增, 所以日志里的 seq 能直接排出先后顺序,
	//   也能看出"一次注入到底进了几个字节"。
	//
	//   用法: ILA 触发条件随便设(甚至 Always capture), 抓下来后按 seq 排序读,
	//         就能看到最近 16 次入队的 {字节, 来源} —— 完全不需要对准时机。
	// ========================================================================
	localparam DBGLOG_N = 16;
	reg [15:0] dbglog_data [0:DBGLOG_N-1];
	reg [5:0]  dbglog_src  [0:DBGLOG_N-1];
	reg [5:0]  dbglog_seq  [0:DBGLOG_N-1];
	reg [3:0]  dbglog_wp   = 4'd0;
	reg [15:0] dbg_evt_cnt  = 16'd0;

	// ========================================================================
	// ★★ 第 113 次：进 BIOS 那一刻的字节身份锁存（本次调查的核心探针）
	//
	//  为什么需要它 —— 一条决定性的纯离线推论：
	//    BIOS KeyCode 表不是只到 row26。完整 dump（8KB 映像）显示 row 27 起还有
	//    功能键 / 数字键 / 符号键，其中：
	//        row 51 @0x1D12 首字节 = 0x34 = '4'   ← 屏幕上 j 显示的那个字符
	//        row 52 @0x1D1A 首字节 = 0x33 = '3'
	//    所以「j 显示成 '4'」对应的行号是 **51**，不是 20。
	//    但 ILA 实测 xlat 输出是 0x14(=20) 完全正确 ⇒ 20 行怎么算出 51 行的字符？
	//    ⇒ 只有一种可能：**进 BIOS 的扫描码不是 0x24**，而是某个映射到 row 51 的码。
	//    （对照 KeyIndex 表：0x05→0x34 即行 52；51 的来源需实测。）
	//
	//  这三个探针直接回答"BIOS 到底收到了什么字节"，一步分开两种可能：
	//    dbg_last_byte : 最后一次装进输出缓冲的字节（期望 0x24）
	//    dbg_last_src  : 它的来源通路（0=注入 1=自检应答 2=物理键盘 3=鼠标）
	//    dbg_take_pulse: 80186 从端口 0x60 取走缓冲那一拍的脉冲
	//    dbg_take_byte : 被取走的字节（dout）——与 dbg_last_byte 必须相等
	// ========================================================================
	reg [7:0]  dbg_last_byte  = 8'h00;
	reg [2:0]  dbg_last_src   = 3'd0;
	reg        dbg_take_pulse = 1'b0;
	reg [7:0]  dbg_take_byte  = 8'h00;
	// 字节指纹: 连续 3 次装缓冲若都拿到同一个"意外值"，就锁住它供 ILA 直接触发
	reg [7:0]  dbg_bad_byte   = 8'h00;
	reg [7:0]  dbg_bad_cnt    = 8'd0;

	// 日志写入点: 每次真正把字节装进输出缓冲时调用(宏而非 task, Verilog-2001
	// 不允许在 always 块里调用 task)。
	`define DBGLOG_PUSH(DATA_, SRC_)                                                \
		begin                                                                      \
			dbglog_data[dbglog_wp] <= (DATA_);                                      \
			dbglog_src [dbglog_wp] <= (SRC_);                                       \
			dbglog_seq [dbglog_wp] <= dbg_evt_cnt[5:0];                             \
			dbglog_wp <= dbglog_wp + 4'd1;                                          \
			dbg_evt_cnt <= dbg_evt_cnt + 16'd1;                                     \
			dbg_last_byte <= (DATA_);                                               \
			dbg_last_src  <= (SRC_);                                                \
		end

	always @(posedge clk) begin
		// vk_data 的"锁存值": vk_valid 为 1 的那一拍, 记下接收端发出的字节
		if (vk_valid) dbg_vk_data <= vk_data;
		dbg_vk_valid <= vk_valid;
		// s_data 每次装缓冲时同步一次, 抓到的是"真正被 80186 读走的那一字节"
		dbg_s_data   <= s_data;
		dbg_dout     <= dout;
		dbg_sel_dout <= cmd ? 2'd1 : (ctl_outb ? 2'd2 : 2'd0);
		dbg_OBF      <= OBF;
		// ★ 第 113 次: BIOS 取走输出缓冲那一拍的脉冲 + 它取到的字节。
		//   ⚠ 必须整个信号只由**这一个** always 块驱动, 写成两个块(一个置 0
		//     一个置 1)会触发 DRC MDRV-1 多驱动。因此这里用与主 always 块
		//     读数据口分支完全相同的条件来重建该时刻:
		//         CS & ~cmd & ~ctl_outb & (OBF | MOBF)
		//   ⚠ 加上 (OBF|MOBF) 限定是必须的: BIOS 轮询状态口后会连续多次读
		//     0x60, 若只判 CS&~cmd&~ctl_outb 则脉冲会连成多拍高电平,
		//     ILA 上根本无法定位"到底哪一拍取走的"(台架已实测复现)。
		dbg_take_pulse <= 1'b0;
		if (CS && !cmd && !ctl_outb && (OBF || MOBF)) begin
			dbg_take_pulse <= 1'b1;
			dbg_take_byte  <= OBF ? s_data : mouse_data;
		end
		// 意外字节指纹: 连续 3 次装缓冲都拿到同一个值, 就把它锁住。
		// 预期压 j 时 dbg_bad_byte 恒为 0(什么都不该锁);
		// 若它停在某个非 0 值上 ⇒ 那个值就是被换进来的"冒充字节", 可直接当触发条件。
		if (dbg_evt_cnt[1:0] == 2'b01) begin
			if (dbg_last_byte != 8'h00) begin
				if (dbg_last_byte == dbg_bad_byte)
					dbg_bad_cnt <= dbg_bad_cnt + 8'd1;
				else begin
					dbg_bad_byte <= dbg_last_byte;
					dbg_bad_cnt  <= 8'd1;
				end
			end
		end
	end

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
	
	// ---- 虚拟鼠标: 命令应答序列发生器(与 vm_cmd_seen 置位分开, 避免多驱动) ----
	//  序列严格照 BIOS_Next186.asm 的期望来定:
	//    0xFF 复位   -> FA, AA, 00     (BIOS 取 AA 判 BAT, 再取 00 判 ID)
	//    0xF2 读 ID  -> FA, 00         (INT15h C2 的 gettype 用它定 3/4 字节包)
	//    0xE9 状态   -> FA, 20, 02, 64 (stream 模式/已使能/1:1, 4 点/mm, 100 次/s)
	//    0xEB 读数据 -> FA, 08, 00, 00 (远程模式下的一个包; 实际驱动多用 stream 模式)
	//    其它(0xF3 采样率 / 0xE8 分辨率 / 0xE6/E7 缩放 / 0xF4/F5/F6) -> 只回 FA
	//  ★ 0xF3/0xE8 的**参数字节**是 BIOS 用下一次 sendcmd 单独发的(见 asm 的 send2c/
	//    send1c), 走的是同一条 0xD4 通路, 因此同样落到"其它 -> FA", 不需要额外状态。
	always @(posedge clk) begin
		vm_cmd_ack <= 1'b0;
		if (m_taken & vm_out_v) begin
			// 上一字节已被装进输出缓冲 -> 吐序列里的下一个字节(或结束)
			case (vm_state)
				VM_BAT:   begin vm_out <= 8'hAA; vm_out_v <= 1'b1; vm_state <= VM_BATID; end
				VM_BATID: begin vm_out <= 8'h00; vm_out_v <= 1'b1; vm_state <= VM_IDLE;  end
				VM_ID:    begin vm_out <= 8'h00; vm_out_v <= 1'b1; vm_state <= VM_IDLE;  end
				VM_ST1:   begin vm_out <= 8'h20; vm_out_v <= 1'b1; vm_state <= VM_ST2;   end
				VM_ST2:   begin vm_out <= 8'h02; vm_out_v <= 1'b1; vm_state <= VM_ST3;   end
				VM_ST3:   begin vm_out <= 8'h64; vm_out_v <= 1'b1; vm_state <= VM_IDLE;  end
				VM_PKT0:  begin vm_out <= 8'h08; vm_out_v <= 1'b1; vm_state <= VM_PKT1;  end
				VM_PKT1:  begin vm_out <= 8'h00; vm_out_v <= 1'b1; vm_state <= VM_PKT2;  end
				VM_PKT2:  begin vm_out <= 8'h00; vm_out_v <= 1'b1; vm_state <= VM_IDLE;  end
				VM_IDLE:  begin vm_out_v <= 1'b0; end          // 序列发完
				default:  begin vm_out_v <= 1'b0; vm_state <= VM_IDLE; end
			endcase
		end else if (vm_state == VM_IDLE && vm_enable && vm_cmd_seen) begin
			// 新命令 -> 第一字节永远是 ACK
			vm_cmd_ack <= 1'b1;
			vm_out   <= 8'hFA;
			vm_out_v <= 1'b1;
			case (vm_cmd)
				8'hff: vm_state <= VM_BAT;    // reset: AA, 00
				8'hf2: vm_state <= VM_ID;     // get ID: 00
				8'he9: vm_state <= VM_ST1;    // status: 3 bytes
				8'heb: vm_state <= VM_PKT0;   // read data: 3 bytes
				default: vm_state <= VM_IDLE; // 其它命令只回 ACK
			endcase
		end
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
		// ★ 鼠标应答"已取走"脉冲: 只由本块驱动(应答器只读它, 避免 MDRV-1 多驱动)
		m_taken <= 1'b0;
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
			//   下面六处 dbglog_push 就是"字节真正入队"的时刻, 也是日志的唯一写入点。
			if(vk_enable & vk_out_v) begin
				OBF <= 1'b1;
				s_data <= vk_out;
				dbg_src <= 3'd1;
				`DBGLOG_PUSH(vk_out, 3'd1);
			end else if(vm_enable & vm_out_v) begin
				// ★ 鼠标命令应答(FA/AA/00/状态包): 与键盘自检应答同级, 必须优先于数据,
				//   因为 BIOS 的 sendcmd 在**死等**这个 0xFA(等到 vblank 超时就判失败)。
				//   用 MOBF 标记来源(真实硬件: 鼠标数据走辅助口, 状态口 bit5=1)。
				//   vm_out_v 是**电平**(不是单拍脉冲), 收到 m_taken 才吐下一字节 ——
				//   见下面应答器的说明: 单拍脉冲会因为"缓冲还没被 CPU 取走"而丢字节。
				MOBF <= 1'b1;
				s_data <= vm_out;
				dbg_src <= 3'd4;
				`DBGLOG_PUSH(vm_out, 3'd4);
				m_taken <= 1'b1;
			end else if(vm_enable & vm_valid & vm_reporting) begin
				// ★ 鼠标移动包: 只在 0xF4 打开数据上报之后才放行(理由见 vm_reporting 注释)。
				//   只置 MOBF, **不置 OBF**: OBF 为 1 会同时触发 IRQ1, BIOS 的 int09
				//   会把移动包当成键盘扫描码解释(0x08..0x0F 正好是数字/退格等, 且没有
				//   对应的 break => 按键粘死)。I_MOUSE = cmdbyte[1] & MOBF => IRQ12。
				MOBF <= 1'b1;
				s_data <= vm_data;
				dbg_src <= 3'd5;
				`DBGLOG_PUSH(vm_data, 3'd5);
			// ★ 未开数据上报(还没收到 0xF4)时收到的鼠标字节在这里**不出现**:
			//   它既不会被装进缓冲, 也不会挡住下面的键盘分支 —— 接收端看到 vm_ready
			//   就会弹出, 所以"不处理"就等于丢弃, 且 FIFO 不会堵(键盘侧踩过的坑)。
			end else if(vk_enable & vk_valid) begin
				OBF <= 1'b1;
				s_data <= vk_data;
				dbg_src <= 2'd0;
				`DBGLOG_PUSH(vk_data, 2'd0);
			end else if(kb_data_out_ready & ~rd_kb & ~cmdbyte[2] & ~vk_enable) begin
				OBF <= 1'b1;
				s_data <= kb_data;
				dbg_src <= 2'd2;
				`DBGLOG_PUSH(kb_data, 2'd2);
			end else if(mouse_data_out_ready & ~rd_mouse & ~cmdbyte[3] & ~vk_enable) begin
				OBF <= 1'b1;
				s_data <= mouse_data;
				dbg_src <= 2'd3;
				`DBGLOG_PUSH(mouse_data, 2'd3);
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

		// ★ 鼠标命令标志: 只在"应答器真的开始应答了"时才清(这样序列未完时来的新命令
		//   不会被吃掉)。而且放在**写命令之前**: 同一 always 块内对同一 reg 的最后一次
		//   赋值生效, 所以本拍刚写入的命令也不会被这条清掉。
		if (vm_cmd_ack) vm_cmd_seen <= 1'b0;
		
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
						if(vk_enable | vm_enable) begin
							// ★ 虚拟模式: 键盘口和鼠标口都**不驱动物理 PS/2**。
							//   原码这里无条件 `wr_mouse <= next_mouse`, 于是 BIOS 的
							//   0xD4+命令会去驱动一个根本不存在的物理鼠标: PS2Interface
							//   拉低时钟后等不到设备时钟, data_in_ready 永久为 0
							//   => IBF 永久为 1 => BIOS 的 sendps2byte 超时 => nomouse。
							//   这是"鼠标检测不到"的第一层根因, 这里直接掐掉。
							wr_kb    <= 1'b0;
							wr_mouse <= 1'b0;
							if(next_mouse) begin
								// 0xD4 之后的字节 = 鼠标命令 -> 交给虚拟鼠标应答器
								if(vm_enable) begin
									vm_cmd      <= din;
									vm_cmd_seen <= 1'b1;
									// 0xF4 使能数据上报 / 0xF5 关闭 / 0xF6 恢复默认(关闭)
									if(din == 8'hf4)      vm_reporting <= 1'b1;
									else if(din == 8'hf5) vm_reporting <= 1'b0;
									else if(din == 8'hf6) vm_reporting <= 1'b0;
								end
							end else if(vk_enable) begin
								vk_cmd      <= din;
								vk_cmd_seen <= 1'b1;
							end
						end else begin
							wr_mouse <= next_mouse;
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
