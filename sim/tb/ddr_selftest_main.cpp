// sim/tb/ddr_selftest_main.cpp  --  stage 2b
//
// Replays the REAL on-board BIOS self-test byte for byte:
//
//   0x39F: xor di,di / xor al,al / mov cx,4 / rep stosb / inc al / jne   (fill 1KB,
//          byte at offset m == (m>>2)&0xFF)
//   0x3B0: mov al,[di]        di=0x40   -> CONTROL  (expect 0x10)
//   0x3B2: mov di,0x0080
//   0x3B5: call 0x10F         scan256: bx=0x4000; do { cmp bl,[bx]; bx-=0x40 } while(bx)
//   0x3B8: mov ah,[di]        di=0x80   -> MEASURE  (expect 0x20 ; 0x50 == line+3)
//
// The point of this harness: the previous stage-2 driver never ran scan256, so the
// buffer lines were never evicted and the cache<->DDR round trip never happened
// (line-2 write-backs = 0).  Here the round trip DOES happen, which is where the
// board loses the data.
//
// Bus cycles are faithful: MREQ is held until the cache releases CE (stall), exactly
// like the BIU does.  The previous driver deasserted MREQ after one cycle.
#include "Vddr_pipe.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>

static Vddr_pipe* dut;
static long long cyc = 0;
static bool trace_on = false;

static bool vga_on = false;
static int  cpu_gap = 0;   // idle clk_cpu cycles inserted after every bus cycle
// ---- clocking model ------------------------------------------------------------
// Real board: clk_cpu 25 MHz, clk_sdr 50 MHz  =>  exactly 2 clk_sdr periods per
// clk_cpu period, and the two domains come out of separate MMCM outputs, so their
// relative PHASE is a free parameter.  seg_map is a clk_cpu-domain BRAM whose output
// (memmap_mux) is consumed by the clk_sdr-domain sdraddr mux, so the phase decides how
// stale that value is when sdraddr is latched.  Both the ratio and the phase are
// therefore testbench parameters, and the sweep is the experiment.
static int SDR_PER_CPU = 2;   // clk_sdr periods per clk_cpu period (real design: 2)
static int CPU_PHASE   = 1;   // clk_sdr half-period index at which clk_cpu rises

static void tick() {
    // VGA starvation model: the scan-out FIFO runs dry for 4 clk_sdr out of every 300.
    // ★ It MUST be driven here, not only inside the scan256 loop: leaving it frozen at 1
    //   during the read-back phase would starve the cache for ever (cmd stays 2'b10) and
    //   the CPU would spin - a test-bench artefact, not an RTL bug.
    if (vga_on) dut->vga_starving = ((cyc % 300) < 4) ? 1 : 0;
    const int half = 2 * SDR_PER_CPU;
    dut->clk_cpu = 0; dut->clk_sdr = 0; dut->eval();
    for (int h = 0; h < half; h++) {
        if (h == CPU_PHASE) { dut->clk_cpu = 1; dut->eval(); }
        dut->clk_sdr = (h & 1) ? 0 : 1;
        dut->eval();
    }
    dut->clk_sdr = 0; dut->eval();
    cyc++;
}

// one 186 bus cycle; returns the 32-bit word the cache presents on DOUT
static unsigned bus(unsigned addr, unsigned data, unsigned wmask) {
    for (long long g = 0; g < 2000000; g++) { if (dut->cpu_ce) break; tick(); }
    dut->cpu_addr = addr; dut->cpu_din = data; dut->cpu_wmask = wmask; dut->cpu_mreq = 1;
    bool stalled = false;
    for (int i = 0; i < 2000000; i++) {
        tick();
        if (!dut->cpu_ce) stalled = true;
        else if (stalled) break;      // miss: CE went low and came back
        else if (i >= 3) break;       // plain hit
    }
    unsigned v = dut->cpu_dout;
    dut->cpu_mreq = 0;
    tick();
    // cpu_gap: extra idle clk_cpu cycles between bus cycles.  The real 80186 BIU has a
    // fixed T1..T4 cadence, so the phase of the cache's transactions relative to the DDR
    // FSM's bursts is set by the bus rhythm - make it sweepable.
    for (int g = 0; g < cpu_gap; g++) tick();
    return v;
}

