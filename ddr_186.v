`timescale 1ns / 1ps

module system
	(
         // AXI4 Burst 原生接口
         output wire [1:0]  ram_cmd,        
         input  wire [1:0]  ram_cmd_ack,    
         output wire [23:0] ram_addr,       
         output wire [31:0] ram_wdata,      
         input  wire [15:0] ram_rdata,      
         input  wire        ram_rd_valid,   
         input  wire        ram_wr_valid,   
		 input 	CLK_50MHZ,
		 output reg [5:0]VGA_R,
		 output reg [5:0]VGA_G,
		 output reg [5:0]VGA_B,
		 output frame_on,
		 output wire VGA_HSYNC,
		 output wire VGA_VSYNC,
		 input BTN_RESET,	
		 input BTN_NMI,		
		 output [7:0]LED,	
		 input RS232_DCE_RXD,
		 output RS232_DCE_TXD,
		 input RS232_EXT_RXD,
		 output RS232_EXT_TXD,
		 input RS232_HOST_RXD,
		 output RS232_HOST_TXD,
		 output reg RS232_HOST_RST,

		 output reg SD_n_CS = 1'b1,
		 output wire SD_DI,
		 output reg SD_CK = 0,
		 input SD_DO,
		 
		 output AUD_L,
		 output AUD_R,
	 	 inout PS2_CLK1,
		 inout PS2_CLK2,
		 inout PS2_DATA1,
		 inout PS2_DATA2,
		 
		 inout [7:0]GPIO,
		 output I2C_SCL,
		 inout I2C_SDA,
		 output wire I2S_MCLK,
		 output wire I2S_SCLK,
		 output wire I2S_LRCLK,
		 output wire I2S_SDIN,
		 output MIDI_OUT,
		 input CLKBD,
		 input WSBD,
		 input DABD
		 
    );

	initial SD_n_CS = 1'b1;
	//wire [15:0] cpu_wdata_latch;//new
	wire [31:0]cntrl0_user_input_data;
	wire [15:0]sys_DOUT;	
	wire [31:0] DOUT;
	wire [15:0]CPU_DOUT;
	wire [15:0]PORT_ADDR;
	wire [31:0] DRAM_dout;
	wire [20:0] ADDR;
	wire IORQ;
	wire WR;
	wire INTA;
	wire WORD;
	wire [3:0] RAM_WMASK;


	wire hblnk;
	wire vblnk;
	wire [9:0]hcount;
	wire [9:0]vcount;
	reg [3:0]vga_hrzpan = 0;
	wire [3:0]vga_hrzpan_req;
	wire [9:0]hcount_pan = hcount + vga_hrzpan - 17;
	reg FifoStart = 1'b0;	
	wire displ_on = !(hblnk | vblnk | !FifoStart);
	wire [17:0]DAC_COLOR;
	wire [8:0]fifo_wr_used_words;
	wire AlmostFull;
	wire AlmostEmpty;
	wire clk_cpu;
	wire clk_dsp;
	wire clk_sdr;
	wire CPU_CE;	
	wire CE;
	wire CE_186;
	wire ddr_rd; 
	wire ddr_wr;
	wire TIMER_OE = PORT_ADDR[15:2] == 14'b00000000010000;	
	wire VGA_DAC_OE = PORT_ADDR[15:4] == 12'h03c && PORT_ADDR[3:0] <= 4'h9; 
	wire LED_PORT = PORT_ADDR[15:0] == 16'h03bc;
	wire SPEAKER_PORT = PORT_ADDR[15:0] == 16'h0061;
	wire MEMORY_MAP = PORT_ADDR[15:4] == 12'h008;
	wire VGA_FONT_OE = PORT_ADDR[15:0] == 16'h03cb;
	wire AUX_OE = PORT_ADDR[15:0] == 16'h0001;
	wire I2C_SELECT = PORT_ADDR[15:0] == 16'h0004;
	wire INPUT_STATUS_OE = PORT_ADDR[15:0] == 16'h03da;
	wire VGA_CRT_OE = (PORT_ADDR[15:1] == 15'b000000111011010) || (PORT_ADDR[15:1] == 15'b000000111101010); 
	wire RTC_SELECT = PORT_ADDR[15:0] == 16'h0070;
	wire VGA_SC = PORT_ADDR[15:1] == (16'h03c4 >> 1); 
	wire VGA_GC = PORT_ADDR[15:1] == (16'h03ce >> 1); 
	wire PIC_OE = PORT_ADDR[15:8] == 8'h00 && PORT_ADDR[6:0] == 7'b0100001;	
	wire KB_OE = PORT_ADDR[15:4] == 12'h006 && {PORT_ADDR[3], PORT_ADDR[1:0]} == 3'b000; 
	wire JOYSTICK = PORT_ADDR[15:4] == 12'h020; 
	wire MPU401_OE = PORT_ADDR[15:1] == (16'h0330 >> 1); 
	wire PARALLEL_PORT = PORT_ADDR[15:0] == 16'h0378;
	wire PARALLEL_PORT_CTL = PORT_ADDR[15:0] == 16'h0379;
	wire CPU32_PORT = PORT_ADDR[15:1] == (16'h0002 >> 1); 
	wire COM1_PORT = PORT_ADDR[15:3] == (16'h03f8 >> 3);
	wire OPL3_PORT = PORT_ADDR[15:2] == (16'h0388 >> 2); 
	wire NMI_IORQ_PORT = PORT_ADDR[15:1] == (16'h0006 >> 1); 
 	wire [7:0]VGA_DAC_DATA;
	wire [7:0]VGA_CRT_DATA;
	wire [7:0]VGA_SC_DATA;
	wire [7:0]VGA_GC_DATA;
	wire [15:0]PORT_IN;
	wire [7:0]TIMER_DOUT;
	wire [7:0]KB_DOUT;
	wire [7:0]PIC_DOUT;
	wire [7:0]COM1_DOUT;
	wire [7:0]MPU401_DOUT;
	wire HALT;
	wire CLK14745600; 
 	wire CLK44100x256;
	wire sq_full; 
	wire dss_full;
	wire [15:0]cpu32_data;
	wire cpu32_halt;
	
	reg [1:0]cntrl0_user_command_register = 0;
	// ★★ 112th VGA 帧缓冲基址单一真源（2026-09-27）：作者代码在 3 处硬编码文本基址(0xe000)，
	//   端口改为 0x14000 时漏改 endframe 那处 → VGA 每帧复位读错页(0x0805C000)→ 花屏。
	//   现收敛为两个 localparam，端口化时只改这两行，杜绝"改 N 处漏一处"类回归。
	localparam [16:0] VGA_TEXT_ROWCOL  = 17'h0E000; // ★128th 恢复(B)：作者原值/作者单位；×2 只在行998 输出处统一做
//   （★128th 恢复 (B) 修法，上面两点一并解决：
//    ① 加法器留在作者单位：最大 0xE000+0xFFFF=0x1DFFF<0x20000，且 7+7=14≤15 ⇒ 不再溢出
//       （ILA 实测 scraddr=0x6000 也安全；121st 时 14+3=17 会回绕）
//    ② 每行步进 +40 在输出处被 ×2 ⇒ 等效 80 移植单位=160B=一整行 ⇒ 修掉"每 8 字符重复"
//    ★ 重要教训：换 bitstream 必须"断电重上电再烧录"，否则 DDR 残留脏数据会让 VGA 读到垃圾页）
//   （★129th 上板实测再补一刀：步进已对、字符连续，但整体偏移 16 字符
//    —— 每显示行 = 帧缓冲[16+80k, 96+80k)，即"前64字符 + 后16字符"拼接（三处样本精确对上：
//    r0[16]='n'→"n redistribute..."、r16[16]='F'→"FreeDOS]"、r17[16]='t'→"t found"）。
//    16 字符 = 16 移植单位 = 8 作者单位 = 恰好一个 burst(8字)。
//    故在输出处再 -8 作者单位：sdraddr = 0x40000 + 2*(row_col+lnbytecount-8)
//    → scraddr=0 时 0x5C000-0x10 = 0x5BFF0，显示从帧缓冲 char 0 开始。
//    注意：不能把 -8 加进 VGA_TEXT_ROWCOL —— 行1065 endframe 公式只取 ROWCOL[16:13]、丢低13位。
//    宽度安全：A(17b)+B(8b)-5'd8 → 17bit，A>=0xE000 无下溢；concat 仍 5+17+1=23bit。）
//   （★130th 上板实测：16 字符偏移已消、字符连续可读 ✓。残差 = 水平 1 字符
//    （r3[78]='s'（"values"的s）折到下一行行首 ⇒ 原始偏移实为 15 而非 16，-8 多修了 1 个）。
//    1 字符 = 0.5 作者单位，无法用 -k 表达 ⇒ 把 concat 末位 1'b0 → 1'b1（= +1 移植单位 = +1 字符）。
//    注意：sdraddr 变为奇数 —— 作者原版 {6'b000001, row_col+lnbytecount} 本就可奇可偶，故支持；
//    若综合后 burst/FIFO 出问题，把这一位改回 1'b0 即可。
//    垂直方向：**不是** scraddr 滚屏（ILA 实测 scraddr=0000，131st 已更正 130th 的误判）——
//    显示起点比帧缓冲早 11 行 = 880 字符 = 880 移植单位 = 440 作者单位（= 11×40）。
//    故再 -440 作者单位，与之前的 -8 合并为 **-448**：
//    sdraddr = 0x5C000 + 2*(scraddr+lnbytecount) - 2*448 + 1 = 0x5C000 + 2*(...) - 895
//    （相对上一版的 -15，正好再减 880 = 11 整行 ⇒ 纯垂直平移，水平对齐不受影响。
//     宽度安全：9'd448 为 9bit，A(17b)+B(8b)-9'd448 → 17bit；A>=0xE000 故 0xDE40>0 无下溢。）
	localparam [16:0] VGA_GRAPH_ROWCOL = 17'h08000; // ★128th 恢复(B)：作者原值，同上
	reg [16:0]vga_ddr_row_col = VGA_TEXT_ROWCOL; 
	reg s_prog_full;
	 reg s_prog_empty;
	reg s_ddr_rd = 1'b0;
	reg s_ddr_wr = 1'b0;
	// ★★ 95th 修复（2026-09-26）：一条 cache 事务只允许一次 AXI burst
	//   —— cache_cmd_done 标记“当前呈现的 cache 请求已经被服务过一次 burst”，
	//   当 cache 完全无请求时自动复位，下一条事务自然重新使能。
	//   cache_owns = 本拍 cache 是否拥有 DDR 总线（用于命令寄存器与 sdraddr 同源）。
	//   详见下方 cntrl0_user_command_register 处的 95th 修复注释。
	reg cache_cmd_done = 1'b0;
	wire cache_owns = (ddr_wr || ddr_rd) && !cache_cmd_done;   // 96th: real-time request, so cmd/type/address are same-cycle
	reg crw = 0;	
	 reg cache_line_start = 1'b0;   // ★ Task #8：cache 行事务开始脉冲（cache_controller 用它复位 lowaddr）
	reg s_RS232_DCE_RXD;
	reg s_RS232_HOST_RXD;
	reg [18:0]rstcount = 0;
	reg [18:0]s_displ_on = 0;	
	reg [2:0]vga13 = 0; 		
	reg [2:0]vgatext = 0;  		
	reg [2:0]v240 = 0;
	reg [2:0]planar = 0;
	reg [2:0]half = 0;
	reg [0:0]repln_graph = 0;
	wire vgaflash;
	reg flashbit = 0;
	reg [5:0]flashcount = 0;
	wire [5:0]char_row = vcount[8:3] >> !half[2];
	wire [3:0]char_ln = {(vcount[3] & !half[1]), vcount[2:0]};
	wire [11:0]charcount = {char_row, 4'b0000} + {char_row, 6'b000000} + hcount_pan[9:3];
	wire [31:0]fifo_dout32;
	wire [15:0]fifo_dout = (vgatext[1] ? hcount_pan[3] : vga13[1] ? hcount_pan[2] : hcount_pan[1]) ? fifo_dout32[31:16] : fifo_dout32[15:0];

	reg [8:0]vga_ddr_row_count = 0;
	reg [2:0]max_read;
	reg [4:0]col_counter;
	// ★★ 146th 三处配套修复**实测仍未解决**（水平偏移 + 首行顶部被截）⇒ 已回退，回到"上下颠倒"基线。
	//    根因未定，改用 Verilator 台架离线复现定位（见 sim/tb），不再上板盲试。
	wire vga_end_frame = vga_ddr_row_count == (v240[0] ? 479 : 399);
	reg [3:0]vga_repln_count = 0; 
	wire [3:0]vga_repln = vgatext[0] ? (half[0] ? 7 : 15) : {3'b000, repln_graph[0]};
	reg [7:0]vga_lnbytecount = 0; 
	wire [4:0]vga_lnend = (vgatext[0] | half[0]) ? 6 : (vga13[0] | planar[0]) ? 11 : 21; 
	reg [11:0]vga_font_counter = 0;
	reg [7:0]vga_attr;
	reg [4:0]RTCDIV25 = 0;
	reg [1:0]RTCSYNC = 0;
	reg [15:0]RTC = 0;
	reg [15:0]RTCSET = 0;
	wire RTCEND = RTC == RTCSET;
	wire RTCDIVEND = RTCDIV25 == 24;
	wire [14:0]cache_hi_addr;
	wire [8:0]memmap;
	wire [8:0]memmap_mux;
	// ★ 三十四次诊断（第三十四次诊断）：VRAM row0 写回时锁存 memmap_mux
	//   物理地址 = 0x0800_0000 + 2*sdraddr，上段由 memmap_mux 决定
	//   期望 4'h6（map[11]=6）⇒ sdraddr=0x34000 → 物理 0x0806_8000
	reg [3:0] dbg_wr0_memmap = 4'd0;
	reg dbg_wr0_mm_l = 1'b0;
	always @(posedge clk_sdr) begin
		if(!s_ddr_wr) dbg_wr0_mm_l <= 1'b0;
		else if(!dbg_wr0_mm_l && (cache_hi_addr == 15'h2E00)) begin
			dbg_wr0_memmap <= memmap_mux[3:0];
			dbg_wr0_mm_l   <= 1'b1;
		end
	end
	wire [7:0]font_dout;
	wire [7:0]VGA_FONT_DATA;
	wire vgatextreq;
	wire vga13req;
	wire planarreq;
	wire replnreq;
	wire halfreq;
	wire oncursor;
	wire [4:0]crs[1:0];
	wire [11:0]cursorpos;
	wire [15:0]scraddr;
	reg flash_on;
	reg speaker_on = 1'b0;
	reg [9:0]rNMI = 0;
	wire [2:0]shift = half[1] ? ~hcount_pan[3:1] : ~hcount_pan[2:0];
	wire [2:0]pxindex = -hcount_pan[2:0];
	wire [3:0]EGA_MUX = vgatext[1] ? (font_dout[pxindex] ^ flash_on) ? vga_attr[3:0] : {vga_attr[7] & ~vgaflash, vga_attr[6:4]} :
							  {fifo_dout32[{2'b11, shift}], fifo_dout32[{2'b10, shift}], fifo_dout32[{2'b01, shift}], fifo_dout32[{2'b00, shift}]};
	wire [7:0]VGA_INDEX;						  
	reg [3:0]exline = 4'b0000; 
	wire vrdon = s_displ_on[~vga_hrzpan];
	wire vrden = (vrdon || exline[3]) && ((vgatext[1] | half[1]) ? &hcount_pan[3:0] : (vga13[1] | planar[1]) ? &hcount_pan[2:0] : &hcount_pan[1:0]);
	reg s_vga_endline;
	reg s_vga_endscanline = 1'b0;
	reg s_vga_endframe;
	reg [23:0]sdraddr;
	wire [3:0]vga_wplane;
	wire [1:0]vga_rplane;
	wire [7:0]vga_bitmask;	
	wire [2:0]vga_rwmode;
	wire [3:0]vga_setres;
	wire [3:0]vga_enable_setres;
	wire [1:0]vga_logop;
	wire [3:0]vga_color_compare;
	wire [3:0]vga_color_dont_care;
	wire [2:0]vga_rotate_count;
	wire [7:0]vga_offset;
	reg [2:0]auto_flush = 3'b000;
	wire ppm; 			
	wire [9:0]lcr; 		
	wire [9:0]vde;		
	// ★139th 已撤回：曾在这里给文本分支加 "vcount < 400" 的可见区截断。
	//   用户确认**底部那 7 行是有真实数据的**（C:\> 盘符和光标就在那里），
	//   ⇒ 截断会把真实内容藏掉，**不可接受**。乱码是基址读偏导致的，应从基址/取址修，不能靠裁剪显示区。
	wire sdon = s_displ_on[17+vgatext[1]] & (vcount <= vde);

   wire clk_sys_locked;
    wire clk_cpu_locked;

// Com interface
	reg [1:0]ComSel = 2'b00; 
	wire RX = ComSel[1] ? RS232_HOST_RXD : ComSel[0] ? RS232_EXT_RXD : RS232_DCE_RXD;	
	wire TX;
	assign RS232_DCE_TXD = ComSel[1:0] == 2'b00 ? TX : 1'b1;
	assign RS232_EXT_TXD = ComSel[1:0] == 2'b01 ? TX : 1'b1;
	assign RS232_HOST_TXD = ComSel[1] ? TX : 1'b1;
	reg [1:0]COMBRShift = 2'b00; 
	
// SD interface
	reg [7:0]SDI;
	// ★ 三十九次诊断（2026-09-23）：SD/SPI 链路观测（clk_cpu 域采样）。
	//   背景：SD 卡走端口 0x3DA 位敲 SPI——写 8-bit → SD_CK 一个脉冲 + SDI 移入 SD_DO；
	//   SD_DI = CPU_DOUT[7]；写 16-bit → SD_n_CS <= ~CPU_DOUT[8]；读 0x3DA → 高字节 = SDI。
	//   判读：上电后 dbg_sd_cs 有下拉 + dbg_sd_ckc > 0 ⇒ BIOS 确实在跑 SD 例程（即使没插卡）；
	//         dbg_sd_rx 若恒 0xFF ⇒ 卡无响应（物理/初始化时序/卡类型）；若出现 0x01 ⇒ CMD0 成功进 SPI 模式。
	 reg        dbg_sd_cs  = 1'b1;  // SD 片选（低 = 在通信）
	 reg        dbg_sd_ck  = 1'b0;  // SPI 时钟（SCLK）
	 reg        dbg_sd_di  = 1'b0;  // MOSI（BIOS → 卡）
	 reg        dbg_sd_do  = 1'b0;  // MISO（卡 → BIOS）
	reg dbg_sd_ck_d = 1'b0;
	always @(posedge clk_cpu) begin
		dbg_sd_cs <= SD_n_CS; dbg_sd_ck <= SD_CK;
		dbg_sd_di <= SD_DI;   dbg_sd_do <= SD_DO;
		dbg_sd_ck_d <= SD_CK;
	end
	// ⚠四十六次修正（探针除阱 #4）：
	//   dbg_sd_ck 与 dbg_sd_ck_d 都在同一 posedge 采样 SD_CK
	//   ⇒ 二者恒等 ⇒ dbg_sd_ck && !dbg_sd_ck_d 恒假
	//   ⇒ dbg_sd_ckall / dbg_sd_rxnz 永不更新（读数全为 0 = 假读数）。
	//   现改为 raw SD_CK + dbg_sd_ck_d（与 dbg_sd_ckc 同源）。
	// ★ 四十次（SD 探针 v2）：区分“完全没敲 SPI”与“只在片选拉低前敲了初始化时钟”。
	//   dbg_sd_ckc 只统计 CS 低期间的时钟（初始化的 80 拍是 CS 高时发的，不会被计入）。
	 reg        dbg_sd_cslow = 1'b0;  // 粘滞：CS 曾拉低过（与 LED 交叉验证）
	 reg        dbg_sd_rxnz  = 1'b0;  // 粘滞：SDI 曾非全 1（=卡把 MISO 拉低过）
	// ★★ 四十九次修正（探针除阱 #5/#6，2026-09-24）：
	//   reg [7:0] SDI; 无初值 ⇒ 上电为 0x00；在 MISO 恒高时移位序列为 0x00→0x01→0x03→…→0xFF，
	//   ⇒ 旧判据 dbg_sd_rxnz(SDI != 0xFF) 与 dbg_sd_rx01(SDI == 0x01) 都会必然触发 = 假阳性
	//     （四十七次据此判“卡在应答”是错的）。
	//   现改：rxnz / dolow 直接看 raw SD_DO（不经移位寄存器）；rx01 移到字节边界处判。
	reg [9:0]  dbg_sd_bcnt  = 10'd0;  // CS 低期字节边界计数（验证 stb 真的在跑）
	// ★ 四十七次探针：直接判定“SD 初始化走到哪一步”（卡哪怕只回一次也能看出）。
	//   dbg_sd_rxnz：MISO 曾被拉低（卡至少响应过）——已有。
	//   dbg_sd_rx01：SDI 曾 == 0x01（CMD0 的 R1 特征值 ⇒ 卡已进 SPI 模式）。
	//   dbg_sd_rxfe：SDI 曾 == 0xFE（数据令牌 ⇒ 已经在读扇区）。
	//   判读：rxnz=0 ⇒ 卡从未应答（物理/时钟）；rx01=1 ⇒ 越过 CMD0；
	//         rxfe=1 ⇒ 已到读扇区阶段（那就该查镜像位置/校验和）。
	reg        dbg_sd_rxfe  = 1'b0;
	reg        dbg_sd_r00   = 1'b0;
	always @(posedge clk_cpu) begin
		if(!SD_n_CS) dbg_sd_cslow <= 1'b1;
		if(SD_CK && !dbg_sd_ck_d && (SD_DO == 1'b0)) dbg_sd_rxnz <= 1'b1;
		// [62nd probe fix] Both original lines had NO gating at all, which made them
		// useless (or actively misleading):
		//   if(SD_DO == 0)    -> card insertion contact bounce alone sets it.
		//                        Proved to be an insertion detector, NOT a card response.
		//   if(SDI == 8'hFE)  -> a free-running shift register passes through 0xFE anyway.
		// Now gated by the SD_CK rising edge (same source as dbg_sd_rxnz), so the value
		// means 'the card actually drove the bus low on a clock edge'.
		// dbg_sd_dolow is therefore IDENTICAL to dbg_sd_rxnz now; kept only so old
		// readings can still be compared. The 0xFE test moved into the byte-aligned
		// block below (dbg_sd_rxfe is now byte-aligned like dbg_sd_1st).
	end
	// ★ 四十八次探针：**字节对齐**捕获，直接看"卡回了什么"。
	//   背景：四十七次读数 rxnz=1 / rx01=1 / rxfe=0 ⇒ 卡确实应答了，
	//   但从未出现数据令牌 0xFE ⇒ 失败在 CMD0 之后、CMD9 之前。
	//   rx01 是"任意时刻 SDI==0x01"，不对齐到字节边界，说服力不足 ⇒ 本次改成字节对齐。
	//   字节边界 = 每 8 个 SD_CK 上升沿（每个 8-bit 写 = 1 个收到的字节）。
	//   判读：dbg_sd_1st = 卡的第一条响应（CMD0 的 R1，期望 0x01；若为 0x05 则 CMD0 被拒）；
	//         dbg_sd_aa  = 1 ⇒ 字节对齐地出现过 0xAA ⇒ **CMD8 的 R7 校验回显成功**（卡是 v2）；
	//         dbg_sd_byte = 最后一个完成的字节（看总线当前状态）。
	reg [2:0] dbg_sd_sht  = 3'd0;   // 移位计数 mod 8
	reg [7:0] dbg_sd_byte = 8'hFF;  // 最后完成的字节（字节对齐）
	reg [7:0] dbg_sd_1st  = 8'hFF;  // 首个非 0xFF 字节（卡的第一条响应）
	reg       dbg_sd_aa   = 1'b0;   // 字节对齐值曾 == 0xAA（CMD8 R7 回显）
	reg dbg_sd_ck_e = 1'b0;
	reg dbg_sd_1st_seen = 1'b0;
	reg dbg_sd_stb = 1'b0;
	always @(posedge clk_cpu) begin
		dbg_sd_ck_e <= SD_CK;
		if (SD_CK && !dbg_sd_ck_e) dbg_sd_sht <= dbg_sd_sht + 3'd1;
		// 第 8 次移位的下一拍，SDI 即为完整的一个字节
		dbg_sd_stb <= (SD_CK && !dbg_sd_ck_e) && (dbg_sd_sht == 3'd7);
		// 仅在片选拉低期统计（初始化的 80 拍在 CS 高时，不计）
		if (dbg_sd_stb && !dbg_sd_cs) begin
			dbg_sd_byte <= SDI;
			if (dbg_sd_bcnt != 10'h3FF) dbg_sd_bcnt <= dbg_sd_bcnt + 1'b1;
			if (SDI == 8'hAA) dbg_sd_aa <= 1'b1;
			if (SDI == 8'h00) dbg_sd_r00 <= 1'b1;
			if (SDI == 8'hFE) dbg_sd_rxfe <= 1'b1;
			if (!dbg_sd_1st_seen && (SDI != 8'hFF)) begin
				dbg_sd_1st <= SDI; dbg_sd_1st_seen <= 1'b1;
			end
		end
		// [65th fix, 2026-09-25] Clear on the SD_n_CS falling edge => dbg_sd_bcnt
		// now reads as 'bytes transferred in the CURRENT / most recent SPI
		// transaction'. A complete CMD17 (6-byte command + R1 + token + 512 B
		// + 2 CRC + dummies) is about 523; a read that bails out because the
		// data token was not 0xFE stops at about 8.
		if (dbg_sd_cs_d && !SD_n_CS) dbg_sd_bcnt <= 10'd0;
		if (dbg_sd_cs_d && !SD_n_CS) dbg_sd_rxfe <= 1'b0;  // [68th] per-transaction token flag
	end
	// [69th probe, 2026-09-25] The probe flops are initialised at FPGA configuration
	// only - the button reset does NOT clear them. dbg_sd_ncs therefore accumulates
	// across reset presses, so a saturated 0xFFFF may just mean "many button resets
	// ago" instead of a runaway loop. Clearing both counters on the RISING edge of
	// BTN_RESET makes them read "this BIOS run only" after a key reset.
	reg dbg_rst_d = 1'b0;
	always @(posedge clk_cpu) dbg_rst_d <= BTN_RESET;

	// ===== [62nd probe, 2026-09-25] Transaction-level instruments =====================
	// Context: with the DI/DO wiring fixed the card is now recognised (string 2
	// 'BIOS not found' no longer appears), but the flow stops at
	// 'Searching BIOS on SDCard ...' and never advances.
	// Only one question is left: WHICH stage is it stuck in?
	//   (a) inside ONE SPI transaction, waiting for R1 or the data token
	//   (b) cycling through the 16-sector read retries
	//   (c) already jumped into the BIOS image loaded from the SD card
	// The slowed SPI (~100 clk_cpu per bit, commit 62f2b9d) means a 1024-deep ILA
	// covers about ONE byte, so the protocol cannot be watched as a waveform.
	// Everything below is therefore sticky counters/flags and needs NO capture depth.
	//   dbg_sd_ncs   : SD_n_CS falling edges = number of SPI transactions started.
	//                  Still growing => it is retrying, not hung.
	//   dbg_sd_ckrun : SD_CK rising edges inside the CURRENT CS-low window
	//                  (cleared when CS goes high, saturating). A normal CMD17 is
	//                  ~520 bytes ~ 4200 clocks. Saturated at 0xFFFF while
	//                  dbg_sd_cs == 0 => stuck inside this single transaction.
	//   dbg_sd_r00   : byte-aligned 0x00 seen => CMD17 R1 == 0 (command accepted).
	//   dbg_sd_rxfe  : byte-aligned 0xFE seen => data token (card is sending data).
	// =================================================================================
	 reg [15:0] dbg_sd_ncs   = 16'd0;
	reg dbg_sd_cs_d = 1'b1;
	always @(posedge clk_cpu) begin
		dbg_sd_cs_d <= SD_n_CS;
		if(dbg_sd_cs_d && !SD_n_CS) begin
			if(dbg_sd_ncs != 16'hFFFF) dbg_sd_ncs <= dbg_sd_ncs + 1'b1;
		end
		if(BTN_RESET && !dbg_rst_d) dbg_sd_ncs <= 16'd0;   // [69th] this-run-only
	end
	// ===== [68th probe, 2026-09-25] Hardware debug ports (write-only scratch) =====
	// WHY: the on-screen row1/row2 readout cannot be trusted any more (the VGA read
	// path repeats every 7-8 characters), so the BIOS now reports its diagnostics
	// through four otherwise unused I/O ports instead of the text buffer.
	// 0x00E0..0x00E3 are decoded nowhere else in this design and are unused by BOTH
	// the 1 KB bootstrap and the 8 KB card image (checked by scanning every
	// "mov dx,imm16" in both images).
	//   0x00E0 (8b)  <- CMD17 R1                 (pr1  @0x374)
	//   0x00E1 (8b)  <- data token               (pr2  @0x391)
	//   0x00E2 (16b) <- 8 KB checksum            (only when "Next" was found)
	//   0x00E3 (16b) <- sector number HIGH 16 b  (the 4 hex digits at row1 col0..3)
	//   0x00E4 (16b) <- 内存自测上报（capstone 核对）：
	//                   AL = 对照（填 1KB 后读 offset 0x40，期望 0x10）
	//                   AH = 测量（scan256 逐出全部后读 offset 0x80，期望 0x20）
	//                   ⇒ 整体期望 0x2010
	//   0x00E5 (8b)  <- ★ 95th self-test probe v2：scan256 后再读 offset 0x180
	//                   （line 6 自己的槽位）的字节。
	//                   v1 已经证实 [0x80]=0x60 且 [0x84]=0x61 ⇒ 自测图案
	//                   整体右移 0x100 字节（+4 行），line 2 槽位装的是 line 6 的整行内容。
	//                   本轮判据：[0x180]==0x60 ⇒ DDR 完好、是填充读错地址（读侧）；
	//                             否则 ⇒ line 6 的写回落到了别处（写侧）。
	// In the 68th revision these five probes were deleted as useless/traps:
	//   dbg_sd_shiftreq (saturates at once), dbg_sd_ckc / dbg_sd_ckall (12-bit
	//   saturating counters), dbg_sd_dolow (== dbg_sd_rxnz), dbg_sd_rx01 (SDI
	//   passes through 0x01 on its way to 0xFF, so it fires with no card present).
	 reg [7:0]  dbg_dbg0 = 8'h00;
	 reg [7:0]  dbg_dbg1 = 8'h00;
	 reg [15:0] dbg_dbg2 = 16'h0000;
	 reg [15:0] dbg_dbg3 = 16'h0000;
	 reg [15:0] dbg_dbg4 = 16'h0000;
 reg [7:0] dbg_dbg5 = 8'h00;
	always @(posedge clk_cpu) begin
		if(IORQ & CPU_CE & WR) begin
			if(PORT_ADDR[15:0] == 16'h00E0) dbg_dbg0 <= CPU_DOUT[7:0];
			if(PORT_ADDR[15:0] == 16'h00E1) dbg_dbg1 <= CPU_DOUT[7:0];
			if(PORT_ADDR[15:0] == 16'h00E2) dbg_dbg2 <= CPU_DOUT[15:0];
			if(PORT_ADDR[15:0] == 16'h00E3) dbg_dbg3 <= CPU_DOUT[15:0];
			if(PORT_ADDR[15:0] == 16'h00E4) dbg_dbg4 <= CPU_DOUT[15:0];
			if(PORT_ADDR[15:0] == 16'h00E5) dbg_dbg5 <= CPU_DOUT[7:0];
		end
	end
	// Largest byte count ever seen inside a single CS-low window (sticky since reset).
	//   ~136  (0x088) => every CMD17 bailed out BEFORE its 512-byte data phase
	//   ~522  (0x20A) => at least one CMD17 really moved the whole 512-byte block
	reg [9:0] dbg_sd_bcntmax = 10'd0;
	always @(posedge clk_cpu) begin
		if(BTN_RESET && !dbg_rst_d) dbg_sd_bcntmax <= 10'd0;   // [69th] this-run-only
		else if(dbg_sd_bcnt > dbg_sd_bcntmax) dbg_sd_bcntmax <= dbg_sd_bcnt;
	end
	// [SD-MOSI] During SoC reset (power-up 5 s window and any button reset) hold MOSI high.
	//   SD spec: to enter SPI mode the card wants DI held HIGH around power-up / init.
	//   Previously SD_DI = CPU_DOUT[7] unconditionally, i.e. undefined while the CPU is
	//   held in reset (typically 0). While BTN_RESET is asserted no 0x3DA access can
	//   happen, so overriding to 1 here cannot corrupt any SPI transfer.
	assign SD_DI = BTN_RESET ? 1'b1 : CPU_DOUT[7];
	
// GPIO interface
	reg [7:0]GPIOState = 8'h00;
	reg [7:0]GPIOData;
	reg [7:0]GPIODout = 8'hff;
	assign GPIO[0] = GPIOState[0] ? GPIODout[0] : 1'bz;
	assign GPIO[1] = GPIOState[1] ? GPIODout[1] : 1'bz;
	assign GPIO[2] = GPIOState[2] ? GPIODout[2] : 1'bz;
	assign GPIO[3] = GPIOState[3] ? GPIODout[3] : 1'bz;
	assign GPIO[4] = GPIOState[4] ? GPIODout[4] : 1'bz;
	assign GPIO[5] = GPIOState[5] ? GPIODout[5] : 1'bz;
	assign GPIO[6] = GPIOState[6] ? GPIODout[6] : 1'bz;
	assign GPIO[7] = GPIOState[7] ? GPIODout[7] : 1'bz;

// I2C interface
	reg [11:0]i2c_cd = 0;
	wire [7:0]i2cdout;
	wire i2cack;
	wire i2cackerr;

// opl3 interface
    wire [7:0]opl32_data;
    wire [15:0]opl3left;
    wire [15:0]opl3right;
    wire stb44100;

// MIDI interface
    wire [15:0]midi_left;
    wire [15:0]midi_right;
	 
// NMI on IORQ
	reg [15:0]NMIonIORQ_LO = 16'h0001;
	reg [15:0]NMIonIORQ_HI = 16'h0000;
	
    wire [1:0] sys_cmd_ack = ram_cmd_ack;
    wire sys_rd_data_valid = ram_rd_valid;
    wire sys_wr_data_valid = ram_wr_valid;
//din
    wire [15:0] cpu_wdata_lo;
	assign LED = {1'b0, !cpu32_halt, AUD_L, AUD_R, planarreq, |sys_cmd_ack, ~SD_n_CS, HALT};
	assign frame_on = s_displ_on[16+vgatext[1]];
	
	assign PORT_IN[15:8] = 
		({8{MEMORY_MAP}} & {7'b0000000, memmap[8]}) |
		({8{INPUT_STATUS_OE}} & SDI) |
		({8{CPU32_PORT}} & cpu32_data[15:8]) | 
		({8{JOYSTICK}} & GPIOState) |
		({8{I2C_SELECT}} & i2cdout);

	assign PORT_IN[7:0] = 
							 ({8{VGA_DAC_OE}} & VGA_DAC_DATA) |
							 ({8{VGA_FONT_OE}}& VGA_FONT_DATA) |
							 ({8{KB_OE}} & KB_DOUT) |
							 ({8{INPUT_STATUS_OE}} & {1'b1, i2cack, cpu32_halt, sq_full, vblnk, i2cackerr, s_RS232_DCE_RXD, hblnk | vblnk}) | 
							 ({8{VGA_CRT_OE}} & VGA_CRT_DATA) | 
							 ({8{MEMORY_MAP}} & {memmap[7:0]}) |
							 ({8{TIMER_OE}} & TIMER_DOUT) |
							 ({8{PIC_OE}} & PIC_DOUT) |
							 ({8{VGA_SC}} & VGA_SC_DATA) |
							 ({8{VGA_GC}} & VGA_GC_DATA) |
							 ({8{JOYSTICK}} & GPIOData) |
							 ({8{PARALLEL_PORT_CTL}} & {1'bx, dss_full, 6'bxxxxxx}) |
							 ({8{CPU32_PORT}} & cpu32_data[7:0]) | 
							 ({8{COM1_PORT}} & COM1_DOUT) | 
							 ({8{MPU401_OE}} & MPU401_DOUT) |
							 ({8{OPL3_PORT}} & opl32_data) ;

	dcm dcm_system 
	(
		.inclk0(CLK_50MHZ), 
		.c0(clk_25), 
		.c2(sdr_CLK_out),
		.c3(CLK44100x256),
		.c4(CLK14745600),
		.locked(clk_sys_locked)
    );
    assign clk_sdr = CLK_50MHZ; 
	
    reg [3:0] fifo_rst_cnt = 4'd15;
    reg       fifo_rst     = 1'b1;
    always @(posedge CLK_50MHZ) begin
        if (!clk_sys_locked) begin
            fifo_rst_cnt <= 4'd15;
            fifo_rst     <= 1'b1;
        end else if (fifo_rst_cnt > 0) begin
            fifo_rst_cnt <= fifo_rst_cnt - 1'b1;
            fifo_rst     <= 1'b1;
        end else begin
            fifo_rst     <= 1'b0;
        end
    end

	dcm_cpu dcm_cpu_inst
	(
		.inclk0(CLK_50MHZ), 
		.c0(clk_cpu),
		.c1(clk_dsp),
		.locked(clk_cpu_locked)
	);

	fifo vga_fifo 
	(
	  .wrclk(clk_sdr), 
	  .rdclk(clk_25), 
	  .data(sys_DOUT), 
	  //.wrreq(!crw && sys_rd_data_valid), 
	  .wrreq(!crw && sys_rd_data_valid && !col_counter[4]),
	  .rdreq(vrden), 
	  .q(fifo_dout32), 
	  .wrusedw(fifo_wr_used_words),
	  .rst(fifo_rst)
	);

	VGA_SG VGA 
	(
		.tc_hsblnk(10'd639), 
		.tc_hssync(10'd655 + 10'd17), 
		.tc_hesync(10'd751 + 10'd17), 
		.tc_heblnk(10'd799), 
		.hcount(hcount), 
		.hsync(VGA_HSYNC), 
		.hblnk(hblnk), 
		.tc_vsblnk(v240[2] ? 10'd479 : 10'd399), 
		.tc_vssync(v240[2] ? 10'd489 : 10'd411), 
		.tc_vesync(v240[2] ? 10'd491 : 10'd413), 
		.tc_veblnk(v240[2] ? 10'd520 : 10'd446), 
		.vcount(vcount), 
		.vsync(VGA_VSYNC), 
		.vblnk(vblnk), 
		.clk(clk_25),
		.ce(FifoStart)
	);
	
	VGA_DAC dac 
	(
		 .CE(VGA_DAC_OE && IORQ && CPU_CE), 
		 .WR(WR), 
		 .addr(PORT_ADDR[3:0]), 
		 .din(CPU_DOUT[7:0]), 
		 .dout(VGA_DAC_DATA), 
		 .CLK(clk_cpu), 
		 .VGA_CLK(clk_25), 
		 .vga_addr((vgatext[1] | (~vga13[1] & planar[1])) ? VGA_INDEX : (vga13[1] ? hcount_pan[1] : hcount_pan[0]) ? fifo_dout[15:8] : fifo_dout[7:0]), 
		 .color(DAC_COLOR),
		 .vgatext(vgatextreq),
		 .vga13(vga13req),
		 .half(halfreq),
		 .vgaflash(vgaflash),
		 .setindex(INPUT_STATUS_OE && IORQ && CPU_CE),
		 .hrzpan(vga_hrzpan_req),
		 .ppm(ppm),
		 .ega_attr(EGA_MUX),
		 .ega_pal_index(VGA_INDEX)
    );
	 
	 VGA_CRT crt
	 (
		.CE(IORQ && CPU_CE && VGA_CRT_OE),
		.WR(WR),
		.WORD(WORD),
		.din(CPU_DOUT),
		.addr(PORT_ADDR[0]),
		.dout(VGA_CRT_DATA),
		.CLK(clk_cpu),
		.oncursor(oncursor),
		.cursorstart(crs[0]),
		.cursorend(crs[1]),
		.cursorpos(cursorpos),
		.scraddr(scraddr),
		.offset(vga_offset),
		.lcr(lcr),
		.repln(replnreq),
		.vde(vde)
	);
	
	VGA_SC sc
	(
		.CE(IORQ && CPU_CE && VGA_SC),
		.WR(WR),
		.WORD(WORD),
		.din(CPU_DOUT),
		.dout(VGA_SC_DATA),
		.addr(PORT_ADDR[0]),
		.CLK(clk_cpu),
		.planarreq(planarreq),
		.wplane(vga_wplane)
    );

	VGA_GC gc
	(
		.CE(IORQ && CPU_CE && VGA_GC),
		.WR(WR),
		.WORD(WORD),
		.din(CPU_DOUT),
		.addr(PORT_ADDR[0]),
		.CLK(clk_cpu),
		.rplane(vga_rplane),
		.bitmask(vga_bitmask),
		.rwmode(vga_rwmode),
		.setres(vga_setres),
		.enable_setres(vga_enable_setres),
		.logop(vga_logop),
		.color_compare(vga_color_compare),
		.color_dont_care(vga_color_dont_care),
		.rotate_count(vga_rotate_count),
		.dout(VGA_GC_DATA)
	);


	sr_font VGA_FONT 
	(
		.clock_a(clk_25), 
		.wren_a(1'b0), 
		.address_a({fifo_dout[7:0], char_ln}), 
		.data_a(8'h00), 
		.q_a(font_dout), 
		.clock_b(clk_cpu), 
		.wren_b(WR & IORQ & VGA_FONT_OE & ~WORD & CPU_CE), 
		.address_b(vga_font_counter), 
		.data_b(CPU_DOUT[7:0]), 
		.q_b(VGA_FONT_DATA) 
	);

		cache_controller cache_ctl 
	(
		 .addr(ADDR), 
		 .dout(DRAM_dout), 
		 .clk(clk_cpu), 
		 .mreq(MREQ), 
		 .wmask(RAM_WMASK),
		 .ce(CE), 
		 .ddr_din(sys_DOUT), 
		 .ddr_dout(cntrl0_user_input_data), 
		 .ddr_clk(clk_sdr), 
		 .ddr_rd(ddr_rd), 
		 .ddr_wr(ddr_wr),
		 .hiaddr(cache_hi_addr),
		 .cache_write_data((sys_cmd_ack == 2'b11) && sys_rd_data_valid), // 91st fix: gate the fill on the burst the DDR FSM actually took. ram_rd_valid is shared by BOTH read commands (2'b10 = VGA scan-out, 2'b11 = cache fill), so the ungated form let a VGA burst drive the fill's lowaddr AND write VGA data straight into the cache line. The write-back side was never affected: ram_wr_valid is only high for cmd 2'b01.
		 .cache_read_data(sys_wr_data_valid),  // ★ 三十一次修复：去掉 crw——crw 反映“最近一条 DDR 命令”，VGA 行读会把它清 0 → 写回 beat 丢失、BRAM 未使能→写出旧值。现改用 ram_wr_valid（仅写回 burst 时高）
		 .flush(auto_flush == 3'b110),
		 .cache_line_start(cache_line_start),
		 .din(DOUT)
	);

	wire I_KB;
	wire I_MOUSE;
	wire KB_RST;
	KB_Mouse_8042 KB_Mouse 
	(
		 .CS(IORQ && CPU_CE && KB_OE), 
		 .WR(WR), 
		 .cmd(PORT_ADDR[2]), 
		 .din(CPU_DOUT[7:0]), 
		 .dout(KB_DOUT), 
		 .clk(clk_cpu), 
		 .I_KB(I_KB), 
		 .I_MOUSE(I_MOUSE), 
		 .CPU_RST(KB_RST), 
		 .PS2_CLK1(PS2_CLK1), 
		 .PS2_CLK2(PS2_CLK2), 
		 .PS2_DATA1(PS2_DATA1), 
		 .PS2_DATA2(PS2_DATA2)
	);
	
	wire [7:0]PIC_IVECT;
	wire INT;
	wire timer_int;
	wire I_COM1;
	PIC_8259 PIC 
	(
		 .CS(PIC_OE && IORQ && CPU_CE), 
		 .WR(WR), 
		 .din(CPU_DOUT[7:0]), 
		 .slave(PORT_ADDR[7]),
		 .dout(PIC_DOUT), 
		 .ivect(PIC_IVECT), 
		 .clk(clk_cpu), 
		 .INT(INT), 
		 .IACK(INTA & CPU_CE), 
		 .I({I_COM1, I_MOUSE, RTCEND, I_KB, timer_int})
    );

	wire [3:0]seg_addr;
	wire vga_planar_seg;

	// ★★★ 98th CPU-side probes（2026-09-27）：定位"CPU 跑飞"卡在哪。
	//   全部在 clk_cpu 域**边沿锁存**（事件后值长期稳定 ⇒ clk_sdr 域采样安全，
	//   规避多比特跨域采样失真；符合"加探针前先确认采样无缺陷"的规矩）。
	//   · dbg_cpu_laddr = 最近一次 MREQ 的地址（取指/取数）—— 等价于"卡住的 IADDR"证据
	//   · dbg_cpu_lport = 最近一次 IORQ 的端口 —— "卡在哪个 Port"
	//   · dbg_cpu_lwr / dbg_cpu_pwr = 该次访问是读还是写
	//   · dbg_cpu_halt / dbg_cpu_ce = CPU 是否 HALT / 是否在跑
	//   · dbg_cpu_ios = IORQ 上升沿计数（饱和）—— 判断"在空转等 I/O"还是"真的死了"
	 reg [20:0] dbg_cpu_laddr = 21'h0;
	 reg        dbg_cpu_lwr   = 1'b0;
	 reg [15:0] dbg_cpu_lport = 16'h0;
	 reg        dbg_cpu_pwr   = 1'b0;
	 reg        dbg_cpu_halt  = 1'b0;
	 reg        dbg_cpu_ce    = 1'b0;
	 reg [7:0]  dbg_cpu_ios   = 8'h00;
	reg iorq_d98 = 1'b0;

	// ★★★ 98th-FONT probes（2026-09-27）：回答"字模 RAM 是否被重写、写成了什么"。
	//   事实基础：sr_font 由 font8x16.mem 预初始化（标准 8x16 字库）；
	//   BIOS 写端口 0x3CB 才可能改动它（字写=设地址{vga_font_counter}、字节写=顺序填+写使能）。
	//   全部在 clk_cpu 域**事件锁存/计数**（写事件后长期稳定 ⇒ clk_sdr 采样安全）。
	 reg [5:0]  dbg_font_wr_n = 6'd0;
	 reg [11:0] dbg_font_addr = 12'h000;
	 reg [7:0]  dbg_font_data = 8'h00;
	always @(posedge clk_cpu) begin
		if (IORQ & CPU_CE & VGA_FONT_OE) begin
			if (WR & ~WORD && !dbg_font_wr_n[5]) dbg_font_wr_n <= dbg_font_wr_n + 1'b1;
			dbg_font_addr <= vga_font_counter;
			dbg_font_data <= CPU_DOUT[7:0];
		end
	end

	// ★★★ 98th VGA-mode probes（2026-09-27）：回答"是不是切了显示模式 / 改了显存起始地址"。
	//   现象：屏幕先显示 "Searching BIOS..." 后变乱码，而**文本 VRAM 原封未动**
	//   ⇒ 典型"显示侧模式/起点被改"的签名（显示内容与 VRAM 内容脱钩）。
	//   scraddr = CRT 起始地址；vgatext/vga13/planar/half = 文本/图形/平面/半行 模式位
	//   （[0]=当前生效，[1]=待生效）。全部准静态（只在切模式时变）⇒ clk_sdr 采样安全。
	(* mark_debug = "true", keep = "true" *) reg [15:0] dbg_vga_scraddr = 16'h0;   // ★144th 加回：验证"上下对调 = 控制台滚屏(scraddr≠0)"这一假设
	 reg [1:0]  dbg_vga_text    = 2'b00;
	 reg [1:0]  dbg_vga_13      = 2'b00;
	 reg [1:0]  dbg_vga_planar  = 2'b00;
	 reg [1:0]  dbg_vga_half    = 2'b00;
	// ★140th 新增探针（纯观测，不改逻辑）：定位"半屏上下对调"的行序问题。
	//   dbg_vga_lcr    = 行比较寄存器（L268）——若它被 BIOS 设成半屏位置，
	//                    则 L1088 `row_count == lcr` 会在帧中途把行地址拉回 ROWCOL。
	//   dbg_vga_rowcol = 帧内真实行地址（L141, 17bit）——直接看基址与推进。
	//   dbg_vga_rowcnt = 扫描行计数器（L198, 9bit）——与 rowcol 配对，
	//                    即可还原"第 k 条扫描行读到哪一行"，一眼看出行序是否被重排。
	 reg [9:0]  dbg_vga_lcr     = 10'h0;
	 reg [16:0] dbg_vga_rowcol  = 17'h0;
	(* mark_debug = "true", keep = "true" *) reg [8:0]  dbg_vga_rowcnt  = 9'h0;
	// ★142nd 再加两个（纯观测）：把"取指侧"与"显示侧"直接对齐比较。
	//   dbg_vga_vcount  = 显示侧垂直计数（L76, 10bit）
	//   dbg_vga_charrow = 显示侧正在扫的字符行（L192 char_row, 6bit）
	//   取指侧字符行 = dbg_vga_rowcnt/16。两者之差 = 屏幕相位错位量（"上下对调"的根因候选）。
	(* mark_debug = "true", keep = "true" *) reg [9:0]  dbg_vga_vcount  = 10'h0;
	(* mark_debug = "true", keep = "true" *) reg [5:0]  dbg_vga_charrow = 6'h0;
	always @(posedge clk_sdr) begin
		dbg_vga_scraddr <= scraddr;
		dbg_vga_text    <= vgatext[1:0];
		dbg_vga_13      <= vga13[1:0];
		dbg_vga_planar  <= planar[1:0];
		dbg_vga_half    <= half[1:0];
		dbg_vga_lcr     <= lcr;
		dbg_vga_rowcol  <= vga_ddr_row_col;
		dbg_vga_rowcnt  <= vga_ddr_row_count;
		dbg_vga_vcount  <= vcount;
		dbg_vga_charrow <= char_row;
	end
	always @(posedge clk_cpu) begin
		if (MREQ) begin dbg_cpu_laddr <= ADDR; dbg_cpu_lwr <= WR; end
		if (IORQ) begin dbg_cpu_lport <= PORT_ADDR; dbg_cpu_pwr <= WR; end
		iorq_d98 <= IORQ;
		if (IORQ && !iorq_d98 && !dbg_cpu_ios[7]) dbg_cpu_ios <= dbg_cpu_ios + 1'b1;
		dbg_cpu_halt <= HALT;
		dbg_cpu_ce   <= CPU_CE;
	end
	
    // 【核心修复】：彻底移除所有的 is_bios 拦截逻辑，恢复纯净的原作者连线
	unit186 CPUUnit
	(
		 .INPORT(INTA ? {8'h00, PIC_IVECT} : PORT_IN), 
		 .DIN(DRAM_dout),   // <--- 这里直接吃入 DRAM_dout 
		 .CPU_DOUT(CPU_DOUT),
		 .PORT_ADDR(PORT_ADDR),
		 .SEG_ADDR(seg_addr),
		 .DOUT(DOUT), 
		 .ADDR(ADDR), 
		 .WMASK(RAM_WMASK), 
		 .CLK(clk_cpu), 
		 .CE(CE), 
		 .CPU_CE(CPU_CE),
		 .CE_186(CE_186),
		 .INTR(INT), 
		 .NMI(rNMI[9] || (CPU_CE && IORQ && PORT_ADDR >= NMIonIORQ_LO && PORT_ADDR <= NMIonIORQ_HI)), 
		 .RST(!rstcount[18]), 
		 .INTA(INTA), 
		 .LOCK(LOCK), 
		 .HALT(HALT), 
		 .MREQ(MREQ),
		 .IORQ(IORQ),
		 .WR(WR),
		 .WORD(WORD),
		 .FASTIO(1'b1),
		 .VGA_SEL(planarreq && vga_planar_seg),
		 .VGA_WPLANE(vga_wplane),
		 .VGA_RPLANE(vga_rplane),
		 .VGA_BITMASK(vga_bitmask),
		 .VGA_RWMODE(vga_rwmode),
		 .VGA_SETRES(vga_setres),
		 .VGA_ENABLE_SETRES(vga_enable_setres),
		 .VGA_LOGOP(vga_logop),
		 .VGA_COLOR_COMPARE(vga_color_compare),
		 .VGA_COLOR_DONT_CARE(vga_color_dont_care),
		 .VGA_ROTATE_COUNT(vga_rotate_count)
		 //.CPU_WDATA_OUT(cpu_wdata_latch)
	);

	seg_map seg_mapper 
	(
		 .CLK(clk_cpu), 
		 .cpuaddr(PORT_ADDR[3:0]), 
		 .cpurdata(memmap), 
		 .cpuwdata(CPU_DOUT[8:0]), 
		 .memaddr(cache_hi_addr[14:10]), 
		 .memdata(memmap_mux), 
		 .WE(MEMORY_MAP & WR & WORD & IORQ & CPU_CE),
		 .seg_addr(seg_addr),
		 .vga_planar_seg(vga_planar_seg)
    );

	 wire timer_spk;
	 timer_8253 timer 
	 (
		 .CS(TIMER_OE && IORQ && CPU_CE), 
		 .WR(WR), 
		 .addr(PORT_ADDR[1:0]), 
		 .din(CPU_DOUT[7:0]), 
		 .dout(TIMER_DOUT), 
		 .CLK_25(clk_cpu), 
		 .clk(clk_cpu), 
		 .out0(timer_int), 
		 .out2(timer_spk)
    );
	 
	 soundwave sound_gen
	 (
		.CLK(clk_cpu),
		.CLK44100x256(CLK44100x256),
		.data(CPU_DOUT),
		.we(IORQ & CPU_CE & WR & PARALLEL_PORT),
		.word(WORD),
		.speaker(speaker_on & timer_spk),
		.opl3left(opl3left),
      .opl3right(opl3right),
      .stb44100(stb44100),
		.full(sq_full),
		.dss_full(dss_full),
		.midi_left(midi_left),
		.midi_right(midi_right),
		.AUDIO_L(AUD_L),
		.AUDIO_R(AUD_R),
		.CLK_I2S(CLK_50MHZ),
		.I2S_MCLK(I2S_MCLK),
		.I2S_SCLK(I2S_SCLK),
		.I2S_LRCLK(I2S_LRCLK),
		.I2S_SDIN(I2S_SDIN)
	);
	 
	DSP32 DSP32_inst
	(
		.clkcpu(clk_cpu),
		.clkdsp(clk_dsp),
		.cmd(PORT_ADDR[0]), 
		.ce(IORQ & CPU_CE & CPU32_PORT & WORD),
		.wr(WR),
		.din(CPU_DOUT),
		.dout(cpu32_data),
		.halt(cpu32_halt)
	);
	
	UART_8250 UART(
		.CLK_18432000(CLK14745600),
		.RS232_DCE_RXD(RX),
		.RS232_DCE_TXD(TX),
		.clk(clk_cpu),
		.din(CPU_DOUT[7:0]),
		.dout(COM1_DOUT),
		.cs(COM1_PORT && IORQ && CPU_CE),
		.wr(WR),
		.addr(PORT_ADDR[2:0]),
		.BRShift(COMBRShift),
		.INT(I_COM1)
    );
    
    opl3 opl3_inst (
        .clk(CLK_50MHZ), 
        .cpu_clk(clk_cpu),
        .addr(PORT_ADDR[1:0]),
        .din(CPU_DOUT[7:0]),
        .dout(opl32_data),
        .ce(IORQ & CPU_CE & OPL3_PORT),
        .wr(WR),
        .left(opl3left),
        .right(opl3right),
        .stb44100(stb44100),
        .reset(!rstcount[18])    
     );

	mpu401 midi(
		.clk_cpu(clk_cpu),
		.clk_sys(clk_25),
		.reset(!rstcount[18]),
		.cs(MPU401_OE && IORQ && CPU_CE),
		.wr(WR),
		.addr(PORT_ADDR[0]),
		.din(CPU_DOUT[7:0]),
		.dout(MPU401_DOUT),
		.midi_out(MIDI_OUT)
	);

	i2s_decoder i2s_midi (
		.clk(clk_25),
		.sck(CLKBD),
		.ws(WSBD),
		.sd(DABD),
		.left_out(midi_left),
		.right_out(midi_right)
	);
	
	i2c_master_byte i2cmb
	(
		.refclk(clk_25),
		.din(i2c_cd[7:0]),
		.cmd(i2c_cd[11:8]),
		.dout(i2cdout),
		.ack(i2cack),
		.noack(i2cackerr),
		.SCL(I2C_SCL),
		.SDA(I2C_SDA),
		.rst(1'b0)
	);
	
    reg [1:0] sys_cmd_ack_d1 = 2'b00;

	always @ (posedge clk_sdr) begin
        sys_cmd_ack_d1 <= sys_cmd_ack;

// v6: page the DDR FSM actually consumed (sdraddr delayed 2 clk_sdr).
//   sdraddr(k) = f(hiaddr(k-1)); the FSM samples sdraddr(k-1) at edge k.
dbg_pg_d1 <= sdraddr[23:15];
dbg_ad_d1 <= sdraddr[14:5];

		// ★ Task #8 修复：当 DDR 命令确认跳变为 cache 行读(2'b11 填充)/写(2'b01 写回)时，产生单周期脉冲。
		//   该脉冲送入 cache_controller，在开始一行 cache 事务时把 lowaddr 强制归零，
		//   避免残留行内偏移造成半行(0x20)错位。VGA 读(2'b10)与空闲不产生脉冲。
		cache_line_start <= (sys_cmd_ack != 2'b00) && (sys_cmd_ack_d1 == 2'b00) &&
		                    ((sys_cmd_ack == 2'b01) || (sys_cmd_ack == 2'b11));

		s_prog_full <= fifo_wr_used_words > 350; 


		if(fifo_wr_used_words < 64) s_prog_empty <= 1'b1; 
		else begin
			s_prog_empty <= 1'b0;
			FifoStart <= 1'b1;
		end

		s_ddr_rd <= ddr_rd;
		s_ddr_wr <= ddr_wr;
		s_vga_endline <= vga_repln_count == vga_repln;
		s_vga_endframe <= vga_end_frame;
		// ★★ 95th 修复：请求被服务后立即释放命令线。
		//   cache_line_start 正是“FSM 确认了 cache 行读(2'b11)/写(2'b01)”的那个单周期脉冲
		//   （见上方 885 行），所以它天然就是“已服务”事件。
		//   清零条件取“cache 完全无请求”：只有此时才能确定上一条事务已结束。
		//   （cache 在 STATE 011/111 里只能靠 ram_wr_valid/ram_rd_valid 推进，
		//    所以 ddr_wr/ddr_rd 不可能在 FSM 服务之前自行拉低；不会丢事务。）
		if(!ddr_wr && !ddr_rd)    cache_cmd_done <= 1'b0;
		else if(cache_line_start) cache_cmd_done <= 1'b1;
		
		// ★★ 95th 修复：地址使能与命令同源（cache_owns），
		//   保证 FSM 采样瞬间“命令”与“地址”不会错配
		//   （原来两者分别取自 s_ddr_wr||s_ddr_rd 和实时 cache_hi_addr，存在错配窗口）。
		//sdraddr <= s_prog_empty || !cache_owns ? 
		//    {5'b00001, vga_ddr_row_col + vga_lnbytecount - 9'd448, 1'b0} :   // ★152nd 只改 k（相位补偿），末位 1'b0 严格不动（用户确认：1'b0 才是消除水平偏移的那一位）。旋转 11 整行：实测"顶部=fb row11"+"底部7行=fb row0-6"(回绕30行) ⇒ 30-19=11 行 ⇒ Δk=440(880字符=11行=40倍数, 无水平分量) ⇒ k=8+440=448
		//    {memmap_mux[8:0], cache_hi_addr[9:0], 5'b00000};
		//max_read <= &sdraddr[7:3] ? ~sdraddr[2:0] : 3'b111;	
		
	    // ★★ 95th 修复：地址使能与命令同源（cache_owns），
		//   保证 FSM 采样瞬间"命令"与"地址"不会错配
		//   （原来两者分别取自 s_ddr_wr||s_ddr_rd 和实时 cache_hi_addr，存在错配窗口）。
		sdraddr <= s_prog_empty || !cache_owns ? 
		    {5'b00001, vga_ddr_row_col + vga_lnbytecount - 5'd8, 1'b1} :   // ★149th 回退到"稳定上下对调"基线（148th 的 -9'd480 实测反而引入水平偏移+下半屏垃圾）
		    {memmap_mux[8:0], cache_hi_addr[9:0], 5'b00000};
		max_read <= &sdraddr[7:3] ? ~sdraddr[2:0] : 3'b111;	
			
		// ★★★ 95th 修复（2026-09-26）：一条 cache 事务只允许一次 AXI burst。
		//
		//   根因（sim/tb/ddr_pipe.v 逐拍日志实测，gate_fill=1）：
		//     ddr_wr / ddr_rd 是**电平**，覆盖整条 cache 事务（实测 144 个 clk_sdr），
		//     而 top_zynq7010 的一次 16 拍 burst 只要 ~80 个 clk_sdr，之后还有 6 拍 IDLE 采样窗口。
		//     于是 FSM 在**同一条事务内**就回到 IDLE，重新采样本寄存器
		//     （此时 s_ddr_wr 仍为 1）⇒ 再发一次完整的 16 拍 burst。
		//   对写回是致命的：ram_wdata 取自 cache 的 ddr_dout，而 wb_pcnt 在 ddr_wr=0 时被清零
		//     （cache_controller.v:358）。此时 cache 已离开 STATE 011 ⇒ wb_pcnt==0 ⇒
		//     16 拍全发 word0，把刚写回正确的那一行覆盖成“word0 重复”。
		//   实测证据（cyc 36717 → 36804，SD 缓冲行 0）：
		//     36717 AW cmd=01 byte=08150000 cst=3 ddrwr=1  ← 正确写回
		//     36803 IDLE ic=5 ack=00 cmd=01 dwr=0          ← FSM 采样到残留命令
		//     36804 AW cmd=10 byte=08150000 cst=7 ddrwr=0  ← 多发的伪 burst，16 拍全 word0
		//   16 个缓冲行**行行如此**：48 次 AW 中 16 次是伪 burst。
		//   端到端判据：自测读回整个 1KB 缓冲区，
		//     旧逻辑 960/1024 字节错，95th 修复后 0/1024。
		//
		//   修法：cache 一条事务只需要一次 burst。cache_cmd_done 在 FSM 确认（cache_line_start）
		//   后置位，使 cache_owns 拉低⇒命令线立即释放；此时 FSM 还在 burst 中，
		//   到它下一个 IDLE 采样窗口时 cmd 已经是 2'b10（或 2'b00）。
		//   命令类型与地址仍取**实时** s_ddr_wr/s_ddr_rd 与 cache_hi_addr（不锁存）：
		//   若锁存，则 VGA 抢占把 FSM 拖过请求尾巴后会把写回当成填充发，
		//   cache 会在 STATE 011 等一个永远不会来的 ram_wr_valid → 死锁。
		if(s_prog_empty) cntrl0_user_command_register <= 2'b10;
		else if(cache_owns) cntrl0_user_command_register <= ddr_wr ? 2'b01 : 2'b11;  // 96th: real-time (was s_ddr_wr, 1 cycle stale)
		else if(~s_prog_full) cntrl0_user_command_register <= 2'b10;
		else cntrl0_user_command_register <= 2'b00;
					
		if(!crw && sys_rd_data_valid) col_counter <= col_counter - 1'b1;
		
        if (sys_cmd_ack != 2'b00 && sys_cmd_ack_d1 == 2'b00) begin
            case(sys_cmd_ack)
                2'b10: begin
                    crw <= 1'b0;	
                    col_counter <= {1'b0, max_read, 1'b1};
                    // ★ 已回退（2026-09-27）：曾把步进改成 2*(max_read+1)，但 `vga_lnbytecount`
                    //   同时是「扫描行长度判据」的计数器（见 :1064 `s_vga_endscanline <=
                    //   (vga_lnbytecount[7:3] == vga_lnend)`，文本模式 vga_lnend=6）。步进翻倍后
                    //   [7:3] 跳着走（偶数）⇒ 行结束判据提前一半触发
                    //   ⇒ 行/帧指针跑得比实际扫描快 ⇒ **画面全黑**。
                    //   正确方向：保持本行语义不变，改为限制 FIFO 每事务接受量 = max_read+1 个半字（待验证）。
                    vga_lnbytecount <= vga_lnbytecount + max_read + 1'b1;
                end					
                2'b01, 2'b11: crw <= 1'b1;		
            endcase
        end
				
		if(s_vga_endscanline) begin
			col_counter[3:1] <= col_counter[3:1] - vga_lnbytecount[2:0];
			vga_lnbytecount <= 0;
			s_vga_endscanline <= 1'b0;

			// ★★ VGA 文本基址移植修复（2026-09-27）：
			//   移植时只把"初值(行141, 来源 localparam 139-140)"和"lcr 换行(行1060)"从作者的
			//   0xe000 改成了端口的 0x14000，却漏改了 endframe 复位这行公式。文本偏移 7 → 0xe000
			//   (作者页，错)，改成 10 → 10*0x2000 = 0x14000(端口帧缓冲页，对，=DDR 0x08068000)。
			//   scraddr=0 时：{1'b0,scraddr[15:13]}=0，故 vga_ddr_row_col = offset<<13。
			//   非文本分支取 VGA_GRAPH_ROWCOL[16:13]（128th 后回到作者值 0x8000[16:13]=4'b0100），与行1063 非文本一致。
			//   现三处统一引用 VGA_TEXT_ROWCOL / VGA_GRAPH_ROWCOL，端口化只需改这两个 localparam。
			if(s_vga_endframe) vga_ddr_row_col <= {{1'b0, scraddr[15:13]} + (vgatext[0] ? VGA_TEXT_ROWCOL[16:13] : VGA_GRAPH_ROWCOL[16:13]), scraddr[12:0]};
			else if({1'b0, vga_ddr_row_count} == lcr) vga_ddr_row_col <= vgatext[0] ? VGA_TEXT_ROWCOL : VGA_GRAPH_ROWCOL; 
				 else if(s_vga_endline) vga_ddr_row_col <= vga_ddr_row_col + (vgatext[0] ? 40 : {vga_offset, 1'b0});   // 146th 钳位已回退（回到"上下颠倒"基线）
			
			if(s_vga_endline) vga_repln_count <= 0;
			else vga_repln_count <= vga_repln_count + 1'b1;
			if(s_vga_endframe) begin
				vga13[0] <= vga13req;
				vgatext[0] <= vgatextreq;
			// ★★ 137th：**显示模式锁死 640x480 60Hz**（本机显示器不支持 400 行/70Hz）。
			//    135th 曾改成作者原逻辑 `vde >= 10'd400` ⇒ 实际落到 400 行 ⇒ 显示器不同步 ⇒ **黑屏**。
			//    故这里恢复硬编码 1，把 v240[0] 锁死为 1 ⇒ v240[2]=1 ⇒
			//    tc_vsblnk 479 / tc_vssync 489 / tc_vesync 491 / tc_veblnk 520（即 640x480）。
			//    由此带来的"30 字符行 vs 25 行文本页(4000B)"越界，改由行推进钳位解决：
			//    （137th 的行推进钳位已撤回：用户实测确认版本A(`-5'd8`)本就无乱码，钳位会干扰环形滚屏。）
				v240[0] <= 1'b1;
				planar[0] <= planarreq;
				half[0] <= halfreq;
				repln_graph[0] <= replnreq;
				vga_ddr_row_count <= 0;
			end else vga_ddr_row_count <= vga_ddr_row_count + 1'b1; 
		end else s_vga_endscanline <= (vga_lnbytecount[7:3] == vga_lnend);
	end
	
	// ============================================================================
	// ★★ [86th probe, 2026-09-26] Does a write-back / fill of an SD-data-buffer line
	//    (tag 0x1E0 = maddr 0xF0000..0xF1FFF, 186 page 15) ever reach the DDR controller?
	//    Built ONLY from cache_controller's module-boundary ports (ddr_wr / ddr_rd / hiaddr),
	//    so nothing is placed inside the CPU core or inside the cache.
	//      dbg_bufwb_n = cache -> DDR write-back bursts for a buffer line (saturating)
	//      dbg_bufrd_n = DDR -> cache fill bursts  for a buffer line (saturating)
	//      dbg_bufwb_a = hiaddr of the LAST buffer-line write-back ({tag,index})
	//    Self test v3 (change 85) fills 2 KB at F000:0000, waits about 2 VGA frames so the
	//    per-frame flush can write the dirty lines back, then evicts with scan256 and reads
	//    offset 0x40 - it comes back 0x00 although the control sum 0xFC00 proves the data was
	//    correctly in the cache.  So either no write-back ever happened for these lines
	//    (dbg_bufwb_n == 0) or one did and its address/data is wrong (dbg_bufwb_n != 0).
	// ============================================================================
	// ★ 97b：写回"数据↔地址"一致性计数 —— 自测图案里缓冲行 k 的首字高半字节 = k&0xF，
	//   而 cq_addr[3:0] = victim 的 index[3:0] —— 两者不等 ⇒ 有写回把别行的数据写进了本地址
	//   （错位写回的直接实锤）。仅统计缓冲行（dbg_buf_line），全速累计不冻结（同 pmis）。
	 reg [5:0]  dbg_wmis  = 6'h00;
	// v7: the FULL line address ({tag[4:0], index}) the DDR FSM consumed.
	//   v6 proved the PAGE is never stale (pmis=0), but pmis only sees bits [23:15].
	//   A hiaddr change inside the sampling window that stays within the SAME page
	//   (buffer lines thrashing among themselves) is invisible to pmis yet makes the
	//   fill read another buffer line's address = the observed "+N lines" shift.
	 reg [9:0] dbg_fill_addr = 10'h000;
	 reg [9:0] dbg_wb_addr   = 10'h000;
	// ★★★ [v5 probe, 2026-09-27] fill integrity (line 2).
	//   v4b captured fill data with `dbg_fill_arm && sys_rd_data_valid`, which
	//   also fires for VGA reads -> the board reading nib=0 was not usable.
	//   These five are gated on the fill's OWN burst (sys_cmd_ack == 2'b11).
	//   Expect (pattern byte@m=(m>>2)&0xFF): w0=0x2020 wl=0x2F2F n=32 x=0 full=1
	// v5 window scratch (not probes)
	// v6 (rework): write-back integrity + the page the DDR FSM actually used.
	 reg [15:0] dbg_wb_wl    = 16'h0000;
	 reg [8:0]  dbg_fill_page = 9'h000;
	 reg [8:0]  dbg_wb_page   = 9'h000;
	reg [8:0]  dbg_pg_d1 = 9'h000;   // sdraddr[23:15] delayed 1 clk_sdr
	reg [8:0]  dbg_fill_page_live = 9'h000;
	reg [8:0]  dbg_wb_page_live   = 9'h000;
	reg        dbg_bw_act = 1'b0;
	reg [5:0]  dbg_bw_n   = 6'd0;
	reg [15:0] dbg_bw_wl  = 16'd0;

	// ** [91st probe, 2026-09-26] Mechanism check for the 91st fix: did a NON-cache read burst
	//    (VGA scan-out, cmd 2'b10) ever deliver data while the cache's fill read was pending
	//    (ddr_rd = 1)?  Before the fix such a burst drove the fill's lowaddr and wrote VGA
	//    pixels straight into the cache line.  Built only from ddr_186.v's own clk_sdr signals.

	// ★★★ [95th probe, 2026-09-26] 直接数“FSM 接受了 cache 并没在请求的 burst”。
	//   判据取 sys_cmd_ack 的**上升沿**（= FSM 刚接受一条命令的那一刻），问一句
	//   “cache 这一拍到底在请求什么？”：
	//     dbg_spur_wb_n : ack 升到 2'b01（写 burst）但 ddr_wr==0  → 伪写回 burst
	//     dbg_spur_rd_n : ack 升到 2'b11（填充 burst）但 ddr_rd==0 → 伪填充 burst
	//   95th 修复前：每条 cache 事务各多一次（台架实测 WB=16 / RD=92）；
	//   95th 修复后必须**恒 0**（台架实测 WB=0 / RD=0）。
	//   只用 cache_controller 的**模块边界端口**（sys_cmd_ack / ddr_wr / ddr_rd），
	//   不往 cache 或 CPU 内部放任何东西。
	//   ★ 94th 的 5 个高位半字节 OR 探针已删除：SD 驱动会把真实 SD 数据
	//     （含 0xF? 字节）写进**同一个** F000:0000 缓冲区，所以 cpu/wb/rd
	//     三个 OR 一律饱和到 4'hF，零信息量（板上实测 cpu=f wb=f rd=f）。
	//     腾出的 20 bit 预算给本探针（16 bit）。
	// 95th probe v4 scratch (not probes themselves)
	reg        dbg_fill_arm = 1'b0;
	reg        dbg_wb_arm   = 1'b0;
	reg        dbg_wb_pcnt  = 1'b0;
	reg [4:0]  dbg_fill_idx = 5'd0;
	reg [4:0]  dbg_wb_idx   = 5'd0;
	reg [14:0] dbg_bufwb_a_live = 15'd0;
	reg [9:0]  dbg_ad_d1 = 10'd0;   // sdraddr[14:5] delayed 1 clk_sdr
	reg [9:0]  dbg_fill_addr_live = 10'd0;
	reg [9:0]  dbg_wb_addr_live   = 10'd0;
	reg        dbg_wm_act  = 1'b0;
	reg        dbg_wm_first = 1'b0;
	reg        dbg_wm_run  = 1'b1;   // 97c: 1=e5 之前（自测窗口，不变量成立）
	reg [8:0]  dbg_v4_wb_live = 9'd0;
	reg [8:0]  dbg_v4_rd_live = 9'd0;
	// 0x00E5 write detect + 2-FF sync into clk_sdr (see the freeze comment below)
	reg        e5_wr = 1'b0, e5_s1 = 1'b0, e5_s2 = 1'b0;
	always @(posedge clk_cpu) e5_wr <= IORQ & CPU_CE & WR & (PORT_ADDR[15:0] == 16'h00E5);
	// ★ [90th probe, 2026-09-26] The 89th run showed dbg_rd_addr = 0x000 - CORRECT
	//   (the self test's 1 KB fill starts with WRITE misses, and a write-allocate also
	//    performs a fill, so the first buffer-line fill is line 0, not line 2 as I had
	//    wrongly predicted).  dbg_wb_addr = 0x00F cannot be trusted yet, because it
	//   samples cache_hi_addr AT THE ACK: if the DDR master delays the burst (the VGA
	//   read has priority) the ack can land after hiaddr has moved on to another line.
	//   Add the registers that CANNOT move - hiaddr is maddr all through STATE 111 and
	//   wb_hiaddr is frozen all through STATE 011 - and gate the write sample on
	//   wb_hiaddr[14:5] so the gate itself is skew-free.
	//   dbg_rd_reg / dbg_wb_reg are those registers; dbg_wbr_seen distinguishes a
	//   legitimate 0x000 (buffer line 0) from "never latched".
	 reg [9:0] dbg_rd_reg = 10'h000;
	 reg [9:0] dbg_wb_reg = 10'h000;
	// [87th probe] The 86th run showed dbg_bufwb_n saturating (0xFF) with a plausible
	//   address (0x3C0F = tag 0x1E0 / index 15), so buffer-line write-backs DO reach the DDR
	//   controller - and dbg_bufrd_n read 0, but that probe was WRONG: it used ddr_rd's
	//   rising edge, and ddr_rd rises at STATE 000 while hiaddr still holds the VICTIM's
	//   address, not the address of the line about to be filled.  Replaced by a level-tested
	//   sticky flag.  Now measure the two DATA paths directly:
	//     dbg_wb_or  = OR of the 32-bit write data (ddr_dout / ram_wdata) over every cycle a
	//                  buffer-line write-back is active  -> 0 means the write-back carried
	//                  nothing but zeros (wrong BRAM way/word in the write-back read)
	//     dbg_rd_or  = OR of ram_rdata while the CACHE owns the read (ddr_rd high) for a buffer
	//                  line -> 0 means the DDR never returned any data for a buffer fill, so
	//                  the cache would be filled with zeros
	//     dbg_vga_or = OR of ram_rdata for reads NOT owned by the cache (the VGA scan-out) -
	//                  the known-good control: non-zero proves the DDR read path itself works
	wire dbg_buf_line = (cache_hi_addr[14:5] == 10'h1E0);
	reg dbg_rst_s1 = 1'b0;
	reg dbg_rst_s2 = 1'b0;
	always @(posedge clk_sdr) begin
		dbg_rst_s1 <= BTN_RESET;
		dbg_rst_s2 <= dbg_rst_s1;
		if(dbg_rst_s2) begin               // held at 0 during reset => "this BIOS run only"
			dbg_wmis    <= 6'h00;
			dbg_wb_wl    <= 16'h0000;
			dbg_fill_page <= 9'h000;
			dbg_wb_page   <= 9'h000;
			dbg_bw_act    <= 1'b0;
			dbg_bw_n      <= 6'd0;
			dbg_bw_wl     <= 16'd0;
			dbg_rd_reg     <= 10'h000;
			dbg_wb_reg     <= 10'h000;
		end else begin
			// ★ 97c：wmis 只在 e5 之前计数 —— SD 阶段缓冲区是映像数据，"高半字节==index"
			//   不变量不成立，不门控会把计数器污染到饱和（97b 板上 0x3F 即此，作废）。
			if(e5_s1 && !e5_s2) dbg_wm_run <= 1'b0;
			// ★ 97b：每笔写回的首个数据拍，比对"数据高半字节 vs cq_addr index 低半字节"
			if((sys_cmd_ack == 2'b01) && (sys_cmd_ack_d1 != 2'b01)) begin
				dbg_wm_act  <= 1'b1;
				dbg_wm_first <= 1'b1;
			end else if (dbg_wm_act) begin
				if (sys_wr_data_valid && (sys_cmd_ack == 2'b01)) begin
					if (dbg_wm_first) begin
						dbg_wm_first <= 1'b0;
						if (dbg_buf_line && (cntrl0_user_input_data[7:4] != cq_addr[3:0]) &&
						    (dbg_wmis != 6'h3F))
							dbg_wmis <= dbg_wmis + 1'b1;
					end
				end
				if ((sys_cmd_ack != 2'b01) && !ddr_wr) dbg_wm_act <= 1'b0;
			end
			// （98th：95th 伪 burst 计数器已删除 —— 已验证恒 0，探针预算回收）
			// [90th fix, 2026-09-26] SKEW-FREE: sample at the COMMAND
			//   not at the ack.  Lines 901-911 load both sdraddr (the DDR address) and
			//   cntrl0_user_command_register (01 = write, 11 = read) on the SAME edge, from
			//   s_prog_empty / s_ddr_wr / s_ddr_rd.  Gating on exactly that condition and
			//   latching cache_hi_addr - the .hiaddr() port, i.e. the very signal being muxed
			//   into sdraddr - gives by construction the address the DDR was handed.
			//   NOTE: hiaddr / wb_hiaddr are cache_controller INTERNALS and are NOT visible
			//   in ddr_186.v - that is what broke synthesis with [Synth 8-36].  No extra port
			//   is needed: cache_hi_addr already carries both of them out here (hiaddr = maddr
			//   all through STATE 111, wb_hiaddr frozen all through STATE 011).
			// ★★★ [95th probe v4] 给“写回 / 填充送出的数据”指认它属于哪一行。
			//   v3 已经证明地址通路干净（板上 dbg_rd_reg == dbg_wb_reg）
			//   ⇒ 那个 +0x100 字节（+4 行）位移在**数据侧**。
			//   自测图案 byte@m=(m>>2)&0xFF ⇒ 缓冲行 k 的**任何字**高半字节都 = (k & 0xF)
			//   ⇒ 用高半字节就能直接指认数据来自哪一行。
			//   锁最近一次缓冲行写回 / 填充：
			//     dbg_rd_reg[3:0] = 写回第 2 拍数据的高半字节；[8:4] = 该写回**属于**的行
			//     dbg_wb_reg[3:0] = 填充第 1 拍数据的高半字节；[8:4] = 该填充**属于**的行
			//   判读：低半字节 == (行号 & 0xF) ⇒ 自己的数据；
			//         不等 ⇒ 拿到了**别的行**的数据。
			//   （未新增探针信号 ⇒ 不用重建 Set Up Debug。）
			// 只针对 line 2（自测在 offset 0x80 读的就是这一行）
			if(dbg_buf_line && (cache_hi_addr[4:0] == 5'd2) && (sys_cmd_ack == 2'b11) && (sys_cmd_ack_d1 != 2'b11)) begin
				dbg_fill_arm <= 1'b1;
				dbg_fill_idx <= cache_hi_addr[4:0];
			end else if(dbg_fill_arm && sys_rd_data_valid && (sys_cmd_ack == 2'b11)) begin
				dbg_fill_arm <= 1'b0;
				dbg_v4_wb_live <= {dbg_fill_idx, ram_rdata[7:4]};
			end
			if(dbg_buf_line && (cache_hi_addr[4:0] == 5'd2) && (sys_cmd_ack == 2'b01) && (sys_cmd_ack_d1 != 2'b01)) begin
				dbg_wb_arm  <= 1'b1;
				dbg_wb_idx  <= cache_hi_addr[4:0];
			end else if(dbg_wb_arm && sys_wr_data_valid && (sys_cmd_ack == 2'b01)) begin
				if(dbg_wb_pcnt == 1'b0) dbg_wb_pcnt <= 1'b1;
				else begin
					dbg_wb_pcnt <= 1'b0;
					dbg_wb_arm  <= 1'b0;
					dbg_v4_rd_live <= {dbg_wb_idx, cntrl0_user_input_data[7:4]};
				end
			end
			// （98th：v5 fill-integrity 窗口已删除 —— 其结论已被 8KB 100% 一致取代，探针预算回收）
			// ★★★ [v6, 2026-09-27] write-back integrity + the page the DDR FSM used.
			//   v5: the line-2 fill's own burst is complete (n=32, full=1) and unpolluted (x=0),
			//   yet it returns w0=0x0000 / wl=0x0C00 - not the self-test pattern, not the BIOS.
			//   dbg_rd_reg=0x022 proves a real line-2 AXI write burst carrying line-2 data also
			//   happened.  So either that write landed elsewhere, or the fill read DDR before it
			//   landed.  Both show up in the PAGE the FSM actually consumed (dbg_pg_d1).
			//   dbg_pmis_* counts acks where the used page disagrees with the page implied by the
			//   CURRENT hiaddr (memmap_mux): non-zero => hiaddr was moving when the FSM sampled.
			//   8-bit timestamps were tried first and abandoned: the self-test spans ~84k clk_sdr
			//   cycles, so an 8-bit counter wraps and carries no ordering information.
			if(dbg_bw_act) begin
				if(sys_wr_data_valid && (sys_cmd_ack == 2'b01)) begin
					dbg_bw_wl <= cntrl0_user_input_data;
					if(dbg_bw_n < 6'd63) dbg_bw_n <= dbg_bw_n + 1'b1;
				end
				if((sys_cmd_ack != 2'b01) && !ddr_wr) dbg_bw_act <= 1'b0;
			end else if(dbg_buf_line && (cache_hi_addr[4:0] == 5'd2) &&
			            (sys_cmd_ack == 2'b01) && (sys_cmd_ack_d1 != 2'b01)) begin
				dbg_bw_act <= 1'b1;
				dbg_bw_n   <= 6'd0;
			end
			if((sys_cmd_ack != 2'b00) && (sys_cmd_ack_d1 == 2'b00)) begin
			if(sys_cmd_ack == 2'b11) begin
				// ★ v7b 修复：addr 采集必须与 page 同门控（原来裸放在门外，
				//   捕到的是"冻结前最后一条任意行的填充"—— 板上 0x3FF 就是
				//   最后一次 BIOS 取指行 (tag 0x1FF,index 31)，不是 line 2 的地址！）
				// ★ 97b：探针改接 cq_addr —— 97th 之下 sdraddr 不再是 FSM 消费的地址！
				if(dbg_buf_line && (cache_hi_addr[4:0] == 5'd2)) begin
					dbg_fill_page_live <= cq_addr[23:15];
					dbg_fill_addr_live <= cq_addr[14:5];
				end
				end
			if(sys_cmd_ack == 2'b01) begin
				// ★ v7b：wb 侧同样补门控（板上 0x001 = scan256 最后 victim index 1，
				//   与 dbg_bufwb_a=0x3C01 一致 —— 是"最后一笔任意写回"，不是 line 2 的）
				if(dbg_buf_line && (cache_hi_addr[4:0] == 5'd2)) begin
					dbg_wb_page_live <= cq_addr[23:15];
					dbg_wb_addr_live <= cq_addr[14:5];
				end
				end
			end
			// ★★ 冻结：CPU 写端口 0x00E5（自测上报那一刻）时快照。
			//   自测在启动早期跑，而 SD 阶段会写**同一个**缓冲区（tag 0x1E0）⇒
			//   不冻结就会拿到 SD 阶段的事件（v4 板上读数 0x021/0x020 就是这个原因）。
			e5_s1 <= e5_wr; e5_s2 <= e5_s1;
			if(e5_s1 && !e5_s2) begin
				dbg_rd_reg <= {1'b0, dbg_v4_rd_live};
				dbg_wb_reg <= {1'b0, dbg_v4_wb_live};
				dbg_wb_wl    <= dbg_bw_wl;
				dbg_fill_page <= dbg_fill_page_live;
				dbg_fill_addr <= dbg_fill_addr_live;
				dbg_wb_page   <= dbg_wb_page_live;
				dbg_wb_addr   <= dbg_wb_addr_live;
				// （dbg_bufwb_n 已在 97b 删除：其值 16 已解释为正常且无判别力；
				//   写回一致性改由 dbg_wmis 全速计数器承担。）
			end
		end
	end

	always @ (posedge clk_cpu) begin
		s_RS232_DCE_RXD <= RS232_DCE_RXD;
		s_RS232_HOST_RXD <= RS232_HOST_RXD;
		if(IORQ & CPU_CE) begin
			if(WR & AUX_OE) begin
				if(WORD) auto_flush[2] <= CPU_DOUT[0];
				else {COMBRShift[1:0], RS232_HOST_RST, ComSel[1:0]} <= CPU_DOUT[4:0];
			end
			if(VGA_FONT_OE) vga_font_counter <= WR && WORD ? {CPU_DOUT[7:0], 4'b0000} : vga_font_counter + 1'b1; 
			if(WR & SPEAKER_PORT) speaker_on <= &CPU_DOUT[1:0];
		end
		if(CPU_CE) begin
			SD_CK <= IORQ & INPUT_STATUS_OE & WR & ~WORD;
			if(IORQ & INPUT_STATUS_OE & WR) begin
				if(WORD) SD_n_CS <= ~CPU_DOUT[8]; 
				// [67th fix] shift ONLY when this cycle creates the SD_CK rising edge.
				//   The raw condition can stay asserted across several CPU_CE cycles when
				//   `ce` stalls mid-`out` (our cache miss / per-frame flush scan), which
				//   used to shift SDI more times than SD_CK pulsed -> SPI bit drift.
				else if(!SD_CK) SDI <= {SDI[6:0], SD_DO};
			end
			// [67th fix probe] the OLD shift condition, counted per CS-low window.
			//   Read together with dbg_sd_ckrun: shiftreq > ckrun proves the old code
			//   shifted SDI more times than it clocked the card (SPI bit drift).
			if(IORQ & INPUT_STATUS_OE & WR & ~WORD) begin
			end
		end

		if(1'b0 || BTN_RESET) rstcount <= 0;
		else if(CPU_CE && ~rstcount[18]) rstcount <= rstcount + 1'b1;
			
		RTCSYNC <= {RTCSYNC[0], RTCDIVEND};
		if(IORQ && CPU_CE && WR && WORD && RTC_SELECT) begin
			RTC <= 0;
			RTCSET <= CPU_DOUT;
		end else if(RTCSYNC == 2'b01) begin
			if(RTCEND) RTC <= 0;
			else RTC <= RTC + 1'b1;
		end
		
		if(CPU_CE) GPIOData <= GPIO;
		if(IORQ && CPU_CE && WR && JOYSTICK) begin
			if(WORD) GPIOState <= CPU_DOUT[15:8];
			GPIODout <= CPU_DOUT[7:0];
		end
		
		if(IORQ && CPU_CE && WR && NMI_IORQ_PORT)
			if(PORT_ADDR[0]) NMIonIORQ_HI <= CPU_DOUT;
			else NMIonIORQ_LO <= CPU_DOUT;

		if(CPU_CE && IORQ && WR && WORD && I2C_SELECT) i2c_cd <= CPU_DOUT[11:0];
					
		auto_flush[1:0] <= {auto_flush[0], vblnk};		
		
		// ★ 修复(commit: cache-flush-wrbk)：每帧垂直消隐自动触发缓存回写。
		//   原实现只有软件写 I/O 端口 0x0001(bit0) 才会置 auto_flush[2]，清屏等未写该端口的
		//   场景里 flush 永不触发，脏的显存行永远留在本 cache、写不回 DDR → VGA 看不到更新。
		//   现于每帧 vblnk 自动置位（与 cache_controller 是否改动无关，独立保证脏行落到 DDR）。
		auto_flush[2] <= auto_flush[2] | vblnk;   // 持有到本帧 flush 脉冲(3'b110)产生为止；shift 寄存器在 vblnk 下降沿输出一次 flush

	end

	// ★ Task #8 flush 链路诊断探针（2026-09-19）：clk_cpu 域采样、无门控，以此为准。
	//   （板端此前手加的 dbg_auto_flush_r/dbg_flush_r/dbg_vblnk_r 采样时钟不明，波形出现
	//   flush 脉冲 2 拍、脉冲期间 auto_flush=4 而非 6、vblnk 无脉冲等自相矛盾读数——
	//   按 RTL，flush=(auto_flush==3'b110) 每个 vblnk 下降沿只能持续 1 个 clk_cpu 周期。）
	reg [2:0] dbg_sys_auto_flush_r;
	reg       dbg_sys_vblnk_r;
	reg       dbg_sys_flush_r;
	always @(posedge clk_cpu) begin
		dbg_sys_auto_flush_r <= auto_flush;
		dbg_sys_vblnk_r      <= vblnk;
		dbg_sys_flush_r      <= (auto_flush == 3'b110);
	end
	
	always @ (posedge clk_25) begin
		s_displ_on <= {s_displ_on[17:0], displ_on};
		exline <= vrdon ? 4'b1111 : (exline - vrden); 
		
		vga_attr <= fifo_dout[15:8];		
		flash_on <= (vgaflash & fifo_dout[15] & flashcount[5]) | (~oncursor && flashcount[4] && (charcount == cursorpos) && (char_ln >= crs[0][3:0]) && (char_ln <= crs[1][3:0]));		
		
		if(!vblnk) begin
			flashbit <= 1;
			vga13[2] <= vga13[1];
			vgatext[2] <= vgatext[1];
			v240[2] <= v240[1];
			planar[2] <= planar[1];
			half[2] <= half[1];
		end else if(flashbit) begin
			flashcount <= flashcount + 1'b1;
			flashbit <= 0;
			vga13[1] <= vga13[0];
			vgatext[1] <= vgatext[0];
			v240[1] <= v240[0];
			planar[1] <= planar[0];
			half[1] <= half[0];
		end
		
		if(RTCDIVEND) RTCDIV25 <= 0;	
		else RTCDIV25 <= RTCDIV25 + 1'b1;
		
		if(!BTN_NMI) rNMI <= 0;		
		else if(!rNMI[9] && RTCDIVEND) rNMI <= rNMI + 1'b1;	

		if(VGA_VSYNC) vga_hrzpan <= half[0] ? {vga_hrzpan_req[2:0], 1'b0} : {1'b0, vga_hrzpan_req[2:0]};
		else if(VGA_HSYNC && ppm && (vcount == lcr)) vga_hrzpan <= 4'b0000;

		{VGA_B, VGA_G, VGA_R} <= DAC_COLOR & {18{sdon}};
	end
	
	// ★★★ 97th 修复（2026-09-27）：cache 请求的"命令+地址"跨时钟域一致性呈现。
	//   AXI FSM（m_axi_aclk，与 clk_sdr 异步）在任意 m 沿采样 ram_cmd/ram_addr。
	//   填充请求恰好在写回 burst 结束 ~6 个 m 周后被采样，而 clk_sdr 域里
	//   cntrl0_user_command_register 翻转 10→11 与 sdraddr 翻转 VGA→cache 发生在
	//   同一个 clk_sdr 沿 —— FSM 的采样沿结构性撞上这个翻转沿：输掉竞态就在
	//   cmd=11（新事务）下锁存旧地址 = victim 行 ⇒ 填充读了 victim 的槽。
	//   板上证据：line 2 的填充 araddr=0x002（探针实测，门控后）而数据= line 7 图案
	//   （7070/7F7F）—— +5 恰为 4 路组相联的 LRU victim 距离；写回侧采样时机不同
	//   故大多幸免 ⇒ 拔卡 dump 仍完好、台架（无 CDC 相位抖动）永不复现。
	//   修法：请求起点一次性锁存 (addr,cmd)，先呈现 2 拍 2'b00（FSM 对 00 不动作），
	//   再稳定呈现整个请求期 ⇒ FSM 任何非 00 采样看到的都是 ≥2 个 clk_sdr 稳定的配套值。
	reg        cq_act  = 1'b0;   // 正在呈现 cache 请求
	reg        cq_seen = 1'b0;   // 本笔 cache 请求已锁存（防同笔重复锁存）
	reg        cq_req_d = 1'b0;  // ★ 97b：请求延迟 1 拍 —— cache_hi_addr 与 ddr_wr/ddr_rd 的
	                          //   可见沿相差 1 个 clk_sdr（hiaddr 在状态进入后一拍才更新），
	                          //   请求上升沿直接锁存会抓到上一笔事务的 hiaddr（板上 +6 实证）。
	reg        cq_on   = 1'b0;   // 呈现通道被选中（延迟 1 拍跟踪 cq_want）
	reg  [1:0] cq_sp   = 2'd0;   // 00 间隔计数
	reg  [1:0] cq_cmd  = 2'b00;
	reg [23:0] cq_addr = 24'h0;
	wire       cq_req  = ddr_wr || ddr_rd;
	wire       cq_want = cq_act && cache_owns && !s_prog_empty;
	always @(posedge clk_sdr) begin
		cq_req_d <= cq_req;
		if (!cq_req) begin
			cq_seen <= 1'b0;
			cq_act  <= 1'b0;
			cq_on   <= 1'b0;
			cq_sp   <= 2'd0;
		end else begin
			if (cq_req_d && !cq_seen) begin
				cq_seen <= 1'b1;
				cq_act  <= 1'b1;
				cq_addr <= {memmap_mux[8:0], cache_hi_addr[9:0], 5'b0};
				cq_cmd  <= ddr_wr ? 2'b01 : 2'b11;
			end else if (cache_line_start) begin
				cq_act <= 1'b0;    // 已被 FSM 接管：释放呈现（95th 单 burst 抑制仍在）
			end
			cq_on <= cq_want;
			if (cq_want && !cq_on)   cq_sp <= 2'd2;
			else if (cq_sp != 2'd0)  cq_sp <= cq_sp - 2'd1;
		end
	end
    assign ram_cmd   = (cq_act && cq_on) ? (cq_sp != 2'd0 ? 2'b00 : cq_cmd) : cntrl0_user_command_register;
    assign ram_addr  = (cq_act && cq_on) ? cq_addr : sdraddr;
    assign ram_wdata = cntrl0_user_input_data; 
    assign sys_DOUT  = ram_rdata;             
    reg [14:0] dbg_cache_hiaddr;
    reg        dbg_cache_ddr_wr;
    reg [23:0] dbg_sdraddr;
    // ★ 十五次修复探针精简（2026-09-19）：移除 dbg_fifo_dout / dbg_cpu_halt / dbg_ram_wdata_lo /
    //   dbg_fifo_words_r。dbg_cpu_halt 与 Next186_CPU.v 的 dbg_HALT 完全重复；fifo / 写数据通路
    //   探针属早期 bring-up 遗留，当前 cache / 显存写回调试不再需要，删除以释放 ILA 位宽与布线。

    // 非 top 模块必须用 reg+always 采样，否则会被 Vivado 布线优化掉
    always @(posedge clk_sdr) begin
        dbg_cache_hiaddr  <= cache_hi_addr;
        dbg_cache_ddr_wr  <= ddr_wr;
        dbg_sdraddr       <= sdraddr;
    end

    // ===== [62nd probe, 2026-09-25] CPU-side instruments =============================
    //   ADDR is unit186's 21-bit address bus (it drives cache_controller.addr), so it
    //   is asserted on EVERY memory cycle, instruction fetches included. Bits [20:6]
    //   give the 64-byte line address, the same granularity as cache_hiaddr.
    //   dbg_cpu_addr   : most recent CPU bus line address. Does it still move?
    //   dbg_cpu_halt   : CPU HALT (core ran off into garbage / executed HLT).
    //   dbg_cpu_idle   : cleared whenever the bus address changes, saturating at
    //                    0x3FFFF (= ~5 ms at 50 MHz). If it saturates, the core is
    //                    NOT executing: halted, or stalled forever on a memory cycle.
    //   dbg_cpu_imgrun : saw an INSTRUCTION FETCH (not a write) from F000:E000..FBFF
    //                    => the core is executing the BIOS image loaded from SD.
    //                    DECISIVE: if 1, the SD path is finished and the hang is
    //                    inside the loaded image.
    //   dbg_cpu_pgseen : sticky 'region ever addressed' mask
    //                    bit0 = F000:0000-1FFF  (the 8 KB SD data buffer)
    //                    bit1 = F000:FC00-FFFF  (the built-in 1 KB BIOS itself)
    //                    bit2 = 0xB8000-0xB8F9F  (VGA text buffer)
    // =================================================================================
endmodule
