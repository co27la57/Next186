// Exact display-side phase observer for the ddr_pipe flow model, in mode 13h.
//
// ddr_pipe models the DDR command path and exports each accepted VGA halfword.
// This harness deliberately ignores its fixed-rate FIFO drain observer and
// replays those halfwords through a 16-bit-write/32-bit-read FIFO driven by a
// faithful copy of VGA_SG + ddr_186's vrden/exline equations.  It is still a
// testbench-only model: no functional RTL is changed.

#include "Vddr_pipe_async.h"
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
    uint32_t source;
};

struct Halfword { uint16_t data; uint32_t source; };

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
    std::deque<Halfword> halves;
    bool pe = false, pf = false;
    uint32_t burst_source = 0;
    unsigned burst_half = 0;
    uint64_t display_words = 0;
    uint64_t underflow = 0;
    uint64_t dropped = 0;
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

    bool write_half(uint16_t x) {
        // The external queue is the sole occupancy model in this closed-loop
        // bench.  Count rejected writes explicitly; silently dropping them
        // would make a no-underflow result meaningless.
        if (halves.size() >= 1024u) {
            ++dropped;
            return false;
        }
        halves.push_back({x, burst_source + 2u * burst_half++});
        ++write_count;
        return true;
    }

    void clk25_edge(uint64_t sdr_cycle) {
        // All RHS below are pre-edge values, matching Verilog NBA semantics.
        const bool displ_on = !(hblnk || vblnk || !fstart);
        const unsigned pipe_index = 15; // ~vga_hrzpan, hrzpan=0 => 4'hf
        const bool vrdon = ((s_displ_on >> pipe_index) & 1u) != 0;
        const unsigned hp = hpan(hcount);
        // Mode 13h consumes one 32-bit FIFO word every 8 dot clocks.
        const bool cadence = (hp & 0x07u) == 0x07u;
        const bool vrden = (vrdon || ((exline >> 3) & 1u)) && cadence;

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
                sample.low = halves.front().data;
                sample.source = halves.front().source;
                halves.pop_front();
                const uint16_t high = halves.front().data;
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
                    // VGA_SG compares the pre-edge vcount in this NBA.
                    vblnk = (vcount >= 479u);
                    vcount = vcount + 1u;
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
static bool use_fix_re = true;
static bool use_fix_96 = true;
static bool use_fix_97 = true;

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

    void begin_if_due(Vddr_pipe_async* dut, uint64_t sdr_cycle) {
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
    void cpu_edge(Vddr_pipe_async* dut) {
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

static void observe_vga_transaction(Vddr_pipe_async* dut, ExactDisplay& display) {
    if (dut->o_vga_fifo_wr)
        ++accepted_since_ack;

    const uint8_t ack = static_cast<uint8_t>(dut->o_ack);
    if (ack != 0 && prev_ack == 0 && ack == 2) {
        display.burst_source = dut->o_axi_araddr;
        display.burst_half = 0;
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

static unsigned axi_order_for(uint64_t cycle, unsigned mode) {
    if (mode == 0) return 1; // AXI clock first every cycle
    if (mode == 1) return 0; // SDR clock first every cycle
    if (mode == 2) {          // deterministic alternating phase
        return ((cycle ^ (cycle >> 3)) & 1u) == 0;
    }
    // A small deterministic pseudo-random order.  This is not a clock model;
    // it is a phase sweep that exercises both sides of every CDC boundary.
    uint32_t x = static_cast<uint32_t>(cycle) ^ 0x9e3779b9u;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return (x & 1u) != 0;
}

static void tick_async(Vddr_pipe_async* dut, uint64_t& cycle, ExactDisplay& display,
                       unsigned order_mode) {
    // ddr_186 samples vcount in the clk_sdr-side row-sequence logic.  Drive
    // the testbench copy before the SDR rising edge, while the AXI clock has
    // an independently selected phase relative to it.
    cpu_injector.begin_if_due(dut, cycle);
    dut->model_vcount_valid = use_display_reset ? 1 : 0;
    dut->model_vcount = display.vcount;
    dut->vga_starving = display.pe;
    dut->vga_ready = !display.pf;
    const bool next_pe = display.halves.size() < 64u;
    const bool next_pf = display.halves.size() > 350u;
    const bool next_fstart = display.fstart || display.halves.size() >= 64u;

    dut->clk_cpu = ((cycle & 1u) == 0) ? 1 : 0;
    dut->clk_sdr = 0;
    dut->clk_axi = 0;
    dut->eval();
    if ((cycle & 1u) == 0)
        cpu_injector.cpu_edge(dut);

    const bool axi_first = axi_order_for(cycle, order_mode) != 0;
    if (axi_first) {
        dut->clk_axi = 1;
        dut->eval();
        dut->clk_sdr = 1;
        dut->eval();
    } else {
        dut->clk_sdr = 1;
        dut->eval();
        dut->clk_axi = 1;
        dut->eval();
    }

    // The FIFO write observer is registered on clk_sdr.  Sampling after both
    // edges captures exactly the value visible to the core after this SDR edge.
    if (dut->o_vga_fifo_wr)
        display.write_half(dut->o_vga_fifo_wr_data);
    observe_vga_transaction(dut, display);

    // Keep the display-side phase fixed while sweeping the independent AXI/SDR
    // order.  The display still consumes one 32-bit word every eight dots.
    if ((cycle & 1u) == 0)
        display.clk25_edge(cycle);

    if (!dut->rst) {
        display.pe = next_pe;
        display.pf = next_pf;
        display.fstart = next_fstart;
    }

    dut->clk_sdr = 0;
    dut->clk_axi = 0;
    dut->eval();
    dut->clk_cpu = 0;
    dut->eval();
    cpu_injector.finish_edge(cycle);
    ++cycle;
}
static void run_case(const char* name, unsigned burst_variant,
                     unsigned order_mode, uint64_t cycles, bool cpu_enabled) {
    auto* dut = new Vddr_pipe_async;
    ExactDisplay display;
    uint64_t cycle = 0;
    prev_ack = 0;
    accepted_since_ack = 0;
    cpu_injector = CpuInjector{};
    cpu_injector.enabled = cpu_enabled;

    dut->clk_cpu = 0;
    dut->clk_sdr = 0;
    dut->clk_axi = 0;
    dut->rst = 1;
    dut->cpu_mreq = 0;
    dut->cpu_addr = 0;
    dut->cpu_din = 0;
    dut->cpu_wmask = 0;
    dut->vga_starving = 0;
    dut->vga_ready = 1;
    dut->frame_period = 0;
    dut->vblnk_len = 0;
    // Closed-loop mode: the C++ queue is the only occupancy model.  Feed its
    // thresholds back into the real command scheduler instead of running a
    // second fixed-rate FIFO that can silently diverge from the display.
    dut->fifo_drain = 0;
    dut->display_extra = 8;
    dut->model_vcount_valid = use_display_reset ? 1 : 0;
    dut->model_vcount = 0;
    dut->vga_lnend_cfg = 11;
    dut->vga_stride = 80;
    // BIOS programs the 10-bit line-compare register to 0x3ff for the
    // 640x480 mode; row_count (0..479) therefore does not take this wrap
    // branch during a frame.  The earlier 400 default was a stale bench
    // convenience value and creates a false mid-frame reset.
    dut->vga_lcr = 1023;
    dut->inject_fill_shift = 0;
    dut->fix_96 = use_fix_96;
    dut->fix_97 = use_fix_97;
    dut->fix_100 = burst_variant;
    dut->snap_now = 0;
    dut->gate_fill = 1;
    dut->fix_re = use_fix_re;
    dut->tr_on = 0;
    dut->dump_idx = 0;

    for (unsigned i = 0; i < 8; ++i)
        tick_async(dut, cycle, display, order_mode);
    dut->rst = 0;

    for (uint64_t i = 0; i < cycles; ++i)
        tick_async(dut, cycle, display, order_mode);

    std::printf("\n=== %s (axi-order-mode=%u) ===\n", name, order_mode);
    std::printf("cpu injector: %s issued=%llu completed=%llu misses=%llu writes=%llu aborted=%llu active=%u\n",
                cpu_enabled ? "enabled" : "disabled",
                (unsigned long long)cpu_injector.issued,
                (unsigned long long)cpu_injector.completed,
                (unsigned long long)cpu_injector.misses,
                (unsigned long long)cpu_injector.writes,
                (unsigned long long)cpu_injector.aborted,
                unsigned(cpu_injector.active));
    std::printf("sdr=%llu accepted_writes=%llu attempted_pulses=%llu dropped=%llu display_words=%llu reads=%llu frames=%llu underflow=%llu level=%u\n",
                (unsigned long long)cycle,
                (unsigned long long)display.write_count,
                (unsigned long long)(display.write_count + display.dropped),
                (unsigned long long)display.dropped,
                (unsigned long long)display.display_words,
                (unsigned long long)display.rd_count,
                (unsigned long long)display.frame_count,
                (unsigned long long)display.underflow,
                unsigned(display.halves.size()));
    std::printf("closed-loop queue: conservation=%s (accepted - 2*reads = %lld)\n",
                (static_cast<long long>(display.write_count) -
                 static_cast<long long>(2 * display.display_words) ==
                 static_cast<long long>(display.halves.size())) ? "OK" : "FAIL",
                static_cast<long long>(display.write_count) -
                 static_cast<long long>(2 * display.display_words) -
                 static_cast<long long>(display.halves.size()));
    std::printf("ddr_pipe flow observability (internal model disabled): FifoStart=%u level=%u min/max=%u/%u underruns=%u\n",
                unsigned(dut->o_fstart), unsigned(dut->o_lvl),
                unsigned(dut->o_lvl_min), unsigned(dut->o_lvl_max),
                unsigned(dut->o_underr_n));
    std::printf("cache arbitration: fills=%u writebacks=%u foreign_fills=%u pe=%u pf=%u\n",
                unsigned(dut->o_l2_fill_n), unsigned(dut->o_l2_wb_n),
                unsigned(dut->o_fill_foreign_n), unsigned(dut->o_pe_n),
                unsigned(dut->o_pf_n));
    std::printf("AXI totals: fill_bursts=%u wb_bursts=%u spur_fill=%u spur_wb=%u\n",
                unsigned(dut->o_ar11_n), unsigned(dut->o_aw_n),
                unsigned(dut->o_spur_ar11), unsigned(dut->o_spur_aw));
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
        std::printf("  frame%zu @%llu v=%u h=%u fifo=%u %s low=%04x source=%08x rel=%d\n",
                    i, (unsigned long long)f.cycle, f.vcount, f.hcount,
                    f.fifo_half, f.valid ? "OK" : "UNDERFLOW",
                    unsigned(f.low), f.source, f.rel);
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
    if (argc > 5 && std::strcmp(argv[5], "oldarb") == 0) {
        use_fix_re = false;
        use_fix_96 = false;
        use_fix_97 = false;
    }
    std::printf("mode: 13h graph\n");
    std::printf("CPU idle gap after each request: %llu clk_cpu; mode=%s\n",
                (unsigned long long)cpu_idle_cycles,
                cpu_write_mode ? "read/write" : "read-only");
    if (cpu_thrash_mode)
        std::printf("CPU address pattern: five tags at one cache index (thrash)\n");
    std::printf("arbiter fixes: 95=%u 96=%u 97=%u\n",
                unsigned(use_fix_re), unsigned(use_fix_96), unsigned(use_fix_97));
    std::printf("row reset model: %s\n", use_display_reset ?
                "display vcount==0 (current RTL)" :
                "fetch vga_end_frame (control)");
    // Baseline and CPU-contention pairs use the current 16-beat VGA path
    // with the mode-13h geometry above. The display model is unchanged
    // between each pair; only cache traffic on ddr_pipe's real CPU ports
    // is enabled.
    run_case("baseline: AXI-first, no CPU", 0, 0, cycles, false);
    run_case("contention: AXI-first, periodic CPU reads", 0, 0, cycles, true);
    run_case("baseline: SDR-first, no CPU", 0, 1, cycles, false);
    run_case("contention: SDR-first, periodic CPU reads", 0, 1, cycles, true);
    run_case("baseline: alternating CDC phase, no CPU", 0, 2, cycles, false);
    run_case("contention: alternating CDC phase, periodic CPU reads", 0, 2, cycles, true);
    run_case("baseline: pseudo-random CDC phase, no CPU", 0, 3, cycles, false);
    run_case("contention: pseudo-random CDC phase, periodic CPU reads", 0, 3, cycles, true);
    return 0;
}