// A byte write.  The real BIU drives RAM_DOUT = {DSWAP,DSWAP}, i.e. the selected byte is
// REPLICATED into all four byte lanes, so that whichever lane byteena selects gets the
// right value.  Feeding the value only in the low byte would write 0x00 into bytes 1..3.
static void wr_byte(unsigned addr, unsigned val) {
    unsigned b = val & 0xFFu;
    bus(addr, b * 0x01010101u, 1u << (addr & 3));
}
static void wr_word16(unsigned addr, unsigned val) {
    unsigned w = val & 0xFFFFu;
    bus(addr, w | (w << 16), (addr & 2) ? 0xCu : 0x3u);
}
static unsigned rd_byte(unsigned addr) {
    return bus(addr, 0, 0) & 0xFFu;
}

static unsigned dump_word(unsigned idx) {
    dut->dump_idx = idx; dut->eval();
    return dut->dump_data;
}

// ---- [多 hot 置脏实验]：写命中"4 way 同 tag"的行时，数据只进一个 way，但四个 way 全被置脏
//      ⇒ 兄弟 way 的陈旧数据会在它被选为 victim 时写回**同一地址** ⇒ DDR 里那行被打坏。
//      目标行 = linear 0xFFC00（tag=511, index=16，正是复位初值的多 hot 行 = F 段顶/bootstrap）
//      台架映射下该行的物理地址 = 0x0815_FC00。
static void exp_multihot(void) {
    const unsigned line = 0xFFC00u, ddr = 0x0815FC00u;
    const unsigned idx0 = (ddr - 0x08000000u) >> 2;
    printf("\n---- [exp] multi-hot dirty experiment (line 0xFFC00 -> DDR 0x%08X) ----\n", ddr);
    printf("EXP-BEGIN\n");

    // ① 前哨：先把目标行从 DDR 端读一遍，记下"原始(陈旧)"内容，作为"被覆盖"的参照。
    printf("  pre  DDR line:");
    for (int i = 0; i < 4; i++) printf(" %08X", dump_word(idx0 + i));
    printf("\n");

    // ② 整行写图案 0x5A5A0000..0x5A5A000F（写命中 multi-hot 行 tag=511,index=16）。
    for (int i = 0; i < 16; i++) bus(line + i*4, 0x5A5A0000u + (unsigned)i, 0xF);
    printf("  after 16 writes, DDR line:");
    for (int i = 0; i < 4; i++) printf(" %08X", dump_word(idx0 + i));
    printf("\n");

    // ③ 同 index(16)、不同 tag 的写 ⇒ 逼出 victim。22 次足以轮遍 4 个 way，
    //    其中必含"装着图案的那个 way"（⇒ 正确写回应出现）与"陈旧兄弟 way"（⇒ pre-fix 会打坏本行）。
    for (int k = 0; k < 22; k++) {
        unsigned a = 0x400u + (unsigned)k * 0x800u;
        bus(a, 0xC3C30000u + (unsigned)k, 0xF);
    }
    printf("  after 22 evictions, DDR line:");
    for (int i = 0; i < 4; i++) printf(" %08X", dump_word(idx0 + i));
    printf("\n");

    int bad = 0;
    for (int i = 0; i < 16; i++)
        if (dump_word(idx0 + i) != (0x5A5A0000u + (unsigned)i)) bad++;
    printf("  words NOT matching written pattern: %d / 16   =>  %s\n", bad,
           bad ? "**CLOBBER: written line was overwritten**" : "clean: written pattern intact");
    printf("EXP-END\n");
    printf("---- [exp] end ----\n\n");
}

