# VGA ILA payload (2026-10-14)

The active parent XDC maps one ILA to a 199-bit packed VGA payload plus a
one-bit frame-start trigger, for **200 bits total**. Both ports are sampled in
the `clk_sdr` domain.

`probe0` is packed MSB to LSB as follows:

| Bits | Signal |
|---:|---|
| 198:182 | `vga_ddr_row_col[16:0]` |
| 181:173 | `vga_ddr_row_count[8:0]` |
| 172:169 | `vga_repln_count[3:0]` |
| 168:161 | `vga_lnbytecount[7:0]` |
| 160:137 | `sdraddr[23:0]` |
| 136:128 | `fifo_wr_used_words[8:0]` |
| 127:118 | display `vcount[9:0]` |
| 117:108 | display `hcount[9:0]` |
| 107:104 | `hcount_pan[3:0]` |
| 103:102 | `vgatext[1:0]` |
| 101:100 | `vga13[1:0]` |
| 99:98 | `planar[1:0]` |
| 97:96 | `half[1:0]` |
| 95:80 | CRT `scraddr[15:0]` |
| 79:72 | CRT `vga_offset[7:0]` |
| 71:70 | `sys_cmd_ack[1:0]` |
| 69 | `sys_rd_data_valid` |
| 68 | `sys_wr_data_valid` |
| 67 | `crw` |
| 66:62 | `col_counter[4:0]` |
| 61:59 | `max_read[2:0]` |
| 58 | `s_vga_endscanline` |
| 57 | `s_vga_endline` |
| 56 | `s_vga_endframe` |
| 55 | `dbg_vga_fs` |
| 54 | `dbg_vga_rowreset_evt` |
| 53:45 | `dbg_vga_fifo_at_fs[8:0]` |
| 44:41 | `dbg_vga_repln_at_fs[3:0]` |
| 40:33 | `dbg_vga_lnb_at_fs[7:0]` |
| 32:25 | `dbg_vga_mode_at_fs[7:0]` |
| 24:1 | `dbg_vga_cfg_at_fs[23:0]` |
| 0 | `dbg_vga_cache_seen_at_fs` |

`probe1[0]` is `dbg_vga_trigger`, asserted for the first `clk_sdr` sample
where the display-side `vcount` is zero. Use it as the ILA trigger (`== 1`).
Capture both text mode after boot and graphics mode after launching Monkey
Island. Compare `fifo_wr_used_words`, `vga_ddr_row_col`, `vga_lnbytecount`,
`vcount`, and the command/data-valid fields at the trigger and over the
following frame. A stable frame-start FIFO level with changing row phase points
to address/reset timing; a changing FIFO level with stable row phase points to
DDR arbitration/throughput.

