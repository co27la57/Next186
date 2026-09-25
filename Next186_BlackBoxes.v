// =========================================================================
// Next186 Vivado XPM & BRAM Replacements for Altera Primitives
// 包含所有报 Black Box 错误的 FIFO 和 双口/单口 RAM
// =========================================================================

// ---------------------------------------------------------
// 1. VGA 视频 FIFO (异步跨时钟域，非对称 16位入/32位出)
// ---------------------------------------------------------

// =========================================================================
// 最标准、最底层的防死锁 FIFO (直接替换 Next186_BlackBoxes.v 里的 vga_fifo)
// =========================================================================
module fifo (
    input  wire        wrclk,
    input  wire        rdclk,
    input  wire [15:0] data,
    input  wire        wrreq,
    input  wire        rdreq,
    output wire [31:0] q,
    output wire [8:0]  wrusedw,
    input  wire        rst
);
    wire wr_busy;
    wire rd_busy;
    wire [10:0] full_wrusedw;

    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE("auto"),
        .READ_DATA_WIDTH(32),
        .WRITE_DATA_WIDTH(16),
        .FIFO_WRITE_DEPTH(1024),
        .RD_DATA_COUNT_WIDTH(10), // 必须显式声明: log2(512)+1
        .WR_DATA_COUNT_WIDTH(11), // 必须显式声明: log2(1024)+1
        .USE_ADV_FEATURES("0707") // 强制启用所有底层计数器
    ) vga_fifo_inst (
        .wr_clk(wrclk),
        .rd_clk(rdclk),
        .din(data),
        .wr_en(wrreq & ~wr_busy),
        .rd_en(rdreq & ~rd_busy),
        .dout(q),
        .wr_data_count(full_wrusedw),
        .wr_rst_busy(wr_busy),
        .rd_rst_busy(rd_busy),
        .sleep(1'b0),
        .rst(rst),
        .injectsbiterr(1'b0),
        .injectdbiterr(1'b0)
    );

    // 【终极修复】：彻底移除复位欺骗，返回真实水量，并增加饱和防溢出截断！
    // 这保证了 VGA 状态机只在真正有画面数据时才会点亮屏幕！
    assign wrusedw = (full_wrusedw >= 11'd511) ? 9'd511 : full_wrusedw[8:0];

endmodule
// ---------------------------------------------------------
// 2. 音频 FIFO (异步跨时钟域, 带容量状态指示)
// ---------------------------------------------------------
module sndfifo (
    input  wire        wrclk,
    input  wire        rdclk,
    input  wire [15:0] data,
    input  wire        wrreq,
    input  wire        rdreq,
    output wire [15:0] q,
    output wire        wrfull,
    output wire        rdempty,
    output wire [11:0] wrusedw,  // 写入端已用数据量
    output wire [11:0] rdusedw   // 读取端已用数据量
);
    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE("auto"), 
        .READ_DATA_WIDTH(16), 
        .WRITE_DATA_WIDTH(16), 
        .FIFO_WRITE_DEPTH(2048),
        .USE_ADV_FEATURES("0404") // 开启 wr_data_count 和 rd_data_count 高级特性
    ) snd_fifo_inst (
        .wr_clk(wrclk), .rd_clk(rdclk),
        .din(data), .wr_en(wrreq), .rd_en(rdreq),
        .dout(q), .full(wrfull), .empty(rdempty),
        .wr_data_count(wrusedw), 
        .rd_data_count(rdusedw),
        .sleep(1'b0), .rst(rst), .injectsbiterr(1'b0), .injectdbiterr(1'b0)
    );
endmodule
// ---------------------------------------------------------
// 3. UART 串口 FIFO (q16 - 异步双时钟)
// ---------------------------------------------------------
module q16 (
    input  wire        wrclk,
    input  wire        rdclk,
    input  wire [7:0]  data,
    input  wire        wrreq,
    input  wire        rdreq,
    output wire [7:0]  q,
    output wire        rdempty,
    output wire        wrfull,
    output wire        empty,
    output wire        full,
    output wire [3:0]  usedw,
    output wire [3:0]  wrusedw,
    output wire [3:0]  rdusedw
);
    wire e, f;
    assign empty = e; assign rdempty = e;
    assign full = f;  assign wrfull = f;
    assign usedw = rdusedw; // 兼容单时钟容量查询

    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE("auto"), 
        .READ_DATA_WIDTH(8), 
        .WRITE_DATA_WIDTH(8), 
        .FIFO_WRITE_DEPTH(16),
        .USE_ADV_FEATURES("0404")
    ) q16_inst (
        .wr_clk(wrclk), .rd_clk(rdclk),
        .din(data), .wr_en(wrreq), .rd_en(rdreq),
        .dout(q), .full(f), .empty(e),
        .wr_data_count(wrusedw), .rd_data_count(rdusedw),
        .sleep(1'b0), .rst(rst), .injectsbiterr(1'b0), .injectdbiterr(1'b0)
    );
endmodule

// ---------------------------------------------------------
// 4 & 5. DSP 协处理器 & OPL3 FIFO (异步双时钟)
// ---------------------------------------------------------
module qdsp (
    input  wire        wrclk,
    input  wire        rdclk,
    input  wire [15:0] data,
    input  wire        wrreq,
    input  wire        rdreq,
    output wire [15:0] q,
    output wire        rdempty,
    output wire        wrfull,
    output wire        empty,
    output wire        full
);
    wire e, f;
    assign empty = e; assign rdempty = e;
    assign full = f;  assign wrfull = f;

    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE("auto"), 
        .READ_DATA_WIDTH(16), 
        .WRITE_DATA_WIDTH(16), 
        .FIFO_WRITE_DEPTH(256)
    ) qdsp_inst (
        .wr_clk(wrclk), .rd_clk(rdclk),
        .din(data), .wr_en(wrreq), .rd_en(rdreq),
        .dout(q), .full(f), .empty(e),
        .sleep(1'b0), .rst(rst), .injectsbiterr(1'b0), .injectdbiterr(1'b0)
    );
endmodule

module opl3_in (
    input  wire        wrclk,
    input  wire        rdclk,
    input  wire [15:0] data,
    input  wire        wrreq,
    input  wire        rdreq,
    output wire [15:0] q,
    output wire        rdempty,
    output wire        wrfull,
    output wire        empty,
    output wire        full
);
    wire e, f;
    assign empty = e; assign rdempty = e;
    assign full = f;  assign wrfull = f;

    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE("auto"), 
        .READ_DATA_WIDTH(16), 
        .WRITE_DATA_WIDTH(16), 
        .FIFO_WRITE_DEPTH(256)
    ) opl3_fifo (
        .wr_clk(wrclk), .rd_clk(rdclk),
        .din(data), .wr_en(wrreq), .rd_en(rdreq),
        .dout(q), .full(f), .empty(e),
        .sleep(1'b0), .rst(rst), .injectsbiterr(1'b0), .injectdbiterr(1'b0)
    );
endmodule
// ---------------------------------------------------------
// 6. CPU 缓存 Cache (真双口 RAM, 预载原版 boot186 镜像 + 4-way 冗余)
// ---------------------------------------------------------
module cache (
    input  wire        clock_a,
    input  wire        clock_b,
    input  wire        enable_a,
    input  wire        enable_b,
    input  wire [3:0]  byteena_a,
    input  wire [3:0]  byteena_b,
    input  wire        wren_a,
    input  wire        wren_b,
    input  wire [10:0] address_a, 
    input  wire [10:0] address_b,
    input  wire [31:0] data_a,
    input  wire [31:0] data_b,
    output reg  [31:0] q_a,
    output reg  [31:0] q_b
);
    // 32-bit x 2048 真双口 RAM
    (* ram_style = "block" *) reg [31:0] ram [2047:0];

    integer i;
    initial begin
        // ===== 原版 cache_bootload.txt 内容 (256 word) =====
        // 注意：不要在此处加 "for (i=0;i<2048;i=i+1) ram[i]=32'hF4F4F4F4;" 全量填充循环！
        // 该循环会让 Vivado 推断 BRAM INIT 失败，BIOS(ram[0..0FF])及后续 4-way 复制(479行)被覆盖为 F4F4F4F4 全部失效。
        // 仅保留下面的显式 BIOS 赋值 + 479 行 4-way 复制即可。
        ram[11'h000] = 32'hC88CFCFA;
        ram[11'h001] = 32'hC08ED88E;
        ram[11'h002] = 32'h00BCD08E;
        ram[11'h003] = 32'hE7C033FC;
        ram[11'h004] = 32'hE706B080; // 文本窗对齐修复：mov al,0xb -> mov al,0x6，使 out 0x8b 写 map[11]=6 -> CPU 文本物理 0x08068000(与 VGA scraddr=0x6000 读窗&PS写址一致)。原 0x0B -> map[11]=11 -> 0x080B8000 越出 VGA 可读上限 0x0807FFFE。
        ram[11'h005] = 32'hE70FB08B;
        ram[11'h006] = 32'hE634B08F;
        ram[11'h007] = 32'hE6C03243;
        ram[11'h008] = 32'hE840E640;
        ram[11'h009] = 32'hFF3300A9;
        ram[11'h00A] = 32'hE8FEC3BE;
        ram[11'h00B] = 32'hDEE800F8;
        ram[11'h00C] = 32'h0209E800;
        ram[11'h00D] = 32'h0375C085;
        ram[11'h00E] = 32'h8B0117E9;
        ram[11'h00F] = 32'h06EAC1D0;
        ram[11'h010] = 32'hB90AE0C1;
        ram[11'h011] = 32'hC12B0010;
        ram[11'h012] = 32'h3300DA83;
        ram[11'h013] = 32'h001AE8DB;
        ram[11'h014] = 32'h28E90372;
        ram[11'h015] = 32'h33D23301;
        ram[11'h016] = 32'h000EE8C0;
        ram[11'h017] = 32'h1CE90372;
        ram[11'h018] = 32'hF8834001;
        ram[11'h019] = 32'hE9F27640;
        ram[11'h01A] = 32'h525000E8;
        ram[11'h01B] = 32'h90605351;
        ram[11'h01C] = 32'hE8929090;
        ram[11'h01D] = 32'h9092030C;
        ram[11'h01E] = 32'h92E89090;
        ram[11'h01F] = 32'h75E86100;
        ram[11'h020] = 32'h81467201;
        ram[11'h021] = 32'h75654E3F;
        ram[11'h022] = 32'h027F8140;
        ram[11'h023] = 32'h39757478;
        ram[11'h024] = 32'h01C08349;
        ram[11'h025] = 32'h8100D283;
        ram[11'h026] = 32'hE80200C3;
        ram[11'h027] = 32'h29720158;
        ram[11'h028] = 32'hC381EFE2;
        ram[11'h029] = 32'hF6330200;
        ram[11'h02A] = 32'hE81FEEB9;
        ram[11'h02B] = 32'h9090009A;
        ram[11'h02C] = 32'hE8C28B90;
        ram[11'h02D] = 32'h56E8032C;
        ram[11'h02E] = 32'hEE478B00;
        ram[11'h02F] = 32'h7400F883;
        ram[11'h030] = 32'h75C23B04;
        ram[11'h031] = 32'hEB59F804;
        ram[11'h032] = 32'h59F95B02;
        ram[11'h033] = 32'h06C3585A;
        ram[11'h034] = 32'hB003C0BA;
        ram[11'h035] = 32'h08B0EE10;
        ram[11'h036] = 32'h03D4BAEE;
        ram[11'h037] = 32'h42EE0AB0;
        ram[11'h038] = 32'h4AEE20B0;
        ram[11'h039] = 32'h42EE0CB0;
        ram[11'h03A] = 32'h4AEE60B0;   // ★ VGA读地址对齐：scraddr 0x3000->0x6000(CRT 起始地址高 mov al,0x30->0x60)。ddr_186.v:735 重算 row_col=0x14000，VGA 读物理 0x08068000。配合 map[11]=6(BIOS out 0x8b 写 6，见 ram[11'h004])，CPU 文本窗 = 0x08068000，三者(CPU/VGA/PS)对齐，消除花屏/乱码
        ram[11'h03B] = 32'h42EE0DB0;
        ram[11'h03C] = 32'h68EE00B0;
        ram[11'h03D] = 32'h3307B800;
        ram[11'h03E] = 32'h07D0B9FF;
        ram[11'h03F] = 32'hABF3C033;
        ram[11'h040] = 32'hB803C8BA;
        ram[11'h041] = 32'h42EE0101;
        ram[11'h042] = 32'hEEEE2AB0;
        ram[11'h043] = 32'h53C307EE;
        ram[11'h044] = 32'h3A4000BB;   // 改后：BB 40 00 3A
        //ram[11'h044] = 32'hE7C033FC;
        ram[11'h045] = 32'h40EB831F;
        ram[11'h046] = 32'hC35BF975;
        ram[11'h047] = 32'hB8006806;
        ram[11'h048] = 32'hAB01B407;
        ram[11'h049] = 32'hE8ACC307;
        ram[11'h04A] = 32'h84ACFFF2;
        ram[11'h04B] = 32'hC3F875C0;
        ram[11'h04C] = 32'hC10004B9;
        ram[11'h04D] = 32'h245004C0;
        ram[11'h04E] = 32'h720A3C0F;
        ram[11'h04F] = 32'h04070402;
        ram[11'h050] = 32'hFFD8E830;
        ram[11'h051] = 32'hC3ECE258;
        ram[11'h052] = 32'hC033D233;
        ram[11'h053] = 32'hE2D003AC;
        ram[11'h054] = 32'hA0BFC3FB;
        ram[11'h055] = 32'hFEFDBE00;
        ram[11'h056] = 32'hE8FFCBE8;
        ram[11'h057] = 32'h00BEFFB1;
        ram[11'h058] = 32'h0034E801;
        ram[11'h059] = 32'h2FE8FC8A;
        ram[11'h05A] = 32'hE8DC8A00;
        ram[11'h05B] = 32'h2488002A;
        ram[11'h05C] = 32'hF7754B46;
        ram[11'h05D] = 32'hD48EE433;
        ram[11'h05E] = 32'h000100EA;
        ram[11'h05F] = 32'hFD91BEF0;
        ram[11'h060] = 32'h07B9FB8B;
        ram[11'h061] = 32'hBFA4F300;
        ram[11'h062] = 32'hF633E000;
        ram[11'h063] = 32'hFF1000B9;
        ram[11'h064] = 32'hEAA5F3E3;
        ram[11'h065] = 32'hFFFF0000;
        ram[11'h066] = 32'hDABA80B4;
        ram[11'h067] = 32'hFA52B903;
        ram[11'h068] = 32'h02E8C0EC;
        //ram[11'h069] = 32'h40E4FA72;
        ram[11'h069] = 32'h40E4FAEB;  //卡srstb
        ram[11'h06A] = 32'h40E4E802;
        ram[11'h06B] = 32'hEC0008E8;
        ram[11'h06C] = 32'hD002E8C0;
        ram[11'h06D] = 32'h81F573DC;
        ram[11'h06E] = 32'hE40A5BE9;
        ram[11'h06F] = 32'hE4E83840;
        ram[11'h070] = 32'hC3F87540;
        ram[11'h071] = 32'h01B4FFB0;
        ram[11'h072] = 32'h73C003EE;
        ram[11'h073] = 32'hACC3EDFB;
        ram[11'h074] = 32'hE2018FE8;
        ram[11'h075] = 32'h87E8C3FA;
        ram[11'h076] = 32'h47258801;
        ram[11'h077] = 32'hE8C3F8E2;
        ram[11'h078] = 32'h06B9017E;
        ram[11'h079] = 32'hFFE7E800;
        ram[11'h07A] = 32'h73E8F633;
        ram[11'h07B] = 32'h05744601;
        ram[11'h07C] = 32'h74FFFC80;
        ram[11'h07D] = 32'h5250C3F5;
        ram[11'h07E] = 32'h0007E851;
        ram[11'h07F] = 32'h5901E983;
        ram[11'h080] = 32'h50C3585A;
        ram[11'h081] = 32'hB250C28A;
        ram[11'h082] = 32'hF48B5251;
        ram[11'h083] = 32'hB403DABA;
        ram[11'h084] = 32'h44C6EF01;
        ram[11'h085] = 32'h5BE8FF05;
        ram[11'h086] = 32'h06C48301;
        ram[11'h087] = 32'h1675E40A;
        ram[11'h088] = 32'h80016EE8;
        ram[11'h089] = 32'h0E75FEFC;
        ram[11'h08A] = 32'hFB8B02B5;
        ram[11'h08B] = 32'hE8018DE8;
        ram[11'h08C] = 32'h2BE8012E;
        ram[11'h08D] = 32'hC0334101;
        ram[11'h08E] = 32'h0124E8EF;
        ram[11'h08F] = 32'h03DABAC3;
        ram[11'h090] = 32'hE8000AB9;
        ram[11'h091] = 32'hFBE2011A;
        ram[11'h092] = 32'hBEEF01B4;
        ram[11'h093] = 32'h91E8FF38;
        ram[11'h094] = 32'h75CCFEFF;
        ram[11'h095] = 32'hFF3EBE65;
        ram[11'h096] = 32'hFEFF84E8;
        ram[11'h097] = 32'hB15B75CC;
        ram[11'h098] = 32'h8BE12B04;
        ram[11'h099] = 32'h0154E8FC;
        ram[11'h09A] = 32'hFC805858;
        ram[11'h09B] = 32'hBE4B75AA;
        ram[11'h09C] = 32'h6AE8FF50;
        ram[11'h09D] = 32'h00E8E8FF;
        ram[11'h09E] = 32'hE8FF4ABE;
        ram[11'h09F] = 32'hCCFEFF64;
        ram[11'h0A0] = 32'h56BEED74;
        ram[11'h0A1] = 32'hFF57E8FF;
        ram[11'h0A2] = 32'hE12B04B1;
        ram[11'h0A3] = 32'h2BE8FC8B;
        ram[11'h0A4] = 32'h40A85801;
        ram[11'h0A5] = 32'hBE237458;
        ram[11'h0A6] = 32'h42E8FF44;
        ram[11'h0A7] = 32'h75E40AFF;
        ram[11'h0A8] = 32'hFF44E819;
        ram[11'h0A9] = 32'h75FEFC80;
        ram[11'h0AA] = 32'h2B12B111;
        ram[11'h0AB] = 32'hE8FC8BE1;
        ram[11'h0AC] = 32'h4D8B010A;
        ram[11'h0AD] = 32'h41CD86F6;
        ram[11'h0AE] = 32'hC033E78B;
        ram[11'h0AF] = 32'h00A0E8EF;
        ram[11'h0B0] = 32'h53C3C18B;
        ram[11'h0B1] = 32'h63726165;
        ram[11'h0B2] = 32'h676E6968;
        ram[11'h0B3] = 32'h4F494220;
        ram[11'h0B4] = 32'h6E6F2053;
        ram[11'h0B5] = 32'h43445320;
        ram[11'h0B6] = 32'h20647261;
        ram[11'h0B7] = 32'h73616C28;
        ram[11'h0B8] = 32'h4B382074;
        ram[11'h0B9] = 32'h6E612042;
        ram[11'h0BA] = 32'h69662064;
        ram[11'h0BB] = 32'h20747372;
        ram[11'h0BC] = 32'h74636573;
        ram[11'h0BD] = 32'h2973726F;
        ram[11'h0BE] = 32'h2E2E2E20;
        ram[11'h0BF] = 32'h4F494200;
        ram[11'h0C0] = 32'h6F6E2053;
        ram[11'h0C1] = 32'h6F662074;
        ram[11'h0C2] = 32'h2C646E75;
        ram[11'h0C3] = 32'h69617720;
        ram[11'h0C4] = 32'h676E6974;
        ram[11'h0C5] = 32'h206E6F20;
        ram[11'h0C6] = 32'h33325352;
        ram[11'h0C7] = 32'h31282032;
        ram[11'h0C8] = 32'h30323531;
        ram[11'h0C9] = 32'h73706230;
        ram[11'h0CA] = 32'h3066202C;
        ram[11'h0CB] = 32'h313A3030;
        ram[11'h0CC] = 32'h20293030;
        ram[11'h0CD] = 32'h002E2E2E;
        ram[11'h0CE] = 32'h00000040;
        ram[11'h0CF] = 32'h00489500;
        ram[11'h0D0] = 32'h87AA0100;
        ram[11'h0D1] = 32'h00000049;
        ram[11'h0D2] = 32'h4069FF00;
        ram[11'h0D3] = 32'hFF000000;
        ram[11'h0D4] = 32'h00000077;
        ram[11'h0D5] = 32'h007AFF00;
        ram[11'h0D6] = 32'hFF000000;
        ram[11'h0D7] = 32'h00000000;
        ram[11'h0D8] = 32'h01B4FFB0;
        ram[11'h0D9] = 32'h40B951EE;
        ram[11'h0DA] = 32'h59FEE200;
        ram[11'h0DB] = 32'hF473C003;
        ram[11'h0DC] = 32'h0000C3ED;
        ram[11'h0DD] = 32'h50FE6BE8;
        ram[11'h0DE] = 32'h00E0BA52;
        ram[11'h0DF] = 32'h5AEEC48A;
        ram[11'h0E0] = 32'h5250C358;
        ram[11'h0E1] = 32'hEF00E3BA;
        ram[11'h0E2] = 32'h90C3585A;
        ram[11'h0E3] = 32'h90909090;
        ram[11'h0E4] = 32'hFE54E890;
        ram[11'h0E5] = 32'hE1BA5250;
        ram[11'h0E6] = 32'hEEC48A00;
        ram[11'h0E7] = 32'h90C3585A;
        ram[11'h0E8] = 32'h90909090;
        ram[11'h0E9] = 32'h90909090;
        ram[11'h0EA] = 32'h90909090;
        ram[11'h0EB] = 32'h0F249090;
        ram[11'h0EC] = 32'h02720A3C;
        ram[11'h0ED] = 32'h30040704;
        ram[11'h0EE] = 32'hC3FD61E8;
        ram[11'h0EF] = 32'hFFA0E853;
        ram[11'h0F0] = 32'h9BE8DC8A;
        ram[11'h0F1] = 32'h89C38AFF;
        ram[11'h0F2] = 32'h02C78305;
        ram[11'h0F3] = 32'h7502E983;
        ram[11'h0F4] = 32'hBEC35BEC;
        ram[11'h0F5] = 32'h87E80200;
        ram[11'h0F6] = 32'hFEFC80FF;
        ram[11'h0F7] = 32'h754E0374;
        ram[11'h0F8] = 32'h8B52C3F5;
        ram[11'h0F9] = 32'h00E2BAC2;
        ram[11'h0FA] = 32'h90C35AEF;
        ram[11'h0FB] = 32'h90909090;
        // 改回：
        ram[11'h0FC] = 32'h00FC00EA;   // EA 00 FC 00 = JMP F000:FC00
        ram[11'h0FD] = 32'h000000F0;   // F0
        ram[11'h0FE] = 32'h00000000;
        ram[11'h0FF] = 32'h00000000;

        // ============================================================
        // ★ 4-way 复制：way0 index 16-31 复制到 way1/2/3 index 16-31
        //    RAM 地址映射：way0 → 0x000~0x0FF, way1 → 0x400~0x4FF
        //                  way2 → 0x800~0x8FF, way3 → 0xC00~0xCFF
        // ============================================================
        for (i = 0; i < 256; i = i + 1) begin
            ram[11'h200 + i] = ram[i];
            ram[11'h400 + i] = ram[i];
            ram[11'h600 + i] = ram[i];
        end
    end

    // 端口 A
    always @(posedge clock_a) begin
        if (enable_a) begin
            if (wren_a) begin
                if (byteena_a[0]) ram[address_a][7:0]   <= data_a[7:0];
                if (byteena_a[1]) ram[address_a][15:8]  <= data_a[15:8];
                if (byteena_a[2]) ram[address_a][23:16] <= data_a[23:16];
                if (byteena_a[3]) ram[address_a][31:24] <= data_a[31:24];
            end
            q_a <= ram[address_a];
        end
    end

    // 端口 B
    always @(posedge clock_b) begin
        if (enable_b) begin
            if (wren_b) begin
                if (byteena_b[0]) ram[address_b][7:0]   <= data_b[7:0];
                if (byteena_b[1]) ram[address_b][15:8]  <= data_b[15:8];
                if (byteena_b[2]) ram[address_b][23:16] <= data_b[23:16];
                if (byteena_b[3]) ram[address_b][31:24] <= data_b[31:24];
            end
            q_b <= ram[address_b];
        end
    end
endmodule
// ---------------------------------------------------------
// 7. 显卡 DAC 色彩表 (修复非对称端口位宽，预载 VGA 调色板)
// ---------------------------------------------------------
module DAC_SRAM (
    input         clock_a,
    input         clock_b,
    input  [9:0]  address_a,  // A 端口 10位地址
    input  [7:0]  address_b,  // B 端口 8位地址
    input  [7:0]  data_a,     // A 端口 8位写入
    input  [31:0] data_b,     // B 端口 32位写入 (暂不使用)
    input         wren_a,
    input         wren_b,
    output reg [7:0]  q_a,
    output reg [31:0] q_b     // B 端口 32位输出
);
    // 主存储器：256 个 32位数据
    reg [31:0] ram [255:0];

    integer i;
    initial begin
        for (i = 0; i < 256; i = i + 1) ram[i] = 32'h0;

        // 预加载标准 VGA 16色调色板的 RGB 映射 (防止 BIOS 未初始化导致全黑)
        // Next186 格式: 32'h00_BB_GG_RR (RGB 各占 6 位，即 0x00~0x3F)
        ram[8'h00] = 32'h00_00_00_00; // Black
        ram[8'h01] = 32'h00_2A_00_00; // Blue
        ram[8'h02] = 32'h00_00_2A_00; // Green
        ram[8'h03] = 32'h00_2A_2A_00; // Cyan
        ram[8'h04] = 32'h00_00_00_2A; // Red
        ram[8'h05] = 32'h00_2A_00_2A; // Magenta
        ram[8'h14] = 32'h00_00_15_2A; // Brown (Index 20)
        ram[8'h07] = 32'h00_2A_2A_2A; // Light Gray

        ram[8'h38] = 32'h00_15_15_15; // Dark Gray (Index 56)
        ram[8'h39] = 32'h00_3F_15_15; // Light Blue
        ram[8'h3A] = 32'h00_15_3F_15; // Light Green
        ram[8'h3B] = 32'h00_3F_3F_15; // Light Cyan
        ram[8'h3C] = 32'h00_15_15_3F; // Light Red
        ram[8'h3D] = 32'h00_3F_15_3F; // Light Magenta
        ram[8'h3E] = 32'h00_15_3F_3F; // Yellow
        ram[8'h3F] = 32'h00_3F_3F_3F; // White
    end

    // 端口 A：非对称位宽拼凑逻辑 (模拟 altsyncram 特性)
    always @(posedge clock_a) begin
        if (wren_a) begin
            case (address_a[1:0])
                2'b00: ram[address_a[9:2]][7:0]   <= data_a;
                2'b01: ram[address_a[9:2]][15:8]  <= data_a;
                2'b10: ram[address_a[9:2]][23:16] <= data_a;
                2'b11: ram[address_a[9:2]][31:24] <= data_a;
            endcase
        end
        case (address_a[1:0])
            2'b00: q_a <= ram[address_a[9:2]][7:0];
            2'b01: q_a <= ram[address_a[9:2]][15:8];
            2'b10: q_a <= ram[address_a[9:2]][23:16];
            2'b11: q_a <= ram[address_a[9:2]][31:24];
        endcase
    end

    // 端口 B：32位直接输出
    always @(posedge clock_b) begin
        if (wren_b) ram[address_b] <= data_b;
        q_b <= ram[address_b];
    end
endmodule
// ---------------------------------------------------------
// 8. 显卡字库 ROM/RAM (双时钟 双口 RAM)
// ---------------------------------------------------------
module sr_font (
    input clock_a, input clock_b, input [11:0] address_a, input [11:0] address_b, 
    input [7:0] data_a, input [7:0] data_b, input wren_a, input wren_b, 
    output reg [7:0] q_a, output reg [7:0] q_b
);
    (* ram_style = "block" *)reg [7:0] ram [4095:0];
    initial begin
        $readmemh("font8x16.mem",ram);
    end
    
    always @(posedge clock_a) begin
        if (wren_a) ram[address_a] <= data_a;
        q_a <= ram[address_a];
    end
    always @(posedge clock_b) begin
        if (wren_b) ram[address_b] <= data_b;
        q_b <= ram[address_b];
    end
endmodule

// ---------------------------------------------------------
// 9, 10, 11. DSP 及 OPL3 数据/指令内存 (单口 RAM)
// ---------------------------------------------------------
module instrmem (
    input  wire        clock,
    input  wire        wrclock,
    input  wire        rdclock,
    input  wire [9:0]  rdaddress,
    input  wire [9:0]  wraddress,
    input  wire [15:0] data,
    input  wire        wren,
    input  wire        rden,
    output reg  [15:0] q
);
    reg [15:0] ram [1023:0];
    
    // 自动选择可用的写时钟
    wire actual_wr_clk = (wrclock !== 1'bz) ? wrclock : clock;
    // 自动选择可用的读时钟
    wire actual_rd_clk = (rdclock !== 1'bz) ? rdclock : clock;

    always @(posedge actual_wr_clk) begin
        if (wren) ram[wraddress] <= data;
    end
    
    always @(posedge actual_rd_clk) begin
        if (rden) q <= ram[rdaddress];
    end
endmodule

module datamem16 (
    input  wire        clock,
    input  wire        wrclock,
    input  wire        rdclock,
    input  wire [10:0] rdaddress,
    input  wire [10:0] wraddress,
    input  wire [15:0] data,
    input  wire        wren,
    input  wire        rden,
    output reg  [15:0] q
);
    reg [15:0] ram [2047:0];
    
    wire actual_wr_clk = (wrclock !== 1'bz) ? wrclock : clock;
    wire actual_rd_clk = (rdclock !== 1'bz) ? rdclock : clock;

    always @(posedge actual_wr_clk) begin
        if (wren) ram[wraddress] <= data;
    end
    
    always @(posedge actual_rd_clk) begin
        if (rden) q <= ram[rdaddress];
    end
endmodule
module opl3_mem (
    input  wire        clock,
    input  wire        clock_a,
    input  wire        clock_b,
    input  wire        wren_a,
    input  wire        wren_b,
    input  wire [8:0]  address_a,
    input  wire [8:0]  address_b,
    input  wire [15:0] data_a,
    input  wire [15:0] data_b,
    output reg  [15:0] q_a,
    output reg  [15:0] q_b
);
    reg [15:0] ram [511:0];
    
    // 自动兼容单时钟或独立双时钟
    wire clk_a_real = (clock_a !== 1'bz) ? clock_a : clock;
    wire clk_b_real = (clock_b !== 1'bz) ? clock_b : clock;

    always @(posedge clk_a_real) begin
        if (wren_a) ram[address_a] <= data_a;
        q_a <= ram[address_a];
    end
    
    always @(posedge clk_b_real) begin
        if (wren_b) ram[address_b] <= data_b;
        q_b <= ram[address_b];
    end
endmodule