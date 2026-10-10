#!/usr/bin/env python3
# Independent verification of the patched bootloader.
import re
from capstone import Cs, CS_ARCH_X86, CS_MODE_16
VFILE = r"D:\Xilinx\workspace\Next186\Network\Network.srcs\sources_1\imports\Next186_BlackBoxes.v"
txt = open(VFILE, encoding="utf-8", errors="ignore").read()
pat = re.compile(r"ram\[11'h([0-9A-Fa-f]{3})\]\s*=\s*32'h([0-9A-Fa-f]{8})")
w = {int(m.group(1),16):int(m.group(2),16) for m in pat.finditer(txt)}
b = bytearray()
for i in range(0x100):
    v = w.get(i,0)
    b += bytes([v&0xFF,(v>>8)&0xFF,(v>>16)&0xFF,(v>>24)&0xFF])
b = bytes(b)
assert len(b)==1024

# 1) call site
print("call site 0x004B:", b[0x004B:0x0050].hex(), "(expect e8bf029090 -> target 0x030D)")
assert b[0x004B:0x0050]==bytes([0xE8,0xBF,0x02,0x90,0x90]), "call site mismatch"
# compute the REAL 80186 near-call target (IP_after = 0x004B + 3) to guard against off-by-2
_disp = b[0x004C] | (b[0x004D]<<8)
_call_target = (0x004B + 3 + _disp) & 0xFFFF
print(f"[verify] call 0x004B real CPU target = 0x{_call_target:04X} (must be 0x030D)")
assert _call_target == 0x030D, "call does NOT land on beep start 0x030D (off-by-N bug)"

# 2) beep at its REAL address 0x030D
md = Cs(CS_ARCH_X86, CS_MODE_16)
print("\n--- beep routine disassembled at REAL address 0x030D ---")
for ins in md.disasm(b[0x030D:0x030D+46], 0x030D):
    print(f"0x{ins.address:04X}: {ins.bytes.hex():10} {ins.mnemonic} {ins.op_str}")

# 3) the original code path around the call site unchanged except the call
print("\n--- context 0x0000..0x0050 (only 0x004B changed) ---")
for ins in md.disasm(b[0x0000:0x0050], 0x0000):
    mark = "  <-- PATCHED" if ins.address==0x004B else ""
    print(f"0x{ins.address:04X}: {ins.bytes.hex():10} {ins.mnemonic} {ins.op_str}{mark}")

# 4) confirm 0x0000..0x004A bytes equal original cached extract (compare to backup)
bak = open(r"D:\Xilinx\workspace\Next186\Network\Network.srcs\sources_1\imports\Next186_BlackBoxes.v.bak_beep",encoding="utf-8",errors="ignore").read()
wb = {int(m.group(1),16):int(m.group(2),16) for m in pat.finditer(bak)}
ob = bytearray()
for i in range(0x100):
    v = wb.get(i,0); ob += bytes([v&0xFF,(v>>8)&0xFF,(v>>16)&0xFF,(v>>24)&0xFF])
ob = bytes(ob)
unchanged_pre = all(b[i]==ob[i] for i in range(0x0000,0x004B))
unchanged_post = all(b[i]==ob[i] for i in range(0x0050,0x030D))
unchanged_tail = all(b[i]==ob[i] for i in range(0x033B,0x0400))
print("\n[verify] 0x0000-0x004A identical to original:", unchanged_pre)
print("[verify] 0x0050-0x030C identical to original:", unchanged_post)
print("[verify] 0x033B-0x03FF identical to original:", unchanged_tail)
assert unchanged_pre and unchanged_post and unchanged_tail
# guard: delay must be a private nested loop, NOT a call to non-returning 0x3eb
DELAY_SIG = bytes([0xBB,0x40,0x00, 0xB9,0xB8,0x88, 0xE2,0xFE, 0x4B, 0x75,0xF8])
assert b[0x030D+0x15:0x030D+0x20]==DELAY_SIG, "beep delay is NOT the private nested loop"
assert b[0x030D:0x030D+46].count(0xE8)==1, "beep must contain exactly one call (to 0x6a), no call to 0x3eb"
print("\n[INDEPENDENT VERIFY OK] Only the call site (0x004B) and beep region (0x030D-0x033A) changed; all other bootloader bytes are byte-identical to the original.")
