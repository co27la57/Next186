// sim/tb/ddr_pipe_main.cpp  —  stage 2 harness
// Same self-test sequence as stage 1, but now driving the REAL command pipeline and the
// REAL AXI FSM, with a VGA scan-out traffic model on the arbiter.
#include "Vddr_pipe.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>

static Vddr_pipe* dut;
static long long cyc = 0;

// ★★★ VGA 取指序列追踪(2026-10-10)
//   只在 sdraddr 走 VGA 分支的那些拍打印, 并去重(值不变不重复打印)。
//   用途: 直接看出 (a) 行内是否 1:1 推进 (b) 是否每个 32bit 字被取两次
//         (c) 行末 row_col += stride 与回绕是否正确。
static int    tr_vga      = 1;        // 由第一个命令行参数控制: 默认开
static int    tr_vga_max  = 400;      // 最多打印多少条
static int    tr_vga_n    = 0;
static unsigned p_sdr = ~0u; static int p_rc = -1, p_lnb = -1, p_col = -1;

static void trace_vga() {
    if (!tr_vga || tr_vga_n >= tr_vga_max) return;
    if (!dut->o_vga_isvga) return;
    unsigned sdr = (unsigned)dut->o_sdraddr;
    int rc = (int)dut->o_vga_row_col, lnb = (int)dut->o_vga_lnb, col = (int)dut->o_vga_col;
    if (sdr == p_sdr && rc == p_rc && lnb == p_lnb && col == p_col) return;
    p_sdr = sdr; p_rc = rc; p_lnb = lnb; p_col = col;
    printf("[VGA] cyc=%-7lld sdr=0x%06X phys=0x%08X rowcol=0x%05X lnb=%3d col=%2d\n",
           cyc, sdr, 0x08000000u + 2u * sdr, (unsigned)rc, lnb, col);
    tr_vga_n++;
}


// ★ 追加: 追踪 cmd/ack 转换(判断 VGA 读是否真的被 ack)
static int p_cmd=-1, p_ack=-1; static int tr_cmd_n=0;
static void trace_cmdack() {
    if (!tr_vga || tr_cmd_n >= 5000) return;
    int cm=(int)dut->o_cmd, ak=(int)dut->o_ack;
    if (cm==p_cmd && ak==p_ack) return;
    p_cmd=cm; p_ack=ak;
    printf("[CMD] cyc=%-7lld cmd=%d ack=%d lnb=%3d col=%2d sdr=0x%06X\n",
           cyc, cm, ak, (int)dut->o_vga_lnb, (int)dut->o_vga_col, (unsigned)dut->o_sdraddr);
    tr_cmd_n++;
}

static void tick() {
    // clk_cpu 25 MHz, clk_sdr 50 MHz  ->  2 ddr edges per cpu edge
    dut->clk_cpu = 0; dut->clk_sdr = 0; dut->eval();
    dut->clk_sdr = 1; dut->eval();
    dut->clk_sdr = 0; dut->eval();
    dut->clk_sdr = 1; dut->eval();
    dut->clk_cpu = 1; dut->eval();
    trace_vga(); trace_cmdack();
    dut->clk_sdr = 0; dut->eval();
    dut->clk_sdr = 1; dut->eval();
    dut->clk_sdr = 0; dut->eval();
    dut->clk_sdr = 1; dut->eval();
    cyc++;
}

static void cpu_write(unsigned addr, unsigned data, unsigned wmask) {
    for (int g = 0; g < 400000; g++) { if (dut->cpu_ce) break; tick(); }
    dut->cpu_addr = addr; dut->cpu_din = data; dut->cpu_wmask = wmask; dut->cpu_mreq = 1;
    tick();
    dut->cpu_mreq = 0;
    tick();
}
static unsigned cpu_read(unsigned addr) {
    for (int g = 0; g < 400000; g++) { if (dut->cpu_ce) break; tick(); }
    dut->cpu_addr = addr; dut->cpu_din = 0; dut->cpu_wmask = 0; dut->cpu_mreq = 1;
    tick();
    unsigned v = dut->cpu_dout;
    dut->cpu_mreq = 0;
    tick();
    return v;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vddr_pipe;

    int gate = (argc > 1) ? atoi(argv[1]) : 1;
    if (argc > 2) tr_vga = atoi(argv[2]);      // 第2个参数: 0 = 关闭取指序列打印
    printf("gate_fill = %d  (%s)\n", gate, gate ? "91st fix: fill gated on its own burst"
                                                : "OLD: fill accepts ANY read burst");
    printf("trace_vga = %d\n", tr_vga);
    dut->rst = 1; dut->cpu_mreq = 0; dut->cpu_wmask = 0; dut->cpu_din = 0;
    dut->cpu_addr = 0; dut->vga_starving = 0; dut->vga_ready = 0;   // vga_ready=0 => FIFO full => ram_cmd 才会回到 2b00
    dut->gate_fill = (gate != 0) ? 1 : 0;
    for (int i = 0; i < 8; i++) tick();
    dut->rst = 0;
    for (int i = 0; i < 4; i++) tick();

    const unsigned BASE = 0x000F0000u;                 // F000:0000
    for (unsigned k = 0; k < 256; k++)
        cpu_write(BASE + 4*k, (k & 0xFFu) * 0x01010101u, 0xF);

    unsigned ctrl = cpu_read(BASE + 0x40);

    // per-frame flush is NOT present in stage 2 yet (flush is tied 0 in ddr_pipe.v);
    // instead drive VGA scan-out demand.  REALISTIC level: the real FIFO is 1024 deep and
    // s_prog_empty only when occupancy < 64, i.e. SHORT, RARE starvation bursts - not the
    // 40%-duty model used in the first stage-2 run.
    const int VGA_PERIOD = 300;   // cycles between starvation bursts
    const int VGA_LEN    = 4;     // cycles per burst
    for (int f = 0; f < 12; f++) {
        for (int i = 0; i < VGA_PERIOD * 6; i++) {
            // ★ 让 FIFO 平时"满"(vga_ready=0 => s_prog_full=1 => ram_cmd=2'b00),
            //   只在 starvation 窗口脉冲 => ram_cmd 在 2'b00/2'b10 间变化 => sys_cmd_ack 有上升沿
            //   => vga_lnbytecount 才会推进(否则台架永远停在 lnb=0)。
            int ph = i % VGA_PERIOD;
            dut->vga_starving = (ph < VGA_LEN) ? 1 : 0;
            dut->vga_ready    = (ph < VGA_LEN) ? 1 : 0;
            tick();
        }
        (void)cpu_read(BASE + 0x1000 + (f & 0xF)*0x40);
    }
    dut->vga_starving = 0; dut->vga_ready = 0;
    for (int i = 0; i < 200; i++) tick();

    unsigned meas = cpu_read(BASE + 0x80);

    printf("\n================ stage-2 result ================\n");
    printf("control  offset 0x40 = 0x%08X   (expect 0x10101010)\n", ctrl);
    printf("measure  offset 0x80 = 0x%08X   (expect 0x20202020)\n", meas);
    printf("byte  @0x80 = 0x%02X  (0x20 ok ; 0x50 line+3 ; 0xFF erased)\n", meas & 0xFF);
    printf("line-2 fills = %u , line-2 write-backs = %u\n",
           (unsigned)dut->o_l2_fill_n, (unsigned)dut->o_l2_wb_n);
    printf("fill_foreign = %u  (91st condition)\n", (unsigned)dut->o_fill_foreign_n);
    printf("cycles = %lld\n", cyc);
    printf("================================================\n");

    dut->final();
    delete dut;
    return 0;
}
