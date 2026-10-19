// Exact display-side phase observer for the ddr_pipe flow model.
//
// ddr_pipe models the DDR command path and exports each accepted VGA halfword.
// This harness deliberately ignores its fixed-rate FIFO drain observer and
// replays those halfwords through a 16-bit-write/32-bit-read FIFO driven by a
// faithful copy of VGA_SG + ddr_186's vrden/exline equations.  It is still a
// testbench-only model: no functional RTL is changed.

#include "Vddr_pipe.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <vector>

struct FrameSample {
    uint64_t cycle;
    unsigned vcount;
    unsigned hcount;
    unsigned fifo_half;
    bool valid;
    uint16_t low;
    int rel;
};

struct ExactDisplay {
    // VGA_SG state (clk_25 domain).
    unsigned hcount = 0;
    unsigned vcount = 0;
    bool hblnk = false;
    bool vblnk = false;
    // ddr_186 display pipeline.
    uint32_t s_displ_on = 0; // only bits [18:0] are used
    unsigned exline = 0;
    bool fstart = false;
    // 16-bit write / 32-bit read FIFO.  Values are low-to-high halfwords.
    std::deque<uint16_t> halves;
    uint64_t display_words = 0;
    uint64_t underflow = 0;
    uint64_t rd_count = 0;
    uint64_t write_count = 0;
    uint64_t vga_ack_count = 0;
    uint64_t vga_accept_count = 0;
    uint64_t vga_accept_min = UINT64_MAX;
    uint64_t vga_accept_max = 0;
    uint64_t ar_delta_min = UINT64_MAX;
    uint64_t ar_delta_max = 0;
    uint64_t ar_line_start_n = 0;
    uint64_t ar_within_line_bad_n = 0;
    uint64_t ar_anomaly_printed = 0;
    uint64_t rowcol_drop_n = 0;
    uint64_t rowcol_drop_printed = 0;
    uint32_t prev_rowcol = 0;
    bool have_prev_rowcol = false;
    uint32_t prev_vga_ar = 0;
    bool have_prev_vga_ar = false;
    uint64_t frame_count = 0;
    int frame_seen_v = -1;
    std::vector<FrameSample> frames;

    static unsigned hpan(unsigned h) {
        // hcount_pan = hcount + hrzpan - 17, with a 10-bit wire.
        return (h + 1024u - 17u) & 1023u;
    }

    void write_half(uint16_t x) {
        // Real FIFO has 1024 16-bit write words.  ddr_pipe's occupancy model
        // already prevents sustained overflow; keep the same bounded behavior
        // here so a diagnostic run cannot grow without limit.
        if (halves.size() < 1024u)
            halves.push_back(x);
        ++write_count;
    }

    void clk25_edge(uint64_t sdr_cycle) {
        // All RHS below are pre-edge values, matching Verilog NBA semantics.
        const bool displ_on = !(hblnk || vblnk || !fstart);
        const unsigned pipe_index = 15; // ~vga_hrzpan, hrzpan=0 => 4'hf
        const bool vrdon = ((s_displ_on >> pipe_index) & 1u) != 0;
        const unsigned hp = hpan(hcount);
        // Text mode, full-height character rows: &hcount_pan[3:0].
        const bool cadence = (hp & 0x0fu) == 0x0fu;
        const bool vrden = (vrdon || ((exline >> 3) & 1u)) && cadence;

        if (!fstart && halves.size() >= 64u)
            fstart = true;

        // The FIFO read request is sampled on this clk_25 edge.  XPM's
        // asymmetric FIFO presents the first halfword in the low 16 bits and
        // the next halfword in the high 16 bits.
        if (vrden) {
            ++rd_count;
            FrameSample sample{};
            sample.cycle = sdr_cycle;
            sample.vcount = vcount;
            sample.hcount = hcount;
            sample.fifo_half = static_cast<unsigned>(halves.size());
            sample.valid = halves.size() >= 2u;
            if (sample.valid) {
                sample.low = halves.front();
                halves.pop_front();
                const uint16_t high = halves.front();
                halves.pop_front();
                // The synthetic DDR contents are 0xDEAD0000 + word index.
                sample.rel = static_cast<int16_t>(sample.low - uint16_t(0xE000));
                ++display_words;
            } else {
                ++underflow;
                sample.low = 0;
                sample.rel = 0;
            }

            // Capture the first read in every vcount==0 interval.  vcount==0
            // lasts one complete raster line, so guard against repeated reads.
            if (vcount == 0 && frame_seen_v != 0) {
                frame_seen_v = 0;
                ++frame_count;
                frames.push_back(sample);
            }
        }

        // ddr_186's exline and display-on shift register.
        const unsigned exline_next = vrdon ? 0xFu : ((exline - (vrden ? 1u : 0u)) & 0xFu);
        s_displ_on = ((s_displ_on & ((1u << 18) - 1u)) << 1) | (displ_on ? 1u : 0u);
        exline = exline_next;

        // VGA_SG horizontal and vertical counters.  ce is FifoStart; before
        // FifoStart they remain at their initialized zero values.
        if (fstart) {
            const unsigned old_h = hcount;
            if (hcount >= 799u) {
                hcount = 0;
                hblnk = false;
            } else {
                hcount = hcount + 1u;
                hblnk = (old_h >= 639u);
            }
            if (old_h == 799u) {
                if (vcount >= 520u) {
                    vcount = 0;
                    vblnk = false;
                    frame_seen_v = -1;
                } else {
                    vcount = vcount + 1u;
                    vblnk = (vcount >= 479u);
                    frame_seen_v = static_cast<int>(vcount);
                }
            }
        }
    }
};

