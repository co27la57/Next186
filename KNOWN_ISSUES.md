# Known issues

Open bugs in this port, with reproduction notes and current status.
Last updated: 2026-10-24.

## Current state (2026-10-24)

| Item | Value |
|---|---|
| Remote HEAD | `b89ee21` (`fix(audio): send signed PCM to I2S instead of PDM offset binary`) |
| VGA baseline | `d237a4f`, tag **`vga-stable-20261021`** — board-verified 2026-10-21 |
| OPL3 core | nukeykt YMF262 (`opl3_ym.v` + `ymf262.sv` + `ym_lib.sv`), MCLK = 50 MHz, 8 µs/byte replay |
| Audio mixer | `soundwave.v` — 19-bit signed mix; I2S = signed PCM (`b89ee21`), AUDIO_L/R = PDM offset code |
| Volume ports | `0x38C` = attenuation (right-shift 0..8), `0x38D` = version id (`0x40|(ovf<<1)|vol_hit`), `0x38E` = master |
| Open issues | **#6 PCM (DSS/Covox) no audio output**, **#7 VGMSLAP text lines truncated** |

Issues #1 and #5 are **fixed** by the `d237a4f` VGA baseline (kept as history).
Issue #2 is **fixed in-tree** (`f96476d` digit-scancode correction + lossless
FIFO/rdy path, `a50a066` shift symbols, `1ec24ec` function keys, `b3f1511`
watchdog, `7a36a53` flag-word clear) — pending board re-verification.

---

## 6. PCM audio (DSS / Covox, port 0x378) produces no output — only Adlib is audible

**Status:** open — root cause identified at RTL level (2026-10-24); fix drafted below, not yet applied/synthesised.
**Severity:** functional — all PCM playback (VGM DAC streams, DSS/Covox test tones, digitised sound) is silent or a DC thump, while OPL3/Adlib FM audio plays normally.
**Reproduction:** play any VGM with a DAC stream (e.g. VGMSLAP) or run a Covox/DSS test tone. OPL3 channels sound; the PCM stream does not.

### 6.1 Why Adlib still works (and why that matters)

`opl3_ym` feeds `soundwave.opl3left/opl3right` **directly** (see the `soundwave
sound_gen` instantiation in `ddr_186.v`). The DSS/Covox path is the *only* audio
source that goes through the `sndfifo` sample queue. A broken `sndfifo`
therefore mutes PCM while leaving FM untouched — exactly the reported symptom.

### 6.2 Root cause A — `sndfifo` port width does not match its user (16-bit vs 32-bit)

`soundwave.v` reads/writes the queue as **32-bit stereo pairs** (`wdata` /
`sample` are `[31:0]`; one pop per 44.1 kHz tick delivers `{R, L}`) and was
written against the upstream `sndfifo` (32-bit × 4096, show-ahead OFF). The
port's `sndfifo` in `Next186_BlackBoxes.v` is an XPM async FIFO with
`READ_DATA_WIDTH(16) / WRITE_DATA_WIDTH(16) / FIFO_WRITE_DEPTH(2048)`.

Verilog silently truncates / zero-extends mismatched port connections, so it
compiles and then misbehaves:

- every write stores only `wdata[15:0]` (the LEFT half);
- every read returns `q` zero-extended into `sample[31:0]` ⇒
  `sample[31:16] == 0` forever ⇒ **the RIGHT channel is permanently silent**;
- the "one pop = one stereo pair" protocol is destroyed, and the byte-write
  replication scheme (6 entries per byte write, see 6.3) pushes six copies of
  the low half only.

### 6.3 Root cause B — byte-write packing is a full-scale DC offset under signed I2S

`soundwave.v` (upstream original, unchanged by this port):

```verilog
write <= 3'b110;
wdata  <= {1'b1, data[7:0], 8'b00000001, data[7:0], 7'b0000000};
```

Both 16-bit halves evaluate to `0x8000 | (data << 7)`. Interpreted as the
**signed** value the mixer uses (`lmix = {{3{sample1[15]}}, sample1[15:0]} …`),
that is `-32768 + data*128` — a Covox mid-scale byte (`0x80`) produces ≈ −32752,
nearly full-scale negative DC. On the I2S output this drives the amplifier into
clipping/protection (silence or thumps); on the PDM output the duty cycle
centres at ~100 % instead of 50 %. The comment "the 8bit sample value is shifted
by 8" states the *intent*; the correct signed mapping is `(data − 128) << 8`.

