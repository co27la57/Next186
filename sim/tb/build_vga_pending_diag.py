"""Causal A/B: retain display frame-start until the next fetch-line end.

Run from imports/ with the repository's existing Python environment:
  python sim/tb/build_vga_pending_diag.py

Only a generated copy under sim/run/vga_contention_diag_pending is changed.
Production RTL and sim/tb/ddr_pipe.v are read-only inputs. This experiment
changes neither FIFO contents nor row/repeat counters, burst length, geometry,
CPU traffic, or display raster. It is not a proposed complete VGA repair.
"""
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "sim" / "run" / "vga_contention_diag_pending"
OUT.mkdir(parents=True, exist_ok=True)
os.chdir(ROOT)

source = (ROOT / "sim" / "tb" / "ddr_pipe.v").read_text(encoding="utf-8")
old = """    wire model_vga_frame_start = model_vcount_valid ?
                                  (model_vcount == 10'd0) : vga_end_frame;"""
new = """    // DIAGNOSTIC COPY ONLY: consume each display FS once at a fetch-line end.
    // A coincident FS and fetch-line end is consumed immediately. Otherwise
    // keep the request even after vcount leaves zero; FIFO/counters unchanged.
    reg model_vcount_zero_d = 1'b0;
    reg model_frame_reset_pending = 1'b0;
    wire model_display_fs = model_vcount_valid && (model_vcount == 10'd0) &&
                            !model_vcount_zero_d;
    wire model_vga_frame_start = model_vcount_valid ?
                                  (model_frame_reset_pending || model_display_fs) :
                                  vga_end_frame;
    always @(posedge clk_sdr) begin
        if (rst) begin
            model_vcount_zero_d <= 1'b0;
            model_frame_reset_pending <= 1'b0;
        end else begin
            model_vcount_zero_d <= model_vcount_valid && (model_vcount == 10'd0);
            if (!model_vcount_valid)
                model_frame_reset_pending <= 1'b0;
            else if (s_vga_endscanline && model_vga_frame_start)
                model_frame_reset_pending <= 1'b0;
            else if (model_display_fs)
                model_frame_reset_pending <= 1'b1;
        end
    end"""
if source.count(old) != 1:
    raise SystemExit("Expected one original frame-reset predicate; refusing to patch")
copy = OUT / "ddr_pipe_pending.v"
copy.write_text(source.replace(old, new), encoding="utf-8")

# The sandbox permits these cache paths; reuse the already populated cache.
os.environ.setdefault("ZIG_GLOBAL_CACHE_DIR", str(ROOT / "sim/run/opl3_led/zig-global"))
os.environ.setdefault("ZIG_LOCAL_CACHE_DIR", str(ROOT / "sim/run/opl3_led/zig-local"))
sys.path.insert(0, str(ROOT / "sim"))
import build

original_run = build.run


def with_geometry(cmd, **kwargs):
    if "--cc" in cmd:
        cmd = cmd + ["-GVGA_BASE_PARAM=32768", "-GVGA_REPLN_PARAM=1"]
    return original_run(cmd, **kwargs)


build.run = with_geometry
sys.argv = [
    "build.py", "--top", "ddr_pipe", "--out", str(OUT),
    "--extra=--bbox-unsup", str(copy), "cache_controller.v",
    "Next186_BlackBoxes.v", "sim/tb/vga_contention_diag_main.cpp",
]
build.main()

with (OUT / "rw_long_pending.log").open("w", encoding="utf-8") as log:
    result = subprocess.run([str(OUT / "ddr_pipe.exe"), "8400000", "3"],
                            stdout=log, stderr=subprocess.STDOUT)
print("A/B log:", OUT / "rw_long_pending.log", flush=True)
raise SystemExit(result.returncode)
