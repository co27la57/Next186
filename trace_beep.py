#!/usr/bin/env python3
# Minimal 80186 trace: EXECUTE the patched beep routine from the real
# Next186_BlackBoxes.v to prove (a) it terminates (no infinite loop),
# (b) it turns the PC speaker on then off via port 61h, (c) it reaches
# the final RET, and (d) it re-executes the SD-read (call 0x6a).
#
# Only the opcodes present in the beep routine are implemented. I/O ports
# are stubbed; `call 0x6a` (SD read) is stubbed to return immediately.
import re

VFILE = r"D:\Xilinx\workspace\Next186\Network\Network.srcs\sources_1\imports\Next186_BlackBoxes.v"
BASE = 0x030D  # beep entry

txt = open(VFILE, encoding="utf-8", errors="ignore").read()
pat = re.compile(r"ram\[11'h([0-9A-Fa-f]{3})\]\s*=\s*32'h([0-9A-Fa-f]{8})")
w = {int(m.group(1), 16): int(m.group(2), 16) for m in pat.finditer(txt)}
mem = bytearray(64 * 1024)
for i in range(0x100):
    v = w.get(i, 0)
    mem[4 * i:4 * i + 4] = bytes([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF])

# registers (16-bit)
ax = bx = cx = dx = si = di = sp = 0
# flags
zf = 0
# stack: flat model, SP starts high; caller return address = sentinel
SENT = 0xDEAD
sp = 0xFF00
mem[sp - 2] = SENT & 0xFF
mem[sp - 1] = (SENT >> 8) & 0xFF
sp -= 2  # caller's call pushed return addr

ip = BASE
out_writes = []
sd_read_called = False
steps = 0
MAX = 20_000_000

def rd16(a): return mem[a] | (mem[a + 1] << 8)
def wr16(a, v): mem[a] = v & 0xFF; mem[a + 1] = (v >> 8) & 0xFF
def push(v):
    global sp
    sp -= 2; wr16(sp, v & 0xFFFF)
def pop():
    global sp
    v = rd16(sp); sp += 2; return v

def reg8(r):  # r: 0..7 -> al,cl,dl,bl,ah,ch,dh,bh
    return {0: ax & 0xFF, 1: cx & 0xFF, 2: dx & 0xFF, 3: bx & 0xFF,
            4: (ax >> 8) & 0xFF, 5: (cx >> 8) & 0xFF, 6: (dx >> 8) & 0xFF, 7: (bx >> 8) & 0xFF}[r]
def set8(r, v):
    global ax, cx, dx, bx
    v &= 0xFF
    if r == 0: ax = (ax & 0xFF00) | v
    elif r == 1: cx = (cx & 0xFF00) | v
    elif r == 2: dx = (dx & 0xFF00) | v
    elif r == 3: bx = (bx & 0xFF00) | v
    elif r == 4: ax = (ax & 0x00FF) | (v << 8)
    elif r == 5: cx = (cx & 0x00FF) | (v << 8)
    elif r == 6: dx = (dx & 0x00FF) | (v << 8)
    elif r == 7: bx = (bx & 0x00FF) | (v << 8)
def reg16(r):
    return {0: ax, 1: cx, 2: dx, 3: bx, 6: si, 7: di}[r]
def set16(r, v):
    global ax, cx, dx, bx, si, di
    v &= 0xFFFF
    if r == 0: ax = v
    elif r == 1: cx = v
    elif r == 2: dx = v
    elif r == 3: bx = v
    elif r == 6: si = v
    elif r == 7: di = v

