// Focused VGA FIFO phase harness.
//
// This drives the existing ddr_pipe command/AXI model with the real VGA
// geometry, reconstructs the 16-bit-write/32-bit-read FIFO from its accepted
// write pulses, and records the source word seen at each display scanline.
// It is intentionally a testbench-only observer: no RTL source is modified.

#include "Vddr_pipe.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <vector>

static Vddr_pipe* dut;
static uint64_t sdr_cycle = 0;
static uint64_t display_words = 0;
static std::deque<uint16_t> fifo_halves;

struct LineSample {
    uint64_t cycle;
    unsigned level_half;
    bool valid;
    uint16_t source_word_low;
    int relative_word;
    uint32_t word;
};

static std::vector<LineSample> lines;
static unsigned underflow = 0;

static void observe_after_sdr_edge() {
    if (dut->o_vga_fifo_wr)
        fifo_halves.push_back(dut->o_vga_fifo_wr_data);

    if (!dut->o_vga_fifo_rd)
        return;

    LineSample sample{};
    sample.cycle = sdr_cycle;
    sample.level_half = dut->o_vga_fifo_level;
    sample.valid = fifo_halves.size() >= 2;
    if (sample.valid) {
        const uint16_t lo = fifo_halves.front();
        fifo_halves.pop_front();
        const uint16_t hi = fifo_halves.front();
        fifo_halves.pop_front();
        sample.word = (uint32_t(hi) << 16) | lo;
        sample.source_word_low = lo;
        // The DDR model initializes word i as 0xDEAD0000+i.  The VGA text
        // window has low word index 0xE000, so this is the signed offset from
        // the text frame base, including the RTL's -8 compensation.
        sample.relative_word = int16_t(lo - uint16_t(0xE000));
    } else {
        ++underflow;
    }

    if ((display_words % 48u) == 0u)
        lines.push_back(sample);
    ++display_words;
}

static void tick_sdr() {
    dut->clk_sdr = 0;
    dut->eval();
    dut->clk_sdr = 1;
    dut->eval();
    observe_after_sdr_edge();
    dut->clk_sdr = 0;
    dut->eval();

    // Keep the CPU clock alive at the real 25/50 MHz ratio.  No CPU request is
    // driven in this harness; the clock is only needed for the copied wrapper.
    if ((sdr_cycle & 1u) == 1u) {
        dut->clk_cpu = 1;
        dut->eval();
        dut->clk_cpu = 0;
        dut->eval();
    }
    ++sdr_cycle;
}

static void run_case(const char* name, unsigned burst_variant, uint64_t cycles) {
    dut = new Vddr_pipe;
    fifo_halves.clear();
    lines.clear();
    underflow = 0;
    display_words = 0;
    sdr_cycle = 0;

    dut->clk_cpu = 0;
    dut->clk_sdr = 0;
    dut->rst = 1;
    dut->cpu_mreq = 0;
    dut->cpu_addr = 0;
    dut->cpu_din = 0;
    dut->cpu_wmask = 0;
    dut->vga_starving = 0;
    dut->vga_ready = 1;
    dut->frame_period = 0;
    dut->vblnk_len = 0;
    dut->fifo_drain = 32;      // one 32-bit display pop per 32 clk_sdr
    dut->display_extra = 8;     // ddr_186.exline: eight post-visible text pops
    dut->model_vcount_valid = 0;
    dut->model_vcount = 0;
    dut->vga_lnend_cfg = 6;    // text: 48 accepted 32-bit words per scanline
    dut->vga_stride = 40;
    // BIOS leaves the 10-bit line-compare register at 0x3ff in the 640x480
    // mode.  Using 400 here would create an artificial mid-frame row reset.
    dut->vga_lcr = 1023;
    dut->inject_fill_shift = 0;
    dut->fix_96 = 0;
    dut->fix_97 = 0;
    dut->fix_100 = burst_variant; // 0 = current 16-beat burst, 2 = 8-beat VGA burst
    dut->snap_now = 0;
    dut->gate_fill = 1;
    dut->fix_re = 0;
    dut->tr_on = 0;
    dut->dump_idx = 0;

    for (unsigned i = 0; i < 8; ++i)
        tick_sdr();
    dut->rst = 0;

    for (uint64_t i = 0; i < cycles; ++i)
        tick_sdr();

    std::printf("\n=== %s ===\n", name);
    std::printf("sdr cycles=%llu  display words=%llu  line samples=%zu\n",
                (unsigned long long)sdr_cycle,
                (unsigned long long)display_words, lines.size());
    std::printf("fifo level now=%u halfwords  min/max unavailable in wrapper  underrun=%u\n",
                unsigned(dut->o_vga_fifo_level), underflow);
    std::printf("wrapper flow: FifoStart=%u  level=%u  min/max=%u/%u  s_prog_empty=%u/%u  underruns=%u\n",
                unsigned(dut->o_fstart), unsigned(dut->o_lvl),
                unsigned(dut->o_lvl_min), unsigned(dut->o_lvl_max),
                unsigned(dut->o_pe_hi), unsigned(dut->o_pe_lo),
                unsigned(dut->o_underr_n));
    std::printf("first display line samples (line, fifo_half, word, src_rel):\n");
    const size_t limit = lines.size() < 24 ? lines.size() : 24;
    for (size_t i = 0; i < limit; ++i) {
        const auto& s = lines[i];
        if (s.valid)
            std::printf("  %3zu @%8llu  L=%3u  %08x  rel=%d\n",
                        i, (unsigned long long)s.cycle, s.level_half,
                        s.word, s.relative_word);
        else
            std::printf("  %3zu @%8llu  L=%3u  UNDERFLOW\n",
                        i, (unsigned long long)s.cycle, s.level_half);
    }
    if (lines.size() > 480) {
        std::printf("frame-start samples (line 480+):\n");
        for (size_t i = 480; i < lines.size() && i < 480 + 8; ++i) {
            const auto& s = lines[i];
            std::printf("  line %zu  L=%3u  %08x  rel=%d\n",
                        i, s.level_half, s.word, s.valid ? s.relative_word : 0);
        }
    }

    dut->final();
    delete dut;
    dut = nullptr;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const uint64_t cycles = (argc > 1) ? std::strtoull(argv[1], nullptr, 0) : 600000;
    run_case("current: 16-beat AXI VGA burst", 0, cycles);
    run_case("candidate: 8-beat AXI VGA burst", 2, cycles);
    return 0;
}

