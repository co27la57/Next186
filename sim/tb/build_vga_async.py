"""Build the graph-mode bench with an independent AXI clock."""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import build

repeat = int(sys.argv[1]) if len(sys.argv) > 1 else 1
original_run = build.run


def run_with_geometry(cmd, **kwargs):
    if '--cc' in cmd:
        cmd = cmd + ["-GVGA_BASE_PARAM=17'h08000",
                     '-GVGA_REPLN_PARAM=' + str(repeat)]
    return original_run(cmd, **kwargs)


build.run = run_with_geometry
sys.argv = ['build.py', '--top', 'ddr_pipe_async', '--out',
            'sim/run/vga_graph_async_r' + str(repeat),
            '--extra=--bbox-unsup', 'sim/tb/ddr_pipe_async.v',
            'cache_controller.v', 'Next186_BlackBoxes.v',
            'sim/tb/vga_graph_async_main.cpp']
build.main()
