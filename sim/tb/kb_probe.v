// ============================================================================
// sim/tb/kb_probe.v — KB_8042 新增探针(dbg_last_byte/take_byte/take_pulse)专测台架
// ----------------------------------------------------------------------------
// 目的: 在丢给 Vivado 编译之前, 用 Verilator 快速验证第 113 次新增/修改的探针逻辑
//       是否正确 —— 特别是新加的 `dbg_take_pulse` / `dbg_take_byte` 写在了
//       「BIOS 读数据口 0x60」那个分支里, 必须确认它真的在字节被取走时拉高,
//       且取到的字节与送进去的字节一致。
//
// 被验目标(节选自本次调查的关键结论):
//   故障现象 : 注入 0x24 (j), BIOS 屏幕上却显示 '4' (0x34)
//   离线推论 : KeyCode 表 row51 首字节 = 0x34 = '4'
//               ⇒ 若 xlat 算出的行号(20)正确, 却读出 row51 的字符,
//                 则只能是「进 BIOS 的扫描码不是 0x24」。
//               本台架验证: 只要注入 0x24, dbg_take_byte 就必须是 0x24。
//
// 判据: 注入 5 个字节, 每个都满足
//         (a) dbg_last_byte  == 注入值   (装缓冲时刻锁存)
//         (b) dbg_take_byte  == 注入值   (BIOS 取走时刻锁存)
//         (c) dbg_take_pulse 恰好拉高 1 拍
//       → 全中 RESULT: PASS
// ============================================================================
`timescale 1ns / 1ps

module kb_probe (
    input wire clk,
    input wire rst_n
);

    // ---- 模拟 BIOS 的 I/O 端口访问 ----
    reg  [7:0] port_addr = 8'h00;   // 0x60 = 数据口, 0x64 = 命令口
    reg        cs        = 1'b0;
    reg        we        = 1'b0;
    reg  [7:0] wdata     = 8'h00;
    wire [7:0] dout;

    // ---- 虚拟键盘输入 ----
    reg  [7:0] vk_byte  = 8'h00;
    reg        vk_vld   = 1'b0;
    wire       vk_rdy;
    reg        vk_en    = 1'b1;

    wire I_KB, I_MOUSE, CPU_RST;
    wire PS2_CLK1, PS2_CLK2, PS2_DATA1, PS2_DATA2;
    assign PS2_CLK1 = 1'b1;  assign PS2_DATA1 = 1'b1;
    assign PS2_CLK2 = 1'b1;  assign PS2_DATA2 = 1'b1;

    KB_Mouse_8042 u_kb (
        .CS       (cs),
        .WR       (we),
        .cmd      (port_addr[2]),   // 与 ddr_186.v 一致: cmd = PORT_ADDR[2] (0x64=>1, 0x60=>0)
        .din      (wdata),
        .dout     (dout),
        .clk      (clk),
        .I_KB     (I_KB),
        .I_MOUSE  (I_MOUSE),
        .CPU_RST  (CPU_RST),
        .PS2_CLK1 (PS2_CLK1),
        .PS2_CLK2 (PS2_CLK2),
        .PS2_DATA1(PS2_DATA1),
        .PS2_DATA2(PS2_DATA2),
        .vk_enable(vk_en),
        .vk_valid (vk_vld),
        .vk_data  (vk_byte),
        .vk_ready (vk_rdy)
    );

    // 层次化引用被测探针
    wire [7:0] last_byte  = u_kb.dbg_last_byte;
    wire [1:0] last_src   = u_kb.dbg_last_src;
    wire       take_pulse = u_kb.dbg_take_pulse;
    wire [7:0] take_byte  = u_kb.dbg_take_byte;

    // ---- 测试序列 ----
    localparam NB  = 5;
    reg [7:0] tb [0:NB-1];
    reg [3:0] li = 4'd0;
    reg [7:0] wpo = 8'd0;
    reg [2:0] ph = 3'd0;

    initial begin
        tb[0]=8'h24; tb[1]=8'hE0; tb[2]=8'hF0; tb[3]=8'h7A; tb[4]=8'hE1;
    end

    integer ok_a = 0, ok_b = 0, ok_c = 0, bad = 0;
    integer cyc = 0;

    // ---- 期望值锁存 ----
    reg [7:0] exp_last = 8'h00;
    reg [7:0] exp_take = 8'h00;
    reg       pulse_seen = 1'b0;
    reg       take_pulse_q = 1'b0;
    reg prev_pulse = 1'b0;

    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (cyc > 4000) begin
            $display("  [DBG] ph=%0d li=%0d vk_rdy=%0d dout=%02x OBF_path last=%02x tp=%0d",
                     ph, li, vk_rdy, dout, last_byte, take_pulse);
            $display("");
            $display("  dbg_last_byte OK : %0d / %0d", ok_a, NB);
            $display("  dbg_take_byte OK : %0d / %0d", ok_b, NB);
            $display("  take_pulse   OK : %0d / %0d", ok_c, NB);
            if (bad == 0) $display("RESULT: PASS");
            else          $display("RESULT: FAIL (%0d mismatches)", bad);
            $finish;
        end
    end

    // ---- 激励状态机 ----
    always @(posedge clk) begin
        if (!rst_n) begin
            li <= 4'd0; wpo <= 8'd0; ph <= 3'd0;
            vk_vld <= 1'b0; cs <= 1'b0; we <= 1'b0;
            exp_last <= 8'h00; exp_take <= 8'h00; pulse_seen <= 1'b0;
        end else begin
            case (ph)
            3'd0: begin
                // 等待缓冲空
                if (vk_rdy) begin
                    vk_byte <= tb[li];
                    exp_last <= tb[li];
                    exp_take <= tb[li];
                    vk_vld   <= 1'b1;
                    ph <= 3'd1;
                end
            end
            3'd1: begin
                vk_vld <= 1'b0;
                wpo    <= 8'd0;
                ph     <= 3'd2;
            end
            3'd2: begin
                // 模拟 BIOS 读状态口 0x64 (一个周期), 轮询 bit0 = OBF
                if (wpo == 8'd0) begin
                    port_addr <= 8'h64; cs <= 1'b1; wpo <= 8'd1;
                end else begin
                    cs   <= 1'b0;
                    wpo  <= 8'd0;
                    if (dout[0]) ph <= 3'd3;   // OBF 有数据 → 去读数据口
                end
            end
            3'd3: begin
                // 读数据口 0x60 —— 这一刻触发 dbg_take_pulse
                cs  <= 1'b1;
                port_addr <= 8'h60;
                ph  <= 3'd4;
            end
            3'd4: begin
                cs <= 1'b0;
                if (take_pulse_q) begin
                    pulse_seen <= 1'b1;
                    if (last_byte == exp_last) ok_a <= ok_a + 1;
                    else begin
                        bad <= bad + 1;
                        $display("  [A] last_byte mismatch @li=%0d exp=%02x act=%02x",
                                 li, exp_last, last_byte);
                    end
                    if (take_byte == exp_take) ok_b <= ok_b + 1;
                    else begin
                        bad <= bad + 1;
                        $display("  [B] take_byte mismatch @li=%0d exp=%02x act=%02x",
                                 li, exp_take, take_byte);
                    end
                    ok_c <= ok_c + 1;
                end
                ph <= 3'd5;
            end
            3'd5: begin
                li <= li + 4'd1;
                if (li + 4'd1 >= NB) begin
                    ph <= 3'd0;
                    $display("  byte[%0d] done: last=%02x take=%02x src=%0d",
                             li, last_byte, take_byte, last_src);
                end else begin
                    ph <= 3'd0;
                end
            end
            default: ph <= 3'd0;
            endcase
        end
    end

    // ---- 探针内部逻辑自检: take_pulse 是否恰好 1 拍 ----
    always @(posedge clk) begin
        take_pulse_q <= take_pulse;
        prev_pulse   <= take_pulse;
        if (prev_pulse && take_pulse) begin
            bad <= bad + 1;
            $display("  [C] take_pulse stuck high for >1 cycle");
        end
    end

endmodule