static uint8_t prev_ack = 0;
static uint64_t accepted_since_ack = 0;
static bool use_display_reset = true;

static void observe_vga_transaction(Vddr_pipe* dut, ExactDisplay& display) {
    if (dut->o_vga_fifo_wr)
        ++accepted_since_ack;

    const uint8_t ack = static_cast<uint8_t>(dut->o_ack);
    if (ack != 0 && prev_ack == 0 && ack == 2) {
        const bool have_completed_transaction = display.vga_ack_count != 0;
        ++display.vga_ack_count;
        // The first ACK is the startup request and has no preceding return
        // burst.  Exclude that zero from the transaction-width statistics.
        if (have_completed_transaction) {
            if (accepted_since_ack < display.vga_accept_min)
                display.vga_accept_min = accepted_since_ack;
            if (accepted_since_ack > display.vga_accept_max)
                display.vga_accept_max = accepted_since_ack;
        }
        // The counter above belongs to the preceding transaction because the
        // registered observer pulse is sampled after the edge.  Start the
        // next transaction's count here; the first pulse is counted on a
        // later edge.
        accepted_since_ack = 0;

        const uint32_t ar = dut->o_axi_araddr;
        const uint32_t rowcol = dut->o_vga_row_col;
        if (display.have_prev_vga_ar && display.have_prev_rowcol && rowcol < display.prev_rowcol) {
            ++display.rowcol_drop_n;
            if (display.rowcol_drop_printed < 8) {
                std::printf("  rowcol drop #%llu ack=%llu 0x%05x->0x%05x "
                            "lnb=%u vcount=%u\n",
                            (unsigned long long)(display.rowcol_drop_printed + 1),
                            (unsigned long long)display.vga_ack_count,
                            unsigned(display.prev_rowcol), unsigned(rowcol),
                            unsigned(dut->o_vga_lnb), display.vcount);
                ++display.rowcol_drop_printed;
            }
        }
        display.prev_rowcol = rowcol;
        display.have_prev_rowcol = true;
        if (display.have_prev_vga_ar) {
            const uint64_t delta = (ar >= display.prev_vga_ar)
                ? uint64_t(ar - display.prev_vga_ar) : 0;
            if (delta < display.ar_delta_min)
                display.ar_delta_min = delta;
            if (delta > display.ar_delta_max)
                display.ar_delta_max = delta;
            // lnb==0 is a legitimate line boundary: the address jumps back
            // to the row start (or forward to the next character row).  Only
            // nonzero lnb samples are expected to advance by 0x20 bytes.
            if (dut->o_vga_lnb == 0)
                ++display.ar_line_start_n;
            else if (delta != 0x20) {
                ++display.ar_within_line_bad_n;
                if (display.ar_anomaly_printed < 8) {
                    std::printf("  AR anomaly #%llu ack=%llu delta=0x%llx ar=0x%08x "
                                "rowcol=0x%05x lnb=%u vcount=%u\n",
                                (unsigned long long)(display.ar_anomaly_printed + 1),
                                (unsigned long long)display.vga_ack_count,
                                (unsigned long long)delta, unsigned(ar),
                                unsigned(dut->o_vga_row_col),
                                unsigned(dut->o_vga_lnb), display.vcount);
                    ++display.ar_anomaly_printed;
                }
            }
        }
        display.prev_vga_ar = ar;
        display.have_prev_vga_ar = true;
    }
    prev_ack = ack;
}

static void tick_sdr(Vddr_pipe* dut, uint64_t& cycle, ExactDisplay& display,
                     unsigned phase) {
    // ddr_186 samples vcount in the clk_sdr-side row-sequence logic.  Drive
    // the testbench copy before the rising edge so the model exercises that
    // same frame-start condition instead of falling back to fetch-side EOF.
    dut->model_vcount_valid = use_display_reset ? 1 : 0;
    dut->model_vcount = display.vcount;
    dut->clk_sdr = 0;
    dut->eval();
    dut->clk_sdr = 1;
    dut->eval();

    // Accepted halfwords are written at the clk_sdr edge.  Capture after the
    // edge, exactly as the previous FIFO harness did.
    if (dut->o_vga_fifo_wr)
        display.write_half(dut->o_vga_fifo_wr_data);
    observe_vga_transaction(dut, display);

    // The DCM relationship is 50 MHz : 25 MHz.  Run the display edge on one
    // of the two possible relative phases; both are tested by the caller.
    if ((cycle & 1u) == phase)
        display.clk25_edge(cycle);

    dut->clk_sdr = 0;
    dut->eval();
    ++cycle;
}

