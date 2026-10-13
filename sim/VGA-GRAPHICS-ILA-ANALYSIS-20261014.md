# VGA graphics ILA capture — 2026-10-14

Bitstream: `sim/run/Network_wrapper_vga_probe_20261014.bit`, target `Digilent/210299129354`, device `xc7z010_1`.

## Capture procedure

1. Programmed the VGA packed probe bitstream through Vivado hw_server (`PROGRAM_ONLY_DONE`).
2. Waited for FreeDOS boot to finish.
3. Sent `cd monkey` and `monkey.exe` through SSH using `/home/workspace/kbd_gpio_inject -g 3000`. The JTAG GPIO scripts were not used because their millisecond strobe is classified as a mouse pulse by the current `MOUSE_STB_MIN_US=1000` receiver.
4. Captured frame start and scanline ILA data with `capture_vga_20261014.tcl`.

Capture files are in `Network.hw/backup/ila_vga_graphics_*_20261014_052237-052239.{ila,csv}`.

## Observations

At all frame starts, the live mode is graphics: `vgatext=0`, `vga13=3`; the frame snapshot is `mode_fs=0x30`. The configuration is stable (`cfg_fs=0x28`, `scraddr=0` in this run) and FIFO startup level is stable at `fifo_fs=0x160`.

The DDR row pointer is not stable at frame start:

| capture | `vga_ddr_row_col` at `vcount=0` | `sdraddr` | `fifo` |
|---|---:|---:|---:|
| fs_a | `0x160b0` | `0x6c190` | `0x160` |
| fs_b | `0x0cab0` | `0x59590` | `0x160` |
| fs_c | `0x115b0` | `0x62b90` | `0x160` |

`cfg_fs` and the display mode do not change, so this is a stale fetch-side row pointer/phase, not a CPU change to the VGA CRTC address. The low address phase changes between frames and directly explains horizontal scrolling.

The FIFO also approaches its empty threshold while a frame is being scanned. Approximate captured levels are: line 1 starts near `0x0d0`, line 2 near `0x0b0`, line 3 near `0x040`; later samples are at or below `0x040`. This leaves little margin for DDR arbitration and explains intermittent underflow, flicker, and small garbage regions.

The current `vga_ddr_row_col` reset is nested under `s_vga_endscanline` and tests `vcount==0`; this can miss the display frame boundary because the fetch clock and display clock are asynchronous. A frame-start reset/synchronization must establish row pointer and FIFO phase before the first visible line, with sufficient prefetch headroom.
