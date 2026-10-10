#!/usr/bin/env python3
# Reproduces the soundwave.v mixer + clamp arithmetic to prove the idle-tone fix.
# Verbatim logic from soundwave.v:
#   wire [31:0]sample1 = qempty ? 32'h........ : sample;
#   lmix = {sample1[15], sample1[15:0]} + {opl,opl} + {mid,mid} + (spk<<11)
#   lclamp = (~|lmix[16:15] | &lmix[16:15]) ? {!lmix[15], lmix[14:0]} : {16{!lmix[16]}};
# PDM idle tone: a constant target != 50% density makes the 1st-order sigma-delta
# lock into a limit cycle -> a fixed-frequency tone. 50% (0x8000) is DC mid = silence.

def sign17(x16, signbit):
    # 16-bit value sign-extended to 17-bit two's complement
    val = x16 & 0xFFFF
    if signbit:
        val -= 0x10000
    return val & 0x1FFFF  # keep 17 bits

def clamp(lmix17):
    lmix = lmix17 & 0x1FFFF
    b16 = (lmix >> 16) & 1
    b15 = (lmix >> 15) & 1
    low14 = lmix & 0x7FFF  # bits [14:0] = 15 bits
    in_range = ((~(b16 | b15)) & 1) | (b16 & b15)
    if in_range:
        return ((~b15 & 1) << 15) | low14
    else:
        return (0xFFFF if (~b16 & 1) else 0x0000)

def report(name, sample1):
    # idle: opl3=midi=spk=0
    s_low = sample1 & 0xFFFF
    s_sign = (sample1 >> 15) & 1
    lmix = sign17(s_low, s_sign)
    lc = clamp(lmix)
    density = lc / 0x10000
    tone = "IDLE TONE (limit cycle)" if abs(density - 0.5) > 1e-9 else "SILENCE (50% DC mid)"
    print(f"  {name}:")
    print(f"    sample1      = 0x{sample1:08X}")
    print(f"    lmix (signed)= {lmix} (0x{lmix:05X})")
    print(f"    lclamp       = 0x{lc:04X}")
    print(f"    PDM density  = {density*100:.2f}%  -> {tone}")
    return lc

print("=== Idle / FIFO-empty mixer output (qempty=1) ===")
old = report("OLD (32'hC000C000)", 0xC000C000)
new = report("NEW (32'h00000000)", 0x00000000)

print()
print("=== Sanity: Covox 'silence' byte (data=0x80) when FIFO has data ===")
# wdata <= {1'b1, data[7:0], 8'b00000001, data[7:0], 7'b0000000}
# left 16-bit = wdata[31:16]
data = 0x80
wdata = (1 << 31) | (data << 23) | (0x01 << 15) | (data << 7)
left16 = (wdata >> 16) & 0xFFFF
lmix = sign17(left16, (left16 >> 15) & 1)
lc = clamp(lmix)
density = lc / 0x10000
print(f"    data=0x80 -> wdata=0x{wdata:08X} -> left16=0x{left16:04X}")
print(f"    lmix(signed)={lmix}  lclamp=0x{lc:04X}  density={density*100:.2f}%")
print("    (residual -16384 bias: Covox silent passages still ~25% -> optional deeper fix)")

print()
assert old == 0x4000, "OLD must be 0x4000 (25%, tone)"
assert new == 0x8000, "NEW must be 0x8000 (50%, silence)"
print("PASS: OLD=0x4000 (idle tone), NEW=0x8000 (silence). Patch verified.")