static void run_case(const char* name, unsigned burst_variant,
                     unsigned phase, uint64_t cycles) {
    auto* dut = new Vddr_pipe;
    ExactDisplay display;
    uint64_t cycle = 0;
    prev_ack = 0;
    accepted_since_ack = 0;

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
    // Keep ddr_pipe's command scheduler active.  Its internal fixed-drain
    // occupancy is only used to choose DDR commands; display reads below are
    // driven by the faithful VGA model and are independently observed.
    dut->fifo_drain = 32;
    dut->model_vcount_valid = use_display_reset ? 1 : 0;
    dut->model_vcount = 0;
    dut->vga_lnend_cfg = 6;
    dut->vga_stride = 40;
    // BIOS programs the 10-bit line-compare register to 0x3ff for the
    // 640x480 mode; row_count (0..479) therefore does not take this wrap
    // branch during a frame.  The earlier 400 default was a stale bench
    // convenience value and creates a false mid-frame reset.
    dut->vga_lcr = 1023;
    dut->inject_fill_shift = 0;
    dut->fix_96 = 0;
    dut->fix_97 = 0;
    dut->fix_100 = burst_variant;
    dut->snap_now = 0;
    dut->gate_fill = 1;
    dut->fix_re = 0;
    dut->tr_on = 0;
    dut->dump_idx = 0;

    for (unsigned i = 0; i < 8; ++i)
        tick_sdr(dut, cycle, display, phase);
    dut->rst = 0;

    for (uint64_t i = 0; i < cycles; ++i)
        tick_sdr(dut, cycle, display, phase);

    std::printf("\n=== %s (clk25 phase=%u) ===\n", name, phase);
    std::printf("sdr=%llu writes_fifo=%zu display_words=%llu reads=%llu frames=%llu underflow=%llu level=%u\n",
                (unsigned long long)cycle, display.halves.size(),
                (unsigned long long)display.display_words,
                (unsigned long long)display.rd_count,
                (unsigned long long)display.frame_count,
                (unsigned long long)display.underflow,
                unsigned(display.halves.size()));
    std::printf("ddr_pipe flow: FifoStart=%u level=%u min/max=%u/%u underruns=%u\n",
                unsigned(dut->o_fstart), unsigned(dut->o_lvl),
                unsigned(dut->o_lvl_min), unsigned(dut->o_lvl_max),
                unsigned(dut->o_underr_n));
    std::printf("fetch: VGA bursts=%u rowcol=%05x lnb=%u col=%u last_rowcol=%05x writes=%llu\n",
                unsigned(dut->o_vga_burst_n), unsigned(dut->o_vga_row_col),
                unsigned(dut->o_vga_lnb), unsigned(dut->o_vga_col),
                unsigned(dut->o_vga_rowcol_last),
                (unsigned long long)display.write_count);
    std::printf("address audit: ack=%llu accepted/txn=%llu..%llu AR-delta=0x%llx..0x%llx\n",
                (unsigned long long)display.vga_ack_count,
                (unsigned long long)(display.vga_accept_min == UINT64_MAX ? 0 : display.vga_accept_min),
                (unsigned long long)display.vga_accept_max,
                (unsigned long long)(display.ar_delta_min == UINT64_MAX ? 0 : display.ar_delta_min),
                (unsigned long long)display.ar_delta_max);
    std::printf("address audit detail: line-start=%llu within-line-bad=%llu\n",
                (unsigned long long)display.ar_line_start_n,
                (unsigned long long)display.ar_within_line_bad_n);
    std::printf("rowcol drops: %llu\n", (unsigned long long)display.rowcol_drop_n);
    for (size_t i = 0; i < display.frames.size(); ++i) {
        const auto& f = display.frames[i];
        std::printf("  frame%zu @%llu v=%u h=%u fifo=%u %s low=%04x rel=%d\n",
                    i, (unsigned long long)f.cycle, f.vcount, f.hcount,
                    f.fifo_half, f.valid ? "OK" : "UNDERFLOW",
                    unsigned(f.low), f.rel);
    }

    dut->final();
    delete dut;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const uint64_t cycles = (argc > 1) ? std::strtoull(argv[1], nullptr, 0) : 1800000;
    if (argc > 2 && std::strcmp(argv[2], "fetch") == 0)
        use_display_reset = false;
    std::printf("row reset model: %s\n", use_display_reset ?
                "display vcount==0 (current RTL)" :
                "fetch vga_end_frame (control)");
    run_case("current: 16-beat AXI VGA burst", 0, 0, cycles);
    run_case("current: 16-beat AXI VGA burst", 0, 1, cycles);
    run_case("candidate: 8-beat AXI VGA burst", 2, 0, cycles);
    run_case("candidate: 8-beat AXI VGA burst", 2, 1, cycles);
    return 0;
}
