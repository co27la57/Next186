"""Derive a text-mode closed-loop diagnostic from the existing graph bench.

Only generated files in sim/run/vga_text_phase are changed. No production RTL
or existing bench is modified. Run from imports/ with the bundled Python.
"""
import pathlib
import sys

sim_dir = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(sim_dir))
import build

source = (sim_dir / "tb/vga_graph_closedloop_main.cpp").read_text(encoding="utf-8")
replacements = {
    "(hp & 0x07u) == 0x07u": "(hp & 0x0fu) == 0x0fu",
    "dut->vga_lnend_cfg = 11;": "dut->vga_lnend_cfg = 6;",
    "dut->vga_stride = 80;": "dut->vga_stride = 40;",
    "std::vector<FrameSample> frames;":
        "std::vector<FrameSample> frames;\n    std::vector<FrameSample> line_starts;\n    std::vector<FrameSample> row0_arrivals;\n    int last_line_key = -1;\n    int row0_frame = -1;",
}
# Keep the exact source guards explicit: an upstream bench change must be
# reviewed rather than silently producing a partly converted geometry.
for old, new in replacements.items():
    if source.count(old) != 1:
        raise RuntimeError("Expected exactly one source anchor: " + old)
    source = source.replace(old, new)

old = "            // Capture the first read in every vcount==0 interval."
new = """            const int line_key = int(vcount);
            if (line_key != last_line_key) {
                last_line_key = line_key;
                if (frame_count < 3 && vcount < 32) line_starts.push_back(sample);
            }
            if (vcount < 8 && sample.source == 0x080b7fe0u && row0_frame != int(frame_count)) {
                row0_frame = int(frame_count);
                row0_arrivals.push_back(sample);
            }
            // Capture the first read in every vcount==0 interval."""
if source.count(old) != 1:
    raise RuntimeError("Missing scanline capture anchor")
source = source.replace(old, new)
old = "    dut->final();\n    delete dut;"
new = """    std::printf("  TEXT FIRST LINES (source_base=080b8000, stride=160 bytes)\\n");
    for (const auto& f : display.line_starts) {
        const int delta = int(f.source) - int(0x080b8000u);
        std::printf("    cycle=%llu v=%u glyph_row=%u fifo=%u source=%08x row_delta=%d byte_rem=%d\\n",
                    (unsigned long long)f.cycle, f.vcount, f.vcount & 15u,
                    f.fifo_half, f.source, delta / 160, delta % 160);
    }
    for (const auto& f : display.row0_arrivals)
        std::printf("    ROW0_WINDOW_ARRIVAL cycle=%llu v=%u h=%u glyph_row=%u source=%08x\\n",
                    (unsigned long long)f.cycle, f.vcount, f.hcount,
                    f.vcount & 15u, f.source);
    dut->final();
    delete dut;"""
if source.count(old) != 1:
    raise RuntimeError("Missing diagnostic print anchor")
source = source.replace(old, new)
source = source.replace('std::printf("mode: 13h graph', 'std::printf("mode: text closed-loop')
out_dir = sim_dir / "run/vga_text_phase"
out_dir.mkdir(parents=True, exist_ok=True)
cpp = out_dir / "vga_text_phase_main.cpp"
cpp.write_text(source, encoding="utf-8")
sys.argv = ["build.py", "--top", "ddr_pipe", "--out", str(out_dir),
            "--extra=--bbox-unsup", str(sim_dir / "tb/ddr_pipe.v"),
            str(sim_dir.parent / "cache_controller.v"),
            str(sim_dir.parent / "Next186_BlackBoxes.v"), str(cpp)]
build.main()
