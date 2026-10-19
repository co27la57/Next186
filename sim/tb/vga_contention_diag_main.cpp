// Closed-loop mode-13h arbitration diagnostics. Testbench only.
// Reuse the corrected 480-visible-line raster and sole-queue occupancy model.
// This is NOT an XPM model: no Gray-pointer/count CDC latency, std dout
// pipeline, reset busy or metastability. ddr_pipe also has an always-ready
// AXI slave and runs the AXI FSM on clk_sdr. Results separate logical
// contention/phase drift from starvation under these explicit assumptions.
//
// Build from imports/ using the existing Python runtime. Set writable caches:
// $env:ZIG_GLOBAL_CACHE_DIR = "$PWD/sim/run/opl3_led/zig-global"
// $env:ZIG_LOCAL_CACHE_DIR = "$PWD/sim/run/opl3_led/zig-local"
// Then pass the following Python code to that interpreter's -c argument:
// import sys; sys.path.insert(0,'sim'); import build
// original=build.run
// build.run=lambda cmd,**kw: original(cmd+['-GVGA_BASE_PARAM=32768','-GVGA_REPLN_PARAM=1'] if '--cc' in cmd else cmd,**kw)
// sys.argv=['build.py','--top','ddr_pipe','--out','sim/run/vga_contention_diag','--extra=--bbox-unsup','sim/tb/ddr_pipe.v','cache_controller.v','Next186_BlackBoxes.v','sim/tb/vga_contention_diag_main.cpp']
// build.main()
// Interpreter: C:/Users/Administrator/.workbuddy-ai/binaries/python/envs/default/Scripts/python.exe
// Runs (optional cycle count, followed by load 0..4; default all loads):
// & sim/run/vga_contention_diag/ddr_pipe.exe 4200000
// & sim/run/vga_contention_diag/ddr_pipe.exe 8400000 3
// The latter exposes a missing row reset in frame 5 and a source jump in
// frame 6 without transport faults, for both tested 25/50 MHz phases.
#define main original_closedloop_main
#include "vga_graph_closedloop_main.cpp"
#undef main
#include <algorithm>
#include <set>

struct Audit {
    unsigned min_level = 1024, max_level = 0, steady_min = 1024;
    uint64_t bad_data = 0, checked_data = 0;
    uint64_t longest_visible_write_gap = 0, write_gap = 0;
    uint64_t actual_row_reset = 0;
    uint32_t prior_rowcol = 0;
    std::set<uint32_t> steady_sources;
};

static unsigned diag_errors = 0;

