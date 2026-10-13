# Text-mode VGA ILA analysis (2026-10-14)

The diagnostic bitstream was programmed through the verified Digilent target
`localhost:3121/xilinx_tcf/Digilent/210299129354` (`xc7z010_1`). Three captures
were taken at the display frame-start marker and unpacked under
`sim/run/vga_ila_text_20261014/`.

All three captures agree:

| signal at display frame start | value |
|---|---:|
| `vcount` | `0` |
| `vga_ddr_row_col` | `0xE4B0` |
| `vga_ddr_row_count` | `196` |
| `vga_repln_count` | `4` |
| `vga_lnbytecount` | `40` |
| `dbg_vga_fifo_at_fs` | `0x160` |
| `dbg_vga_mode_at_fs` | `0xC0` (both sides text mode) |
| `dbg_vga_cfg_at_fs` | `0x000014` |

Thus the display begins a new frame while the fetch side is still in the
middle of the previous fetch sequence. The FIFO is not empty and the mode
bits agree, so this is not a DDR starvation or mode-switch fault.

After the frame-start sample, the fetch side reaches `s_vga_endscanline`
while `vcount` is still zero and emits exactly one `dbg_vga_rowreset_evt`.
At that event `vga_ddr_row_col` changes to `0xE000` and
`vga_lnbytecount` returns to zero. The event occurs at different sample
indices in the three captures because the asynchronous FIFO phase moves, but
the ordering is the same: display frame start first, fetch row reset later.

This ordering leaves the first display line consuming the tail of the prior
fetch phase. The measured phase is the previously observed three-scanline
offset, which appears on screen as the first three pixel rows of the first
text line being pushed above the visible area. The fixed frame-start FIFO
level (`0x160`) and repeatable row phase show that the clipping is caused by
frame/line phase alignment between the display reader and DDR fetch engine,
not by random DDR corruption.

The functional fix should therefore synchronize the fetch-side row/FIFO
start to the display frame boundary, or hold display consumption until a
known row-start word is available. Changing the constant address offset alone
will not remove the phase race and would also affect graphics mode.