This latent upstream bug only became fatal when the I2S output switched from
offset-binary (PDM) to signed PCM (`b89ee21`).

### 6.4 Root cause C — `full` back-pressure can never assert

`soundwave.v`: `assign full = wrusedw >= 12'd2940;` — 2940 was computed for the
upstream **4096-deep** queue (4096 − 1152-word max write burst ≈ 2940). With
the 2048-deep XPM the count saturates at 2048, so `sq_full` (fed back to the
CPU on port `0x3DA` bit 4) is permanently 0 and any driver polling "queue full"
never waits. Once the XPM itself is full it silently drops writes, so a fast
PCM stream is corrupted rather than throttled.

### 6.5 Fix (draft — apply to the build tree, run the sim harness before synthesis)

**1) `Next186_BlackBoxes.v` — restore the 32-bit × 4096 queue** (matches
`soundwave.v` and the upstream `sndfifo.v`):

```verilog
module sndfifo (
    input  wire        wrclk,
    input  wire        rdclk,
    input  wire        rst,
    input  wire [31:0] data,      // was [15:0] — soundwave writes {R,L} pairs
    input  wire        wrreq,
    input  wire        rdreq,
    output wire [31:0] q,         // was [15:0]
    output wire        wrfull,
    output wire        rdempty,
    output wire [12:0] wrusedw,   // was [11:0] — 4096 deep needs 13 bits
    output wire [12:0] rdusedw    // was [11:0]
);
    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE("auto"),
        .READ_DATA_WIDTH(32),
        .WRITE_DATA_WIDTH(32),
        .FIFO_WRITE_DEPTH(4096),
        .USE_ADV_FEATURES("0404")
    ) snd_fifo_inst (
        .wr_clk(wrclk), .rd_clk(rdclk),
        .din(data), .wr_en(wrreq), .rd_en(rdreq),
        .dout(q), .full(wrfull), .empty(rdempty),
        .wr_data_count(wrusedw),
        .rd_data_count(rdusedw),
        .sleep(1'b0), .rst(rst), .injectsbiterr(1'b0), .injectdbiterr(1'b0)
    );
endmodule
```

**2) `soundwave.v` — widen the counters to match** (otherwise the 13-bit XPM
count truncates and `full >= 2940` is missed again):

```verilog
wire [12:0]wrusedw;  wire [12:0]rdusedw;
assign full     = wrusedw >= 13'd2940;
assign dss_full = rdusedw >  13'd90;
```

**3) `soundwave.v` — signed Covox byte packing** (fixes I2S *and* PDM at once,
because both derive from the signed mixer value):

```verilog
// old: wdata <= {1'b1, data[7:0], 8'b00000001, data[7:0], 7'b0000000};  // 0x8000|(data<<7) per half → DC offset
wdata <= {{~data[7], data[6:0], 8'h00}, {~data[7], data[6:0], 8'h00}};   // (data-128)<<8, both channels
```

> Keeping depth 2048 is possible, but then the `full` threshold must be
> recomputed (2048 − 1152 max-burst ≈ 880) — do not just lower 2940
> mechanically. 4096 × 32 costs ~4 BRAM36 vs 1 today; the XC7Z010 has headroom.

**4) Verify the driver's busy-bit convention.** `dss_full` is exposed on port
`0x379` bit 6 and `sq_full` on `0x3DA` bit 4. If VGMSLAP (or any DSS/Covox
player) polls a different LPT status bit for "queue not full", it will never
throttle and samples will be dropped regardless of the FIFO width.

### 6.6 Verification plan

1. Extend `sim/opl3_output_review` (Verilator + independent I2S receiver —
   10/10 green on `b89ee21`) with a `sndfifo` round-trip case: write a known
   stream at the byte/word protocol level, run the 44.1 kHz reader, compare the
   decoded I2S words against the expected `(data−128)<<8` ramp.
2. Negative control: re-introduce the 16-bit width and confirm the case fails
   (right channel = 0, byte path DC-shifted).
3. Board: Covox test tone first (`oplvol 0 3` is a sane starting attenuation),
   then a VGM with a DAC stream; confirm both channels and no clipping.

---

## 7. VGMSLAP text screen: each line shows only about half of its characters

