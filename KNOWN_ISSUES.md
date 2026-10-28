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

**Status:** open — **prime suspect identified 2026-10-24: the core reports a 286-class CPU, so `win` auto-selects 286 standard (protected) mode; the 80186 cannot enter protected mode. Zero-code fix to try first: `win /r`.**
**Severity:** functional — Windows 3.0 cannot be installed or started.
**Reproduction:** run `SETUP` from the Windows 3.0 install disks — the first screen returns straight to DOS on Enter. Running `win` from DOS shows the Windows 3.0 splash and then hangs.

### 8.1 What the upstream project actually says (OpenCores overview, verified 2026-10-24)

> "Able to run DOS6.22, FreeDos, **Windows3.0**, GeOS. … May run real mode 32bit 386 applications with a 32bit software extender (**see EMU386**). … **The system is able to run Windows3.0 in real mode.**"

- Windows 3.0 on Next186 runs in **real mode** — it does **not** need any extender.
- **EMU386** is a DOS TSR (loaded from `config.sys`; shareware by Eko Priono) that traps 386-only opcodes via INT 6 and re-implements them with 186/286-compatible instruction sequences, so that *32-bit real-mode applications* can run. It is for DOS programs, not for Windows 3.0.
- Interference is still possible: EMU386 hooks **INT 6 (invalid opcode)**, and CPU probing by DOS/Windows software classically works by *executing a 386-only instruction and catching the exception*. A resident EMU386 can corrupt that probe. So removing it is the first cheap experiment, not a conclusion.

### 8.1a Windows 3.0 mode selection — the decisive fact (Microsoft KB WW0335)

> "WIN.COM starts up automatically in the appropriate operating mode for your machine and the amount of memory installed … Windows may be forced into any of the modes through the following command-line switches (provided the mode is supported by your hardware):
> **`win /r` = Real (Windows 3.0 only)** · `win /s` / `win /2` = Standard · `win /3` = 386 enhanced.
> Real mode requirements: Windows 3.0, **8088 or above**, 384K free conventional memory.
> Standard mode requirements: **80286 or above**, 192K free extended memory, **XMS driver loaded (HIMEM.SYS)**."

So the auto-detected mode is decided by (a) what CPU class software probes report and (b) whether XMS is present. Both point at the RTL finding below.

### 8.2 The port did not break the CPU or the BIOS binary (verified 2026-10-24)

| Check | Result |
|---|---|
| `Next186_ALU.v`, `Next186_Regs.v`, `Next186_BIU_2T_delayread.v` vs upstream `neptuno-fpga/Next186_SoC` | **byte-identical** |
| `Next186_CPU.v` vs upstream | functionally identical — only added observation-only `dbg_*` probe registers, all with `mark_debug` commented out (optimised away, no logic feedback) |
| `bios.mem` (8 KB PC BIOS) | **byte-identical to the initial import** — the `scraddr` patch commits (`5d27c32` → `6d48208`) cancelled out; the binary was restored |
| Core exceptions | INT 6 (invalid opcode) is implemented in the core (MOV FS/GS), DIV fix from 23Dec2012 is included |

⇒ The "EMU386 patch was applied wrongly" hypothesis does **not** explain the failure: there is no EMU386 code in this repository at all, and neither the CPU core nor the BIOS binary differs from upstream.

### 8.3 The real root cause candidate — the core reports a 286-class CPU (RTL-verified)

**FastTracker's "requires 80386" message was the clue.** Every flags-based CPU
probe classifies this machine as 286-class, because the core does not model the
80186's reserved flags bits:

```verilog
// Next186_Regs.v (original author's code — identical in the OpenCores SVN trunk,
// in neptuno-fpga's import, and in this port; byte-verified 2026-10-24)
reg [8:0]FLG;                                                    // only 9 flag bits are stored
assign FOUT = {4'b0000, FLG[8:3], 1'b0, FLG[2], 1'b0, FLG[1], 1'b1, FLG[0]};
//              ^^^^^^^ PUSHF bits 15:12 are HARDWIRED 0 (a real 80186 reads them as 1)
```

Consequences:

- **FastTracker** (386-only, protected-mode program) sees "286" → refuses ✓
  (observed). This is *correct* behaviour for a pre-286 machine, and EMU386
  cannot fix it — see 8.3a.