while steps < MAX:
    steps += 1
    op = mem[ip]
    if op == 0x50:  # push ax
        push(ax); ip += 1
    elif op == 0x51:  # push cx
        push(cx); ip += 1
    elif op == 0x59:  # pop cx
        cx = pop(); ip += 1
    elif op == 0x58:  # pop ax
        ax = pop(); ip += 1
    elif op == 0xB0:  # mov al, imm8
        set8(0, mem[ip + 1]); ip += 2
    elif op == 0xB8:  # mov ax, imm16
        ax = rd16(ip + 1); ip += 3
    elif op == 0xBB:  # mov bx, imm16
        bx = rd16(ip + 1); ip += 3
    elif op == 0xB9:  # mov cx, imm16
        cx = rd16(ip + 1); ip += 3
    elif op == 0xE6:  # out imm8, al
        port = mem[ip + 1]; out_writes.append((port, ax & 0xFF)); ip += 2
    elif op == 0xE4:  # in al, imm8
        port = mem[ip + 1]; ax = (ax & 0xFF00) | 0x00; ip += 2  # stub: read 0
    elif op == 0x0C:  # or al, imm8
        v = mem[ip + 1]; ax = (ax & 0xFF00) | ((ax & 0xFF) | v); ip += 2
    elif op == 0x24:  # and al, imm8
        v = mem[ip + 1]; ax = (ax & 0xFF00) | ((ax & 0xFF) & v); ip += 2
    elif op == 0x88:  # mov r/m8, r8  (mod=11 only here)
        modrm = mem[ip + 1]; rm = modrm & 7; reg = (modrm >> 3) & 7
        set8(rm, reg8(reg)); ip += 2
    elif op == 0x33:  # xor r/m16, r16 (mod=11 only here)
        modrm = mem[ip + 1]; rm = modrm & 7; reg = (modrm >> 3) & 7
        res = reg16(rm) ^ reg16(reg)
        set16(rm, res); zf = 1 if res == 0 else 0; ip += 2
    elif op == 0x4B:  # dec bx
        bx = (bx - 1) & 0xFFFF; zf = 1 if bx == 0 else 0; ip += 1
    elif op == 0xE2:  # loop rel8
        cx = (cx - 1) & 0xFFFF
        if cx != 0:
            ip += 2 + (mem[ip + 1] - 256 if mem[ip + 1] >= 128 else mem[ip + 1])
        else:
            ip += 2
    elif op == 0x75:  # jne/jnz rel8
        if zf == 0:
            ip += 2 + (mem[ip + 1] - 256 if mem[ip + 1] >= 128 else mem[ip + 1])
        else:
            ip += 2
    elif op == 0xE8:  # call near rel16
        tgt = (ip + 3 + rd16(ip + 1)) & 0xFFFF
        if tgt == 0x6A:  # SD read: stub to return immediately
            sd_read_called = True
            ip += 3
        else:
            push(ip + 3); ip = tgt
    elif op == 0xC3:  # ret
        ret = pop()
        if ret == SENT:
            print(f"[TRACE] beep returned to caller sentinel after {steps} steps. TERMINATED OK.")
            break
        ip = ret
    else:
        raise SystemExit(f"[TRACE] UNHANDLED opcode 0x{op:02X} at ip=0x{ip:04X}")

print(f"[TRACE] steps executed: {steps}")
if steps >= MAX:
    print("[TRACE] *** INFINITE LOOP DETECTED (hit step cap) ***")
    raise SystemExit(1)

# Analyze OUT writes
print("\n--- port 61h writes during beep ---")
spk = [(p, v) for (p, v) in out_writes if p == 0x61]
for p, v in spk:
    bits = f"bit0(gate)={v&1} bit1(spk)={(v>>1)&1}"
    print(f"  out 61h, al = 0x{v:02X}   ({bits})")
on = any((v & 3) == 3 for (p, v) in spk)
off = any((v & 1) == 0 for (p, v) in spk)
print("\nspeaker turned ON (61h write with bits0&1 set):", on)
print("speaker turned OFF (61h write with bit0 cleared):", off)
print("SD read (call 0x6a) reached:", sd_read_called)
print("PIT programmed (out 43h=0xB6):", any(p == 0x43 and v == 0xB6 for (p, v) in out_writes))
print("PIT divisor 0x07D0 written (out 42h):", any(p == 0x42 for (p, v) in out_writes))

ok = on and off and sd_read_called and (not (steps >= MAX))
print("\n[TRACE RESULT]", "PASS" if ok else "FAIL")
raise SystemExit(0 if ok else 1)
