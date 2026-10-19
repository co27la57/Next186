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
static uint64_t cpu_idle_cycles = 120;
static bool cpu_write_mode = false;
static bool cpu_thrash_mode = false;

// Optional CPU-side cache traffic.  This is deliberately kept in the C++
// harness: ddr_pipe already exposes the real cache_controller ports, so no
// functional RTL is changed.  One CPU rising edge is generated for every two
// clk_sdr edges, matching the board's 25/50 MHz relationship.
struct CpuInjector {
    bool enabled = false;
    bool active = false;
    bool saw_low = false;
    unsigned edge_count = 0;
    uint64_t next_issue_cpu = 30;
    uint64_t issued = 0;
    uint64_t completed = 0;
    uint64_t misses = 0;
    uint64_t writes = 0;
    uint64_t aborted = 0;
    unsigned seq = 0;

    void begin_if_due(Vddr_pipe* dut, uint64_t sdr_cycle) {
        if (!enabled || active || (sdr_cycle & 1u) ||
            (sdr_cycle / 2u < next_issue_cpu))
            return;
        // Read a rotating set of cache lines.  The addresses are in the same
        // F000 segment used by the BIOS self-test, but each request walks a
        // different line to keep the cache/DDR arbiter busy.
        const unsigned n = seq++;
        const unsigned off = cpu_thrash_mode
            ? (((n / 2u) % 5u) * 0x800u)
            : ((n * 0x40u) & 0x3FC0u);
        dut->cpu_addr = 0x000F0000u + off;
        const bool wr = cpu_write_mode && (cpu_thrash_mode ? ((n & 1u) != 0) : ((n & 3u) == 1u));
        dut->cpu_din = 0xA5000000u | n;
        dut->cpu_wmask = wr ? 0xFu : 0u;
        if (wr)
            ++writes;
        dut->cpu_mreq = 1;
        active = true;
        saw_low = false;
        edge_count = 0;
        ++issued;
    }

    // Called immediately after the clk_cpu rising edge.  The cache's CE is
    // sampled with the request held, as in ddr_selftest_main.cpp.  Hits are
    // released after four CPU edges; misses are released on the first CE
    // recovery after it went low.
    void cpu_edge(Vddr_pipe* dut) {
        if (!active)
            return;
        ++edge_count;
        if (!dut->cpu_ce) {
            saw_low = true;
            if (edge_count > 4096) { // defensive bound for a wedged model
                dut->cpu_mreq = 0;
                active = false;
                next_issue_cpu += 8;
                ++aborted;
            }
            return;
        }
        if (saw_low) {
            ++misses;
            ++completed;
            dut->cpu_mreq = 0;
            active = false;
            next_issue_cpu = 0; // replaced below by the caller's current edge
        } else if (edge_count >= 4) {
            ++completed;
            dut->cpu_mreq = 0;
            active = false;
            next_issue_cpu = 0;
        }
    }

    void finish_edge(uint64_t sdr_cycle) {
        if (!enabled)
            return;
        // Keep a fixed idle gap after each completed transaction.  The value
        // is reset from zero above so this remains independent of request
        // latency and is easy to reproduce.
        if (!active && next_issue_cpu == 0)
            next_issue_cpu = sdr_cycle / 2u + cpu_idle_cycles;
    }
};

static CpuInjector cpu_injector;

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
    cpu_injector.begin_if_due(dut, cycle);
    dut->model_vcount_valid = use_display_reset ? 1 : 0;
    dut->model_vcount = display.vcount;
    // Generate the CPU clock before the SDR edge on every even cycle.  The
    // request was placed by begin_if_due() above and is held until CE recovers.
    dut->clk_cpu = ((cycle & 1u) == 0) ? 1 : 0;
    dut->clk_sdr = 0;
    dut->eval();
    if ((cycle & 1u) == 0)
        cpu_injector.cpu_edge(dut);
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
    dut->clk_cpu = 0;
    dut->eval();
    cpu_injector.finish_edge(cycle);
    ++cycle;
}

static void run_case(const char* name, unsigned burst_variant,
                     unsigned phase, uint64_t cycles, bool cpu_enabled) {
    auto* dut = new Vddr_pipe;
    ExactDisplay display;
    uint64_t cycle = 0;
    prev_ack = 0;
    accepted_since_ack = 0;
    cpu_injector = CpuInjector{};
    cpu_injector.enabled = cpu_enabled;

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
    std::printf("cpu injector: %s issued=%llu completed=%llu misses=%llu writes=%llu aborted=%llu active=%u\n",
                cpu_enabled ? "enabled" : "disabled",
                (unsigned long long)cpu_injector.issued,
                (unsigned long long)cpu_injector.completed,
                (unsigned long long)cpu_injector.misses,
                (unsigned long long)cpu_injector.writes,
                (unsigned long long)cpu_injector.aborted,
                unsigned(cpu_injector.active));
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
    std::printf("cache arbitration: fills=%u writebacks=%u foreign_fills=%u pe=%u pf=%u\n",
                unsigned(dut->o_l2_fill_n), unsigned(dut->o_l2_wb_n),
                unsigned(dut->o_fill_foreign_n), unsigned(dut->o_pe_n),
                unsigned(dut->o_pf_n));
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
    if (argc > 2 && std::strcmp(argv[2], "fetch") != 0)
        cpu_idle_cycles = std::strtoull(argv[2], nullptr, 0);
    if (cpu_idle_cycles < 2)
        cpu_idle_cycles = 2;
    if (argc > 3 && std::strcmp(argv[3], "write") == 0)
        cpu_write_mode = true;
    if (argc > 4 && std::strcmp(argv[4], "thrash") == 0)
        cpu_thrash_mode = true;
    std::printf("CPU idle gap after each request: %llu clk_cpu; mode=%s\n",
                (unsigned long long)cpu_idle_cycles,
                cpu_write_mode ? "read/write" : "read-only");
    if (cpu_thrash_mode)
        std::printf("CPU address pattern: five tags at one cache index (thrash)\n");
    std::printf("row reset model: %s\n", use_display_reset ?
                "display vcount==0 (current RTL)" :
                "fetch vga_end_frame (control)");
    // Baseline and CPU-contention pairs use the current 16-beat VGA path.
    // The display model is unchanged between each pair; only cache traffic
    // on ddr_pipe's real CPU ports is enabled.
    run_case("baseline: 16-beat, no CPU", 0, 0, cycles, false);
    run_case("contention: 16-beat, periodic CPU reads", 0, 0, cycles, true);
    run_case("baseline: 16-beat, no CPU (phase1)", 0, 1, cycles, false);
    run_case("contention: 16-beat, periodic CPU reads (phase1)", 0, 1, cycles, true);
    return 0;
}