- **Windows 3.0 auto-detection**: "286-class + XMS loaded" ⇒ WIN.COM selects
  **286 standard mode (protected)**. The 80186 has **no protected mode**, so
  the mode switch fails right after the real-mode splash is drawn — exactly the
  reported "shows the splash, then hangs". This also explains why the original
  author's documented configuration is *real* mode: it is the only mode this
  CPU can actually run.
- The same applies to SETUP's own hardware probing if it uses 286/386-specific
  instructions (SMSW etc.): they raise INT 6 here.

### 8.3a Why EMU386 can never fix FastTracker (boundary, for the record)

EMU386's own requirements (author's documentation): programs must **run in
real mode only** and must **not check (or ignore) the CPU type**. FastTracker II
violates both — it is a *protected-mode* DOS program and it checks the CPU. No
386-opcode emulator can supply protected mode. Realistic options on this
hardware: 286-era real-mode trackers (e.g. Scream Tracker 2.x) or the project's
own real-mode MP3 player (DSP32).

### 8.4 Secondary suspects (keep in view, test after `win /r`)

| Suspect | Status |
|---|---|
| **cache↔DDR data corruption** (still open, see `AI交接说明-2-数据损坏排错.md` §0 / `sim/FINDINGS-95th` §9.2) | Explains a *corrupted-file* crash of SETUP (and the "divide by zero" another port reported). Test by CRC-ing `SETUP.EXE` / `WIN.COM` / `KRNL286.EXE` / `GDI.EXE` / `USER.EXE` in DOS against the original disk images. |
| **Bitstream predates `d237a4f`** | An unfixed VGA can hang Windows' display-driver init. Confirm the flashed bitstream is `≥ d237a4f` (ideally `b89ee21`). |
| **EMU386 resident** | Hooks INT 6, can corrupt CPU probes. Remove from `config.sys` (together with `EMM386`/`QEMM`/`386MAX`, none of which can work on this CPU anyway). |

### 8.5 Action list (cheapest first)

1. **Run `win /r`** — forces real mode (KB WW0335). If Windows starts, the
   root cause is confirmed as mode auto-selection and no code change is needed.
   Same for retrying SETUP afterwards.
2. **Confirm the 286-class reporting on hardware (optional, zero code)**: if
   `HIMEM.SYS` currently loads in `config.sys`, that *already proves* it —
   HIMEM requires a 286+ and refuses on 8086-class machines. A 10-line
   `PUSHF`/`POPF` probe program prints the same answer directly.
3. If `win /r` still hangs → CRC the Windows files (corruption check above),
   then verify the bitstream commit.
4. **RTL option (only if you want 80186-accurate reporting)**: change
   `Next186_Regs.v:104` from `{4'b0000, …}` to `{4'b1111, …}` so PUSHF reports
   8086-class like a real 80186 — auto-detection then picks real mode.
   **Trade-off:** HIMEM.SYS (and any other 286+-requiring software) will refuse
   to load, i.e. no HMA/XMS unless the DOS configuration moves to the BIOS's
   own XMM manager. `win /r` achieves the Windows goal without this cost, so
   treat the RTL change as optional.

### 8.6 Making the machine report 386-class (BattleChess 4000 / FastTracker)

**Observation (2026-10-28):** `BattleChess4000` prints *"requires 80386SX or
higher, currently 80286"*. The `MEM` output shows FreeDOS in HMA, 31,168 KB XMS
via `FDXMS286.SYS INT15=128`; after un-REMing `EMU386S.EXE` it reports
"installed successfully" — yet BattleChess still sees a 286. That is expected:
**EMU386 only hooks INT 6 (invalid opcode) and re-emulates 386 instructions; it
cannot change the flags register**, and CPU detection is a pure flags test.

**Why it reports 286 — the three lines behind it:**

