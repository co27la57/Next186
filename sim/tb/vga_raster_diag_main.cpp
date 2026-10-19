// Run from imports/:
// python sim/build.py --top vga_raster_diag --out sim/run/vga_raster_diag --run
//   sim/tb/vga_raster_diag.v sim/tb/vga_raster_diag_main.cpp vga.v Next186_BlackBoxes.v
// Checks production VGA_SG + production sr_font, with steady display mode.
// No DDR/FIFO/CPU model: this isolates raster geometry and glyph-row timing.
#include "Vvga_raster_diag.h"
#include "verilated.h"
#include <array>
#include <cstdio>
#include <cstdlib>

static unsigned failures = 0;
static void check(bool ok, const char* message) {
    if (!ok) { std::printf("FAIL %s\n", message); ++failures; }
}
static void tick(Vvga_raster_diag& d) {
    d.clk = 0; d.eval(); d.clk = 1; d.eval(); d.clk = 0; d.eval();
}
static void run_case(const char* label, bool text, bool mode13, bool half,
                     unsigned height, unsigned pan) {
    Vvga_raster_diag d;
    d.clk = 0; d.start = 0; d.text_mode = text; d.mode13 = mode13;
    d.half_mode = half; d.tall_mode = 1; d.vde = height - 1;
    d.hrzpan = pan; d.fifo_word = 0x0f410f41; d.eval();
    for (unsigned i = 0; i < 100; ++i) tick(d);
    check(d.hcount == 0 && d.vcount == 0, "raster remains stopped before FifoStart");
    d.start = 1;
    // Discard startup, then measure exactly one complete steady raster frame.
    for (unsigned i = 0; i < 800 * 521; ++i) tick(d);
    while (d.hcount != 0 || d.vcount != 0) tick(d);
    std::array<unsigned, 521> reads{}, pixels{}, active{};
    std::array<unsigned, 16> glyphs{};
    unsigned hs = 0, vs = 0, total_reads = 0;
    for (unsigned i = 0; i < 800 * 521; ++i) {
        const unsigned y = d.vcount;
        ++pixels[y];
        if (d.vrden) { ++reads[y]; ++total_reads; }
        if (d.sdon) ++active[y];
        if (d.hsync) ++hs;
        if (d.vsync) ++vs;
        if (d.hcount == 64 && y < 16) {
            check(d.char_ln == (half ? y % 8 : y), "font raster row is aligned with vcount");
            glyphs[y] = d.font_row;
        }
        tick(d);
    }
    check(d.hcount == 0 && d.vcount == 0, "frame is exactly 800 x 521 pixels");
    unsigned visible_lines = 0, read_lines = 0;
    const unsigned expected_reads = (text || half) ? 48 : mode13 ? 88 : 168;
    for (unsigned y = 0; y < 521; ++y) {
        check(pixels[y] == 800, "each raster line has 800 clocks");
        if (active[y]) { ++visible_lines; check(active[y] == 640, "each enabled output line has 640 pixels"); }
        if (reads[y]) ++read_lines;
        check(reads[y] == (y < 480 ? expected_reads : 0), "read cadence agrees with production raster blanking");
    }
    check(visible_lines == height, "vde gates the requested number of output lines");
    check(read_lines == 480, "FIFO consumes 480 lines even when vde hides the last 80");
    check(hs == 96 * 521 && vs == 2 * 800, "sync widths are 96 pixels and 2 lines");
    std::printf("%s pan=%u: raster=800x521 visible=%u read_lines=%u words/line=%u total_reads=%u\n",
                label, pan, visible_lines, read_lines, reads[0], total_reads);
    if (text) {
        std::printf("  glyph 'A', first 16 raster rows:");
        for (unsigned y = 0; y < 16; ++y) std::printf(" %02x", glyphs[y]);
        std::printf("\n");
    }
    d.final();
}
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    run_case("text 8x16, 400 output lines", true, false, false, 400, 0);
    run_case("text 8x16, 480 output lines", true, false, false, 480, 0);
    run_case("text 8x16, pan 1", true, false, false, 400, 1);
    run_case("text 8x8", true, false, true, 400, 0);
    run_case("mode 13h", false, true, false, 400, 0);
    std::printf("RESULT: %u errors; raster/font only, no DDR/FIFO behavior certified\n", failures);
    return failures ? 1 : 0;
}