int main(int argc, char** argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    Verilated::commandArgs(argc, argv);
    dut = new Vddr_pipe;

    int gate = (argc > 1) ? atoi(argv[1]) : 1;
    int vga  = (argc > 2) ? atoi(argv[2]) : 0;
    vga_on = (vga != 0);
    int fixre = (argc > 4) ? atoi(argv[4]) : 0;
    int trlvl = (argc > 3) ? atoi(argv[3]) : 0;
    trace_on = (trlvl != 0);
    SDR_PER_CPU = (argc > 5) ? atoi(argv[5]) : 2;
    CPU_PHASE   = (argc > 6) ? atoi(argv[6]) : 1;
    if (SDR_PER_CPU < 1) SDR_PER_CPU = 1;
    if (CPU_PHASE < 0 || CPU_PHASE >= 2 * SDR_PER_CPU) CPU_PHASE = 0;

    printf("gate_fill = %d (%s)   vga_model = %d   tr_on = %d   fix_re = %d   sdr/cpu = %d   cpu_phase = %d\n",
           gate, gate ? "91st fix" : "OLD ungated", vga, trlvl, fixre, SDR_PER_CPU, CPU_PHASE);

    dut->fix_re = 0; dut->rst = 1; dut->cpu_mreq = 0; dut->cpu_wmask = 0; dut->cpu_din = 0;
    dut->cpu_addr = 0; dut->vga_starving = 0; dut->vga_ready = 1;
    dut->frame_period = (argc > 7) ? (unsigned)atoi(argv[7]) : 0u;   // 0 = no per-frame flush
    dut->vblnk_len    = (argc > 8) ? (unsigned)atoi(argv[8]) : 3u;
    dut->fifo_drain   = (argc > 9) ? (unsigned)atoi(argv[9]) : 0u;   // 0 = hand-driven s_prog_*
    cpu_gap = (argc > 10) ? atoi(argv[10]) : 0;
    dut->vga_lnend_cfg = (argc > 11) ? (unsigned)atoi(argv[11]) : 6u;    // text mode
    dut->vga_stride    = (argc > 12) ? (unsigned)atoi(argv[12]) : 40u;   // words per row
    dut->vga_lcr       = (argc > 13) ? (unsigned)atoi(argv[13]) : 400u;  // wrap scanline
    dut->inject_fill_shift = (argc > 14) ? (unsigned)atoi(argv[14]) : 0u;   // synthetic fault
    dut->fix_96 = (argc > 15) ? (unsigned)atoi(argv[15]) : 0u;             // 96th fix (default off)
    dut->fix_97 = (argc > 16) ? (unsigned)atoi(argv[16]) : 0u;             // 97th fix (default off)
    dut->fix_100 = (argc > 17) ? (unsigned)atoi(argv[17]) : 0u;           // 100th fix (default off)
    dut->snap_now = 0;
    printf("  vga: lnend=%u stride=%u lcr=%u\n",
           (unsigned)dut->vga_lnend_cfg, (unsigned)dut->vga_stride, (unsigned)dut->vga_lcr);
    printf("  cpu_gap = %d\n", cpu_gap);
    printf("  frame_period = %u clk_cpu   vblnk_len = %u\n",
           (unsigned)dut->frame_period, (unsigned)dut->vblnk_len);
    dut->gate_fill = (gate != 0) ? 1 : 0;
    dut->fix_re    = fixre ? 1 : 0;
    printf("  DUT fix_re driven = %d\n", (int)dut->fix_re);
    dut->tr_on = trlvl;
    dut->dump_idx = 0;
    for (int i = 0; i < 8; i++) tick();
    dut->rst = 0;
    if (getenv("EXP_MULTIHOT")) {          // 独立模式：只跑多 hot 实验
        for (int i = 0; i < 200; i++) tick();
        exp_multihot();
        return 0;
    }
    for (int i = 0; i < 4; i++) tick();

    const unsigned BASE = 0x000F0000u;      // F000:0000

    // ---- 1) fill 1KB with byte@m = (m>>2)&0xFF  (rep stosb, ES=DS=F000) ----
    for (unsigned m = 0; m < 1024; m++) {
        if ((m & 0x3F) == 0) printf("  fill byte %4u  (cyc=%lld)\n", m, cyc);

        wr_byte(BASE + m, (m >> 2) & 0xFFu);
    }
    printf("  fill done (cyc=%lld)\n", cyc);

    // ---- 2) CONTROL: read offset 0x40 (still resident) ----
    unsigned ctrl = rd_byte(BASE + 0x40);
    unsigned ctrl_w = bus(BASE + 0x40, 0, 0);      // full 32-bit word
    unsigned ctrl_w2 = bus(BASE + 0x44, 0, 0);     // word 1 of line 1
    printf("  control read 0x40 = 0x%02X  full=0x%08X  w@0x44=0x%08X (cyc=%lld)\n",
           ctrl, ctrl_w, ctrl_w2, cyc);

    // ---- 3) scan256: bx = 0x4000 .. 0x40 step -0x40, read DS:[bx] ----
    long long before_scan = cyc;
    for (int bx = 0x4000; bx >= 0x40; bx -= 0x40) {
        dut->vga_ready = 1;
        if ((bx & 0x7FF) == 0) printf("  scan bx=%04x (cyc=%lld)\n", bx, cyc);
        (void)rd_byte(BASE + (unsigned)bx);
    }
    long long scan_cycles = cyc - before_scan;
    printf("  scan256 done (cyc=%lld)\n", cyc);

    // ---- 4) MEASURE: read offset 0x80 (line 2, must be refilled from DDR) ----
    unsigned meas = rd_byte(BASE + 0x80);
    // the real BIOS reports right after this read (out dx,ax to 0x00E4/0x00E5) -> freeze here
    dut->snap_now = 1; tick(); tick(); dut->snap_now = 0;
    unsigned meas_w = bus(BASE + 0x80, 0, 0);
    printf("  measure read 0x80 = 0x%02X  full=0x%08X\n", meas, meas_w);

    // ---- 5) also read offset 0x140 (line 5) for reference ----
    unsigned ref5 = rd_byte(BASE + 0x140);
    unsigned ref1 = rd_byte(BASE + 0x40);

    printf("\n================ stage-2b result ================\n");
    printf("CONTROL  offset 0x40  = 0x%02X   expect 0x10\n", ctrl);
    printf("MEASURE  offset 0x80  = 0x%02X   expect 0x20 (0x50 => line+3, 0x00/0xFF => lost)\n", meas);
    printf("ref      offset 0x40  = 0x%02X   expect 0x10\n", ref1);
    printf("ref      offset 0x140 = 0x%02X   expect 0x50\n", ref5);
    printf("line-2 fills = %u , line-2 write-backs = %u , fill_foreign = %u\n",
           (unsigned)dut->o_l2_fill_n, (unsigned)dut->o_l2_wb_n,
           (unsigned)dut->o_fill_foreign_n);
    printf("AXI bursts: AW=%u (spurious=%u)   AR(cmd=11)=%u (spurious=%u)\n",
           (unsigned)dut->o_aw_n, (unsigned)dut->o_spur_aw,
           (unsigned)dut->o_ar11_n, (unsigned)dut->o_spur_ar11);
    printf("ack-edge spurious bursts (the board probe):  WB=%u   RD=%u\n",
           (unsigned)dut->o_spur_ack_wb, (unsigned)dut->o_spur_ack_rd);
    printf("per-frame flush pulses seen: %u\n", (unsigned)dut->o_flush_n);
    printf("v4 data probe: write-back={idx=%02x nib=%x}   fill={idx=%02x nib=%x}   (nib must equal idx&0xF)\n",
           ((unsigned)dut->o_v4_rd >> 4) & 0x1F, (unsigned)dut->o_v4_rd & 0xF,
           ((unsigned)dut->o_v4_wb >> 4) & 0x1F, (unsigned)dut->o_v4_wb & 0xF);
    printf("v5 fill integrity (line 2, frozen at the report point): w0=%04x (exp 2020)  wl=%04x (exp 2F2F)\n",
           (unsigned)dut->o_fill_w0, (unsigned)dut->o_fill_wl);
    printf("   own-burst valids n=%u (exp 32; 64 = served twice)   foreign valids x=%u   own burst full=%u\n",
           (unsigned)dut->o_fill_n, (unsigned)dut->o_fill_x, (unsigned)dut->o_fill_full);
    printf("v6 write-back (line 2): last word wl=%04x (exp 2F2F)\n", (unsigned)dut->o_wb_wl);
    printf("   page the FSM used: fill=%03x  wb=%03x   (expect 015 = buffer; 006 would be VRAM)\n",
           (unsigned)dut->o_fill_page, (unsigned)dut->o_wb_page);
    printf("   stale-page acks (used != implied by hiaddr): fill pmis_r=%u  wb pmis_w=%u  (expect 0/0)\n",
           (unsigned)dut->o_pmis_r, (unsigned)dut->o_pmis_w);
    printf("v7 full line addr the FSM used: fill=%03x (exp 002)  wb=%03x (exp 002)\n",
           (unsigned)dut->o_fill_addr, (unsigned)dut->o_wb_addr);
    printf("VGA sweep: bursts=%u  last row-col base=%05x   s_prog_empty cycles=%u  s_prog_full cycles=%u\n",
           (unsigned)dut->o_vga_burst_n, (unsigned)dut->o_vga_rowcol_last,
           (unsigned)dut->o_pe_n, (unsigned)dut->o_pf_n);
    printf("board-latch equivalents: buf_rd_first=%03x  buf_wb_first=%03x  buf_wb_last=%04x  buf_wb_n=%02x\n",
           (unsigned)dut->o_buf_rd_first, (unsigned)dut->o_buf_wb_first,
           (unsigned)dut->o_buf_wb_last, (unsigned)dut->o_buf_wb_n);
    printf("scan256 took %lld cycles, total %lld\n", scan_cycles, cyc);
    printf("FLOW  FifoStart=%u @cyc=%u  lvl=%u  lvl min/max=%u/%u  s_prog_empty hi/lo=%u/%u  underruns=%u\n",
           (unsigned)dut->o_fstart, (unsigned)dut->o_fstart_cyc, (unsigned)dut->o_lvl,
           (unsigned)dut->o_lvl_min, (unsigned)dut->o_lvl_max,
           (unsigned)dut->o_pe_hi, (unsigned)dut->o_pe_lo, (unsigned)dut->o_underr_n);

    // ---- 6) what is actually in DDR for the buffer (physical 0x0815_0000) ----
    //      word 0 of buffer line k must be (k*16)&0xFF repeated 4x
    const unsigned MEMB = (0x08150000u - 0x08000000u) >> 2;   // model index (base-relative)
    printf("\n---- DDR contents, physical 0x08150000 (buffer) ---- MEMB=%u\n", MEMB);
    {
        unsigned w = dump_word(MEMB);
        printf("  probe: dump_word(MEMB) = %08X\n", w);
    }
    printf("line : word0      word5      (expect word0=(k*16)&FF x4, word5=(k*16+5)&FF x4)\n");
    int bad = 0;
    for (unsigned k = 0; k < 16; k++) {
        unsigned w0 = dump_word(MEMB + k * 16);
        unsigned w5 = dump_word(MEMB + k * 16 + 5);
        unsigned e0 = ((k * 16) & 0xFFu) * 0x01010101u;
        unsigned e5 = (((k * 16) + 5) & 0xFFu) * 0x01010101u;
        printf(" %2u  : %08X  %08X   %s\n", k, w0, w5,
               (w0 == e0 && w5 == e5) ? "ok" : "**MISMATCH**");
        if (w0 != e0 || w5 != e5) bad++;
    }
    printf("buffer lines mismatching in DDR: %d / 16\n", bad);

    // ---- 5b) THE REAL ACCEPTANCE TEST: after scan256 the whole 8 KB window has been
    //      evicted, so every buffer line must be refilled from DDR.  Read back ALL 1024
    //      bytes of the 1 KB buffer and compare against byte@m == (m>>2)&0xFF.
    //      This IS what the board self test does, and unlike the single 0x80 probe it is
    //      discriminating: the "word0 repeated" corruption leaves byte 0x80 == 0x20 (which
    //      looks correct!) but makes 0x81..0xBF read 0x20 instead of 0x21..0x2F.
    {
        int bad = 0, shown = 0;
        unsigned first_bad = 0, first_got = 0, first_exp = 0;
        for (unsigned m = 0; m < 1024; m++) {
            unsigned got = rd_byte(BASE + m);
            unsigned exp = (m >> 2) & 0xFFu;
            if (got != exp) {
                if (bad == 0) { first_bad = m; first_got = got; first_exp = exp; }
                bad++;
                if (shown < 8) {
                    printf("    byte 0x%03X = 0x%02X  expect 0x%02X\n", m, got, exp);
                    shown++;
                }
            }
        }
        printf("\n---- 1 KB read-back AFTER scan256 (all 1024 bytes) ----\n");
        printf("mismatched bytes: %d / 1024", bad);
        if (bad) printf("   first at 0x%03X: got 0x%02X expect 0x%02X", first_bad, first_got, first_exp);
        printf("   %s\n", bad ? "**FAIL**" : "PASS");
    }

    printf("\n---- DDR line 2 (offset 0x80..0xBF) word by word ----\n");
    for (int i = 0; i < 16; i++) {
        unsigned w = dump_word(MEMB + 2 * 16 + i);
        unsigned e = ((0x20 + i) & 0xFFu) * 0x01010101u;
        printf("  w%02d = %08X  expect %08X %s\n", i, w, e, w == e ? "" : "<--");
    }
    printf("\n---- DDR line 5 (offset 0x140..0x17F) word by word ----\n");
    for (int i = 0; i < 16; i++) {
        unsigned w = dump_word(MEMB + 5 * 16 + i);
        unsigned e = ((0x50 + i) & 0xFFu) * 0x01010101u;
        printf("  w%02d = %08X  expect %08X %s\n", i, w, e, w == e ? "" : "<--");
    }
    printf("================================================\n");

    dut->final();
    delete dut;
    return 0;
}