**Status:** open — two candidate root causes, discriminated by the checks below (2026-10-24).
**Severity:** functional/visual — inside VGMSLAP every text line is truncated
(~half the characters visible, the remainder missing/stale), while ordinary DOS
text screens are reported normal.
**Reproduction:** run VGMSLAP and play any VGM; observe its text UI.

### 7.1 How the fetch↔display balance works in the current baseline

- Display side (`clk_25`): text mode pops one 32-bit FIFO word per 16 pixels
  (`&hcount_pan[3:0]`) ⇒ 45 pops per 720-px line; `vga_line_reads` is capped by
  `vga_line_quota = 48` words per scanline (`d237a4f`).
- Fetch side (`clk_sdr` = 50 MHz): each VGA read burst (`main_arlen = 15`,
  16 × 32-bit beats) is accepted into the FIFO for 16 halfwords (`col_counter`
  loaded to `{1'b0, max_read, 1'b1}`), and `vga_lnbytecount` advances by
  `max_read + 1` **words** (= 16 halfwords). The line ends at
  `vga_lnbytecount[7:3] == vga_lnend` (text: 6) ⇒ 6 bursts × 16 halfwords =
  96 halfwords = 48 words per character row — exactly the display quota
  (40 words = 80 visible columns + 8 words of prefetch tail).
- The two sides are re-synchronised at every vblank by the `VGA_FS_*` state
  machine (stop → drain → FIFO reset → wait XPM reset-busy → prefetch from the
  frame base), which is what made the board verification pass.

So in the current baseline the fetch and the display are rate-matched **only if
the address advance equals the FIFO acceptance** and **only if the fetch side
wins enough DDR bandwidth**. Each candidate below violates one of those.

### 7.2 Candidate A — the bitstream contains the reverted step-doubling change (`dcdfb1a`)

`dcdfb1a` (2026-10-20, reverted by `3f73b44`) changed the fetch advance to
`2*(max_read+1)` **and** doubled `vga_lnend` (6→12 / 11→22 / 21→42), on the
belief that each burst returns only 16 halfwords. In reality a burst returns 16
*words* (64 B) of which 16 halfwords are accepted, so the correct advance is
`max_read+1` words. With the doubled advance the fetch skips every other 8-word
block: bursts land at words 0, 16, 32, 48, 64, 80 while the display consumes
0..39 ⇒ each line shows only isolated fragments — **"each line shows only
half"**, and it would affect *every* text screen, not just VGMSLAP.

**Check (30 seconds, on the build tree):**

```sh
grep -n "vga_lnbytecount <=" ddr_186.v     # must be  + max_read + 1'b1   (NOT 2*(max_read+1))
grep -n "vga_lnend ="       ddr_186.v      # must be  6 / 11 / 21         (NOT 12 / 22 / 42)
```

If the build tree shows the doubled values, the bitstream predates the revert —
**rebuild from `vga-stable-20261021` (`d237a4f`) or later** and re-test. Also
confirm the flashed bitstream really is from that commit (`git log --oneline -1`
in the inner Vivado repo).

### 7.3 Candidate B — VGA fetch underrun under heavy DDR load (known-weak case)

`d237a4f`'s own Verilator regression explicitly left the **high-load underrun**
case failing. VGMSLAP is exactly that load profile: the CPU streams the VGM file
from SD through the write-back cache, writes OPL3 registers at 8 µs/byte, and
refreshes the screen, while the VGA fetch needs 48 words per line. The arbiter
serves VGA reads mainly when the FIFO is below the low watermark
(`s_prog_empty`) and lets `cache_owns` preempt; if the fetch side sustains only
~half of the drain rate, every display line empties the FIFO mid-line and the
remainder of the line shows stale/zero data.

**Discriminator:** DOS screens and idle text apps look correct (light load,
fetch keeps up); the truncation appears exactly when the machine is busy
(VGMSLAP playback, big file copies, games). If DOS screens are *also*
truncated, it is candidate A instead.

**Fix directions (safest first):**

1. **Halve the VGA DDR traffic.** Each VGA burst currently fetches 16 words but
   only 8 are consumed. Issuing 8-beat bursts for VGA reads
   (`main_arlen <= (ram_cmd == 2'b10) ? 8'd7 : 8'd15` in `top_zynq7010.v`)
   halves the bytes the arbiter must move per line. This was tried in
   `de565d0` (153rd) and removed the duplication, but was reverted with that
   package before the `VGA_FS_*` frame reset existed — with `d237a4f` in place
   it is worth re-running through `sim/vga_verify` (the frame-start FIFO reset
   is precisely what stabilises the watermark mapping that 153rd could not).