```verilog
// Next186_Regs.v:87    only 9 flag bits are physically stored
reg [8:0]FLG;
// Next186_Regs.v:104  PUSHF bits 15:12 are HARDWIRED 0 (a real 80186 reads them as 1,
//                     a 386 reads NT/IOPL there — that is exactly what the probe tests)
assign FOUT = {4'b0000, FLG[8:3], 1'b0, FLG[2], 1'b0, FLG[1], 1'b1, FLG[0]};
// Next186_Regs.v:174  POPF/IRET stores only the 9 old bits, so bits 12-15 are dropped
if(WE[4]) FLG <= {FIN[11:6], FIN[4], FIN[2], FIN[0]};
// Next186_ALU.v:140   every ALU op writes 4'bxxxx into the high nibble (0 after synthesis)
FOUT[15:8] = {4'bxxxx, WORD ? overflow : overflow8, FIN[10:8]};
```

So a program doing the classic sequence *"clear 12-15 → set NT/IOPL → read
back"* always reads 0 ⇒ "80286". No DOS-level TSR can fix this; only the RTL
can.

**Patch — make NT/IOPL real bits (4 changes, 386SX-like personality):**

```verilog
// 1) Next186_ALU.v:140 — preserve the high nibble on every ALU op instead of x/0
FOUT[15:8] = {FIN[15:12], WORD ? overflow : overflow8, FIN[10:8]};

// 2) Next186_Regs.v:87 — 9 → 12 flag bits (add NT + IOPL1/IOPL0)
reg [11:0]FLG;

// 3) Next186_Regs.v:104 — bit15 = 0 (386 reserved), bits14:12 = NT, IOPL1, IOPL0
assign FOUT = {1'b0, FLG[11:9], FLG[8:3], 1'b0, FLG[2], 1'b0, FLG[1], 1'b1, FLG[0]};

// 4) Next186_Regs.v:174 — store the new bits from POPF/IRET
if(WE[4]) FLG <= {FIN[14:12], FIN[11:6], FIN[4], FIN[2], FIN[0]};
```

After this, the "is it a 386?" probe reads back non-zero (bits 13/14 stick) ⇒
BattleChess/FastTracker-class checks pass; the "is it an 8086?" toggle test still
reads "not 8086" (correct). The CPU then presents itself as a **386 in real
mode**, which is exactly the personality EMU386 was written for.

**Caveats (this is a deliberate lie to the software):**

- Anything that now believes "386" and tries **protected mode** will crash —
  the 80186 has none. Windows 3.0 must still be started with `win /r` (8.1a).
- `EMM386`/`QEMM`/`386MAX` will now *try* to load and fail. Keep `EMM286` (or
  the BIOS XMM) for EMS.
- Verify in simulation first: a tiny tb running the two detection sequences
  (`PUSHF/POPF` toggle test + NT test) and printing the concluded class.

**Optional (nice for a public build): runtime switch.** Gate `FLG[11:9]` with a
spare I/O port bit so users can pick the personality from DOS without
re-synthesising:

| Mode | PUSHF[15:12] | Software sees |
|---|---|---|
| 80186 (true) | `4'b1111` | 8086-class — real-mode Windows, DOS 6.22 era |
| 286 (today) | `4'b0000` | 286-class — HIMEM loads, BattleChess refuses |
| 386 (patch) | `{1'b0, NT, IOPL1, IOPL0}` | 386SX-class — EMU386 targets, BattleChess passes |

### 8.7 Running BattleChess 4000 — two layers, and why "286" is not a version problem

**Two independent layers, both required:**

1. **The CPU must *report* 386-class** — the flags patch in 8.6. The
   "currently 80286" message is a pure `PUSHF`/`POPF` probe; nothing else can
   change it.
2. **The CPU must *execute* 386 instructions** — that is EMU386 (INT 6 hook).
   EMU386 cannot change what the flags report, and the flags patch cannot
   execute a single 32-bit instruction. Neither one alone is enough.

**The release (CD vs disk) is not the variable.** `SETUP.EXE` and the game EXE
carry the same class of probe; another release still refuses on a 286-reporting
CPU. The CD release additionally needs `MSCDEX`/a CD-ROM driver that this
platform does not have, so the floppy/disk release is the better base anyway.

**Five-minute pre-check before spending a synthesis cycle** — look for a DOS
extender signature in the EXE. If one is present the program runs in protected
mode and *neither* the patch nor EMU386 can help:

```python
d = open('SETUP.EXE', 'rb').read()
for s in (b'DOS/4GW', b'DOS4GW', b'DPMI', b'CWSDPMI', b'PMODE',
          b'CAUSEWAY', b'WATCOM', b'PharLap'):
    print(s, d.find(s))
```

