# Next186 — EBAZ4205 (Zynq-7010) FPGA Port

A Zynq-7000 FPGA port of the **Next186** processor core, targeting the
**EBAZ4205** development board (Xilinx Zynq-7010, XC7Z010-CLG400-1) — a
repurposed, resource-constrained board quite different from the upstream
target, which is precisely why the port required substantial rework.

The design runs a **two-processor heterogeneous system**: a legacy 80186-class
CPU in the programmable logic, and an ARM Cortex-A9 running Linux in the
processing system. The 80186 side executes a PC-compatible firmware stack
(bootloader → BIOS → DOS), which is what makes VGA text/graphics output,
PS/2 input, SD-card booting and PC audio possible on the same board.

**Current state (2026-10-24):** remote `origin/main` = `b89ee21`. VGA baseline
= `d237a4f` (tag **`vga-stable-20261021`**, board-verified 2026-10-21). Two
issues are open — PCM (DSS/Covox) audio output and a VGMSLAP text truncation —
see [KNOWN_ISSUES.md](KNOWN_ISSUES.md) #6 and #7.

---

## Table of contents

- [Background](#background)
- [Hardware platform](#hardware-platform)
- [Architecture](#architecture)
- [Memory map](#memory-map)
- [Peripherals](#peripherals)
- [Repository layout](#repository-layout)
- [Building](#building)
- [Known issues](#known-issues)
- [Acknowledgements](#acknowledgements)

---

## Background

Next186 is an open-source 80186/Z80-compatible processor core. The upstream
project targets the **NeptUNO** FPGA board and is organised around a
`neptuno-fpga` integration branch that maps the core onto that board's
peripherals.

This repository is a **port of that work onto a different board entirely**: the
**EBAZ4205** (Zynq-7010, XC7Z010-CLG400-1) — re-hosting the 80186 core in the
PL and wiring its system bus to the PS-side DDR3 through the PS/PL AXI path.
The port keeps the original core sources (`Next186_*`, `NextZ80*`) intact and
concentrates board-, bus- and peripheral-level changes in the surrounding
modules, so that re-syncing with upstream core updates stays tractable.

Re-targeting to the EBAZ4205 is the main source of the work in this repository:
the XC7Z010's fabric is far smaller than the upstream target, the board's DDR3
sits behind the PS (so every memory access crosses the PS/PL AXI path), and none
of the upstream board-level infrastructure applies. The memory interface,
write-back cache and top-level AXI protocol were therefore rewritten for this
board rather than adapted.

The port exists because the Zynq-7000's PS is comparatively weak for legacy
software: the 80186 core in the PL provides a real 8086-class machine with
cycle-accurate bus timing, which the original PC software (BIOS, DOS, drivers)
expects.

---

## Hardware platform

| Item | Detail |
|---|---|
| FPGA | Xilinx Zynq-7010 (XC7Z010-CLG400-1) on the EBAZ4205 board |
| PL fabric | Hosts the Next186 CPU core, DDR3 controller arbitration, VGA, PS/2, SD, UART, audio |
| PS | Zynq dual-core ARM Cortex-A9, runs PetaLinux (Linux) |
| System memory | 256 MB DDR3 on the PS (device tree: `SEG_processing_system7_0_HP0_DDR_LOWOCM`, 32 MB usable window) |
| PL clock | FCLK0 = 50 MHz |
| Toolchain | Vivado 2025.2 |

---

## Architecture

```
                     ┌────────────────────────── Zynq-7000 ──────────────────────────┐
                     │                                                                │
  SD card ──► stage-1 ──►  stage-2  ──►  ┌──────────── PL (programmable logic) ───────────┐ │
  bootloader   loader      BIOS     │  │  Next186 CPU core (80186-class)                  │ │
  (BlackBoxes) (a.asm)   (BIOS_Next186)  NextZ80 CPU (boot monitor / assist)              │ │
                     │            │  │            │                                     │ │
                     │            │  │      Next186_SoC  ──  system  (ddr_186.v)            │ │
                     │            │  │            │              │                      │ │
                     │            │  │            │        ┌─────┴─────┐                │ │
                     │            │  │            │        │  cache     │                │ │
                     │            │  │            │        │ controller │                │ │
                     │            │  │            │        └─────┬─────┘                │ │
                     │            │  │            │              │ bus arbiter             │ │
                     │            │  │            │   ┌──────────┼──────────┐              │ │
                     │            │  │            │   │          │          │              │ │
                     │            │  │            │  VGA     PS/2 kb   PS/2 mouse       │ │
                     │            │  │            │  KB_8042  UART_8250   soundwave       │ │
                     │            │  │            │                              audio    │ │
                     │            │  │            │                                       │ │
                     │            │  └────────────┼───────────────────────────────────────┘ │
                     │            │               │  m_axi (AXI3/AXI4 burst master)        │ │
                     │            └───────────────┼────────────────────────────────────────┘ │
                     │                            ▼                                        │ │
                     │            ┌───────────────────────────────┐                         │
                     │            │  PS: processing_system7        │                         │ │
                     │            │   S_AXI_HP0 ◄── DDR3          │                         │ │
                     │            │   Cortex-A9 → PetaLinux       │                         │ │
                     │            └───────────────────────────────┘                         │
                     └────────────────────────────────────────────────────────────────────────┘
```

The 80186 core does **not** own DDR3 directly. It drives an internal
`ram_cmd` / `ram_addr` / `ram_wdata` burst interface that `system`
(`ddr_186.v`) arbitrates between the CPU, the VGA scan-out engine and the
write-back cache (`cache_controller.v`). That arbiter is exported to the PS as a
burst AXI master on `m_axi`, crossing to DDR3 via the PS `S_AXI_HP0` port.

### CPU cores

| File(s) | Role |
|---|---|
| `Next186_CPU.v`, `Next186_ALU.v`, `Next186_BIU_2T_delayread.v`, `Next186_Regs.v` | 80186-class core: BIU with delayed-read bus cycle, ALU, register file |
| `NextZ80CPU.v`, `NextZ80ALU.v`, `NextZ80Reg.v` | Z80-class core used by the boot monitor |
| `unit186.v`, `Next186_SoC.v` | SoC wrappers instantiating the cores + peripherals |

### Firmware

| Stage | Location | Function |
|---|---|---|
| Stage-1 | `Next186_BlackBoxes.v` (embedded RAM image) | SD-card bootloader, loads stage-2 |
| Stage-2 | `images/BIOS/bootload*` | Bootstrap to the full BIOS image |
| BIOS | `images/BIOS/BIOS_Next186.asm` → `bios.mem` | PC-compatible BIOS (INT 9/10h/16h, PS/2 controller, cache config) |
| Video BIOS | `images/*.mem` (EGA/VGA palettes, `font8x16.mem`) | Character/bitmap fonts loaded at boot |

### Video subsystem (VGA)

`vga.v` / `VGA_SG` model the EGA/VGA CRTC and timing; the scan-out engine in
`ddr_186.v` fetches the framebuffer from DDR through a 16-bit-write /
32-bit-read async FIFO and re-synchronises fetch and display at every vblank
(`VGA_FS_*` FSM: stop → drain → FIFO reset → wait XPM reset-busy → prefetch from
the frame base). The display side pops at most `vga_line_quota` words per
scanline (text 48 / mode-13h 88 / planar 168). The board-verified baseline is
**`d237a4f`** (tag `vga-stable-20261021`); do not change the frame-start reset
order, the per-line quota, or the address units without simulating first — see
`sim/vga_verify/README.md` and `sim/CODEX-VGA-STATUS.md`.

### Audio subsystem

Four sources are summed in `soundwave.v` with a 19-bit signed accumulator and
saturate to 16 bits after the master attenuation (`master_att`, port `0x38C`,
right-shift 0..8):

| Source | Path |
|---|---|
| OPL3 / Adlib FM | `opl3_ym.v` (nukeykt **YMF262** core, `ymf262.sv` + `ym_lib.sv`), real register writes on `0x388/0x389`, MCLK = 50 MHz, 8 µs/byte replay — feeds the mixer directly |
| PCM (DSS / Covox) | byte/word writes to port `0x378` → `sndfifo` sample queue → mixer (see KNOWN_ISSUES #6 — currently broken) |
| MIDI | `mpu401.v` + `i2s_decoder.v` → `midi_left/right` |
| PC speaker | port `0x61` + `timer8253` channel 2 → +2048 offset in the mixer |

Outputs: **I2S** (`audio_top.vhd` + `dac_if.vhd`, signed two's-complement PCM,
MSB first — silence = `0x0000`) and **PDM** (`AUDIO_L/R` 1-bit, offset-binary
code where silence = mid-scale). Runtime volume: `0x38C` (attenuation),
`0x38D` (version id, read `0x40|(ovf<<1)|vol_hit`), `0x38E` (master);
`tools/oplvol.com` adjusts it from DOS without DEBUG.

---

## Memory map

The 80186's physical address space is mapped into the PS DDR3 window. The PL AXI
master presents the CPU address space at a fixed offset, so the same core
sources work across memory sizes.

| 80186 region | Contents | Notes |
|---|---|---|
| `0x00000`–`0x9FFFF` | VGA framebuffer (MDA/CGA/EGA/VGA apertures) | Text mode base `0xB8000`, graphics `0xA0000`; see `VGA_TEXT_ROWCOL` / `VGA_GRAPH_ROWCOL` in `ddr_186.v` |
| `0xE0000`–`0xFFFFF` | Stage-2 BIOS (F000:E000) | Loaded from SD by stage-1 |
| `0xF0000`–`0xFFFFF` | Option ROMs / boot | Legacy PC layout preserved |
| Above | DDR3 (via `m_axi` → `S_AXI_HP0`) | 32 MB window in the PetaLinux device tree |

---

## Peripherals

| Peripheral | File(s) | Notes |
|---|---|---|
| VGA | `vga.v`, `VGA_SG` (in `ddr_186.v`) | RGB565 output, text + planar/chain4 graphics, CRTC modelled after the EGA/VGA register set; scan-out through the async FIFO described above |
| PS/2 controller | `KB_8042.v`, `PS2Interface.v` | 8042-compatible: command/config byte, OBF, mouse channel |
| Keyboard/mouse | `PS2Interface.v`, `kbd_gpio_rx.v` | Dual channel (`PS2_CLKA/PS2_DATAA`, `PS2_CLKB/PS2_DATAB`); PS→PL injection over EMIO GPIO with FIFO + rdy handshake |
| UART | `UART_8250.v`, `simple_uart.vhd` | RS-232 debug console |
| SD card | bootstrap in `Next186_BlackBoxes.v` | Used to boot stage-1/stage-2 |
| Audio | `soundwave.v`, `audio_top.vhd`, `dac_if.vhd`, `opl3_ym.v`, `ymf262.sv`, `ym_lib.sv`, `mpu401.v`, `i2s_decoder.v` | Mixer + OPL3 + I2S/PDM output, see the audio subsystem section |
| Cache | `cache_controller.v` | Write-back cache in front of DDR3; `cache_line_start` / flush logic |
| Interrupt | `PIC_8259.v` | 8259 pair for the 80186 interrupt map |
| DSP | `DSP32.v` | 32-bit multiply/accumulate assist used by the audio path |

---

## Repository layout

```
├── README.md                  ← this file
├── KNOWN_ISSUES.md            ← open bugs, with reproduction notes
├── AI交接说明-2-数据损坏排错.md  ← handoff: cache↔DDR data-corruption investigation
├── Next186_*.v                ← 80186 core (upstream, unmodified)
├── NextZ80*.v                 ← Z80 core (upstream, unmodified)
├── Next186_SoC.v              ← SoC wrapper: cores + system + peripherals
├── unit186.v                  ← unit wrapper
├── ddr_186.v                  ← system: bus arbiter, VGA scan-out, PS/2, cache glue
├── cache_controller.v         ← write-back cache
├── vga.v                      ← VGA controller
├── KB_8042.v                  ← 8042 keyboard/mouse controller
├── PS2Interface.v             ← PS/2 wire-level encoder/decoder
├── kbd_gpio_rx.v              ← PS→PL keyboard/mouse injection receiver (EMIO GPIO)
├── UART_8250.v                ← 8250 UART
├── soundwave.v                ← audio mixer (OPL3 + PCM/DSS + MIDI + speaker)
├── audio_top.vhd / dac_if.vhd / i2s_decoder.v ← I2S serialiser + MIDI decode
├── opl3_ym.v / ymf262.sv / ym_lib.sv          ← OPL3 core (nukeykt YMF262) + adapter
├── dcm.v / dcm_cpu.v          ── clock management
├── tools/                     ← DOS helpers (oplvol.com) and notes
├── sim/                       ← Verilator harnesses: vga_verify, opl3_output_review,
│                                ddr_pipe cache/DDR bench, ILA notes, findings
├── images/
│   ├── BIOS/                  ← BIOS sources, bootloader, VGA font/palette .mem
│   └── *.mem                  ← palette / font binaries baked into the bitstream
├── *.mem                      ← stage-2/boot images baked into the bitstream
└── Next186_SoC-master/        ← local reference copy of the upstream tree (git-ignored)
```

---

## Building

1. Open the enclosing Vivado project (`Network.xpr`) targeting the EBAZ4205
   (XC7Z010).
2. The PL design instantiates `top_zynq7010` as an out-of-context module
   reference; add this repository to the project's sources.
3. The PS configuration provides `FCLK_CLK0`, DDR3, and `S_AXI_HP0`; the PL AXI
   master `m_axi` is connected through `axi_mem_intercon` to `S_AXI_HP0`.
4. Generate bitstream, program, and boot PetaLinux from the SD card.
5. The 80186 firmware images (`*.mem`, `bios.mem`) are baked into the bitstream
   by `Next186_BlackBoxes.v`; change them there and re-synthesise.
6. When changing ILA probes: `reset_run synth_1; reset_run impl_1` and rebuild
   the debug cores (delete + Set Up Debug), otherwise the OOC flow fails.

> **Note on the `imports/imports/` path:** some Vivado versions resolve module
> references through a nested `imports/` directory. If you add a new `.v` file
> and hit `module not found`, place a copy in both `imports/` and
> `imports/imports/`.

---

## Known issues

See **[KNOWN_ISSUES.md](KNOWN_ISSUES.md)** for the full list with reproduction
notes. Summary as of 2026-10-29:

| # | Issue | Status |
|---|---|---|
| 6 | PCM (DSS/Covox, port `0x378`) produces no audio — only Adlib is audible | **open** — `sndfifo` 16/32-bit width mismatch + Covox byte packing DC offset + unreachable `full` threshold; fix drafted in KNOWN_ISSUES #6.5 |
| 7 | VGMSLAP text lines show only about half of their characters | **open** — check for the reverted step-doubling change first (`dcdfb1a`), then the high-load VGA underrun; see #7 |
| 9 | Lotus: The Ultimate Challenge runs at exactly 2x speed | **root cause found** — `timer8253.v` mode 3 reloads N/2 but steps by 2, so the PIT output is 2x; BIOS divisor `0` hides it, Lotus's per-frame divisor exposes it. One-line fix + patch in #9 |
| 1, 5 | VGA vertical half-swap / 7-row rotation | **fixed** by `d237a4f` (tag `vga-stable-20261021`) |
| 2 | Keyboard injection `j`→`4`, Enter/Backspace hang | **fixed in tree**, board re-verification pending |
| 3, 4 | XDC `foreach`; `imports/imports/` layout | fixed / workaround documented |

Preserve tag **`vga-stable-20261021`** as the VGA baseline; the repair report
and the reproducible Verilator regression live in `sim/vga_verify/`.

---

## Acknowledgements

- The **Next186** processor core and the original NeptUNO FPGA integration
  (upstream `neptuno-fpga` branch).
- The **NeptUNO** board design and toolchain.
- **nukeykt** for the YMF262 (OPL3) core used by `opl3_ym.v`.
