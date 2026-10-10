// sim/tb/tb_cache_main.cpp
// Drives the stage-1 TB: reproduce the self-test's essence on the SD buffer line.
//
//   line 2 of the buffer (tag 0x1E0, index 2) -> physical 0x08150080
//   write word k = 0x20+k*0x01010101  (byte at offset m == (m>>2)&0xFF, like the BIOS test)
//   then force the cache to evict by hammering other addresses, then read offset 0x80 back.
//
// Prints a per-cycle trace of (state, hiaddr, sdraddr, cmd, ack, cache_write_data, wbdata, rddata)
// while any DDR transaction is in flight.
#include "Vtb_cache.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>

static Vtb_cache* dut;
static long long cyc = 0;

static void tick() {
    // one clk_cpu cycle = 2 ddr_clk cycles (clk 25 MHz, ddr_clk 50 MHz in the real design)
    dut->clk = 0; dut->ddr_clk = 0; dut->eval();
    dut->ddr_clk = 1; dut->eval();
    dut->ddr_clk = 0; dut->eval();
    dut->ddr_clk = 1; dut->eval();
    dut->clk = 1; dut->eval();
    dut->ddr_clk = 0; dut->eval();
    dut->ddr_clk = 1; dut->eval();
    dut->ddr_clk = 0; dut->eval();
    dut->ddr_clk = 1; dut->eval();
    cyc++;
}

// ---- CPU bus helpers -------------------------------------------------
// The cache de-asserts `ce` while it is busy (miss/fill/write-back); the CPU must wait.
static void cpu_write(unsigned addr, unsigned data, unsigned wmask) {
    for (int guard = 0; guard < 200000; guard++) {
        if (dut->cpu_ce) break;
        tick();
    }
    dut->cpu_addr = addr; dut->cpu_din = data; dut->cpu_wmask = wmask; dut->cpu_mreq = 1;
    tick();
    dut->cpu_mreq = 0;
    tick();
}

static unsigned cpu_read(unsigned addr) {
    for (int guard = 0; guard < 200000; guard++) {
        if (dut->cpu_ce) break;
        tick();
    }
    dut->cpu_addr = addr; dut->cpu_din = 0; dut->cpu_wmask = 0; dut->cpu_mreq = 1;
    tick();
    unsigned v = dut->cpu_dout;
    dut->cpu_mreq = 0;
    tick();
    return v;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vtb_cache;

    int gate = (argc > 1) ? atoi(argv[1]) : 1;     // 1 = 91st fix, 0 = old behaviour
    int verbose = (argc > 2) ? atoi(argv[2]) : 0;
    (void)verbose;
    printf("gate_fill = %d  (%s)\n", gate, gate ? "91st fix: fill gated on its own burst"
                                                : "OLD: fill accepts ANY read burst");

    dut->rst = 1; dut->cpu_mreq = 0; dut->cpu_wmask = 0; dut->cpu_din = 0;
    dut->cpu_addr = 0; dut->vga_starving = 0; dut->flush_in = 0;
    dut->gate_fill = (gate != 0) ? 1 : 0;
    for (int i = 0; i < 8; i++) tick();
    dut->rst = 0;
    for (int i = 0; i < 4; i++) tick();

    // ---- fill the 1 KB buffer at F000:0000 with the BIOS self-test pattern ----
    // byte at offset m == (m>>2)&0xFF  ->  32-bit word at offset 4k == 0x01010101*k
    const unsigned BASE = 0x000F0000u;                 // F000:0000
    for (unsigned k = 0; k < 256; k++) {
        unsigned word = (k & 0xFFu) * 0x01010101u;
        cpu_write(BASE + 4*k, word, 0xF);
    }

    // ---- control read (line 1, still cached) : offset 0x40 ----
    unsigned ctrl = cpu_read(BASE + 0x40);

    // ---- per-frame flush (real design: flush = auto_flush==3'b110, one pulse per vblnk) ----
    // This is what actually writes the dirty buffer lines back on the real board, so the TB
    // must model it - otherwise line 2 is never evicted and the round trip never happens.
    // Interleaved with VGA contention so the write-backs face the same arbitration.
    for (int f = 0; f < 4; f++) {
        dut->vga_starving = 1;
        dut->flush_in = 1; tick();
        dut->flush_in = 0;
        for (int i = 0; i < 400; i++) {
            if ((i & 0x3F) == 0) dut->vga_starving = !dut->vga_starving;
            tick();
        }
        dut->vga_starving = 0;
        for (int i = 0; i < 400; i++) tick();
    }

    // touch other lines so set 2 gets reused
    for (unsigned a = 0; a < 16; a++)
        (void)cpu_read(BASE + 0x1000 + a*0x40);

    // ---- measurement read: offset 0x80 (line 2) ----
    unsigned meas = cpu_read(BASE + 0x80);

    printf("\n================ stage-1 result ================\n");
    printf("control  offset 0x40 (line 1, cached)  = 0x%08X   (expect 0x10101010)\n", ctrl);
    printf("measure  offset 0x80 (line 2, evicted) = 0x%08X   (expect 0x20202020)\n", meas);
    printf("byte  @0x80 = 0x%02X  (expect 0x20 ; 0x50 => line+3 ; 0xFF => erased)\n",
           meas & 0xFF);
    printf("line-2 fills = %u , line-2 write-backs = %u   <- MUST be > 0, else the\n",
           (unsigned)dut->o_l2_fill_n, (unsigned)dut->o_l2_wb_n);
    printf("                                                  measurement was a plain hit\n");
    printf("fill_foreign = %u   <- 91st condition: a NON-cache read burst delivered\n",
           (unsigned)dut->o_fill_foreign_n);
    printf("                       data while the cache wanted a fill. 0 => the VGA\n");
    printf("                       contention never actually overlapped a fill\n");
    printf("cycles = %lld\n", cyc);
    printf("================================================\n");
    if (verbose) { /* per-cycle trace handled by --trace in Verilator */ }

    dut->final();
    delete dut;
    return 0;
}