static void diagnostic_case(const char* name, uint64_t clocks,
                            unsigned phase, unsigned load) {
    auto* dut = new Vddr_pipe;
    ExactDisplay display;
    Audit audit;
    uint64_t cycle = 0;
    prev_ack = 0;
    accepted_since_ack = 0;
    cpu_injector = CpuInjector{};
    cpu_injector.enabled = load != 0;
    cpu_idle_cycles = load == 1 ? 120 : 2;
    cpu_write_mode = load >= 3;
    cpu_thrash_mode = load >= 3;
    use_display_reset = true;
    use_fix_re = use_fix_96 = use_fix_97 = true;
    dut->clk_cpu = dut->clk_sdr = 0;
    dut->rst = 1;
    dut->cpu_mreq = dut->cpu_addr = dut->cpu_din = dut->cpu_wmask = 0;
    dut->vga_starving = 0;
    dut->vga_ready = 1;
    dut->frame_period = dut->vblnk_len = dut->fifo_drain = 0;
    dut->display_extra = 8;
    dut->model_vcount_valid = 1;
    dut->model_vcount = 0;
    dut->vga_lnend_cfg = 11;
    dut->vga_stride = 80;
    dut->vga_lcr = 1023;
    dut->inject_fill_shift = 0;
    dut->fix_re = dut->fix_96 = dut->fix_97 = dut->gate_fill = 1;
    dut->fix_100 = dut->snap_now = dut->tr_on = dut->dump_idx = 0;

    std::printf("\nCASE %s phase=%u clocks=%llu\n", name, phase,
                static_cast<unsigned long long>(clocks));
    for (unsigned i = 0; i < 8; ++i) tick_sdr(dut, cycle, display, phase);
    dut->rst = 0;
    audit.prior_rowcol = dut->o_vga_row_col;
    for (uint64_t i = 0; i < clocks; ++i) {
        // Complete an in-flight CPU request across a load transition, then
        // start/stop new traffic once per physical raster frame period.
        if (load == 4) cpu_injector.enabled = ((i / 833600u) & 1u) != 0;
        const size_t old_frames = display.frames.size();
        const uint64_t old_writes = display.write_count;
        const unsigned prior_lnb = dut->o_vga_lnb;
        tick_sdr(dut, cycle, display, phase);
        const unsigned level = static_cast<unsigned>(display.halves.size());
        if (display.fstart) {
            audit.min_level = std::min(audit.min_level, level);
            audit.max_level = std::max(audit.max_level, level);
            if (display.frame_count >= 2) audit.steady_min = std::min(audit.steady_min, level);
        }
        if (display.write_count != old_writes && !display.halves.empty()) {
            const auto& h = display.halves.back();
            const uint32_t word = 0xdead0000u + ((h.source - 0x08000000u) >> 2);
            const uint16_t expected = static_cast<uint16_t>(word >> ((h.source & 2u) ? 16 : 0));
            ++audit.checked_data;
            if (h.data != expected) {
                if (audit.bad_data < 4)
                    std::printf("DATA_BAD cycle=%llu addr=%08x got=%04x expected=%04x\n",
                                static_cast<unsigned long long>(cycle), h.source, h.data, expected);
                ++audit.bad_data;
            }
        }
        if (display.fstart && !display.hblnk && !display.vblnk && display.write_count == old_writes) {
            ++audit.write_gap;
            audit.longest_visible_write_gap = std::max(audit.longest_visible_write_gap, audit.write_gap);
        } else audit.write_gap = 0;
        if (dut->o_vga_row_col < audit.prior_rowcol) {
            ++audit.actual_row_reset;
            if (audit.actual_row_reset <= 8)
                std::printf("ROW_RESET cycle=%llu v=%u h=%u fifo=%u rowcol=%05x->%05x lnb=%u cpu=%u\n",
                            static_cast<unsigned long long>(cycle), display.vcount, display.hcount,
                            level, audit.prior_rowcol, dut->o_vga_row_col, dut->o_vga_lnb,
                            unsigned(cpu_injector.enabled));
        }
        if (prior_lnb != 0 && dut->o_vga_lnb == 0 && display.vcount <= 1 && display.frame_count > 1)
            std::printf("FETCH_LINE_END frame=%llu cycle=%llu sampled_v=%u display_v=%u h=%u "
                        "fifo=%u rowcol=%05x->%05x previous_lnb=%u\n",
                        static_cast<unsigned long long>(display.frame_count - 1),
                        static_cast<unsigned long long>(cycle), dut->model_vcount, display.vcount,
                        display.hcount, level, audit.prior_rowcol, dut->o_vga_row_col, prior_lnb);
        audit.prior_rowcol = dut->o_vga_row_col;
        if (display.frames.size() != old_frames) {
            const auto& f = display.frames.back();
            if (old_frames != 0) audit.steady_sources.insert(f.source);
            std::printf("FRAME n=%zu cycle=%llu source=%08x fifo=%u rowcol=%05x lnb=%u low=%04x cpu=%u\n",
                        old_frames, static_cast<unsigned long long>(f.cycle), f.source,
                        f.fifo_half, dut->o_vga_row_col, dut->o_vga_lnb, f.low,
                        unsigned(cpu_injector.enabled));
        }
    }
    const bool conserved = display.write_count == 2 * display.display_words + display.halves.size();
    const bool complete_width = display.vga_accept_min == 16 && display.vga_accept_max == 16;
    const bool pass = conserved && complete_width && display.underflow == 0 && display.dropped == 0 &&
                      display.ar_within_line_bad_n == 0 && audit.bad_data == 0 && cpu_injector.aborted == 0;
    if (!pass) ++diag_errors;
    std::printf("SUMMARY %s phase=%u transport_ok=%u ack=%llu halfwords_per_burst=%llu..%llu "
                "underflow=%llu dropped=%llu fifo=%u..%u steady_min=%u final=%zu "
                "visible_write_gap=%llu data_checked=%llu bad_data=%llu "
                "within_line_addr_bad=%llu conserved=%u steady_frame_sources=%zu "
                "cpu_complete=%llu cpu_miss=%llu cpu_write=%llu cpu_abort=%llu "
                "axi_fill=%u axi_wb=%u spur_fill=%u spur_wb=%u\n",
                name, phase, unsigned(pass), static_cast<unsigned long long>(display.vga_ack_count),
                static_cast<unsigned long long>(display.vga_accept_min), static_cast<unsigned long long>(display.vga_accept_max),
                static_cast<unsigned long long>(display.underflow), static_cast<unsigned long long>(display.dropped),
                audit.min_level, audit.max_level, audit.steady_min, display.halves.size(),
                static_cast<unsigned long long>(audit.longest_visible_write_gap),
                static_cast<unsigned long long>(audit.checked_data), static_cast<unsigned long long>(audit.bad_data),
                static_cast<unsigned long long>(display.ar_within_line_bad_n), unsigned(conserved), audit.steady_sources.size(),
                static_cast<unsigned long long>(cpu_injector.completed), static_cast<unsigned long long>(cpu_injector.misses),
                static_cast<unsigned long long>(cpu_injector.writes), static_cast<unsigned long long>(cpu_injector.aborted),
                dut->o_ar11_n, dut->o_aw_n, dut->o_spur_ar11, dut->o_spur_aw);
    dut->final();
    delete dut;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const uint64_t clocks = argc > 1 ? std::strtoull(argv[1], nullptr, 0) : 4200000;
    const int selected_load = argc > 2 ? std::atoi(argv[2]) : -1;
    const char* names[] = {"baseline", "read_gap120", "read_gap2", "rw_thrash_gap2", "rw_toggle_per_frame"};
    for (unsigned phase = 0; phase < 2; ++phase) {
        for (unsigned load = 0; load < 5; ++load)
            if (selected_load < 0 || selected_load == static_cast<int>(load))
                diagnostic_case(names[load], clocks, phase, load);
    }
    std::printf("RESULT failures=%u; ideal synchronous AXI + sole queue; no XPM CDC/data-output model\n", diag_errors);
    return diag_errors ? 1 : 0;
}
