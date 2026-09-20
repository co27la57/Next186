`timescale 1ns / 1ps

module Next186_SoC (
    input  wire        CLOCK_50,
    
    // ==========================================
    // 新的 AXI4 Full Burst 突发内存接口
    // ==========================================
    output wire [1:0]  ram_cmd,
    input  wire [1:0]  ram_cmd_ack,
    output wire [23:0] ram_addr,
    output wire [31:0] ram_wdata,
    input  wire [15:0] ram_rdata,
    input  wire        ram_rd_valid,
    input  wire        ram_wr_valid,

    // ==========================================
    // 外部物理引脚
    // ==========================================
    output wire [19:0] SRAM_ADDR,
    inout  wire [15:0] SRAM_DQ,
    output wire        SRAM_OE_N,
    output wire        SRAM_WE_N,
    output wire        SRAM_UB_N,
    output wire        SRAM_LB_N,
    
    output wire [5:0]  VGA_R,
    output wire [5:0]  VGA_G,
    output wire [5:0]  VGA_B,
    output wire        VGA_VSYNC,
    output wire        VGA_HSYNC,
    
    output wire        SDLED,
    input  wire        BTN_SOUTH,
    input  wire        BTN_WEST,
    
    inout  wire        PS2_CLKA,
    inout  wire        PS2_DATA,
    inout  wire        PS2_CLKB,
    inout  wire        PS2_DATB,
    
    output wire        AUDIO_L,
    output wire        AUDIO_R,
    
    output wire        SD_nCS,
    input  wire        SD_DO,
    output wire        SD_CK,
    output wire        SD_DI,
    
    input  wire        RX_EXT,
    output wire        TX_EXT,
    output wire        MIDI_OUT,
    
    input  wire        CLKBD,
    input  wire        WSBD,
    input  wire        DABD,
    output wire        LRCLK,
    output wire        SDIN,
    output wire        SCLK,
    output wire        STM_RST
);

    // ==========================================
    // 例化核心 system 模块 (ddr_186.v)
    // ==========================================
    system sys_inst (
        // 挂载新的 Burst 内存接口
        .ram_cmd        (ram_cmd),
        .ram_cmd_ack    (ram_cmd_ack),
        .ram_addr       (ram_addr),
        .ram_wdata      (ram_wdata),
        .ram_rdata      (ram_rdata),
        .ram_rd_valid   (ram_rd_valid),
        .ram_wr_valid   (ram_wr_valid),
        
        // 时钟与复位
        .CLK_50MHZ      (CLOCK_50),
        .BTN_RESET      (BTN_SOUTH),
        .BTN_NMI        (1'b0),
        
        // VGA 接口
        .VGA_R          (VGA_R),
        .VGA_G          (VGA_G),
        .VGA_B          (VGA_B),
        .VGA_HSYNC      (VGA_HSYNC),
        .VGA_VSYNC      (VGA_VSYNC),
        .frame_on       (), 
        
        // UART / RS232 接口
        .RS232_DCE_RXD  (RX_EXT),
        .RS232_DCE_TXD  (TX_EXT),
        .RS232_EXT_RXD  (1'b1),
        .RS232_EXT_TXD  (),
        .RS232_HOST_RXD (1'b1),
        .RS232_HOST_TXD (),
        .RS232_HOST_RST (STM_RST),
        
        // SD 卡接口
        .SD_n_CS        (SD_nCS),
        .SD_DI          (SD_DI),
        .SD_CK          (SD_CK),
        .SD_DO          (SD_DO),
        
        // 声音接口
        .AUD_L          (AUDIO_L),
        .AUD_R          (AUDIO_R),
        
        // PS/2 键盘鼠标接口
        .PS2_CLK1       (PS2_CLKA),
        .PS2_CLK2       (PS2_CLKB),
        .PS2_DATA1      (PS2_DATA),
        .PS2_DATA2      (PS2_DATB),
        
        // I2S 音频接口
        .I2S_MCLK       (),
        .I2S_SCLK       (SCLK),
        .I2S_LRCLK      (LRCLK),
        .I2S_SDIN       (SDIN),
        
        // MIDI 接口
        .MIDI_OUT       (MIDI_OUT),
        .CLKBD          (CLKBD),
        .WSBD           (WSBD),
        .DABD           (DABD),
        // 未使用的引脚直接悬空或拉低
        .LED            (),
        .GPIO           (),
        .I2C_SCL        (),
        .I2C_SDA        ()
    );
    
    // ==========================================
    // 杂项逻辑处理
    // ==========================================
    // 用 SD 卡的片选信号点亮指示灯
    assign SDLED = ~SD_nCS;
    
    // Zynq-7010 板子上不用老旧的 SRAM，直接把控制引脚拉高屏蔽掉，防止引脚乱跳
    assign SRAM_ADDR = 20'hz;
    assign SRAM_OE_N = 1'b1;
    assign SRAM_WE_N = 1'b1;
    assign SRAM_UB_N = 1'b1;
    assign SRAM_LB_N = 1'b1;

endmodule