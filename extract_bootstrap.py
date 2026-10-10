#!/usr/bin/env python3
# Extract the stage-1 bootloader (first 1KB) from Next186_BlackBoxes.v cache ram[]
# and disassemble it (16-bit x86) for analysis. Also sanity-checks byte layout
# by searching for known ASCII strings.
import re, sys
from capstone import Cs, CS_ARCH_X86, CS_MODE_16

VFILE = r"D:\Xilinx\workspace\Next186\Network\Network.srcs\sources_1\imports\Next186_BlackBoxes.v"

txt = open(VFILE, encoding="utf-8", errors="ignore").read()
pat = re.compile(r"ram\[11'h([0-9A-Fa-f]{3})\]\s*=\s*32'h([0-9A-Fa-f]{8})")
words = {}
for m in pat.finditer(txt):
    idx = int(m.group(1), 16)
    val = int(m.group(2), 16)
    words[idx] = val

print(f"[parse] explicit ram[] assignments found: {len(words)} (expect 256 for 0x000..0x0FF)")
missing = [f"0x{i:03X}" for i in range(0x100) if i not in words]
if missing:
    print(f"[parse] MISSING indices: {missing[:20]} ... total {len(missing)}")

def build(le):
    b = bytearray()
    for i in range(0x100):
        w = words.get(i, 0)
        if le:
            b += bytes([w & 0xFF, (w>>8)&0xFF, (w>>16)&0xFF, (w>>24)&0xFF])
        else:
            b += bytes([(w>>24)&0xFF, (w>>16)&0xFF, (w>>8)&0xFF, w&0xFF])
    return bytes(b)

le = build(True)
be = build(False)
open("boot_le.bin","wb").write(le)
open("boot_be.bin","wb").write(be)

def find_str(b, s):
    p = b.find(s.encode())
    return p

for name, b in [("LE", le), ("BE", be)]:
    for s in ["SD Card", "RS232", "Searching", "waiting"]:
        p = find_str(b, s)
        if p >= 0:
            # print surrounding context
            seg = b[max(0,p-12):p+len(s)+12]
            print(f"[{name}] found {s!r} at byte offset 0x{p:04X} (word 0x{p//4:03X}): {seg!r}")

# Disassemble LE from 0; also print a clean hex+ascii map
md = Cs(CS_ARCH_X86, CS_MODE_16)
md.detail = False
with open("boot_disasm.txt","w") as f:
    for ins in md.disasm(le, 0):
        f.write(f"0x{ins.address:04X}: {ins.bytes.hex():16} {ins.mnemonic} {ins.op_str}\n")

# Find longest run of a single repeated byte (candidate padding / free space)
best = (0,0,0)
i = 0
n = len(le)
while i < n:
    j = i
    while j < n and le[j] == le[i]:
        j += 1
    run = j - i
    if run > best[0]:
        best = (run, i, le[i])
    i = j
print(f"\n[free-space] longest identical-byte run: len={best[0]} at byte 0x{best[1]:04X} (word 0x{best[1]//4:03X}), byte=0x{best[2]:02X}")
# Also report all runs >= 8 of 0x00 or 0x90
print("[free-space] runs >= 8 bytes of 0x00 or 0x90:")
i = 0
while i < n:
    j = i
    while j < n and le[j] in (0x00, 0x90) and le[j]==le[i]:
        j += 1
    run = j - i
    if run >= 8:
        print(f"   len={run} at 0x{i:04X} (word 0x{i//4:03X}) byte=0x{le[i]:02X}")
    i = j

# Compact hex+ascii map for manual inspection
print("\n[hexmap]")
for off in range(0, n, 16):
    chunk = le[off:off+16]
    hexs = " ".join(f"{b:02X}" for b in chunk)
    asc = "".join(chr(b) if 32<=b<127 else "." for b in chunk)
    print(f"0x{off:04X}: {hexs:48} {asc}")
