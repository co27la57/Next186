// ============================================================================
// opl3_ym.v — nukeykt YMF262 核的 Next186 适配层（2026-10-19）
// ----------------------------------------------------------------------------
// 目的：用真实 YMF262 门级模型（ymi262.v + ym_lib.v）替换原作者那套
//   "命令 FIFO + 内部 Z80 + opl3.mem 固件 + opl3seq 状态机" 的 OPL3 实现，
//   从而排除"丢 TL 写 / FIFO 溢出 / Z80 固件初始化"这一整类嫌疑。
//
// 关键设计点：
//  1) 时钟：MCLK = CLK_50MHZ；CLK = 14.318 MHz 由相位累加器生成
//     （真实 YMF262 出样率 = CLK/288 = 49716 Hz；14.318 MHz 才能保证音高正确）。
//     50 MHz * 1229922297/2^32 = 14.3182 MHz（CLK14 实测 14.3182MHz）。
//     ★ 2026-10-19 实测结论：MCLK 频率**不影响**出样率（核心是「单时钟 + c1/c2 相位使能」
//       结构，CLK 才是决定音高/速度的）。四频点扫描 100 / 71.4 / 62.5 / 50 MHz 结果逐位相同：
//       CLK14=14.3182MHz、SMPBD=49720Hz、CLK14/采样=287.98、峰值 ±4085。
//       ⇒ 所以用 50 MHz 即可（原 opl3 核本来也跑 CLK_50MHZ），无需独立的 100MHz 域。
//       100MHz 在 xc7z010-1 上时序不收敛：门级模型关键路径 13.5ns/15级逻辑（WNS=-3.99ns）。
//  2) 寄存器接口：与真实芯片一致 —— ADDRESS[1:0] 取 0x388..0x38B 的低 2 位，
//     CS/WR/RD **低有效**，写数据在 MCLK 上锁存。
//     186 侧总线在 clk_cpu(25MHz) 域，这里用 2FF 同步 + 把写脉冲展宽到 >=2 个 MCLK，
//     保证核心一定能在 MCLK 边沿采到一次完整的写。
//  3) 音频：核心只提供真实芯片的 YAC512 串行 DAC 接口（SY/DOAB/SMPAC/SMPBD），
//     这里照抄已上板验证过的解码器。★ 核心是 **LSB-first** 输出（ym_dbg_read 的
//     next=data_out[0]），所以移位必须是**右移** —— 不要"修"成左移，那会把音频比特镜像。
//  4) 输出 ym_left/ym_right 为 16bit 二补码（dac_shifter ^ 0x8000 把偏移码转二补码），
//     与旧 opl3 模块的 left/right 语义一致，可直接接 soundwave 的 r_opl3left/right。
// ============================================================================
`timescale 1ns / 1ps

module opl3_ym #(
    // 14.318 MHz 相位累加步进：50MHz 基 -> 1229922297；100MHz 基 -> 614948834
    //   ★ 别用 307474417：那是 14.318MHz 的 1/4（3.58MHz），会让整片慢 4 倍、音高全错。
    parameter [31:0] INC_14M = 32'd1229922297,
    // 重放半周期拍数。一个字节 = REP_CYC 拍 CS/WR 有效 + REP_CYC 拍间隔。
    //   50MHz 下 REP_CYC=100 -> 2us + 2us = 4us/字节 = 250K 字节/秒。
    //   ★ 实测边界：2us/字节 完全失效（输出只剩 8~12），4us/字节 满幅正常，
    //     8us/字节 也正常。取 4us 兼顾吞吐与可靠，不要再往下压。
    parameter [10:0] REP_CYC = 11'd100
) (
    input  wire        mclk,         // MCLK = CLK_50MHZ（核心只需 >=~50MHz；见文件头说明）
    input  wire        rst,          // 低有效复位（接 rstcount[18]：复位期间为 0）
    // ---- 186 I/O 总线（clk_cpu 域）----
    input  wire        cpu_ce,       // 端口译码有效 = IORQ & CPU_CE & OPL3_PORT
    input  wire        cpu_wr,       // 1 = 写, 0 = 读
    input  wire [1:0]  cpu_addr,     // PORT_ADDR[1:0]  (0x388..0x38B)
    input  wire [7:0]  cpu_din,
    output wire [7:0]  cpu_dout,
    // ---- 音频（clk50 域，49716 Hz 更新）----
    output wire [15:0] left,
    output wire [15:0] right,
    // ---- 通道发声指示（LED 用）----
    output wire [3:0]  keyon
);

    // ========================================================================
    // 1. 14.318 MHz 生成（100MHz 基，INC=614948834）
    // ========================================================================
    reg [31:0] phase_acc = 32'd0;
    reg        clk_14m   = 1'b0;
    always @(negedge mclk) begin
        phase_acc <= phase_acc + INC_14M;
        clk_14m   <= phase_acc[31];
    end

    // ========================================================================
    // 2. 186 写总线 -> 写 FIFO -> 按核心能接受的节奏重放
    //    ★ 关键：ymf262 的寄存器写是**边沿检测**，采样节拍 = aclk 相位
    //      (3.58MHz，每相位 139ns)，要求写脉冲 >=139ns 且跨相位边界；
    //      而 186 的 I/O 周期只有 ~160ns、连续两字节间隔可能只有 ~200ns
    //      ⇒ 直接送会大量丢写（仿真实测：TL/AR/FNUM 全没进去，只有 keyon 侥幸进）。
    //    这里用 64 深 FIFO 把 186 的快写排队，再以 500ns 脉冲 + 500ns 间隔重放
    //    （真实 8088 总线的 OUT 也是 ~µs 级；老设计的 256 深命令 FIFO 就是同一思路）。
    // ========================================================================
    wire io_wr = cpu_ce & cpu_wr;
    wire io_rd = cpu_ce & ~cpu_wr;

    (* ASYNC_REG = "TRUE" *) reg io_wr_d1 = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg io_wr_d2 = 1'b0;

    // ★★ 深度必须够深：186 的 OUT 周期只有 ~320ns（3M 字节/秒），而重放只有
    //    125K~250K 字节/秒。DOS 游戏初始化 OPL3 常常连写 200~400 个寄存器，
    //    64 深 FIFO 会被瞬间填满并丢弃 60% 以上的 patch 参数 —— 被丢掉的正是
    //    TL/ADSR，而未写到的通道 TLL 保持 0（= 最大音量）⇒ "部分乐器特别大"。
    //    实测（sim/tb/opl3_ym_burst_main.cpp）：64 深时 200 字节突发只进 71 个。
    //    ⇒ 加到 1024 深（10bit×1024，推断为分布式 RAM，约 160 LUT）。
    //   ★ 必须强制 distributed：读口是**组合读**（rep_d 直接驱动核心的地址/数据），
    //     若让 Vivado 推断成 BRAM，读端口会变成 1 拍同步、并且同址读写会冲突，
    //     硬件行为与仿真不一致。实测不写属性时 Vivado 确实推成了 1x RAMB18E1。
    localparam FIFO_AW = 10;                       // 1024 深
    (* ram_style = "distributed" *)
    reg  [9:0] wfifo [0:(1<<FIFO_AW)-1];           // {addr[1:0], data[7:0]}
    reg [FIFO_AW:0] wptr = 0, rptr = 0;            // 多 1 bit 做整圈标志
    wire wfifo_empty = (wptr == rptr);
    wire wfifo_full  = (wptr[FIFO_AW-1:0] == rptr[FIFO_AW-1:0]) && (wptr[FIFO_AW] != rptr[FIFO_AW]);

    always @(posedge mclk) begin
        io_wr_d1 <= io_wr;
        io_wr_d2 <= io_wr_d1;
        if (io_wr_d1 & ~io_wr_d2 && !wfifo_full) begin
            wfifo[wptr[FIFO_AW-1:0]] <= {cpu_addr, cpu_din};
            wptr <= wptr + 1'b1;
        end
    end

    // 重放节奏：0..REP_CYC-1 拍 CS/WR 有效，REP_CYC..2*REP_CYC-1 拍间隔。
    //   一个字节 = 2*REP_CYC 拍。50MHz 下 REP_CYC=100 -> 4us/字节 = 250K 字节/秒。
    // ★ 核心的写信号链是 write0_sr -> write0_l -> write0_l2 三级、每级 2 个 clk 相位，
    //   写脉冲在 io_write 上升后约 1.1us 才出现；地址/数据必须在这段时间内保持不变，
    //   否则脉冲会落到下一条目上（实测 1us 周期时 ra_address_latch 抓到了下一条的数据）。
    reg [10:0] rep_cnt = 11'd0;
    wire [10:0] rep_half = REP_CYC;
    wire [10:0] rep_full = REP_CYC + REP_CYC - 11'd1;
    always @(posedge mclk) begin
        if (!wfifo_empty) begin
            if (rep_cnt < rep_full) rep_cnt <= rep_cnt + 1'b1;
            else begin rep_cnt <= 11'd0; rptr <= rptr + 1'b1; end
        end else rep_cnt <= 11'd0;
    end
    wire       rep_run = (rep_cnt < rep_half) && !wfifo_empty;
    wire [9:0] rep_d   = wfifo[rptr[FIFO_AW-1:0]];

    // 读口(状态 0x388)直通；写口走重放
    wire [1:0] core_addr = io_rd ? cpu_addr : rep_d[9:8];
    wire [7:0] core_din  = io_rd ? cpu_din  : rep_d[7:0];

    // 真实芯片低有效：CS 在读或写期间拉低；WR 仅写有效；RD 仅读有效
    wire cs_n = ~(rep_run | io_rd);
    wire wr_n = ~rep_run;
    wire rd_n = ~io_rd;

    // ========================================================================
    // 3. YMF262 核心
    // ========================================================================
    wire ymf_sy, ymf_doab, ymf_smpac, ymf_smpbd, ymf_irq;

    ymf262 u_ymf262 (
        .MCLK     (mclk),
        .CLK      (clk_14m),
        .IC       (rst),           // 低有效复位
        .ADDRESS  (core_addr),
        .DATA_i   (core_din),
        .DATA_o   (cpu_dout),      // 状态口回读：{IRQ, T1, T2, 5'b0}（真芯片格式）
        .DATA_d   (),
        .WR       (wr_n),
        .RD       (rd_n),
        .CS       (cs_n),
        .TEST     (),
        .SY       (ymf_sy),
        .DOCD     (),
        .DOAB     (ymf_doab),
        .SMPAC    (ymf_smpac),
        .SMPBD    (ymf_smpbd),
        .IRQ_pull (ymf_irq)
    );

    // ========================================================================
    // 4. YAC512 串行 DAC 解码（照抄已上板验证过的版本；★ 右移，LSB-first）
    // ========================================================================
    reg [15:0] dac_shifter = 16'h0000;
    reg        o_sy    = 1'b0, sy_sync = 1'b0;
    reg        o_smpac = 1'b0, o_smpbd = 1'b0;
    reg [15:0] ym_left  = 16'h0000;
    reg [15:0] ym_right = 16'h0000;

    always @(posedge mclk) begin
        if (~sy_sync & o_sy)
            dac_shifter <= {ymf_doab, dac_shifter[15:1]};      // LSB-first -> 右移
        if (o_smpbd & ~ymf_smpbd)
            ym_left  <= dac_shifter ^ 16'h8000;                // 偏移码 -> 二补码
        if (o_smpac & ~ymf_smpac)
            ym_right <= dac_shifter ^ 16'h8000;
        o_sy    <= sy_sync;   sy_sync  <= ymf_sy;
        o_smpac <= ymf_smpac; o_smpbd  <= ymf_smpbd;
    end

    assign left  = ym_left;
    assign right = ym_right;

    // ========================================================================
    // 5. LED 通道指示（核心内部的 key-on 状态，层次引用；与用户原 IP 一致）
    // ========================================================================
    assign keyon = {u_ymf262.ra_keyon[3], u_ymf262.ra_keyon[2],
                    u_ymf262.ra_keyon[1], u_ymf262.ra_keyon[0]};

endmodule
