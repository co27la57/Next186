`timescale 1ns / 1ps

module top_zynq7010 (
    input  wire        m_axi_aclk,
    input  wire        m_axi_aresetn,

    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m_axi, PROTOCOL AXI4" *)
    output wire [31:0] m_axi_awaddr,
    output wire [2:0]  m_axi_awprot,
    output wire [7:0]  m_axi_awlen,
    output wire [2:0]  m_axi_awsize,
    output wire [1:0]  m_axi_awburst,
    output wire        m_axi_awvalid,
    input  wire        m_axi_awready,

    output wire [31:0] m_axi_wdata,
    output wire [3:0]  m_axi_wstrb,
    output wire        m_axi_wlast,
    output wire        m_axi_wvalid,
    input  wire        m_axi_wready,

    input  wire [1:0]  m_axi_bresp,
    input  wire        m_axi_bvalid,
    output wire        m_axi_bready,

    output wire [31:0] m_axi_araddr,
    output wire [2:0]  m_axi_arprot,
    output wire [7:0]  m_axi_arlen,
    output wire [2:0]  m_axi_arsize,
    output wire [1:0]  m_axi_arburst,
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,

    input  wire [31:0] m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rlast,
    input  wire        m_axi_rvalid,
    output wire        m_axi_rready,
    output wire [5:0]  m_axi_awid,
    output wire [5:0]  m_axi_arid,
    output wire [3:0]  m_axi_arcache,
    output wire [3:0]  m_axi_awcache,
    input  wire        m_axi_rid,
    input  wire        m_axi_bid,

    output wire [3:0]  test_led,
    output wire [5:0]  VGA_R,
    output wire [5:0]  VGA_G,
    output wire [5:0]  VGA_B,
    output wire        VGA_VSYNC,
    output wire        VGA_HSYNC,
    input  wire        btn_sd_load,
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
    // AXI 静态属性
    // ==========================================
    assign m_axi_awprot  = 3'b000;
    assign m_axi_awsize  = 3'b010;      // 4 字节
    assign m_axi_awburst = 2'b01;       // INCR
    assign m_axi_arprot  = 3'b000;
    assign m_axi_arsize  = 3'b010;
    assign m_axi_arburst = 2'b01;
    assign m_axi_awid    = 6'd0;
    assign m_axi_arid    = 6'd0;
    assign m_axi_awcache = 4'b0011;
    assign m_axi_arcache = 4'b0011;
    assign m_axi_wstrb   = 4'b1111;

    // ==========================================
    // 内部信号
    // ==========================================
    wire [1:0]  ram_cmd;
    reg  [1:0]  ram_cmd_ack;
    wire [23:0] ram_addr;
    wire [15:0] ram_wdata;
    wire [15:0] ram_rdata;
    wire        ram_rd_valid;
    wire        ram_wr_valid;
    wire        SDLED;

    reg [25:0] blink_cnt = 0;
    always @(posedge m_axi_aclk) blink_cnt <= blink_cnt + 1'b1;

    // ==========================================
    // 上电复位延迟（5 秒 = 250_000_000 @ 50MHz）
    // ==========================================
    reg [29:0] auto_rst_cnt = 0;
    reg        auto_rst_reg = 1'b1;
    always @(posedge m_axi_aclk or negedge m_axi_aresetn) begin
        if (!m_axi_aresetn) begin
            auto_rst_cnt <= 0;
            auto_rst_reg <= 1'b1;
        end else begin
            if (auto_rst_cnt < 30'd250_000_000) begin
                auto_rst_cnt <= auto_rst_cnt + 1'b1;
                auto_rst_reg <= 1'b1;
            end else begin
                auto_rst_reg <= 1'b0;
            end
        end
    end

    wire init_done = ~auto_rst_reg;

    // ==========================================
    // Next186 SoC 实例化（CPU 锁死在复位）
    // ==========================================
    Next186_SoC u_Next186 (
        .CLOCK_50       (m_axi_aclk),
        .ram_cmd        (ram_cmd),
        .ram_cmd_ack    (ram_cmd_ack),
        .ram_addr       (ram_addr),
        .ram_wdata      (ram_wdata),
        .ram_rdata      (ram_rdata),
        .ram_rd_valid   (ram_rd_valid),
        .ram_wr_valid   (ram_wr_valid),
        .SRAM_ADDR  (), .SRAM_DQ    (), .SRAM_OE_N  (), .SRAM_WE_N  (), .SRAM_UB_N  (), .SRAM_LB_N  (),
        .VGA_R      (VGA_R), .VGA_G      (VGA_G), .VGA_B      (VGA_B),
        .VGA_VSYNC  (VGA_VSYNC), .VGA_HSYNC  (VGA_HSYNC),
        .SDLED      (SDLED),
        .BTN_SOUTH  (1'b1),          // CPU 永久复位
        .BTN_WEST   (1'b0),
        .PS2_CLKA   (PS2_CLKA), .PS2_DATA   (PS2_DATA),
        .PS2_CLKB   (PS2_CLKB), .PS2_DATB   (PS2_DATB),
        .AUDIO_L    (AUDIO_L), .AUDIO_R    (AUDIO_R),
        .SD_nCS     (SD_nCS), .SD_DO      (SD_DO),
        .SD_CK      (SD_CK), .SD_DI      (SD_DI),
        .RX_EXT     (RX_EXT), .TX_EXT     (TX_EXT), .MIDI_OUT   (MIDI_OUT),
        .CLKBD      (CLKBD), .WSBD       (WSBD), .DABD       (DABD),
        .LRCLK      (LRCLK), .SDIN       (SDIN), .SCLK       (SCLK), .STM_RST    (STM_RST)
    );

    // ==========================================
    // AXI 16 拍 burst 测试 FSM
    // ==========================================
    localparam T_IDLE    = 4'd0;
    localparam T_WR_ISSUE= 4'd1;
    localparam T_WR_BRESP= 4'd2;
    localparam T_RD_ISSUE= 4'd3;
    localparam T_RD_WAIT = 4'd4;
    localparam T_DONE    = 4'd5;
    localparam T_FAIL    = 4'd6;

    // 测试参数
    localparam TEST_ADDR = 32'h0805C000;

    reg [3:0]  test_state;
    reg [15:0] test_cnt;
    reg [31:0] test_rdata_fail;
    reg        test_pass;
    reg        test_fail;

    reg [4:0]  w_beat_cnt;
    reg [4:0]  r_beat_cnt;
    reg [31:0] r_data_expect;

    // 测试 FSM 的 AXI 输出
    reg [31:0] t_awaddr;
    reg [7:0]  t_awlen;
    reg        t_awvalid;
    reg [31:0] t_wdata;
    reg        t_wlast;
    reg        t_wvalid;
    reg        t_bready;
    reg [31:0] t_araddr;
    reg [7:0]  t_arlen;
    reg        t_arvalid;
    reg        t_rready;

    always @(posedge m_axi_aclk or negedge m_axi_aresetn) begin
        if (!m_axi_aresetn) begin
            test_state     <= T_IDLE;
            test_cnt       <= 16'd0;
            test_rdata_fail<= 32'h0;
            test_pass      <= 1'b0;
            test_fail      <= 1'b0;
            w_beat_cnt     <= 5'd0;
            r_beat_cnt     <= 5'd0;
            r_data_expect  <= 32'h0;
            t_awaddr       <= 32'h0;
            t_awlen        <= 8'd0;
            t_awvalid      <= 1'b0;
            t_wdata        <= 32'h0;
            t_wlast        <= 1'b0;
            t_wvalid       <= 1'b0;
            t_bready       <= 1'b0;
            t_araddr       <= 32'h0;
            t_arlen        <= 8'd0;
            t_arvalid      <= 1'b0;
            t_rready       <= 1'b0;
        end else if (init_done) begin
            case (test_state)
                T_IDLE: begin
                    t_awvalid <= 1'b0;
                    t_wvalid  <= 1'b0;
                    t_bready  <= 1'b0;
                    t_arvalid <= 1'b0;
                    t_rready  <= 1'b0;

                    if (test_cnt < 16'd100)
                        test_cnt <= test_cnt + 1'b1;
                    else begin
                        // 发起写：16 拍 burst
                        t_awaddr   <= TEST_ADDR;
                        t_awlen    <= 8'd15;
                        t_awvalid  <= 1'b1;
                        t_wdata    <= TEST_ADDR;             // 拍 0
                        t_wlast    <= 1'b0;
                        t_wvalid   <= 1'b1;
                        t_bready   <= 1'b1;
                        w_beat_cnt <= 5'd0;
                        test_state <= T_WR_ISSUE;
                    end
                end

                T_WR_ISSUE: begin
                    if (t_awvalid && m_axi_awready)
                        t_awvalid <= 1'b0;

                    if (t_wvalid && m_axi_wready) begin
                        if (w_beat_cnt == 5'd15) begin
                            t_wvalid   <= 1'b0;
                            t_wlast    <= 1'b0;
                            test_state <= T_WR_BRESP;
                        end else begin
                            w_beat_cnt <= w_beat_cnt + 1'b1;
                            t_wdata    <= TEST_ADDR + {w_beat_cnt + 1'b1, 2'b00};
                            t_wlast    <= (w_beat_cnt == 5'd14);
                        end
                    end
                end

                T_WR_BRESP: begin
                    if (m_axi_bvalid && t_bready) begin
                        t_bready   <= 1'b0;
                        // 发起 16 拍读
                        t_araddr   <= TEST_ADDR;
                        t_arlen    <= 8'd15;
                        t_arvalid  <= 1'b1;
                        t_rready   <= 1'b1;
                        r_beat_cnt <= 5'd0;
                        test_state <= T_RD_ISSUE;
                    end
                end

                T_RD_ISSUE: begin
                    if (t_arvalid && m_axi_arready)
                        t_arvalid <= 1'b0;
                    if (!t_arvalid)
                        test_state <= T_RD_WAIT;
                end

                T_RD_WAIT: begin
                    if (m_axi_rvalid && t_rready) begin
                        // 期望值：TEST_ADDR + r_beat_cnt * 4
                        r_data_expect = TEST_ADDR + {r_beat_cnt, 2'b00};

                        if (m_axi_rdata != r_data_expect) begin
                            test_rdata_fail <= m_axi_rdata;
                            test_pass       <= 1'b0;
                            test_fail       <= 1'b1;
                            t_rready        <= 1'b0;
                            test_state      <= T_FAIL;
                        end else if (m_axi_rlast || (r_beat_cnt == 5'd15)) begin
                            test_pass  <= 1'b1;
                            test_fail  <= 1'b0;
                            t_rready   <= 1'b0;
                            test_state <= T_DONE;
                        end else begin
                            r_beat_cnt <= r_beat_cnt + 1'b1;
                        end
                    end
                end

                T_DONE, T_FAIL: begin
                    // 停在终态
                end

                default: test_state <= T_IDLE;
            endcase
        end
    end

    // ==========================================
    // AXI 输出（测试 FSM 独占）
    // ==========================================
    assign m_axi_awaddr  = t_awaddr;
    assign m_axi_awlen   = t_awlen;
    assign m_axi_awvalid = t_awvalid;
    assign m_axi_wdata   = t_wdata;
    assign m_axi_wlast   = t_wlast;
    assign m_axi_wvalid  = t_wvalid;
    assign m_axi_bready  = t_bready;
    assign m_axi_araddr  = t_araddr;
    assign m_axi_arlen   = t_arlen;
    assign m_axi_arvalid = t_arvalid;
    assign m_axi_rready  = t_rready;

    // ==========================================
    // Next186 的返回信号（CPU 复位，不给数据）
    // ==========================================
    assign ram_rdata    = 16'h0000;
    assign ram_rd_valid = 1'b0;
    assign ram_wr_valid = 1'b0;

    // ==========================================
    // ILA 探针
    // ==========================================
    (* mark_debug = "true" *) reg [3:0]  dbg_test_state;
    (* mark_debug = "true" *) reg [31:0] dbg_awaddr;
    (* mark_debug = "true" *) reg        dbg_awvalid;
    (* mark_debug = "true" *) reg        dbg_awready;
    (* mark_debug = "true" *) reg [31:0] dbg_wdata;
    (* mark_debug = "true" *) reg        dbg_wvalid;
    (* mark_debug = "true" *) reg        dbg_wready;
    (* mark_debug = "true" *) reg        dbg_bvalid;
    (* mark_debug = "true" *) reg [31:0] dbg_araddr;
    (* mark_debug = "true" *) reg        dbg_arvalid;
    (* mark_debug = "true" *) reg        dbg_arready;
    (* mark_debug = "true" *) reg [31:0] dbg_rdata;
    (* mark_debug = "true" *) reg        dbg_rvalid;
    (* mark_debug = "true" *) reg        dbg_rready;
    (* mark_debug = "true" *) reg        dbg_rlast;
    (* mark_debug = "true" *) reg [31:0] dbg_test_rdata_fail;
    (* mark_debug = "true" *) reg        dbg_test_pass;
    (* mark_debug = "true" *) reg        dbg_test_fail;
    (* mark_debug = "true" *) reg [4:0]  dbg_r_beat_cnt;
    (* mark_debug = "true" *) reg [4:0]  dbg_w_beat_cnt;

    always @(posedge m_axi_aclk) begin
        dbg_test_state       <= test_state;
        dbg_awaddr           <= m_axi_awaddr;
        dbg_awvalid          <= m_axi_awvalid;
        dbg_awready          <= m_axi_awready;
        dbg_wdata            <= m_axi_wdata;
        dbg_wvalid           <= m_axi_wvalid;
        dbg_wready           <= m_axi_wready;
        dbg_bvalid           <= m_axi_bvalid;
        dbg_araddr           <= m_axi_araddr;
        dbg_arvalid          <= m_axi_arvalid;
        dbg_arready          <= m_axi_arready;
        dbg_rdata            <= m_axi_rdata;
        dbg_rvalid           <= m_axi_rvalid;
        dbg_rready           <= m_axi_rready;
        dbg_rlast            <= m_axi_rlast;
        dbg_test_rdata_fail  <= test_rdata_fail;
        dbg_test_pass        <= test_pass;
        dbg_test_fail        <= test_fail;
        dbg_r_beat_cnt       <= r_beat_cnt;
        dbg_w_beat_cnt       <= w_beat_cnt;
    end

    // ==========================================
    // LED 指示
    // ==========================================
    assign test_led[0] = test_pass;                                        // 通过
    assign test_led[1] = test_fail;                                        // 失败
    assign test_led[2] = blink_cnt[25];                                    // 心跳
    assign test_led[3] = (test_state == T_DONE) || (test_state == T_FAIL); // 测试结束

endmodule
