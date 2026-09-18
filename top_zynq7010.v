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
    // 5 秒等待 (250_000_000 @ 50MHz)
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

    (* mark_debug = "true" *) wire init_done = ~auto_rst_reg;
    (* mark_debug = "true" *) reg  init_fail = 1'b0;

    // ==========================================
    // 主 FSM 输出信号
    // ==========================================
    reg [31:0] main_awaddr;
    reg [7:0]  main_awlen;
    reg        main_awvalid;
    reg [31:0] main_wdata;
    reg        main_wlast;
    reg        main_wvalid;
    reg        main_bready;
    reg [31:0] main_araddr;
    reg [7:0]  main_arlen;
    reg        main_arvalid;
    reg        main_rready;

    wire next186_reset_trigger = auto_rst_reg;

    // ==========================================
    // Next186 SoC 实例化
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
        .BTN_SOUTH  (next186_reset_trigger),
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
    // 主 AXI FSM
    // ==========================================
    localparam IDLE      = 4'd0;
    localparam AR_ADDR   = 4'd1;
    localparam R_WAIT    = 4'd2;
    localparam R_PUSH_0  = 4'd3;
    localparam R_PUSH_1  = 4'd4;
    localparam W_ISSUE   = 4'd5;
    localparam W_L       = 4'd6;
    localparam W_H       = 4'd7;
    localparam W_WAIT_W  = 4'd8;
    localparam B_RESP    = 4'd9;

    reg [3:0]  state;
    reg [3:0]  idle_cnt;
    reg [31:0] latched_rdata;
    reg [15:0] latched_wdata_low;
    reg        rlast_latched;
    reg [4:0]  w_burst_cnt;
    reg [31:0] timeout_cnt = 32'd0;

    localparam TIMEOUT_MAX = 32'd500_000;

    always @(posedge m_axi_aclk or negedge m_axi_aresetn) begin
        if (!m_axi_aresetn) begin
            state         <= IDLE;
            idle_cnt      <= 4'd0;
            main_arvalid  <= 1'b0;
            main_awvalid  <= 1'b0;
            main_wvalid   <= 1'b0;
            main_rready   <= 1'b0;
            main_bready   <= 1'b0;
            ram_cmd_ack   <= 2'b00;
            timeout_cnt   <= 32'd0;
            w_burst_cnt   <= 5'd0;
        end else if (init_done) begin
            if (state == IDLE)
                timeout_cnt <= 32'd0;
            else
                timeout_cnt <= timeout_cnt + 1'b1;

            if (timeout_cnt >= TIMEOUT_MAX && state != IDLE) begin
                main_arvalid <= 1'b0;
                main_awvalid <= 1'b0;
                main_wvalid  <= 1'b0;
                main_rready  <= 1'b0;
                main_bready  <= 1'b0;
                state        <= IDLE;
                timeout_cnt  <= 32'd0;
            end
            else begin
                case (state)
                    IDLE: begin
                        main_arvalid <= 1'b0;
                        main_awvalid <= 1'b0;
                        main_wvalid  <= 1'b0;
                        main_rready  <= 1'b0;
                        main_bready  <= 1'b0;

                        if (idle_cnt < 4'd5) begin
                            idle_cnt    <= idle_cnt + 1'b1;
                            ram_cmd_ack <= 2'b00;
                        end
                        else if (ram_cmd != 2'b00) begin
                            ram_cmd_ack <= ram_cmd;
                            idle_cnt    <= 4'd0;
                            timeout_cnt <= 32'd0;

                            if (ram_cmd == 2'b10 || ram_cmd == 2'b11) begin
                                main_araddr  <= 32'h0800_0000 + {7'b0, ram_addr, 1'b0};
                                main_arlen   <= 8'd15;
                                main_arvalid <= 1'b1;
                                state        <= AR_ADDR;
                            end
                            else if (ram_cmd == 2'b01) begin
                                main_awaddr  <= 32'h0800_0000 + {7'b0, ram_addr, 1'b0};
                                main_awlen   <= 8'd15;      // ★ 恢复原版：16 拍 burst
                                main_awvalid <= 1'b1;
                                main_bready  <= 1'b1;
                                w_burst_cnt  <= 5'd0;
                                state        <= W_ISSUE;
                            end
                        end
                    end

                    AR_ADDR: begin
                        if (m_axi_arready && main_arvalid) begin
                            main_arvalid <= 1'b0;
                            state        <= R_WAIT;
                        end
                    end
                    R_WAIT: begin
                        main_rready <= 1'b1;
                        if (m_axi_rvalid && main_rready) begin
                            latched_rdata <= m_axi_rdata;
                            rlast_latched <= m_axi_rlast;
                            main_rready   <= 1'b0;
                            state         <= R_PUSH_0;
                        end
                    end
                    R_PUSH_0: state <= R_PUSH_1;
                    R_PUSH_1: begin
                        if (rlast_latched) state <= IDLE;
                        else               state <= R_WAIT;
                    end

                    W_ISSUE: begin
                        if (main_awvalid && m_axi_awready) main_awvalid <= 1'b0;
                        latched_wdata_low <= ram_wdata;
                        state             <= W_L;
                    end

                    W_L: begin
                        state <= W_H;
                    end

                    W_H: begin
                        main_wdata  <= {latched_wdata_low, ram_wdata};
                        main_wlast  <= (w_burst_cnt == 5'd15);
                        main_wvalid <= 1'b1;
                        state       <= W_WAIT_W;
                    end

                    W_WAIT_W: begin
                        if (main_wvalid && m_axi_wready) begin
                            main_wvalid <= 1'b0;
                            main_wlast  <= 1'b0;
                            if (w_burst_cnt == 5'd15) begin
                                state <= B_RESP;
                            end else begin
                                w_burst_cnt <= w_burst_cnt + 1'b1;
                                state       <= W_ISSUE;
                            end
                        end
                    end

                    B_RESP: begin
                        if (m_axi_bvalid && main_bready) begin
                            main_bready <= 1'b0;
                            state       <= IDLE;
                        end
                    end

                    default: state <= IDLE;
                endcase
            end
        end
    end

    // ==========================================
    // 输出 MUX
    // ==========================================
    assign m_axi_awaddr  = main_awaddr;
    assign m_axi_awlen   = main_awlen;
    assign m_axi_awvalid = main_awvalid;
    assign m_axi_wdata   = main_wdata;
    assign m_axi_wlast   = main_wlast;
    assign m_axi_wvalid  = main_wvalid;
    assign m_axi_bready  = main_bready;
    assign m_axi_araddr  = main_araddr;
    assign m_axi_arlen   = main_arlen;
    assign m_axi_arvalid = main_arvalid;
    assign m_axi_rready  = main_rready;

    // ==========================================
    // ILA 探针
    // ==========================================
    (* mark_debug = "true" *) wire [3:0]  dbg_axi_state        = state;
    (* mark_debug = "true" *) wire [1:0]  dbg_axi_bresp        = m_axi_bresp;
    (* mark_debug = "true" *) wire [31:0] dbg_axi_awaddr_full  = m_axi_awaddr;
    (* mark_debug = "true" *) wire [7:0]  dbg_axi_awlen        = m_axi_awlen;
    (* mark_debug = "true" *) wire [3:0]  dbg_axi_wstrb        = m_axi_wstrb;
    (* mark_debug = "true" *) wire [31:0] dbg_axi_wdata_full   = m_axi_wdata;
    (* mark_debug = "true" *) wire        dbg_axi_wvalid       = m_axi_wvalid;
    (* mark_debug = "true" *) wire        dbg_axi_wready       = m_axi_wready;
    (* mark_debug = "true" *) wire        dbg_axi_awvalid      = m_axi_awvalid;
    (* mark_debug = "true" *) wire        dbg_axi_awready      = m_axi_awready;
    (* mark_debug = "true" *) wire        dbg_axi_bvalid       = m_axi_bvalid;
    (* mark_debug = "true" *) wire        dbg_axi_bready       = m_axi_bready;

    // ==========================================
    // 输出脉冲与 LED
    // ==========================================
    assign ram_rdata    = (state == R_PUSH_0) ? latched_rdata[15:0] : latched_rdata[31:16];
    assign ram_rd_valid = (state == R_PUSH_0) || (state == R_PUSH_1);
    assign ram_wr_valid = (state == W_L) || (state == W_H);

    assign test_led[0] = init_done && !init_fail;
    assign test_led[1] = init_done &&  init_fail;
    assign test_led[2] = blink_cnt[25];
    assign test_led[3] = SDLED;

endmodule