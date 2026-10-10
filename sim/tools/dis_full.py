import capstone, sys

BIN = r"d:\Xilinx\workspace\Next186\Network\Network.srcs\sources_1\imports\images\BIOS_Next186.bin"
base = 0x080FE000   # F000:E000 -> DDR 0x080FE000 (BIOS loaded here by stage-1)

data = open(BIN, "rb").read()
print("binary size =", len(data), "(=0x%X)" % len(data))
assert len(data) == 8192, "expected 8KB BIOS"

md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_16)
md.detail = True

# ---- 1) full disassembly, flag interesting ops ----
print("\n==== full disassembly: int/call/ret/hlt of interest ====")
for ins in md.disasm(bytes(data), base):
    m = ins.mnemonic
    op = ins.op_str
    mark = ""
    if m == "int":
        mark = "  <-- INT %s" % op
    elif m in ("hlt", "ret", "retf", "iret", "call", "jmp"):
        mark = "  [%s]" % m
    if mark:
        seg = ins.address - base
        print("%05X (F%04X)  %-14s %s%s" % (ins.address, seg,
              " ".join("%02X"%b for b in ins.bytes), m+" "+op, mark))

# ---- 2) locate the dump region in the binary and disassemble it ----
dump_lo = 0x080FF300
dump_hi = 0x080FF4C0
off_lo = dump_lo - base
off_hi = dump_hi - base
print("\n==== dump region 0x%05X..0x%05X = file offset 0x%04X..0x%04X (F%04X..F%04X) ===="
      % (dump_lo, dump_hi, off_lo, off_hi, off_lo, off_hi))
for ins in md.disasm(bytes(data[off_lo:off_hi]), dump_lo):
    print("%05X  %-16s %s" % (ins.address, " ".join("%02X"%b for b in ins.bytes),
          ins.mnemonic + " " + ins.op_str))

# ---- 3) sanity: does binary at 0x1300 match the devmem dump? ----
# reconstruct expected bytes from the 113 dumped 32-bit words
vals = [
0xE8977202,0x927202A6,0x9FE8D88A,0x8A8B7202,0x0298E8C8,0x505A8472,0xFF8082EB,0xB49A7702,
0xEBE702E5,0x28140AAA,0xC864503C,0x00FC0008,0x00441000,0x561E0000,0x861F406A,0xEFA848C4,
0xFC403E74,0x1C74EFA8,0x7872033C,0x053C7B74,0x093C3D74,0x123C0874,0x923C5674,0x24B00275,
0xF4CF1F5E,0x16CD11B4,0x8BFAF974,0xAD001A36,0x0082363B,0x368B0472,0x36890080,0xE0EB001A,
0x001A368B,0x001C363B,0x1F5EFBAD,0x8B0002CA,0x89001C36,0x3B46460C,0x72008236,0x80368B04,
0x3B01B000,0x74001A36,0x1C3689B7,0xB0EB4800,0x240018A0,0x7404A877,0x8A842C02,0x80009626,
0xE00A0CE4,0xEB0017A0,0x05FC8097,0xC0529275,0xE38005E7,0x80DF0A1F,0x00B47FE3,0x720028E8,
0x970E8023,0xF3B40800,0xE8DB3253,0x725B0199,0xE818B40E,0x07720011,0xDB32E38A,0x800188E8,
0xF7009726,0xBAC0EB5A,0xC8B703DA,0x0097A0FA,0xE0385824,0xECFB0A74,0x0824C732,0xEC73F82A,
0xBE070EC3,0xF9E8F459,0x01B8E801,0x43E6B4B0,0xE6F000B8,0xE742E642,0x8ED88E01,0x0100BEC0,
0xFA0118E8,0x12E8FC8A,0xE8DC8A01,0x2488010D,0xF7754B46,0x000100EA,0x206F4EF0,0x746F6F62,
0x76656420,0x20656369,0x69617661,0x6C62616C,0x77202C65,0x69746961,0x6F20676E,0x5352206E,
0x20323332,0x35313128,0x62303032,0x202C7370,0x30303066,0x3030313A,0x2E2E2029,0x000A0D2E,
0xB90201B8,0x80BA0001,0x07006A00,0xCD7C00BB,0xEA057213,0x00007C00,0x6A1E18CD,0xFC801F40,
0x74127701,
]
expected = bytearray()
for v in vals:
    expected += v.to_bytes(4, 'little')
actual = data[off_lo:off_lo+len(expected)]
print("\n==== dump<->binary byte-compare (first 32 mismatching bytes) ====")
mism = [(i, actual[i], expected[i]) for i in range(min(len(actual), len(expected))) if actual[i] != expected[i]]
print("total bytes compared =", min(len(actual), len(expected)), "mismatches =", len(mism))
for i, a, e in mism[:32]:
    print("  off+%04X  bin=%02X  dump=%02X" % (i, a, e))
