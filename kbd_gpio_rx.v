// ============================================================================
// kbd_gpio_rx.v — 从 PS EMIO GPIO 接收 scancode 字节 (并行 8 位 + 选通, 不经 AXI!)
// ----------------------------------------------------------------------------
// 传输: 8 位并行 + 选通。发送端先写 gpio_data[7:0], 再拉高 gpio_stb;
//   PL 在选通上升沿锁存已稳定的 8 位。
//
// ★★★ 2026-10-10 修复(FIFO 版) ★★★
//   历史演进与各自的真实缺陷:
//     · 第 24 轮: `if(stb_rise) vk_valid <= 1'b1;` —— vk_valid 只有**1 拍**。
//       而 KB_8042 的入队条件是 `if(~OBF & ~MOBF) if(vk_enable & vk_valid)`:
//       只要送字节那一刻 8042 缓冲非空(上一条 make 的 break 还没被 BIOS 的
//       INT09 从端口 0x60 取走), 这**一个脉冲就被整体丢弃**, 字节静默消失。
//       症状: 丢 make ⇒ 该键不出字符; 丢 break ⇒ 按键粘住 ⇒ DOS 卡死。
//     · 第 27 轮: 加 16 深度 FIFO + vk_ready 握手, 结果键盘**一个字符都收不到**。
//       根因: vk_ready 里含 `~ctl_outb`。ctl_outb 是"80186 发了 0x20 读配置
//       命令但还没读端口 0x60"的标志, 启动时一旦卡住, vk_ready 就恒 0
//       ⇒ FIFO 永不弹出 ⇒ 链路整体堵死。
//     · 本版 = 正确的组合:
//         (1) vk_ready **只**用 ~OBF & ~MOBF(在 KB_8042.v 里改), 去掉 ctl_outb
//             ⇒ 不再有"永远不接收"的死锁;
//         (2) 保留 16 深度 FIFO ⇒ 发送端快于 8042 时也不丢字节;
//         (3) vk_valid 为**电平**(= FIFO 非空), 配合上面的握手, 每字节恰好
//             被取走一次(既不丢也不重发)。
//   验证: sim/tb/vk_rx.v 用 KB_8042 入队行为的精确模型 + 慢消费者,
//        12 字节 100% 按序收到 → RESULT: PASS。(旧版同台架会丢字节)
//
//   端口列表与旧版**完全一致**, BD 侧无需任何改动。
// ============================================================================
`timescale 1ns / 1ps

module kbd_gpio_rx #(
    parameter DW    = 8,
    parameter DEPTH = 16          // FIFO 深度(2 的幂)
)(
    input  wire            clk,        // clk_cpu
    input  wire            rst_n,      // 高有效复位
    // ---- PS EMIO GPIO ----
    input  wire [DW-1:0]   gpio_data,
    input  wire            gpio_stb,
    // ---- 与 8042 的握手 ----
    input  wire            vk_ready,   // 1 = 8042 输出缓冲空, 可接收
    // ---- 输出: 一个完整字节(在 clk 域) ----
    output wire            vk_valid,   // **电平**: FIFO 非空期间一直为 1
    output wire [DW-1:0]   vk_data      // 首字直通(FWFT): 始终是队头
);

    // ---- 输入同步 (2-FF + ASYNC_REG) ----
    (* ASYNC_REG = "TRUE" *) reg [DW-1:0] d1 = {DW{1'b0}}, d2 = {DW{1'b0}};
    (* ASYNC_REG = "TRUE" *) reg          s1 = 1'b0, s2 = 1'b0;

    wire stb_rise = (s1 & ~s2);

    // ---- FWFT FIFO ----
    reg  [DW-1:0] mem [0:DEPTH-1];
    reg  [4:0]    wptr = 5'd0;
    reg  [4:0]    rptr = 5'd0;

    wire empty = (wptr == rptr);
    wire full  = (wptr[3:0] == rptr[3:0]) && (wptr[4] != rptr[4]);

    always @(posedge clk) begin
        if (!rst_n) begin
            d1   <= {DW{1'b0}};
            d2   <= {DW{1'b0}};
            s1   <= 1'b0;
            s2   <= 1'b0;
            wptr <= 5'd0;
            rptr <= 5'd0;
        end else begin
            d1 <= gpio_data;
            d2 <= d1;
            s1 <= gpio_stb;
            s2 <= s1;

            if (stb_rise && !full) begin
                // 数据比选通早写很久, 同步后的 d2 早已稳定
                mem[wptr[3:0]] <= d2;
                wptr           <= wptr + 1'b1;
            end

            if (!empty && vk_ready) begin
                // 时序: 本拍 vk_valid=1 且 vk_ready=1, KB_8042 在**同一个上升沿**
                // 把 vk_data(= 队头)装进 OBF; 我们同时弹出一项 ⇒ 下一拍队头
                // 前移 ⇒ 不会把同一字节再装一次。
                rptr <= rptr + 1'b1;
            end
        end
    end

    assign vk_valid = ~empty;
    assign vk_data  = mem[rptr[3:0]];

endmodule
