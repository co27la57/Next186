# Known issues

Open bugs in this port, with reproduction notes and current status.
Last updated: 2026-10-06.

---

## 1. VGA text mode: top/bottom half of the screen is swapped

**Status:** open, pre-existing (predates the Zynq port work)
**Severity:** cosmetic — text renders correctly, but the vertical order of
scanlines is wrong; the console occupies the bottom half of the screen and the
upper half shows the lower part of the frame.

**Symptom**

The display is legible, but the image is vertically displaced: the first rows
appear at the bottom and the last rows at the top. The set of characters shown
is correct; only the vertical scan order is inverted.

**Where it lives**

The VGA scan-out address generator in `ddr_186.v`. The relevant logic is
`vga_ddr_row_col` and the per-line advance that feeds `sdraddr`:

- `VGA_TEXT_ROWCOL` / `VGA_GRAPH_ROWCOL` (framebuffer base, in the author's
  "word" units, `×2` applied once at the output)
- `vga_lnbytecount` — doubles as *both* the per-transaction advance **and**
  the scanline-end predicate (`:1064` `s_vga_endscanline <=
  (vga_lnbytecount[7:3] == vga_lnend)`). These two roles are coupled, which is
  why simply doubling the advance produces a black screen rather than a
  vertical shift: `[7:3]` then walks in steps of two and trips the line-end
  comparison early.
- `sdraddr <= {5'b00001, vga_ddr_row_col + vga_lnbytecount - 5'd8, 1'b1}`
- `col_counter[3:1] <= col_counter[3:1] - vga_lnbytecount[2:0]` at
  `s_vga_endscanline`

The framebuffer base is already consolidated into the two `localparam`s (the
"single source of truth" change), so the remaining work is the scanline
advance / start-of-frame offset arithmetic, not the base.

**Note**

A previous attempt (`149th`, logged in the source) tried `k = 9'd480` and
regressed to horizontal skew plus garbage in the lower half; it was reverted to
the "stable upside-down" baseline at `k = 448`. The vertical swap is therefore
a known-stable failure mode, not a regression.

**Suggested next step**

Add an ILA probe on `sdraddr`, `vga_ddr_row_col`, `vga_lnbytecount` and
`s_vga_endscanline`; compare the first `sdraddr` of a frame against
`VGA_TEXT_ROWCOL` and confirm whether the per-line delta matches the intended
`80 × 2` bytes (one text row = 160 bytes = 80 × 16-bit words).

---

## 2. PS→PL keyboard injection: `j` renders as `4`; Enter/Backspace hang the console

**Status:** open — implementation was written, verified end-to-end, then
**rolled back** pending root-cause work. See "History" below.
**Severity:** functional (feature unusable), but does **not** affect the
existing VGA or PS/2 behaviour.

### 2.1 Goal

Inject keystrokes into the running 80186/DOS machine from the Linux side, so
the on-board PS/2 keyboard is not required. A physical USB keyboard was not
an option (the NeptUNO has no USB host port), so the transport is **PS EMIO
GPIO**, chosen specifically because it does **not** add an AXI slave and does
**not** disturb the DDR read path.

### 2.2 Transport — verified working

The data path was proven end-to-end: Linux wrote bytes through EMIO GPIO, they
traversed the PL, were injected into the 8042 output buffer, raised IRQ1, and
the 80186 rendered them on the VGA text screen.

```
Linux (sysfs GPIO bit-bang)  →  EMIO GPIO  →  PL receiver  →  8042 OBF
                             →  IRQ1  →  80186  →  DOS text screen
```

Two transports were built and measured:

| Transport | Result |
|---|---|
| 3-wire serial (SCLK/SDAT/SVAL, 17 GPIO writes/byte) | Worked, but **intermittent bit loss** (e.g. `0x24` → `0x04`) |
| **8-bit parallel + strobe (9 EMIO bits, 9 writes/byte)** | **Zero bit loss** — stable |

