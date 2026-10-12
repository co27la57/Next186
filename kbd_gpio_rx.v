// ============================================================================
// kbd_gpio_rx.v.mouse — 从 PS EMIO GPIO 接收 scancode / 鼠标字节 (副本, 未改动原文件)
// ----------------------------------------------------------------------------
// 来源: 由 kbd_gpio_rx.v(纯键盘版, 已上板验证可用) 扩展而来;
//   键盘版原文件备份 = kbd_gpio_rx.v.bak.premouse, 一键回退:
//     cp kbd_gpio_rx.v.bak.premouse kbd_gpio_rx.v
// 本版新增: **鼠标通道**。目标是在不改 BD、不加 EMIO 引脚的前提下,
//   让 PS 能把 PS/2 鼠标包(3 字节)送进 8042 的鼠标通路(MOBF -> IRQ12)。
//
// ★ 通道区分方式(默认, AUX_MODE=0): 用**选通高电平宽度**
//     选通高电平 <  MOUSE_STB_MIN_US (默认 1ms)  => 键盘字节 (走 vk_*)
//     选通高电平 >= MOUSE_STB_MIN_US (默认 1ms)  => 鼠标字节 (走 vm_*)
//   为什么这样最稳:
//     · 每个字节**独立判通道**, 没有转义序列 => 不存在"丢一个字节后整条流错位"的风险;
//     · 判据只看"拉高->拉低"的宽度, 发端用 usleep 精确控制(键盘≈0.1ms, 鼠标≈3ms),
//       量级差 30 倍; 且 sysfs 写延迟只会把脉冲**变长**, 是安全方向;
//     · 老的 kbd_gpio_inject 二进制(短脉冲)完全不受影响, 仍然全部走键盘通道。
//   ★ 代价: 字节在**选通下降沿**才入队(比原来的上升沿晚一个脉宽, 无关紧要)。
//
// ★ 备选(AUX_MODE=1): 用第 10 根 EMIO 线 gpio_aux 做通道选择(1=鼠标)。
//   若以后愿意把 EMIO 从 9 位扩到 10 位, 把实例化处的 AUX_MODE 改成 1 并接上即可,
//   判定在上升沿完成, 完全不依赖时序。
//
// 端口: 与 kbd_gpio_rx.v 完全兼容, 只是在尾部追加 vm_ready/vm_valid/vm_data
//   和 gpio_aux / AUX_MODE。键盘侧行为(FIFO + 看门狗)与原件逐行一致。
//
// 配套: KB_8042.v.mouse(虚拟鼠标应答) + ddr_186.v.mouse(接线) + mouse_gpio_inject.c
// ============================================================================
`timescale 1ns / 1ps

module kbd_gpio_rx #(
    parameter DW    = 8,
    parameter DEPTH = 16,             // FIFO 深度(2 的幂)
    parameter CLK_MHZ = 25,           // clk 频率(MHz), 用于把 us 阈值换算成周期数
    parameter MOUSE_STB_MIN_US = 1000,// 选通高电平 >= 该值(us) 判为鼠标字节
    parameter AUX_MODE = 0            // 0=脉宽判通道(默认, 不改 BD); 1=gpio_aux 引脚判通道
)(
    input  wire            clk,        // clk_cpu
    input  wire            rst_n,      // 高有效复位
    // ---- PS EMIO GPIO ----
    input  wire [DW-1:0]   gpio_data,
    input  wire            gpio_stb,
    input  wire            gpio_aux,   // AUX_MODE=1 时: 1=鼠标字节(需第 10 根 EMIO)
    // ---- 与 8042 的握手: 键盘通道 ----
    input  wire            vk_ready,   // 1 = 8042 输出缓冲空, 可接收
    output wire            vk_valid,   // **电平**: FIFO 非空期间一直为 1
    output wire [DW-1:0]   vk_data,    // 首字直通(FWFT): 始终是队头
    // ---- 与 8042 的握手: 鼠标通道 ----
    input  wire            vm_ready,   // 1 = 8042 输出缓冲空, 可接收
    output wire            vm_valid,
    output wire [DW-1:0]   vm_data
);

    // 选通宽度阈值(周期数)
    localparam integer THR_CYC = CLK_MHZ * MOUSE_STB_MIN_US;
    localparam [23:0]  WMAX    = 24'hFFFFFF;

    // ---- 输入同步 (2-FF + ASYNC_REG) ----
    (* ASYNC_REG = "TRUE" *) reg [DW-1:0] d1 = {DW{1'b0}}, d2 = {DW{1'b0}};
    (* ASYNC_REG = "TRUE" *) reg          s1 = 1'b0, s2 = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg          a1 = 1'b0, a2 = 1'b0;

    wire stb_rise = (s1 & ~s2);
    wire stb_fall = (~s1 & s2);

    // ---- 待分类字节(脉宽模式) ----
    reg [DW-1:0] pend   = {DW{1'b0}};
    reg          pend_v = 1'b0;
    reg [23:0]   wcnt   = 24'd0;

    // ---- 入队请求(每拍至多一个字节) ----
    reg          push_v = 1'b0;
    reg          push_m = 1'b0;
    reg [DW-1:0] push_d = {DW{1'b0}};

    // ---- 两个 FWFT FIFO: 键盘 / 鼠标 ----
    reg  [DW-1:0] mem_k [0:DEPTH-1];
    reg  [DW-1:0] mem_m [0:DEPTH-1];
    reg  [4:0]    wptr_k = 5'd0, rptr_k = 5'd0;
    reg  [4:0]    wptr_m = 5'd0, rptr_m = 5'd0;

    wire empty_k = (wptr_k == rptr_k);
    wire full_k  = (wptr_k[3:0] == rptr_k[3:0]) && (wptr_k[4] != rptr_k[4]);
    wire empty_m = (wptr_m == rptr_m);
    wire full_m  = (wptr_m[3:0] == rptr_m[3:0]) && (wptr_m[4] != rptr_m[4]);

    // ---- 看门狗出队: 防止 8042 侧停止消费就把整条链路堵死 ----
    //   现象(实测, 键盘侧): 屏幕上"正好前 16 个字符正常, 之后全乱码" —— 16 = DEPTH。
    //   对策: 队头等待超过 2^20 拍(clk_cpu 25MHz 时约 42ms)就**强行弹出一个**
    //   (宁可丢一个字节, 也不能堵死)。鼠标侧同样处理。
    reg  [19:0] wait_k = 20'd0;
    reg  [19:0] wait_m = 20'd0;
    wire        stalled_k = (wait_k >= 20'hFFFFF);
    wire        stalled_m = (wait_m >= 20'hFFFFF);

    always @(posedge clk) begin
        if (!rst_n) begin
            d1 <= {DW{1'b0}}; d2 <= {DW{1'b0}};
            s1 <= 1'b0; s2 <= 1'b0;
            a1 <= 1'b0; a2 <= 1'b0;
            pend   <= {DW{1'b0}};
            pend_v <= 1'b0;
            wcnt   <= 24'd0;
            push_v <= 1'b0;
            push_m <= 1'b0;
            push_d <= {DW{1'b0}};
            wptr_k <= 5'd0; rptr_k <= 5'd0;
            wptr_m <= 5'd0; rptr_m <= 5'd0;
            wait_k <= 20'd0; wait_m <= 20'd0;
        end else begin
            d1 <= gpio_data;
            d2 <= d1;
            s1 <= gpio_stb;
            s2 <= s1;
            a1 <= gpio_aux;
            a2 <= a1;

            // ---- 通道判定 ----
            push_v <= 1'b0;
            if (AUX_MODE != 0) begin
                // 引脚模式: 上升沿即判定, 与脉宽无关
                if (stb_rise) begin
                    push_v <= 1'b1;
                    push_m <= a2;       // 数据比选通早写很久, a2/d2 均已稳定
                    push_d <= d2;
                end
                pend_v <= 1'b0;
                wcnt   <= 24'd0;
            end else begin
                // 脉宽模式: 上升沿锁存, 下降沿按高电平宽度判定
                if (stb_rise) begin
                    pend   <= d2;
                    pend_v <= 1'b1;
                    wcnt   <= 24'd0;
                end else if (stb_fall) begin
                    pend_v <= 1'b0;
                    if (pend_v) begin
                        push_v <= 1'b1;
                        push_m <= (wcnt >= THR_CYC);
                        push_d <= pend;
                    end
                end else if (pend_v && (wcnt != WMAX)) begin
                    wcnt <= wcnt + 1'b1;
                end
            end

            // ---- 入队 ----
            if (push_v && !push_m && !full_k) begin
                mem_k[wptr_k[3:0]] <= push_d;
                wptr_k             <= wptr_k + 1'b1;
            end
            if (push_v &&  push_m && !full_m) begin
                mem_m[wptr_m[3:0]] <= push_d;
                wptr_m             <= wptr_m + 1'b1;
            end

            // ---- 出队(键盘) ----
            if (empty_k || vk_ready) wait_k <= 20'd0;
            else                     wait_k <= wait_k + 1'b1;
            if (!empty_k && (vk_ready || stalled_k)) rptr_k <= rptr_k + 1'b1;

            // ---- 出队(鼠标) ----
            if (empty_m || vm_ready) wait_m <= 20'd0;
            else                     wait_m <= wait_m + 1'b1;
            if (!empty_m && (vm_ready || stalled_m)) rptr_m <= rptr_m + 1'b1;
        end
    end

    assign vk_valid = ~empty_k;
    assign vk_data  = mem_k[rptr_k[3:0]];
    assign vm_valid = ~empty_m;
    assign vm_data  = mem_m[rptr_m[3:0]];

    // ========================================================================
    // ILA 探针(默认全部注释掉 —— 探针预算 200 bit 已偏紧, 需要时再开)
    //   排查顺序建议: dbg_emio_data(第 0 级 PS 引脚) -> dbg_rx_data(进 8042 的键盘字节)
    //                -> dbg_m_data(进 8042 的鼠标字节) -> KB_8042 内的 dbglog_*。
    // ========================================================================
    /*(* mark_debug = "true", keep = "true" *)*/ reg [7:0] dbg_emio_data = 8'h00;
    /*(* mark_debug = "true", keep = "true" *)*/ reg [7:0] dbg_rx_data   = 8'h00;
    /*(* mark_debug = "true", keep = "true" *)*/ reg [7:0] dbg_m_data    = 8'h00;
    /*(* mark_debug = "true", keep = "true" *)*/ reg       dbg_push_m    = 1'b0;
    /*(* mark_debug = "true", keep = "true" *)*/ reg [23:0]dbg_wcnt      = 24'd0;

    always @(posedge clk) begin
        if (gpio_stb) dbg_emio_data <= gpio_data;
        if (vk_valid) dbg_rx_data   <= vk_data;
        if (vm_valid) dbg_m_data    <= vm_data;
        dbg_push_m <= (push_v && push_m);
        if (stb_fall) dbg_wcnt <= wcnt;
    end

endmodule
