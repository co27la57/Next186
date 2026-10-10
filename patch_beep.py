#!/usr/bin/env python3
# Patch the stage-1 bootloader (Next186_BlackBoxes.v cache ram[]) to beep
# once right before it reads the SD card to load the 2nd-stage BIOS.
#
# Strategy (verified against disassembly):
#   * Call site: replace the 5 bytes at 0x004B (xor bx,bx / call 0x6a) with
#     "call beep" + 2 NOPs. beep re-executes xor bx,bx ; call 0x6a so the
#     SD read still happens with identical registers/flags.
#   * beep routine placed at 0x030D (inside the "waiting on RS232" string
#     data region, only shown on SD-fail fallback, so normal boot is clean).
#   * beep preserves ax,cx (dx,bx untouched by its code) and uses the existing
#     delay routine at 0x3eb.
import re, shutil, sys

VFILE = r"D:\Xilinx\workspace\Next186\Network\Network.srcs\sources_1\imports\Next186_BlackBoxes.v"
BAK   = VFILE + ".bak_beep"

# ---------- 1. parse current ram[] (0x000..0x0FF) ----------
txt = open(VFILE, encoding="utf-8", errors="ignore").read()
pat = re.compile(r"ram\[11'h([0-9A-Fa-f]{3})\]\s*=\s*32'h([0-9A-Fa-f]{8})")
words = {}
for m in pat.finditer(txt):
    idx = int(m.group(1), 16)
    words[idx] = int(m.group(2), 16)
assert len(words) == 256, f"expected 256 ram[] entries, got {len(words)}"

def pack_le(w):
    return bytes([w & 0xFF, (w>>8)&0xFF, (w>>16)&0xFF, (w>>24)&0xFF])
def unpack_le(b):
    return b[0] | (b[1]<<8) | (b[2]<<16) | (b[3]<<24)

orig = bytearray()
for i in range(0x100):
    orig += pack_le(words[i])
assert len(orig) == 1024
orig = bytes(orig)

# ---------- 2. build the beep routine ----------
# helper: append instruction bytes, tracking running address
beep = bytearray()
base = 0x030D
def here(): return base + len(beep)
def emit(bs): beep.extend(bs)
def emit_call(target):
    # E8 + rel16 (signed) ; next instr addr = here()+3
    rel = (target - (here()+3)) & 0xFFFF
    emit(bytes([0xE8, rel & 0xFF, (rel>>8)&0xFF]))

emit(bytes([0x50]))            # push ax
emit(bytes([0x51]))            # push cx  (NOTE: 0x51=push cx, 0x59=pop cx!)
emit(bytes([0xB0, 0xB6]))      # mov al, 0B6h
emit(bytes([0xE6, 0x43]))      # out 43h, al
emit(bytes([0xB8, 0xD0, 0x07]))# mov ax, 07D0h   (divisor 2000 -> ~596Hz)
emit(bytes([0xE6, 0x42]))      # out 42h, al
emit(bytes([0x88, 0xE0]))      # mov al, ah   (88 E0 = mov al,ah; NOTE 88 F8 would be mov al,bh)
emit(bytes([0xE6, 0x42]))      # out 42h, al
emit(bytes([0xE4, 0x61]))      # in al, 61h
emit(bytes([0x0C, 0x03]))      # or al, 03h     (speaker on)
emit(bytes([0xE6, 0x61]))      # out 61h, al
# --- self-contained delay loop ---
# CRITICAL: 0x3eb is NOT a returnable delay routine. It ends in
#   "ljmp 0xf000:0xfc00" and never returns, so CALLing it abandons this
#   routine (speaker never turned off, SD read never re-executed). Use a
#   private nested loop instead, mirroring the original BIOS `bell`:
#   ~0x40 * 0x88B8 (~2.24M iters) ~= 0.5s @40MHz -> clearly audible.
# Uses cx (saved) and bx (re-zeroed later by xor bx,bx).
emit(bytes([0xBB, 0x40, 0x00]))   # mov bx, 0x40      (outer counter)
emit(bytes([0xB9, 0xB8, 0x88]))   # mov cx, 0x88B8    (inner counter)
emit(bytes([0xE2, 0xFE]))         # loop -2           (inner loop)
emit(bytes([0x4B]))                # dec bx
emit(bytes([0x75, 0xF8]))          # jnz -8           (outer loop -> reload cx; bx stays decremented)
# --- speaker off ---
emit(bytes([0xE4, 0x61]))      # in al, 61h
emit(bytes([0x24, 0xFE]))      # and al, 0FEh   (speaker off)
emit(bytes([0xE6, 0x61]))      # out 61h, al
emit(bytes([0x59]))            # pop cx
emit(bytes([0x58]))            # pop ax
emit(bytes([0x33, 0xDB]))      # xor bx, bx      (re-execute dropped)
emit_call(0x6a)                # call 0x6a       (re-execute SD read)
emit(bytes([0xC3]))            # ret

