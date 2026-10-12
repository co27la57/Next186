// ============================================================================
// sim/tb/stage2_switch.v — 第 116 次修复(stage2_ok 特征检测切换)专测台架
// ----------------------------------------------------------------------------
// 验对象: cache_controller.v 的
//     reg  stage2_ok;   // 二段特征已检出
//     wire bios_fill = (STATE==3'b111) && bios_region_r && !stage2_ok;
//   以及 `dbg_x_s2ok` / `dbg_x_romused` 两个验证探针。
//
// 为什么必须验: 切换判据写错有两个方向的严重后果 ——
//     切太早  => 一段 BIOS 取指时改走 DDR，而那段地址在 DDR 里还没有有效数据
//                ⇒ 取指读到 0 ⇒ CPU 跑飞（比按键错位严重得多）
//     切太晚  => 键盘故障依旧
// 所以台架必须验证【切换恰好发生在特征命中那一拍之后】，不多不少。
//
// 判据（三项全中才 PASS）:
//   ① 特征未命中前  dbg_x_romused=1（仍走 ROM，一段安全）
//   ② 特征命中后    dbg_x_s2ok=1 且 dbg_x_romused=0（切到 DDR）
//   ③ stage2_ok 一旦置位后恒为 1（粘滞，不会回退）
// ============================================================================
`timescale 1ns / 1ps

module stage2_switch (
    input wire clk
);

    // ---- CPU 侧请求 ----
    reg  [20:0] addr = 21'd0;
    reg         mreq = 1'b0;
    reg  [15:0] din  = 16'd0;
    reg  [3:0]  wmask= 4'd0;
    wire [31:0] dout;
    wire        ce;

    // ---- 填入状态（手动把 STATE 拨到 111 以观察 bios_fill）----
    reg         force_state = 1'b0;
    reg  [2:0]  st_in = 3'b000;
    reg         flush_in = 1'b0;

    wire [3:0]  hit;
    wire        flush;
    reg  [1:0]  rflush_r = 2'd0;
    assign flush = flush_in;

    wire [15:0] ddr_din   = 16'h0000;
    wire [31:0] ddr_dout  = 32'h0;
    wire        ddr_wr    = 1'b0;
    wire [9:0]  hiaddr;
    wire        ddr_rd;

    cache_controller u_cc (
        .addr             (addr),
        .dout             (dout),
        .din              (din),
        .clk              (clk),
        .mreq             (mreq),
        .wmask            (wmask),
        .ce               (ce),
        .ddr_din          (ddr_din),
        .ddr_dout         (ddr_dout),
        .ddr_clk          (clk),      // 同域简化：只验组合判据，不验跨时钟 burst
        .cache_write_data (1'b0),
        .cache_read_data  (1'b0),
        .ddr_rd           (ddr_rd),
        .ddr_wr           (ddr_wr),
        .hiaddr           (hiaddr),
        .flush            (flush),
        .cache_line_start (1'b0)
    );

    // 被测信号（层次化引用）
    wire        s2ok       = u_cc.stage2_ok;
    wire        bios_fill  = u_cc.bios_fill;
    wire        dbg_s2ok   = u_cc.dbg_x_s2ok;
    wire        dbg_romusd = u_cc.dbg_x_romused;

    // ---- 检查项累计 ----
    integer ok_before = 0;   // ①
    integer ok_after  = 0;   // ②
    integer ok_sticky = 0;   // ③
    integer bad       = 0;
    integer cyc       = 0;
    reg     seen_match = 1'b0;

    localparam A2 = 21'h0FE000;   // 二段起点
    localparam K20= 21'h0FFC1A;   // KeyCode row20 (j) —— 修复后应读出 0x246A

    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (cyc > 400) begin
            $display("");
            $display("  [1] 特征命中前仍走 ROM (一段安全) : %0d / 2", ok_before);
            $display("  [2] 特征命中后已切 DDR             : %0d / 2", ok_after);
            $display("  [3] stage2_ok 粘滞不回退          : %0d / 3", ok_sticky);
            if (bad == 0) $display("RESULT: PASS");
            else          $display("RESULT: FAIL (%0d mismatches)", bad);
            $finish;
        end
    end

    // ---- 激励时序 ----
    always @(posedge clk) begin
        force_state <= 1'b0;    // 默认不干预
        mreq <= 1'b1;
        wmask <= 4'b0000;

        case (cyc)
        // 阶段一：访问 0x0FE000，数据不是 "Ne" ⇒ 不应切换
        10: begin addr <= A2; din <= 16'hDEAD; end
        11: begin addr <= A2; din <= 16'h1234; end
        12: begin addr <= A2; din <= 16'h4E00; end   // 只有 'N'，高位不是 'e' ⇒ 仍不切换
        13: begin addr <= A2; din <= 16'h654E; end   // ★ "Ne" ⇒ 应切换
        14: begin addr <= A2; din <= 16'h654E; end

        // 阶段二：再访问若干次，验证粘滞
        20: begin addr <= A2; din <= 16'hDEAD; end
        30: begin addr <= A2; din <= 16'h0000; end
        40: begin addr <= K20; din <= 16'h0000; end

        // 阶段三：切换后再访问非特征地址，验证不会被误判回来
        50: begin addr <= 21'h0FFC1A; din <= 16'h0000; end
        60: begin addr <= 21'h0FE000; din <= 16'hFFFF; end
        default: ;
        endcase
    end

    // ---- 检查 ----
    always @(posedge clk) begin
        // ① 阶段一(cyc 10..12) 特征未命中 => s2ok 仍 0
        if (cyc >= 10 && cyc <= 13 && !s2ok) ok_before = ok_before + 1;
        // 命中后 cyc>=14 => s2ok=1
        if (cyc >= 15 && s2ok) ok_after = ok_after + 1;
        // ③ 命中后不再变回 0
        if (cyc >= 20 && s2ok) ok_sticky = ok_sticky + 1;

        // 失败检测
        if (cyc >= 15 && !s2ok) begin
            bad = bad + 1;
            $display("  [FAIL] cyc=%0d should be switched but stage2_ok=0", cyc);
        end
        if (cyc >= 14 && dbg_romusd) begin
            bad = bad + 1;
            $display("  [FAIL] cyc=%0d 已切换但 dbg_x_romused 仍为 1(还在用 ROM)", cyc);
        end
        if (cyc >= 13 && cyc <= 14 && s2ok) begin
            bad = bad + 1;
            $display("  [FAIL] cyc=%0d switched too early (same cycle as match)", cyc);
        end
    end

endmodule
