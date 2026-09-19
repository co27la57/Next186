`timescale 1ns / 1ps

module system
	(
         // AXI4 Burst 原生接口
         output wire [1:0]  ram_cmd,        
         input  wire [1:0]  ram_cmd_ack,    
         output wire [23:0] ram_addr,       
         output wire [15:0] ram_wdata,      
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
	wire [15:0]cntrl0_user_input_data;
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
	reg [16:0]vga_ddr_row_col = 17'h14000; 
	reg s_prog_full;
	(* mark_debug = "true" *) reg s_prog_empty;
	reg s_ddr_rd = 1'b0;
	reg s_ddr_wr = 1'b0;
	reg crw = 0;	
	(* mark_debug = "true" *) reg cache_line_start = 1'b0;   // ★ Task #8：cache 行事务开始脉冲（cache_controller 用它复位 lowaddr）
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
	assign SD_DI = CPU_DOUT[7];
	
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
		 .cache_write_data(crw && sys_rd_data_valid), 
		 .cache_read_data(crw && sys_wr_data_valid),
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
		sdraddr <= s_prog_empty || !(s_ddr_wr || s_ddr_rd) ? 
		    {6'b000001, vga_ddr_row_col + vga_lnbytecount} : 
		    {memmap_mux[8:0], cache_hi_addr[9:0], 5'b00000};
		max_read <= &sdraddr[7:3] ? ~sdraddr[2:0] : 3'b111;	
		
		
		if(s_prog_empty) cntrl0_user_command_register <= 2'b10;
		else if(s_ddr_wr) cntrl0_user_command_register <= 2'b01;
		else if(s_ddr_rd) cntrl0_user_command_register <= 2'b11;
		else if(~s_prog_full) cntrl0_user_command_register <= 2'b10;
		else cntrl0_user_command_register <= 2'b00;
					
		if(!crw && sys_rd_data_valid) col_counter <= col_counter - 1'b1;
		
        if (sys_cmd_ack != 2'b00 && sys_cmd_ack_d1 == 2'b00) begin
            case(sys_cmd_ack)
                2'b10: begin
                    crw <= 1'b0;	
                    col_counter <= {1'b0, max_read, 1'b1};
                    vga_lnbytecount <= vga_lnbytecount + max_read + 1'b1;
                end					
                2'b01, 2'b11: crw <= 1'b1;		
            endcase
        end
				
		if(s_vga_endscanline) begin
			col_counter[3:1] <= col_counter[3:1] - vga_lnbytecount[2:0];
			vga_lnbytecount <= 0;
			s_vga_endscanline <= 1'b0;

			if(s_vga_endframe) vga_ddr_row_col <= {{1'b0, scraddr[15:13]} + (vgatext[0] ? 4'b0111 : 4'b0100), scraddr[12:0]};
			else if({1'b0, vga_ddr_row_count} == lcr) vga_ddr_row_col <= vgatext[0] ? 17'h14000 : 17'h8000; 
				 else if(s_vga_endline) vga_ddr_row_col <= vga_ddr_row_col + (vgatext[0] ? 40 : {vga_offset, 1'b0});
			
			if(s_vga_endline) vga_repln_count <= 0;
			else vga_repln_count <= vga_repln_count + 1'b1;
			if(s_vga_endframe) begin
				vga13[0] <= vga13req;
				vgatext[0] <= vgatextreq;
				v240[0] <= 1'b1;
				planar[0] <= planarreq;
				half[0] <= halfreq;
				repln_graph[0] <= replnreq;
				vga_ddr_row_count <= 0;
			end else vga_ddr_row_count <= vga_ddr_row_count + 1'b1; 
		end else s_vga_endscanline <= (vga_lnbytecount[7:3] == vga_lnend);
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
				else SDI <= {SDI[6:0], SD_DO};
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
	(* mark_debug = "true" *) reg [2:0] dbg_sys_auto_flush_r;
	(* mark_debug = "true" *) reg       dbg_sys_vblnk_r;
	(* mark_debug = "true" *) reg       dbg_sys_flush_r;
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
	
    assign ram_cmd   = cntrl0_user_command_register;
    assign ram_addr  = sdraddr;
    assign ram_wdata = cntrl0_user_input_data; 
    assign sys_DOUT  = ram_rdata;             
    (* mark_debug = "true" *) reg [14:0] dbg_cache_hiaddr;
    (* mark_debug = "true" *) reg        dbg_cache_ddr_wr;
    (* mark_debug = "true" *) reg [23:0] dbg_sdraddr;
    // ★ 十五次修复探针精简（2026-09-19）：移除 dbg_fifo_dout / dbg_cpu_halt / dbg_ram_wdata_lo /
    //   dbg_fifo_words_r。dbg_cpu_halt 与 Next186_CPU.v 的 dbg_HALT 完全重复；fifo / 写数据通路
    //   探针属早期 bring-up 遗留，当前 cache / 显存写回调试不再需要，删除以释放 ILA 位宽与布线。

    // 非 top 模块必须用 reg+always 采样，否则会被 Vivado 布线优化掉
    always @(posedge clk_sdr) begin
        dbg_cache_hiaddr  <= cache_hi_addr;
        dbg_cache_ddr_wr  <= ddr_wr;
        dbg_sdraddr       <= sdraddr;
    end
endmodule