beep = bytes(beep)
print(f"[build] beep routine = {len(beep)} bytes at 0x{base:04X} .. 0x{base+len(beep)-1:04X}")

# ---------- 3. apply patches to a copy ----------
new = bytearray(orig)
# (a) beep routine into data region
assert base + len(beep) <= 0x360, "beep overflows data region"
new[base:base+len(beep)] = beep
# (b) call site at 0x004B
# CALL (E8+imm16) is 3 bytes; its IP-after = 0x004B+3 = 0x004E, then the 2 NOPs
# follow at 0x004E/0x004F. The 80186 computes target = IP_after + disp.
call_disp = (base - (0x004B + 3)) & 0xFFFF   # -> target 0x030D
assert call_disp < 0x8000, "call disp must be positive (same segment)"
new[0x004B:0x0050] = bytes([0xE8, call_disp & 0xFF, (call_disp>>8)&0xFF, 0x90, 0x90])

# ---------- 4. VERIFY against the patch (before touching the file) ----------
ok = True
def check(cond, msg):
    global ok
    if not cond:
        ok = False
        print("  [FAIL]", msg)
    else:
        print("  [ok]  ", msg)

# 4a. call site decodes to "call 0x30d"
check(new[0x004B]==0xE8 and new[0x004C]==(call_disp&0xFF) and new[0x004D]==((call_disp>>8)&0xFF),
      f"call site 0x004B = E8 {call_disp&0xFF:02X} {(call_disp>>8)&0xFF:02X} (->0x{base:04X})")
check(new[0x004E]==0x90 and new[0x004F]==0x90, "0x004E/0x004F filled with NOP")
# 4b. beep starts with push ax / push cx
check(new[base]==0x50 and new[base+1]==0x51, "beep starts push ax; push cx (0x51, NOT 0x59=pop cx)")
# 4b'. stack-balance / register-save invariant: exactly push ax, push cx,
#     pop cx, pop ax, in that order, so the routine is stack-neutral.
# pop cx at base+42 (beep[-8]); pop ax at base+43 (beep[-7]); then xor bx,bx/call/ret follow
check(beep[0]==0x50 and beep[1]==0x51 and beep[-8]==0x59 and beep[-7]==0x58,
      "push/pop balanced: push ax; push cx ... pop cx; pop ax (stack-neutral)")
# 4c. speaker-off sequence near end; ends with xor bx,bx; call 0x6a; ret
# layout (46 bytes): speaker-on or at +0x11; delay loop +0x15..+0x1F;
#   in al,61h(+0x20) and al,0FEh(+0x22) out 61h,al(+0x24)
#   pop cx(+0x26) pop ax(+0x27) xor bx,bx(+0x28) call 0x6a(+0x2A) ret(+0x2D)
check(new[base+0x20]==0xE4 and new[base+0x21]==0x61, "in al,61h (speaker-off read)")
check(new[base+0x22]==0x24 and new[base+0x23]==0xFE, "and al,0FEh (speaker off)")
check(new[base+0x24]==0xE6 and new[base+0x25]==0x61, "out 61h,al (speaker off)")
check(new[base+0x28]==0x33 and new[base+0x29]==0xDB, "xor bx,bx (re-execute dropped)")
check(new[base+0x2A]==0xE8, "call 0x6a (re-execute SD read)")
inner_rel = new[base+0x2B] | (new[base+0x2C]<<8)
inner_target = (base+0x2A+3 + inner_rel) & 0xFFFF
check(inner_target==0x6a, f"inner call target = 0x{inner_target:04X} (expect 0x006a)")
check(new[base+0x2D]==0xC3, "ret at end of beep")
# 4c'. DELAY LOOP must be a private nested loop, NOT a call to 0x3eb.
#     0x3eb ends in "ljmp 0xf000:0xfc00" and never returns, so CALLing it
#     would abandon this routine (speaker stays on, SD read skipped). Guard it.
DELAY_SIG = bytes([0xBB,0x40,0x00, 0xB9,0xB8,0x88, 0xE2,0xFE, 0x4B, 0x75,0xF8])
check(beep[0x15:0x15+len(DELAY_SIG)]==DELAY_SIG,
      "delay = private nested loop (mov bx,0x40; mov cx,0x88B8; loop; dec bx; jnz)")
