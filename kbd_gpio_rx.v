// ============================================================================
// kbd_gpio_rx.v — 从 PS EMIO GPIO 接收 scancode 字节 (并行 8 位 + 选通, 不经 AXI!)
// ----------------------------------------------------------------------------
// 背景: 之前用 "AXI4-Lite 从机 + SmartConnect + M_AXI_GP0" 传 scancode,
//       实测证实会挪动 DDR 读返回时序, 导致 VGA 扫描取数窗口错位而花屏。
//       改用 PS EMIO GPIO 后全程不碰 AXI / 不影响 DDR 仲裁。
//
// ★ 传输: 8 位并行 + 选通。发送端先写 gpio_data[7:0], 再拉高 gpio_stb;
//   PL 在选通上升沿锁存**已稳定**(早写 ~50us)的 8 位 -> 结构上不可能丢位。
//   (早期 3 线串行位帧方案会偶发丢位, 已弃用)
//
// ★★★ 2026-10-10 回退: 去掉 FIFO + vk_ready 门控 ★★★
//   第 27 轮曾在此加过"16 深度 FIFO + vk_ready 握手"(理由: 防 8042 缓冲满时丢字节)。
//   但**加了这个握手之后键盘就再也没收到过字符**(对比"能出字符的版本"确认)。
//   原因: 出队条件里的 `~ctl_outb` 会卡住 —— `ctl_outb` 是"80186 发了读配置字节命令
//     (0x20)但还没读端口 0x60"的标志。BIOS 启动时会发该命令; 一旦那次读取没按预期
//     完成, ctl_outb 就长期为 1 ⇒ vk_ready 恒 0 ⇒ FIFO 永不弹出 ⇒ 一个字节都进不去。
//   ⇒ 回到**第 24 轮已验证可工作**的行为: 选通上升沿直接输出一个 vk_valid 脉冲。
//     发送端是 sysfs 逐位敲击(~450us/字节), 字节间隔很长(人打字 / DOS 会取走),
//     8042 缓冲满导致丢字节的实际风险, 远小于"卡死到一个字节都进不去"。
//
// 接口(EMIO 共 9 位):
//   gpio_data[7:0] : scancode 字节
//   gpio_stb       : 选通(上升沿 = 一个新字节已稳定)
//   vk_ready       : 来自 KB_8042; 本版**保留端口但不用于门控**(见上)
// ============================================================================
`timescale 1ns / 1ps

module kbd_gpio_rx #(
    parameter DW = 8
)(
    input  wire            clk,        // clk_cpu (25MHz)
    input  wire            rst_n,      // 高有效 (建议接 clk_cpu_locked)
    // ---- PS EMIO GPIO ----
    input  wire [DW-1:0]   gpio_data,
    input  wire            gpio_stb,
    // ---- 与 8042 的握手端口(保留以兼容上层连线; 不再参与门控) ----
    input  wire            vk_ready,
    // ---- 输出: 一个完整字节(在 clk 域) ----
    output reg             vk_valid,   // 单周期脉冲: vk_data 有效
    output reg  [DW-1:0]   vk_data
);

    // ---- 输入同步 (2-FF + ASYNC_REG) ----
    (* ASYNC_REG = "TRUE" *) reg [DW-1:0] d1 = {DW{1'b0}}, d2 = {DW{1'b0}};
    (* ASYNC_REG = "TRUE" *) reg          s1 = 1'b0, s2 = 1'b0;

    wire stb_rise = (s1 & ~s2);

    always @(posedge clk) begin
        if (!rst_n) begin
            d1       <= {DW{1'b0}};
            d2       <= {DW{1'b0}};
            s1       <= 1'b0;
            s2       <= 1'b0;
            vk_valid <= 1'b0;
            vk_data  <= {DW{1'b0}};
        end else begin
            d1       <= gpio_data;
            d2       <= d1;
            s1       <= gpio_stb;
            s2       <= s1;
            vk_valid <= 1'b0;
            if (stb_rise) begin
                // 选通上升沿: 数据比选通早写 ~50us, 同步后的 d2 早已稳定 -> 直接锁存
                vk_valid <= 1'b1;
                vk_data  <= d2;
            end
        end
    end

    // vk_ready 仅供调试观测, 不参与门控(见文件头说明)。
    wire _unused_vk_ready = vk_ready;

endmodule
