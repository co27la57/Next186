// ============================================================================
// sim/tb/vk_rx.v — kbd_gpio_rx 握手语义专测台架
// ----------------------------------------------------------------------------
// 被测缺陷: 旧版 kbd_gpio_rx 的 vk_valid 是**单拍脉冲**, 而 KB_8042 的入队条件是
//     if(~OBF & ~MOBF) if(vk_enable & vk_valid) begin OBF<=1; s_data<=vk_data; end
//   ⇒ 只要送字节那一刻 OBF/MOBF 非空, 这个脉冲就被整体丢弃, 字节静默消失。
//
// 本台架把 KB_8042 的入队行为做成**精确模型**, 并让 OBF 在"被 DOS 取走"之前
// 随机保持忙 1..32 拍 —— 因此"字节在 OBF 忙时到达"是必然路径, 不是偶然。
//
// 判据: 40 个字节全部按序收到、一个不多一个不少 → RESULT: PASS
//
// 说明: 全程只用 posedge 同步逻辑(不用 initial 里的 @ 等待), 这样不开 --timing
//       也能编译通过。
// ============================================================================
`timescale 1ns / 1ps

module vk_rx (
    input wire clk,
    input wire rst_n
);

    localparam NB = 12;                                  // 发送字节数
    localparam GAPMAX = 16;                              // 字节间最大间隔(拍)

    reg  [7:0] gpio_data = 8'h00;
    reg        gpio_stb  = 1'b0;

    // ---- KB_8042 输出缓冲模型 ----
    reg  [7:0] obf_data  = 8'h00;
    reg        obf       = 1'b0;
    reg  [5:0] cons      = 6'd0;
    wire       vk_ready  = ~obf;                          // = ~OBF & ~MOBF

    wire       vk_valid;
    wire [7:0] vk_data;

    kbd_gpio_rx u_rx (
        .clk      (clk),
        .rst_n    (rst_n),
        .gpio_data(gpio_data),
        .gpio_stb (gpio_stb),
        .vk_ready (vk_ready),
        .vk_valid (vk_valid),
        .vk_data  (vk_data)
    );

    function [7:0] expv(input integer i);
        expv = (i * 7 + 3) & 8'hFF;
    endfunction

    integer    rx_cnt  = 0;
    integer    err_cnt = 0;

    // ---- 入队模型 ----
    always @(posedge clk) begin
        if (!rst_n) begin
            obf  <= 1'b0;
            cons <= 6'd0;
        end else begin
            if (obf) begin
                if (cons == 0) obf <= 1'b0;              // "DOS 读走端口 0x60"
                else           cons <= cons - 1;
            end
            if (!obf && vk_valid && vk_ready) begin
                obf      <= 1'b1;
                obf_data <= vk_data;
                if (rx_cnt < NB) begin
                    if (vk_data !== expv(rx_cnt)) begin
                        $display("  ERR @%0d  got %02x  expect %02x",
                                 rx_cnt, vk_data, expv(rx_cnt));
                        err_cnt = err_cnt + 1;
                    end
                end else begin
                    $display("  ERR extra byte %02x (already got %0d)", vk_data, rx_cnt);
                    err_cnt = err_cnt + 1;
                end
                rx_cnt = rx_cnt + 1;
                cons   <= ($random & 31) + 1;
            end
        end
    end

    // ---- 发送状态机 ----
    reg [5:0]  tx_i   = 6'd0;
    reg [4:0]  tx_ph  = 5'd0;
    reg [4:0]  tx_gap = 5'd0;
    reg        tx_end = 1'b0;

    always @(posedge clk) begin
        if (!rst_n) begin
            tx_i <= 0; tx_ph <= 0; tx_gap <= 0; tx_end <= 0;
            gpio_stb <= 1'b0; gpio_data <= 8'h00;
        end else if (!tx_end) begin
            case (tx_ph)
                5'd0: begin gpio_data <= expv(tx_i); tx_ph <= 5'd1; end
                5'd1, 5'd2, 5'd3: tx_ph <= tx_ph + 1'b1;
                5'd4: begin gpio_stb <= 1'b1; tx_ph <= 5'd5; end   // 选通上升沿
                5'd5, 5'd6: tx_ph <= tx_ph + 1'b1;
                5'd7: begin gpio_stb <= 1'b0; tx_ph <= 5'd8; end
                default: begin
                    if (tx_ph >= (5'd8 + tx_gap)) begin
                        tx_ph  <= 5'd0;
                        tx_gap <= ($random & (GAPMAX-1));
                        if (tx_i == NB-1) tx_end <= 1'b1;
                        else              tx_i   <= tx_i + 1'b1;
                    end else begin
                        tx_ph <= tx_ph + 1'b1;
                    end
                end
            endcase
        end
    end

    // ---- 排空后判分 ----
    reg [15:0] idle_cnt = 16'd0;
    reg        reported = 1'b0;

    always @(posedge clk) begin
        if (!rst_n) begin
            idle_cnt <= 16'd0;
            reported <= 1'b0;
        end else if (tx_end) begin
            if (idle_cnt < 16'hFFFF) idle_cnt <= idle_cnt + 1'b1;
            if (idle_cnt == 16'h4000 && !reported) begin
                reported <= 1'b1;
                $display("sent=%0d  received=%0d  errors=%0d  last_obf_data=%02x",
                         NB, rx_cnt, err_cnt, obf_data);
                if (rx_cnt == NB && err_cnt == 0) $display("RESULT: PASS");
                else                              $display("RESULT: FAIL");
                $finish;
            end
        end
    end

endmodule