2. **Raise the VGA service watermark during active display.** VGA read commands
   are currently requested when `s_prog_empty` (FIFO < 64 halfwords). Keeping
   the fetch further ahead (e.g. request while below ~128–192 halfwords during
   `!vblnk`) gives the per-line quota more slack. Caution: the arbiter is the
   same logic that caused the historical cache-fill / VGA data-pollution bug —
   change one variable at a time and validate in the sim bench before the board.
3. **Deepen the VGA FIFO** (1024 → 2048 halfwords) as pure extra slack; costs
   one more BRAM36 and does not fix a sustained rate deficit.

### 7.4 Candidate C — VGMSLAP uses a text mode the detector does not model

The mode detector (`VGA_SG` → `vgatext/half/vga13/planar/v240`) models 80×25 /
40×25 text, mode 13h, planar EGA/VGA graphics and 480-line timing. If VGMSLAP
programs an unusual text mode (80×30/80×43/80×50 via raw CRTC registers), the
repeat count (`vga_repln`) and the line quota would be wrong and could present
as truncated lines. Check by running another text-mode program right before
VGMSLAP without a mode reset, or by capturing which CRTC registers VGMSLAP sets.

---

## 8. Windows 3.0 will not start (SETUP crashes on first Enter; `win` hangs at the splash)

**Status:** open — EMU386 hypothesis ruled out as the cause; prime suspect is the cache↔DDR data corruption (2026-10-24).
**Severity:** functional — Windows 3.0 cannot be installed or started.
**Reproduction:** run `SETUP` from the Windows 3.0 install disks — the first screen returns straight to DOS on Enter. Running `win` from DOS shows the Windows 3.0 splash and then hangs.

### 8.1 What the upstream project actually says (OpenCores overview, verified 2026-10-24)

> "Able to run DOS6.22, FreeDos, **Windows3.0**, GeOS. … May run real mode 32bit 386 applications with a 32bit software extender (**see EMU386**). … **The system is able to run Windows3.0 in real mode.**"

- Windows 3.0 on Next186 runs in **real mode** — it does **not** need any extender.
- **EMU386** is a DOS TSR (loaded from `config.sys`; shareware by Eko Priono) that traps 386-only opcodes via INT 6 and re-implements them with 186/286-compatible instruction sequences, so that *32-bit real-mode applications* can run. It is for DOS programs, not for Windows 3.0.
- Interference is still possible: EMU386 hooks **INT 6 (invalid opcode)**, and CPU probing by DOS/Windows software classically works by *executing a 386-only instruction and catching the exception*. A resident EMU386 can corrupt that probe. So removing it is the first cheap experiment, not a conclusion.

### 8.2 The port did not break the CPU or the BIOS binary (verified 2026-10-24)

| Check | Result |
|---|---|
| `Next186_ALU.v`, `Next186_Regs.v`, `Next186_BIU_2T_delayread.v` vs upstream `neptuno-fpga/Next186_SoC` | **byte-identical** |
| `Next186_CPU.v` vs upstream | functionally identical — only added observation-only `dbg_*` probe registers, all with `mark_debug` commented out (optimised away, no logic feedback) |
| `bios.mem` (8 KB PC BIOS) | **byte-identical to the initial import** — the `scraddr` patch commits (`5d27c32` → `6d48208`) cancelled out; the binary was restored |
| Core exceptions | INT 6 (invalid opcode) is implemented in the core (MOV FS/GS), DIV fix from 23Dec2012 is included |

⇒ The "EMU386 patch was applied wrongly" hypothesis does **not** explain the failure: there is no EMU386 code in this repository at all, and neither the CPU core nor the BIOS binary differs from upstream.

### 8.3 Where the port *does* differ from the original (real suspects)

