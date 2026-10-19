// sim/tb/opl3_ym_dbg.v — 仿真专用包装层：暴露 opl3_ym 与 ymf262 内部信号
module opl3_ym_dbg(
    input  wire        clk50,
    input  wire        rst,
    input  wire        cpu_ce,
    input  wire        cpu_wr,
    input  wire [1:0]  cpu_addr,
    input  wire [7:0]  cpu_din,
    output wire [7:0]  cpu_dout,
    output wire [15:0] left,
    output wire [15:0] right,
    output wire [3:0]  keyon,
    // 调试
    output wire        dbg_sy,
    output wire        dbg_smpac,
    output wire        dbg_smpbd,
    output wire        dbg_doab,
    output wire        dbg_csn,
    output wire        dbg_wrn,
    output wire        dbg_reset0,
    output wire [15:0] dbg_shifter,
    output wire [3:0]  dbg_wr_str,
    // 核心内部状态
    output wire        dbg_keyon,
    output wire [18:0] dbg_phase0,
    output wire [1:0]  dbg_egstate0,
    output wire [8:0]  dbg_eglevel0,
    output wire [5:0]  dbg_tl0,
    output wire [3:0]  dbg_ar0,
    output wire [3:0]  dbg_multi0,
    output wire [9:0]  dbg_fnum0,
    output wire [2:0]  dbg_block0,
    output wire [2:0]  dbg_fb0,
    output wire [5:0]  dbg_tl1,
    output wire [3:0]  dbg_ar1,
    output wire [47:0] dbg_pow,
    output wire [6:0]  dbg_wptr,
    output wire [6:0]  dbg_rptr,
    output wire [9:0]  dbg_repcnt,
    output wire        dbg_iowrite,
    output wire        dbg_iocs,
    output wire [7:0]  dbg_dlatch,
    output wire [8:0]  dbg_raddr_l,
    output wire [9:0]  dbg_fifo0,
    output wire [9:0]  dbg_fifo1,
    output wire        dbg_ioa0,
    output wire        dbg_wr0,
    output wire        dbg_wr1,
    output wire [1:0]  dbg_core_addr
);
    opl3_ym #(.INC_14M(32'd614948834)) u (
        .mclk(clk50), .rst(rst),
        .cpu_ce(cpu_ce), .cpu_wr(cpu_wr), .cpu_addr(cpu_addr), .cpu_din(cpu_din),
        .cpu_dout(cpu_dout), .left(left), .right(right), .keyon(keyon)
    );
    assign dbg_sy      = u.ymf_sy;
    assign dbg_smpac   = u.ymf_smpac;
    assign dbg_smpbd   = u.ymf_smpbd;
    assign dbg_doab    = u.ymf_doab;
    assign dbg_csn     = u.cs_n;
    assign dbg_wrn     = u.wr_n;
    assign dbg_reset0  = u.u_ymf262.reset0;
    assign dbg_shifter = u.dac_shifter;
    assign dbg_wr_str  = u.wptr[3:0];
    assign dbg_keyon   = u.u_ymf262.keyon;
    assign dbg_phase0  = u.u_ymf262.pg_phase_o[0];
    assign dbg_egstate0= u.u_ymf262.eg_state_o[0];
    assign dbg_eglevel0= u.u_ymf262.eg_level_o[0];
    assign dbg_tl0     = u.u_ymf262.ra_tl[0];
    assign dbg_ar0     = u.u_ymf262.ra_ar[0];
    assign dbg_multi0  = u.u_ymf262.ra_multi[0];
    assign dbg_fnum0   = u.u_ymf262.ra_fnum[0];
    assign dbg_block0  = u.u_ymf262.ra_block[0];
    assign dbg_fb0     = u.u_ymf262.ra_fb[0];
    assign dbg_tl1     = u.u_ymf262.ra_tl[1];
    assign dbg_ar1     = u.u_ymf262.ra_ar[1];
    assign dbg_pow     = u.u_ymf262.pow_lut_out;
    assign dbg_wptr    = u.wptr;
    assign dbg_rptr    = u.rptr;
    assign dbg_repcnt  = u.rep_cnt;
    assign dbg_iowrite = u.u_ymf262.io_write;
    assign dbg_iocs    = u.u_ymf262.io_cs;
    assign dbg_dlatch  = u.u_ymf262.data_latch;
    assign dbg_raddr_l = u.u_ymf262.ra_address_latch;
    assign dbg_fifo0   = u.wfifo[0];
    assign dbg_fifo1   = u.wfifo[1];
    assign dbg_ioa0    = u.u_ymf262.io_a0;
    assign dbg_wr0     = u.u_ymf262.write0;
    assign dbg_wr1     = u.u_ymf262.write1;
    assign dbg_core_addr = u.core_addr;
endmodule