All `-1` ⇒ real-mode 32-bit code is plausible ⇒ the patch is worth trying.
Any hit ⇒ protected mode ⇒ stop; document it as unsupported.

**Pitfall — EMU386 may refuse on a "386".** After the patch the machine
reports 386, and the driver may decide it is not needed and skip the INT 6
hook. If that happens, use the runtime personality switch (8.6): boot with the
286 personality so EMU386 installs, flip to the 386 personality from DOS, then
run the game.

**SETUP may be skippable.** Many 1993 installers only write a config file. Run
SETUP in DOSBox on a PC, copy the configured game directory to the SD card and
run the game EXE directly on the Next186 — the game's own probe still needs the
patch, but the installer's own quirks are bypassed.

### 8.8 BattleChess 4000 — file analysis (2026-10-28): it needs EMS + VESA, **not** a 386

Binary analysis of the Interplay CD tree (`BC4000/BC4`):

| File | Finding |
|---|---|
| `INSTALL.EXE` (78,360 B) | PKWARE-DCL script installer. Strings: `MINCPUTYPE`, `CpuPrompt`, **"The program requires a processor no less than-"**. `INSTALL.CFG` only copies `*.*` + `Bookdata` + `Vesa`, deletes itself, then `RUNATEXIT: setup.exe`. **No `COMPRESSION` key ⇒ it does not decompress anything.** |
| `BC4000.EXE` (253,209 B) | Plain MZ, **no DOS extender** (DOS/4GW, DOS4GW, DPMI, CWSDPMI, PMODE, CAUSEWAY, WATCOM, PharLap → all absent), **no CPU-check strings at all**. Its only gates: `"No expanded memory manager found."`, `"Battle Chess requires 1024K (64 pages) of free EMS (Expanded) memory."`, `"No VESA compatibility driver found"`, `"... VESA driver ... not the correct driver ..."` |
| `SETUP.EXE` (38,655 B) | Sound/video config tool (1992). No CPU-check strings; writes `intrplay.cfg` (the game reads `intrplay.cfg`, `io=%d`, `irq=%d`). |
| `DATA640.DAT` (12.3 MB) | The game's own resource archive — `DATA640.OFF` / `DATA640.SIZ` are its external offset/size indices. Read directly by the game; **nothing to unpack**. |

**Conclusions**

- The *"requires 80386SX or higher, currently 80286"* message does **not** exist anywhere in the game tree — a whole-tree binary search for `80386` / `80286` / `386SX` returns nothing. It comes from **INSTALL.EXE** ("The program requires a processor no less than-"), i.e. the installer's scripted CPU gate. Confirm by reading `INSTALL.BAT` — it simply runs `install.exe`.
- Therefore **the 386-personality patch (8.6) is not needed for BattleChess 4000**. The installer can be skipped entirely: the file set is already complete (and `INTRPLAY/BC4000` even holds an installed copy).
- What the game actually needs: **≥1024 KB free EMS** and a **VESA VBE mode 101h (640×480×256)** provider.

**How to run it**

1. Skip `INSTALL.EXE` / `INSTALL.BAT`.
2. Load the EMS driver **with at least 1024 KB** — `EMM286 2048` (needs XMS from `FDXMS286`, 31 MB present). Verify `MEM` shows an EMS line; without one the game stops at "No expanded memory manager found."
3. **Do not run the bundled `VESA.COM`** (it is a copy of `VESA/ATI.COM`, an ATI-specific driver). The Next186 BIOS already provides VBE 101h; a foreign driver triggers *"not the correct driver for your video card"*.
4. Run `SETUP.EXE` if sound needs configuring (Adlib/SB/PC speaker → `intrplay.cfg`), then `BC4000.EXE`.

**Remaining risks on this platform**

- `"Not enough free base memory"`: the `MEM` capture shows 533 KB largest executable — trimming TSRs / `DEVICEHIGH` may be required.
- EMS must have 64 **free** pages; 2 MB (128 pages) is enough.
- If the game reports *"No VESA compatibility driver found"*, the BIOS VBE is not being seen — that is a separate VGA/BIOS investigation (check INT 10h AX=4F00h), not a CPU issue.

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