check(beep.count(0xE8)==1, "beep has exactly ONE call (to 0x6a); NO call to non-returning 0x3eb")
# 4d. spot-check PIT/speaker programming bytes (unchanged layout)
check(new[base+2]==0xB0 and new[base+3]==0xB6, "mov al,0B6h (PIT mode)")
check(new[base+4]==0xE6 and new[base+5]==0x43, "out 43h,al")
check(new[base+6]==0xB8 and new[base+7]==0xD0 and new[base+8]==0x07, "mov ax,07D0h (divisor)")
check(new[base+11]==0x88 and new[base+12]==0xE0, "mov al,ah (high byte of divisor -> port 42h) NOT bh")
check(new[base+0x0F]==0xE4 and new[base+0x10]==0x61, "in al,61h (speaker on read)")
check(new[base+0x11]==0x0C and new[base+0x12]==0x03, "or al,03h (speaker on)")
# 4e. full byte diff: ONLY the expected regions changed
changed = [i for i in range(1024) if new[i]!=orig[i]]
expected_changed = set(range(0x004B,0x0050)) | set(range(base, base+len(beep)))
check(set(changed)==expected_changed,
      f"changed bytes == expected set (n={len(changed)} vs {len(expected_changed)})")
if set(changed)!=expected_changed:
    extra = sorted(set(changed)-expected_changed)
    missing = sorted(expected_changed-set(changed))
    print("    unexpected changed:", extra[:20])
    print("    expected-but-unchanged:", missing[:20])

if not ok:
    print("\n[ABORT] verification failed, NOT modifying the file.")
    sys.exit(1)

# ---------- 5. re-pack and produce new ram[] lines, apply to v file ----------
new_words = {}
for i in range(0x100):
    new_words[i] = unpack_le(new[4*i:4*i+4])

# backup (only if not already backed up)
import os
if not os.path.exists(BAK):
    shutil.copyfile(VFILE, BAK)
    print(f"[backup] saved {BAK}")
else:
    print(f"[backup] already exists: {BAK}")

# Replace ONLY real assignment lines (skip '//' comment lines) and only when
# the value actually changed, to keep the diff minimal and clean.
changed_lines = 0
out_lines = []
for line in txt.split("\n"):
    st = line.strip()
    if st.startswith("ram[11'h") or st.startswith("ram[11'H"):
        m = pat.search(line)
        if m:
            idx = int(m.group(1), 16)
            if new_words[idx] != words[idx]:
                line = pat.sub(f"        ram[11'h{idx:03X}] = 32'h{new_words[idx]:08X};",
                               line, count=1)
                changed_lines += 1
    out_lines.append(line)
new_txt = "\n".join(out_lines)
open(VFILE, "w", encoding="utf-8").write(new_txt)
print(f"[apply] modified {changed_lines} ram[] lines in {VFILE}")

# ---------- 6. FINAL verification: re-read the written file and diff ----------
txt2 = open(VFILE, encoding="utf-8", errors="ignore").read()
words2 = {int(x.group(1),16):int(x.group(2),16) for x in pat.finditer(txt2)}
rebuilt = bytes().join(pack_le(words2[i]) for i in range(0x100))
assert len(rebuilt)==1024
final_changed = [i for i in range(1024) if rebuilt[i]!=orig[i]]
ok2 = (set(final_changed)==expected_changed)
print(f"[verify] re-read file -> changed bytes match expected: {ok2} "
      f"(n={len(final_changed)})")
assert ok2, "FINAL verification mismatch!"

# Also disassemble the patched call site + beep to show it decodes cleanly
from capstone import Cs, CS_ARCH_X86, CS_MODE_16
md = Cs(CS_ARCH_X86, CS_MODE_16)
print("\n[disasm] patched call site + beep routine:")
for ins in md.disasm(rebuilt[0x004B:0x0050] + rebuilt[base:base+len(beep)], 0x004B):
    print(f"0x{ins.address:04X}: {ins.bytes.hex():14} {ins.mnemonic} {ins.op_str}")
print("\n[SUCCESS] bootloader now beeps before the SD read; original backed up to .bak_beep")
