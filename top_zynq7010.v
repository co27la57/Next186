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
    wire [31:0] ram_wdata;     // ★ 方案A：写回整 32-bit 字（= cache 侧 ddr_dout 经 SoC 直通）
    wire [15:0] ram_rdata;
    wire        ram_rd_valid;
    wire        ram_wr_valid;  // ★ 实验探针：cache 读窗口（方案A 已回退为原始窗口）
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

    wire init_done = ~auto_rst_reg;
    reg  init_fail = 1'b0;

    // ==========================================
    // 主 FSM 输出信号
    // ==========================================
    reg [31:0] main_awaddr;
    reg [7:0]  main_awlen;
    reg        main_awvalid;
    reg [31:0] main_wdata;    // ★ 实验探针：拼出的 32-bit 写数据
    reg        main_wlast;
    reg        main_wvalid;
    reg        main_bready;
    reg [31:0] main_araddr;
    reg [7:0]  main_arlen;
    reg        main_arvalid;
    reg        main_rready;

    // ==========================================
    // [RST-BTN] Reset button (polarity-agnostic): sync + debounce + fixed-length pulse.
    //   Background: next186_reset_trigger used to be driven ONLY by auto_rst_reg
    //   (5 s after configuration). The physical BTN_SOUTH top-level input was left
    //   dangling, so NO button could ever restart the BIOS.
    //   Design: assume NOTHING about button polarity. A *stable level change* on the
    //   pin (low->high OR high->low) generates one fixed-length reset pulse, so the
    //   board can never be stuck permanently in reset, whatever the XDC polarity is.
    //   Usage: hold the button >20 ms. Release also counts as a change (harmless,
    //   it just produces one extra reset pulse).
    // ==========================================
    reg  [1:0]  rst_btn_sync  = 2'b11;  // 2-stage sync; init 1 = typical pulled-up idle
    reg  [19:0] rst_btn_dbc   = 20'd0;  // debounce counter (~21 ms @50MHz)
    reg         rst_btn_lvl   = 1'b1;   // debounced stable level
    reg         rst_btn_pulse = 1'b0;   // reset pulse
    reg  [21:0] rst_btn_cnt   = 22'd0;  // pulse width counter (2_000_000 ~ 40 ms @50MHz)

    always @(posedge m_axi_aclk) begin
        rst_btn_sync <= {rst_btn_sync[0], BTN_SOUTH};
        if (rst_btn_sync[1] == rst_btn_lvl) begin
            rst_btn_dbc <= 20'd0;
        end else if (rst_btn_dbc != 20'hFFFFF) begin
            rst_btn_dbc <= rst_btn_dbc + 1'b1;
            if (rst_btn_dbc == 20'hFFFFE) begin  // level change confirmed stable
                rst_btn_lvl   <= rst_btn_sync[1];
                rst_btn_pulse <= 1'b1;
                rst_btn_cnt   <= 22'd0;
            end
        end
        if (rst_btn_pulse) begin
            if (rst_btn_cnt == 22'd2_000_000) rst_btn_pulse <= 1'b0;
            else                              rst_btn_cnt <= rst_btn_cnt + 1'b1;
        end
    end

    wire next186_reset_trigger = auto_rst_reg | rst_btn_pulse;

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
    localparam W_PRE     = 4'd10;  // ★ 二十二次修复：插入一拍等待 cache_line_start 到达 cache_controller 并把 lowaddr 归零
    localparam W_L       = 4'd6;
    localparam W_H       = 4'd7;
    localparam W_WAIT_W  = 4'd8;
    localparam B_RESP    = 4'd9;

    (* mark_debug = "true", keep = "true" *) reg [3:0]  state;             // ★ 实验探针：写 FSM 状态
    reg [3:0]  idle_cnt;
    reg [31:0] latched_rdata;
    reg        rlast_latched;
    reg [4:0]  w_burst_cnt;       // ★ 实验探针：第几个 32-bit 字（0..15）
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
                        // ★ 方案A：不再采半字（整字在 W_H 拍一次锁存）
                        state             <= W_PRE;
                    end

                    W_PRE: begin
                        // ★ 二十二次修复：多等一拍，让 ddr_186.v 发出的 cache_line_start 脉冲
                        //   在 W_L 拍前到达 cache_controller 并把 lowaddr 强置 0，消除 W_H 拍首字读到
                        //   旧 cache line 残留或 0 造成的 +1 word 偏移。
                        state <= W_L;
                    end

                    W_L: begin
                        state <= W_H;
                    end

                    W_H: begin
                        // ★ 方案A：W_H 拍 cache 已给出整 32-bit 字（ddr_dout=cache_QA=word n），直接锁存
                        main_wdata  <= ram_wdata;
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

    // AXI 探针已全部移除（2026-09-19）：改用 system ILA 自动探针，不再手动 mark_debug。
    // 历史探针名（dbg_axi_awaddr_full/dbg_axi_araddr_full/dbg_axi_rlast 等）如需回溯见 git ae9570a。


    // ==========================================
    // 输出脉冲与 LED
    // ==========================================
    assign ram_rdata    = (state == R_PUSH_0) ? latched_rdata[15:0] : latched_rdata[31:16];
    assign ram_rd_valid = (state == R_PUSH_0) || (state == R_PUSH_1);
    // ★ 方案 A（2026-09-20）：取消 16-bit 半字 × 2 拍配对，写回直接送整 32-bit 字。
    //   方案 B（把本窗口由 (W_L||W_H) 前移为 (W_ISSUE||W_L)）实测仅 56% 正确
    //   （粘滞计数 dup=1771 / ok=2293），证明 2-beat 配对对 AXI wready 造成的
    //   W_WAIT_W 抖动敏感、不可靠 → 回退窗口，改用整字（配对彻底消失）：
    //   W_H 拍 cache 已给出 word n 的整字（lowaddr 每字步进 2 → W_L 拍 address_a=word n
    //   → 寄存 1 拍后 W_H 拍 q_a=word n），FSM 直接 main_wdata<=ram_wdata，与停顿无关。
    assign ram_wr_valid = (state == W_L) || (state == W_H);

    assign test_led[0] = init_done && !init_fail;
    assign test_led[1] = init_done &&  init_fail;
    assign test_led[2] = blink_cnt[25];
    assign test_led[3] = SDLED;

    // ==========================================
    // ★ 方案 A 验证粘滞计数（2026-09-20，纯观测，不影响主逻辑）
    //   dbg_wb_word_cnt  : 累计写出的 32-bit 字数（每次 AXI 写握手 +1）
    //   dbg_wb_burst_cnt : 累计写回 burst 数（w_burst_cnt 到 15 时 +1）
    //   上电清零、持续累加；上板跑几秒读数即可确认写回在持续进行。
    //   **数据是否正确以 PS dump 为准**：0x08068000 起应不再"每 16-bit 成对重复"。
    // ==========================================
    reg [15:0] dbg_wb_word_cnt  = 16'd0;
    reg [15:0] dbg_wb_burst_cnt = 16'd0;

    always @(posedge m_axi_aclk) begin
        if (state == W_WAIT_W && main_wvalid && m_axi_wready) begin
            dbg_wb_word_cnt <= dbg_wb_word_cnt + 1'b1;
            if (w_burst_cnt == 5'd15) dbg_wb_burst_cnt <= dbg_wb_burst_cnt + 1'b1;
        end
    end

endmodule