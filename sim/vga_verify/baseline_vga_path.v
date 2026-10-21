// =========================================================================
// vga_path.v  --  VGA 显示通路整体仿真顶层 (111904f 基线)
// -------------------------------------------------------------------------
// 把 ddr_186.v 里纠缠在 system 大模块中的 VGA 显示链路单独抽出来:
//   VGA_SG(时序) + 异步FIFO(取指/显示跨时钟) + 取指FSM(clk_sdr)
//   + 字符发生器(sr_font) + 显示侧胶水(clk_25)
// 纯 VGA 模式 (无 CPU cache 仲裁: ddr_wr=ddr_rd=0)。
//
// 真实模块:  vga_sg (来自 vga.v), vga_font_model (来自 Next186_BlackBoxes.v)
// 行为模型:  vga_fifo_model (替代 XPM fifo), vga_fb_model (帧缓冲+AXI读从机)
// 取指 FSM 与显示侧逻辑逐字复制自 ddr_186.v @ 111904f:
//   "feat(vga): 帧同步重同步 —— 修图形模式水平滚动+尾部重复 / 文字模式两字符垃圾"
//
// 验证判据 (见 sim_main.cpp):
//   1) 帧稳定性 (第N帧==第N+1帧)  -> vb_resync 确定性
//   2) 无 2 字符重复 / 无垃圾字节  -> 1'b0 末位修复 + 地址正确
//   3) 信标 0xFF 实测屏上位置       -> 本基线真实行/列偏移
// =========================================================================
`timescale 1 ns / 1 ps

module vga_path
  #( parameter integer FIFO_DEPTH16 = 512 )   // 16 位字深度; 真实 wrusedw 饱和 511 => 512
  (
    input  wire        CLK_50MHZ,
  input  wire        rst_n,

    // ---- 配置 (替代 VGA_DAC/VGA_CRT/VGA_SC/VGA_GC 的配置寄存器) ----
    input  wire [3:0]  cfg_vga_hrzpan,
    input  wire        cfg_vgatext,
    input  wire        cfg_vga13,
    input  wire        cfg_planar,
    input  wire        cfg_half,
    input  wire        cfg_repln_graph,
    input  wire [15:0] cfg_scraddr,
    input  wire [7:0]  cfg_vga_offset,
    input  wire [9:0]  cfg_lcr,
    input  wire [9:0]  cfg_vde,
    // ★ 诊断旋钮 (仅仿真): 1 = 抑制行尾 exline 扩展的最后一次 FIFO 读
    //   目的: 把读侧从 48 次/行(96 半字) 精确降到 ILA 实测的 47 次/行(94 半字),
    //   从而复现板上 "写 96 - 读 94 = 净多 2 半字/行" 的 FIFO 溢出。
    //   0 (默认) = 与 111904f 完全一致, 不影响基线行为。
    input  wire        cfg_rd_drop_last_tail,
    // ★ 对照实验旋钮 (仅仿真): 1 = 取指地址按每个突发的实际取回量前进 16 半字
    //   (= 消除 "取 16 前进 8" 的 2x 重叠)。0 (默认) = 111904f 原样。
    //   注意: 仅文本模式可用 (vga_lnbytecount 为 8 位, 文本 6x16=96 不溢出)。
    input  wire        cfg_fetch_step16,
    // ★ 对照实验旋钮 (仅仿真): sdraddr 行首相位补偿量 (111904f 原值 = 8)
    //   2x 重叠消除后该补偿需要重新定标; 台架用 0..15 扫描找最优值
    input  wire [4:0]  cfg_sdrc_off,

    // ---- 帧缓冲 host 后门 (clk_sdr 域) ----
    input  wire        h_wr,
    input  wire [23:0] h_addr,
    input  wire [15:0] h_din,

    // ---- 调试输出 ----
    output wire [9:0]  dbg_hcount, dbg_vcount, dbg_hcount_pan,
    output wire        dbg_hsync, dbg_vsync, dbg_vrden, dbg_sdon, dbg_vblnk,
    output wire [15:0] dbg_fifo_dout,
    output wire [31:0] dbg_fifo_dout32,
    output wire [7:0]  dbg_font_dout, dbg_char_code, dbg_attr,
    output wire [11:0] dbg_charcount,
    output wire [2:0]  dbg_vgatext, dbg_half, dbg_v240,
    output wire [3:0]  dbg_repln_count, dbg_repln,
    output wire        dbg_endline, dbg_endscanline, dbg_endframe,
    output wire [8:0]  dbg_row_count,
    output wire [5:0]  dbg_lnend,
    output wire [23:0] dbg_ram_addr,
    output wire [1:0]  dbg_ram_cmd,
    output wire        dbg_vb_resync,
    output wire [8:0]  dbg_fifo_level,
    output wire        dbg_fifo_wr,      // 一个半字写入
    output wire        dbg_fifo_ovf,     // 满丢弃
    output wire        dbg_fifo_empty,
    output wire        dbg_fifo_underrun,// 空读 (显示侧拿不到新字)
    output wire [11:0] dbg_fifo_wrptr,   // 已写半字数
    output wire [10:0] dbg_fifo_rdptr,   // 已读 32 位字数
    output wire [16:0] dbg_vga_ddr_row_col,
    output wire [7:0]  dbg_vga_lnbytecount,
    output wire [4:0]  dbg_col_counter,
    output wire [15:0] dbg_scraddr,
    output reg  [5:0]  VGA_R, VGA_G, VGA_B
  );

  // ---------------------------------------------------------------------
  // 时钟: clk_sdr = CLK_50MHZ, clk_25 = /2 (与真实 DCM 一致)
  // ---------------------------------------------------------------------
  wire        clk_sdr = CLK_50MHZ;
  reg         clk_25_div;
  wire        clk_25 = clk_25_div;
  always @(posedge CLK_50MHZ) clk_25_div <= ~clk_25_div;

  wire        clk_sys_locked = 1'b1;   // 假设 PLL 已锁定 (仿真)

  // ---------------------------------------------------------------------
  // VGA_SG 时序发生器
  // ---------------------------------------------------------------------
  wire [9:0]  hcount, vcount;
  wire        hblnk, vblnk, VGA_HSYNC, VGA_VSYNC;
  wire [3:0]  vga_hrzpan = cfg_vga_hrzpan;     // 旁路动态 pan, 直接用配置
  wire [9:0]  hcount_pan = hcount + vga_hrzpan - 17;

  reg         FifoStart = 1'b0;
  wire        displ_on  = !(hblnk | vblnk | !FifoStart);
  wire [8:0]  fifo_wr_used_words;

  vga_sg VGA
   (
    .tc_hsblnk(10'd639),  .tc_hssync(10'd655 + 10'd17),
    .tc_hesync(10'd751 + 10'd17), .tc_heblnk(10'd799),
    .hcount(hcount), .hsync(VGA_HSYNC), .hblnk(hblnk),
    .tc_vsblnk(v240[2] ? 10'd479 : 10'd399),
    .tc_vssync(v240[2] ? 10'd489 : 10'd411),
    .tc_vesync(v240[2] ? 10'd491 : 10'd413),
    .tc_veblnk(v240[2] ? 10'd520 : 10'd446),
    .vcount(vcount), .vsync(VGA_VSYNC), .vblnk(vblnk),
    .clk(clk_25), .ce(FifoStart)
   );

  // ---------------------------------------------------------------------
  // 配置信号 (替代 CRT/SC/GC/DAC 输出)
  // ---------------------------------------------------------------------
  wire        vgatextreq = cfg_vgatext;
  wire        vga13req   = cfg_vga13;
  wire        planarreq  = cfg_planar;
  wire        halfreq    = cfg_half;
  wire        replnreq   = cfg_repln_graph;
  wire [15:0] scraddr    = cfg_scraddr;
  wire [9:0]  lcr        = cfg_lcr;
  wire [9:0]  vde        = cfg_vde;
  wire [7:0]  vga_offset = cfg_vga_offset;
  wire        vgaflash   = 1'b0;
  wire        oncursor   = 1'b0;
  wire [11:0] cursorpos  = 12'b0;
  wire [4:0]  crs [1:0];
  assign crs[0] = 5'b0;
  assign crs[1] = 5'b0;

  // ---------------------------------------------------------------------
  // 模式位 3 级流水线 (显示侧锁存)
  // ---------------------------------------------------------------------
  reg [2:0] vgatext = 0;
  reg [2:0] vga13   = 0;
  reg [2:0] v240    = 0;
  reg [2:0] planar  = 0;
  reg [2:0] half    = 0;
  reg [0:0] repln_graph = 0;

  // ---------------------------------------------------------------------
  // 字符 / 显示侧胶水信号
  // ---------------------------------------------------------------------
  // ★ 注意: 真实 ddr_186.v @111904f 中 char_row 是 [5:0] (vcount[8:3])，
  //   文本 8px 行高 => 60 行 (480/8)。我曾误写成 [3:0] 导致只映射 16 行。
  wire [5:0] char_row = vcount[8:3] >> !half[2];
  wire [3:0] char_ln  = {(vcount[3] & !half[1]), vcount[2:0]};
  wire [11:0] charcount = {char_row, 4'b0000} + {char_row, 6'b000000} + hcount_pan[9:3];
  wire [31:0] fifo_dout32;
  wire [15:0] fifo_dout = (vgatext[1] ? hcount_pan[3] : vga13[1] ? hcount_pan[2] : hcount_pan[1]) ? fifo_dout32[31:16] : fifo_dout32[15:0];

  reg  [8:0]  vga_ddr_row_count = 0;
  reg  [2:0]  max_read;
  reg  [4:0]  col_counter;
  wire        vga_end_frame = vga_ddr_row_count == (v240[0] ? 479 : 399);
  reg  [3:0]  vga_repln_count = 0;
  wire [3:0]  vga_repln = vgatext[0] ? (half[0] ? 7 : 15) : {3'b000, repln_graph[0]};
  reg  [7:0]  vga_lnbytecount = 0;
  wire [4:0]  vga_lnend = ((vgatext[0] | half[0]) ? 5'd6 : (vga13[0] | planar[0]) ? 5'd11 : 5'd21) << cfg_fetch_step16;
  reg  [11:0] vga_font_counter = 0;
  reg  [7:0]  vga_attr;

  wire [7:0]  font_dout;
  wire [2:0]  shift  = half[1] ? ~hcount_pan[3:1] : ~hcount_pan[2:0];
  wire [2:0]  pxindex = -hcount_pan[2:0];
  wire [3:0]  EGA_MUX = vgatext[1] ? (font_dout[pxindex] ^ flash_on ? vga_attr[3:0] : {vga_attr[7] & ~vgaflash, vga_attr[6:4]}) :
                          {fifo_dout32[{2'b11, shift}], fifo_dout32[{2'b10, shift}], fifo_dout32[{2'b01, shift}], fifo_dout32[{2'b00, shift}]};
  wire [7:0]  VGA_INDEX = 8'h00;
  reg  [3:0]  exline = 4'b0000;
  wire        vrdon = s_displ_on[~vga_hrzpan];
  // vrden_raw: 111904f 原始读使能 (40 次可见 + 8 次 exline 行尾补读 = 48 次/行)
  wire        vrden_raw = (vrdon || exline[3]) && ((vgatext[1] | half[1]) ? &hcount_pan[3:0] : (vga13[1] | planar[1]) ? &hcount_pan[2:0] : &hcount_pan[1:0]);
  // tail_last: exline 8->7 那一次 = 行尾第 8 次(也是最后一次)补读
  wire        tail_last = exline[3] && (exline == 4'd8) && !vrdon;
  wire        vrden = vrden_raw && !(cfg_rd_drop_last_tail && tail_last);
  reg         s_vga_endline;
  reg         s_vga_endscanline = 1'b0;
  reg         s_vga_endframe;
  reg  [23:0] sdraddr;
  wire [3:0]  vga_wplane = 0;
  wire [1:0]  vga_rplane = 0;

  reg  [18:0] s_displ_on = 0;
  wire        sdon = s_displ_on[17+vgatext[1]] & (vcount <= vde);

  reg         flash_on;
  reg  [5:0]  flashcount = 0;
  reg         flashbit = 0;
  reg  [9:0]  RTCDIV25 = 0;
  reg  [1:0]  RTCSYNC = 0;
  reg  [15:0] RTC = 0;
  reg  [15:0] RTCSET = 0;
  wire        RTCEND = RTC == RTCSET;
  wire        RTCDIVEND = RTCDIV25 == 24;
  wire        BTN_NMI = 1'b1;
  reg  [9:0]  rNMI = 0;

  // ---------------------------------------------------------------------
  // 取指 FSM 相关
  // ---------------------------------------------------------------------
  localparam [16:0] VGA_TEXT_ROWCOL  = 17'h0E000;
  localparam [16:0] VGA_GRAPH_ROWCOL = 17'h08000;
  reg  [16:0] vga_ddr_row_col = VGA_TEXT_ROWCOL;

  reg  [1:0]  cntrl0_user_command_register = 0;
  reg  [1:0]  sys_cmd_ack_d1 = 0;
  wire [1:0]  sys_cmd_ack    = ram_cmd_ack;
  wire        sys_rd_data_valid = ram_rd_valid;
  wire [15:0] sys_DOUT        = ram_rdata;

  wire        ddr_rd = 1'b0, ddr_wr = 1'b0;
  reg         cache_cmd_done = 1'b0;
  wire        cache_owns = (ddr_wr || ddr_rd) && !cache_cmd_done;
  reg         s_ddr_rd = 0, s_ddr_wr = 0;
  reg         s_prog_full;
  reg         s_prog_empty;
  reg         crw = 0;
  wire [8:0]  memmap_mux = 0;
  wire [9:0]  cache_hi_addr = 0;

  // ---------------------------------------------------------------------
  // vb_resync / fifo_rst
  // ---------------------------------------------------------------------
  reg  [1:0]  vb_sync = 2'b00;
  reg         vb_d    = 1'b0;
  reg  [5:0]  vb_win  = 6'd0;
  wire        vb_rise = vb_sync[1] & ~vb_d;
  wire        vb_resync = (vb_win != 6'd0);

  reg  [3:0]  fifo_rst_cnt = 4'd15;
  reg         fifo_rst     = 1'b1;
  always @(posedge CLK_50MHZ) begin
    if (!clk_sys_locked) begin
      fifo_rst_cnt <= 4'd15;
      fifo_rst     <= 1'b1;
    end     else if (fifo_rst_cnt > 0) begin
      fifo_rst_cnt <= fifo_rst_cnt - 1'b1;
      fifo_rst     <= 1'b1;
    end else if (!rst_n) begin
      fifo_rst     <= 1'b1;        // 复位期间强制保持 FIFO 复位
    end else begin
      fifo_rst     <= vb_resync;   // 重同步窗口内保持复位
    end
  end

  // ---------------------------------------------------------------------
  // 异步 FIFO (行为模型)
  // ---------------------------------------------------------------------
  wire        fifo_wr = !crw && sys_rd_data_valid && !col_counter[4];
  wire        fifo_ovf, fifo_empty, fifo_underrun;
  wire [11:0] fifo_wrptr;
  wire [10:0] fifo_rdptr;
  vga_fifo_model
  #( .DEPTH(FIFO_DEPTH16) ) vga_fifo
   (
    .wrclk(clk_sdr), .rdclk(clk_25), .data(sys_DOUT),
    .wrreq(fifo_wr),
    .rdreq(vrden), .q(fifo_dout32),
    .wrusedw(fifo_wr_used_words), .rst(fifo_rst),
    .ovf(fifo_ovf), .empty_o(fifo_empty), .underrun(fifo_underrun),
    .wrptr_o(fifo_wrptr), .rdptr_o(fifo_rdptr)
   );

  // ---------------------------------------------------------------------
  // 字符发生器 (真实 sr_font 逻辑)
  // ---------------------------------------------------------------------
  vga_font_model VGA_FONT
   (
    .clock_a(clk_25), .wren_a(1'b0),
    .address_a({fifo_dout[7:0], char_ln}), .data_a(8'h00), .q_a(font_dout),
    .clock_b(clk_25), .wren_b(1'b0),
    .address_b(12'b0), .data_b(8'h00), .q_b()
   );

  // ---------------------------------------------------------------------
  // 帧缓冲模型 + AXI 读从机
  // ---------------------------------------------------------------------
  wire [1:0]  ram_cmd_ack;
  wire [15:0] ram_rdata;
  wire        ram_rd_valid;
  wire [1:0]  ram_cmd   = cntrl0_user_command_register;
  wire [23:0] ram_addr  = sdraddr;

  vga_fb_model fb
   (
    .clk(clk_sdr), .ram_cmd(ram_cmd), .ram_addr(ram_addr),
    .ram_cmd_ack(ram_cmd_ack), .ram_rdata(ram_rdata), .ram_rd_valid(ram_rd_valid),
    .h_wr(h_wr), .h_addr(h_addr), .h_din(h_din)
   );

  // ---------------------------------------------------------------------
  // 取指 FSM (clk_sdr)  --  逐字复制自 ddr_186.v @ 111904f
  // ---------------------------------------------------------------------
  always @ (posedge clk_sdr) begin
    sys_cmd_ack_d1 <= sys_cmd_ack;

    if (!rst_n) cntrl0_user_command_register <= 2'b00;   // 复位期间禁止取指(便于预填帧缓冲)

    // 帧同步重同步窗口: vblank 上升沿开窗 63 拍
    vb_sync <= {vb_sync[0], vblnk};
    vb_d    <= vb_sync[1];
    if (vb_rise)            vb_win <= 6'd63;
    else if (vb_win != 0)   vb_win <= vb_win - 1'b1;

    s_prog_full <= fifo_wr_used_words > 350;
    if (fifo_wr_used_words < 64) s_prog_empty <= 1'b1;
    else begin
      s_prog_empty <= 1'b0;
      FifoStart    <= 1'b1;
    end

    s_ddr_rd <= ddr_rd;
    s_ddr_wr <= ddr_wr;
    s_vga_endline  <= vga_repln_count == vga_repln;
    s_vga_endframe <= vga_end_frame;

    if (!ddr_wr && !ddr_rd) cache_cmd_done <= 1'b0;
    else                     cache_cmd_done <= 1'b1;

    sdraddr <= s_prog_empty || !cache_owns ?
        {5'b00001, vga_ddr_row_col + vga_lnbytecount - cfg_sdrc_off, 1'b0} :
        {memmap_mux[8:0], cache_hi_addr[9:0], 5'b00000};
    max_read <= &sdraddr[7:3] ? ~sdraddr[2:0] : 3'b111;

    if (s_prog_empty)        cntrl0_user_command_register <= 2'b10;
    else if (cache_owns)     cntrl0_user_command_register <= ddr_wr ? 2'b01 : 2'b11;
    else if (~s_prog_full)   cntrl0_user_command_register <= 2'b10;
    else                     cntrl0_user_command_register <= 2'b00;

    if (!crw && sys_rd_data_valid) col_counter <= col_counter - 1'b1;

    if (sys_cmd_ack != 2'b00 && sys_cmd_ack_d1 == 2'b00) begin
      case (sys_cmd_ack)
        2'b10: begin
          crw <= 1'b0;
          col_counter <= {1'b0, max_read, 1'b1};
          vga_lnbytecount <= vga_lnbytecount +
                             (cfg_fetch_step16 ? ({1'b0, max_read, 1'b0} + 5'd2)
                                               : ({4'b0000, max_read} + 5'd1));
        end
        2'b01, 2'b11: crw <= 1'b1;
      endcase
    end

    if (vb_resync) begin
      vga_ddr_row_col  <= {{1'b0, scraddr[15:13]} + (vgatext[0] ? VGA_TEXT_ROWCOL[16:13] : VGA_GRAPH_ROWCOL[16:13]), scraddr[12:0]};
      vga_lnbytecount  <= 8'd0;
      vga_repln_count  <= 4'd0;
      s_vga_endscanline <= 1'b0;
    end else if (s_vga_endscanline) begin
      col_counter[3:1] <= col_counter[3:1] - vga_lnbytecount[2:0];
      vga_lnbytecount  <= 0;
      s_vga_endscanline <= 1'b0;

      if ({1'b0, vga_ddr_row_count} == lcr) vga_ddr_row_col <= vgatext[0] ? VGA_TEXT_ROWCOL : VGA_GRAPH_ROWCOL;
      else if (s_vga_endline) vga_ddr_row_col <= vga_ddr_row_col + (vgatext[0] ? 40 : {vga_offset, 1'b0});

      if (s_vga_endline) vga_repln_count <= 0;
      else              vga_repln_count <= vga_repln_count + 1'b1;

      if (s_vga_endframe) begin
        vga13[0]        <= vga13req;
        vgatext[0]       <= vgatextreq;
        v240[0]          <= 1'b1;          // 137th: 锁死 640x480
        planar[0]        <= planarreq;
        half[0]          <= halfreq;
        repln_graph[0]   <= replnreq;
        vga_ddr_row_count <= 0;
      end else vga_ddr_row_count <= vga_ddr_row_count + 1'b1;
    end else s_vga_endscanline <= (vga_lnbytecount[7:3] == vga_lnend);
  end

  // ---------------------------------------------------------------------
  // 显示侧 (clk_25)  --  复制自 ddr_186.v
  // ---------------------------------------------------------------------
  always @ (posedge clk_25) begin
    s_displ_on <= {s_displ_on[17:0], displ_on};
    exline <= vrdon ? 4'b1111 : (exline - vrden_raw);

    vga_attr <= fifo_dout[15:8];
    flash_on <= (vgaflash & fifo_dout[15] & flashcount[5]) |
                (~oncursor && flashcount[4] && (charcount == cursorpos) &&
                 (char_ln >= crs[0][3:0]) && (char_ln <= crs[1][3:0]));

    if (!vblnk) begin
      flashbit <= 1'b1;
      vga13[2]   <= vga13[1];
      vgatext[2] <= vgatext[1];
      v240[2]    <= v240[1];
      planar[2]  <= planar[1];
      half[2]    <= half[1];
    end else if (flashbit) begin
      flashcount <= flashcount + 1'b1;
      flashbit   <= 1'b0;
      vga13[1]   <= vga13[0];
      vgatext[1] <= vgatext[0];
      v240[1]    <= v240[0];
      planar[1]  <= planar[0];
      half[1]    <= half[0];
    end

    if (RTCDIVEND) RTCDIV25 <= 0;
    else           RTCDIV25 <= RTCDIV25 + 1'b1;

    if (!BTN_NMI) rNMI <= 0;
    else if (!rNMI[9] && RTCDIVEND) rNMI <= rNMI + 1'b1;

    // 输出像素: 用 idx(4bit 颜色索引) 直接映射到 RGB, 不实例化 DAC
    begin
      reg [3:0] idx;
      idx = vgatext[1] ? ((font_dout[pxindex] ^ flash_on) ? vga_attr[3:0]
                                                     : {vga_attr[7] & ~vgaflash, vga_attr[6:4]})
                       : EGA_MUX;
      VGA_R <= sdon ? {6{idx[0]}} : 6'b0;
      VGA_G <= sdon ? {6{idx[1]}} : 6'b0;
      VGA_B <= sdon ? {6{idx[2]}} : 6'b0;
    end
  end

  // ---------------------------------------------------------------------
  // 调试输出
  // ---------------------------------------------------------------------
  assign dbg_hcount     = hcount;
  assign dbg_vcount     = vcount;
  assign dbg_hcount_pan = hcount_pan;
  assign dbg_hsync      = VGA_HSYNC;
  assign dbg_vsync      = VGA_VSYNC;
  assign dbg_vblnk      = vblnk;
  assign dbg_fifo_dout  = fifo_dout;
  assign dbg_fifo_dout32 = fifo_dout32;
  assign dbg_font_dout  = font_dout;
  assign dbg_char_code  = fifo_dout[7:0];
  assign dbg_attr       = vga_attr;
  assign dbg_vrden      = vrden;
  assign dbg_sdon       = sdon;
  assign dbg_ram_addr   = ram_addr;
  assign dbg_ram_cmd    = ram_cmd;
  assign dbg_vb_resync  = vb_resync;
  assign dbg_fifo_level = fifo_wr_used_words;
  assign dbg_fifo_wr    = fifo_wr;
  assign dbg_fifo_ovf   = fifo_ovf;
  assign dbg_fifo_empty = fifo_empty;
  assign dbg_fifo_underrun = fifo_underrun;
  assign dbg_fifo_wrptr = fifo_wrptr;
  assign dbg_fifo_rdptr = fifo_rdptr;
  assign dbg_vga_ddr_row_col = vga_ddr_row_col;
  assign dbg_vga_lnbytecount = vga_lnbytecount;
  assign dbg_col_counter = col_counter;
  assign dbg_scraddr    = scraddr;

  assign dbg_charcount  = charcount;
  assign dbg_vgatext    = vgatext;
  assign dbg_half       = half;
  assign dbg_v240       = v240;
  assign dbg_repln_count = vga_repln_count;
  assign dbg_repln      = vga_repln;
  assign dbg_endline    = s_vga_endline;
  assign dbg_endscanline = s_vga_endscanline;
  assign dbg_endframe   = s_vga_endframe;
  assign dbg_row_count  = vga_ddr_row_count;
  assign dbg_lnend      = vga_lnend;

endmodule