The serial version was abandoned in favour of parallel: with a bit-frame
transport, any jitter across 17 sysfs writes shifted a whole byte, and the
failure was not reliably reproducible. Parallel removes the failure mode
structurally (the byte is presented on 8 pins and latched on a strobe edge
after the data has settled).

> **Lesson:** enabling a PS master port (`M_AXI_GP0`) and adding an AXI
> interconnect on this design made the VGA scan-out unstable (VGA read
> timing). The DDR read path and the VGA scan-out engine share the same
> arbiter and a latency-sensitive capture window, so any change that shifts
> DDR read latency corrupts the display. **Do not add an AXI slave for this
> feature; use EMIO GPIO.**

### 2.3 Open bug A — `j` renders as `4`

**Reproduction**

```sh
./kb_inject -v      # or the GPIO build; see History
```

Press `j`. The program reports the correct scancode, and the byte is emitted
correctly, but DOS renders the character `4`:

```
[key] 'j'(0x6a) -> sc=0x24
[tx] 0x24
[tx] 0xa4
```

`j` is scancode `0x24`; the character `4` is what the firmware's translation
table produces for a *different* scancode. This is **100% reproducible**, not
intermittent.

**Ruled out**

- **Scancode table.** Verified against `images/BIOS/BIOS_Next186.asm`. The
  `KeyCode` table stores one `dw` per row as
  `dw 246ah, 244ah, 240ah, 2400h ;3b - J` — the **high byte `0x24` is the
  standard PS/2 set-1 scancode** and the **low byte `0x6a` is the ASCII**; the
  `3b` in the comment is a *table index*, not a scancode. `SCANCODE1 equ 1` is
  active. A→`0x1e`, j→`0x24`, k→`0x25`, 1→`0x16`, 4→`0x25`, 0→`0x0b` all agree
  with the standard table.
- **Transport.** The 8-bit parallel path shows zero bit loss; the emitted
  byte is correct on the wire.
- **Dropped bytes / handshake.** A missing `vk_ready` handshake in the first
  receiver revision could drop bytes, but that is an *intermittent* mechanism
  and cannot explain a 100% reproducible mapping error.

**Next step — add a probe, do not guess**

The receiver emitted the right byte on the wire, so the corruption is
downstream (8042 or firmware interpretation). Add an ILA probe on:

- `s_data` / `OBF` in `KB_8042.v` — what byte actually reaches the buffer
- `kb_shift` — whether the shift/break framing is intact
- the 80186 side of port `0x60` reads

A userspace probe mode is also available to bisect without hardware: send a
raw, known scancode (bypassing the key map) and observe what the firmware
renders.

### 2.4 Open bug B — Enter / Backspace hang the console

**Reproduction**

Press Enter or Backspace. DOS stops accepting further input; the console
locks up.

**Suspected area**

The 8042 output-buffer handshake. Enter (`0x1c`) and Backspace (`0x0e`) are
both control codes that the firmware's `int09` handler consumes differently
from ordinary keys, and both involve the `OBF`/`I_KB` path plus the
shift/flag state. Suspects, in order:

1. The injected byte is presented but the 8042 does not re-arm `OBF` for the
   following break code, so the firmware's `in al, 60h` never returns.
2. A break-code (`| 0x80`) is being dropped for these keys, leaving the
   firmware's key-state flags latched.
3. The `0xE0`-prefixed / extended-key path is being entered spuriously.

**Next step**

Same ILA probe set as 2.3, plus a state-machine trace of the firmware
`int09` path (`images/BIOS/BIOS_Next186.asm`, `int09` at line ~575) to see
where the byte stream stops matching expectations.

### 2.5 History