| Original (Dumitrache) | This port | Risk for Windows 3.0 |
|---|---|---|
| 4 KB cache (8 lines × 256 B) directly in front of SDRAM | 8 KB 4-way write-back cache + AXI bursts + DDR arbiter; **cache↔DDR data corruption still open** (see `AI交接说明-2-数据损坏排错.md` §0, `sim/FINDINGS-95th` §9) | **Prime suspect.** Every Windows file (`SETUP.EXE`, `WIN.COM`, `KRNL286.EXE`, `GDI.EXE`, `USER.EXE`, display drivers) is loaded from the SD image through this path; corrupted bytes explain both symptoms (installer crash on first Enter; splash then hang). A different port reported the same class of failure ("divide by zero" in the installer). |
| Custom VGA, board-proven | Rewritten VGA scan-out; broken until `d237a4f` (tag `vga-stable-20261021`) | If the flashed bitstream predates `d237a4f`, Windows' display-driver init (mode sets + palette DAC + heavy VRAM writes) can hang at the splash. The VGMSLAP half-line symptom (#7) suggests the bitstream may not be the `d237a4f` baseline. |
| BIOS provides XMM manager, 64 KB paging, HMA | Same features ported (`MEMORY_MAP` port `0x80`+page etc.), but the bootstrap in `Next186_BlackBoxes.v` is heavily patched | Subtle breakage in XMM/paging would show up under Windows' larger memory footprint. DOS + games work, so this is secondary. |

### 8.4 Action list (no code changes)

1. **Remove EMU386 (and any 386-only driver: `EMM386`, `QEMM`, `386MAX`) from `config.sys`** and retry `SETUP` from a clean boot. If behaviour is unchanged, EMU386 is exonerated; if it starts working, it was interfering via the INT 6 hook.
2. **Verify file integrity in DOS**: compute a checksum/CRC of `SETUP.EXE`, `WIN.COM`, `KRNL286.EXE`, `GDI.EXE`, `USER.EXE` in memory and compare against the original disk images. A mismatch proves the cache↔DDR corruption hypothesis and points the fix at that bug instead of Windows.
3. **Confirm the flashed bitstream is `≥ d237a4f`** (`git log --oneline -1` in the inner Vivado repo); ideally rebuild from `b89ee21` before spending time on Windows.
4. If the CRCs match: check what CPU family the machine reports (a `PUSHF` bits 12–15 probe from DOS), and capture the state at the crash (the BIOS INT 0/INT 6 handlers, CS:IP at the fault) with the existing ILA probe set.
5. If the CRCs mismatch: the root cause is the still-open second corruption mechanism (`sim/FINDINGS-95th` §9.2) — fix that first, Windows 3.0 included.

---

## Historical issues (kept for context)

### 1. VGA text mode: top/bottom half of the screen is swapped — FIXED

**Status:** fixed by the board-verified `d237a4f` baseline (tag
`vga-stable-20261021`, 2026-10-21). Retained as history.

The failure lived in the scan-out address generator (`vga_ddr_row_col` /
`vga_lnbytecount` / `sdraddr` in `ddr_186.v`); the fix replaced the ad-hoc
phase constants with a vblank frame-start FIFO reset plus a per-line read
quota. Do not resurrect the old `-8` / `-448` / `-488` phase compensations —
see `sim/vga_verify/README.md` for the validated change set.

### 2. PS→PL keyboard injection: `j` renders as `4`; Enter/Backspace hang — FIXED IN TREE

**Status:** RTL fixes are in `origin/main` (`f96476d` corrected the digit
scancode table and made the inject path lossless with a FIFO + `rdy` handshake;
`a50a066` shift-symbol map; `1ec24ec` function keys; `b3f1511` FIFO watchdog
pop; `7a36a53` clears the 8086 keyboard flag word and doubles the Shift break).
Board re-verification of the mapping fix is still pending.

The transport is PS EMIO GPIO (8-bit parallel + strobe, zero bit loss) — **do
not add an AXI slave for this feature**: it destabilises the VGA scan-out by
shifting DDR read latency (that lesson is still valid).

### 3. Constraints: `foreach` unsupported in XDC — FIXED

XDC supports only the XDC command subset, not full Tcl; any loop in a `.xdc`
must be unrolled. A stray HTML `<br/>` once silently disabled the CDC
`set_max_delay -datapath_only` constraints — keep loops and HTML out of `.xdc`.

### 4. Root layout duplicate (`imports/imports/`) — WORKAROUND

Some Vivado versions resolve module references through a nested
`imports/imports/` directory; a new `.v` added only under `imports/` fails with
`[Synth 8-439] module '...' not found`. Add new sources to both directories (or
fix the project source list).

### 5. VGA text mode: screen content cyclically rotated by 7 rows — FIXED

**Status:** fixed by the `d237a4f` baseline (same root neighbourhood as #1:
fetch-side row phase vs display-side `vcount`, now re-synchronised at vblank by
the `VGA_FS_*` FSM). Retained as history.