| Stage | Outcome |
|---|---|
| AXI4-Lite slave + SmartConnect + `M_AXI_GP0` | **Rejected** — destabilised VGA scan-out (see 2.2). Also incomplete: BIOS POST disabled the keyboard interface because the virtual keyboard never answered the self-test |
| Replaced with PS EMIO GPIO, 3-wire serial | Worked, intermittent bit loss |
| 8-bit parallel + strobe | Zero bit loss; `j`→`4` and Enter/Backspace hang remain open |
| Receiver `vk_ready` handshake (FIFO) | Correct robustness fix, but **does not explain** the deterministic `j`→`4`; retained as hardening only |
| Current tree | **Rolled back to pre-feature state** so the baseline is clean while root-causing 2.3/2.4 |

The injection RTL is intentionally **not** in the tree right now, so the
project returns to a known-good VGA baseline. The userspace tool and the
diagnosis above are the starting point for the next attempt.

---

## 3. Constraints: `foreach` unsupported in XDC

**Status:** fixed in-tree, noted to prevent regression.

Vivado's XDC reader supports only the XDC command subset, not full Tcl — a
`foreach` loop in `Network.xdc` raises
`[Designutils 20-1307] Command 'foreach' is not supported in the xdc
constraint file`. Any loop in a `.xdc` must be unrolled into explicit
commands.

Separately, the file previously contained a stray HTML `<br/>` that broke a
`set` statement and silently disabled the intended CDC
(`set_max_delay -datapath_only`) constraints on the VGA/system clock domain.
Both are corrected; keep loops out of `.xdc` when editing it.

---

## 4. Root layout duplicate (`imports/imports/`)

**Status:** workaround documented.

Some Vivado versions resolve the module reference through a nested
`imports/imports/` directory. Adding a new `.v` file only under `imports/`
can fail with `[Synth 8-439] module '...' not found`. Either add the file to
both directories or fix the project's source list. See the note in
`README.md`.

---

## 5. VGA text mode: screen content is cyclically rotated by 7 rows

**Status:** open
**Severity:** cosmetic — all characters render correctly and are in the right
column order; only the vertical assignment of rows is shifted.

**Symptom**

The text buffer appears on screen as if the whole frame had been rotated by
exactly **7 rows**: the top 7 lines of the buffer are displayed at the bottom
of the screen, and the first line of the buffer is displayed as row 8. The
rotation is a *cyclic shift of row order*, not a vertical mirror and not a
half-screen swap (see issue 1 for that separate failure mode).

**Where it lives (likely)**

Almost certainly the same neighbourhood as issue 1 — the VGA scan-out start
offset / per-line advance arithmetic in `ddr_186.v`
(`vga_ddr_row_col`, `vga_lnbytecount`, `sdraddr`), since the corruption is a
pure row-index permutation with no character damage:

- a constant start-of-frame offset of `k` rows reproduces exactly this
  signature — row 0 is fetched from framebuffer row `k`, wrapping at the end
  of the buffer. The observed shift of 7 rows corresponds to a start offset
  of `7 × 160 = 1120 bytes` (7 text rows = 7 × 80 16-bit words), if the
  offset is applied in byte/word units the same way as the per-line advance.
- it may also be the *same* root cause as issue 1 with a different constant
  (the "stable upside-down" baseline `k = 448` vs a 7-row offset), or an
  interaction between the base and the per-line advance. Not yet determined.

**Open questions**

- Is the 7-row rotation static, or does it drift/snap under keyboard activity
  or scrolling? (Issue 1's displacement was stable; confirm this one is too.)
- Does this manifest *instead of* the half-screen swap of issue 1 (i.e. after
  a change), or under different conditions? If the failure mode changed from
  "half swap" to "7-row rotation", the delta between the two experiments is
  the most informative signal we have.

**Suggested next step**

Same ILA probe set as issue 1 (`sdraddr`, `vga_ddr_row_col`,
`vga_lnbytecount`, `s_vga_endscanline`), but this time the check is cheaper:
capture the *first* `sdraddr` of a frame and compare it against
`VGA_TEXT_ROWCOL`. A difference of exactly `1120` bytes (or `560` word-units,
pre-`×2`) confirms a pure start-of-frame offset and reduces the fix to the
base/offset arithmetic — no per-line advance changes needed.

