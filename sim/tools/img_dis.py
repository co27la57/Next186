#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 186 物理地址 / 文件偏移反汇编到具体例程 —— 用于解读 ILA 的 dbg_cpu_laddr。

用法：
  img_dis.py <img.bin> <phys_hex> [count]            反汇编（phys = 186 物理地址，F 段窗口 = 0xF0000）
  img_dis.py <img.bin> <phys_hex> --xref             列出映像中所有 call/jmp 指向该地址的位置
  img_dis.py <img.bin> --off <off_hex> [count]       直接按文件偏移反汇编
  img_dis.py <img.bin> <phys_hex> --str [n]          该地址附近 n 字节的可打印字符串（默认 96）

约定（本项目）：
  映像 8KB 由 BIOS 从 SD 卡载入 F000:0000
    ⇒ 物理地址 phys (0x0F0000..0x0F1FFF) 对应文件偏移 off = phys - 0xF0000
  复位向量/ROM 部分在 F000:FC00（bios_rom，不在这个 8KB 里）
"""
import sys, re

try:
    import capstone
except ImportError:
    print("需要 capstone：pip install capstone（本机 venv 内已有 5.0.7）")
    sys.exit(1)

SEG_BASE = 0xF0000          # F000:0000 的物理基址


def load(p):
    return open(p, 'rb').read()


def dis(img, off, count, base):
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_16)
    md.detail = False
    code = img[off:off + count]
    print("== disasm  phys=0x%05X  off=0x%04X  len=%d ==" % (base, off, len(code)))
    for ins in md.disasm(code, base):
        raw = ' '.join('%02X' % b for b in ins.bytes)
        print("%05X  %-14s %-8s %s" % (ins.address, raw, ins.mnemonic, ins.op_str))


def xref(img, phys):
    """扫描 E8/E9 (call/jmp rel16) 与 EA (jmp far) ，找出指向 phys 的位置。"""
    hits = []
    for i in range(len(img) - 2):
        op = img[i]
        if op in (0xE8, 0xE9):
            rel = int.from_bytes(img[i + 1:i + 3], 'little', signed=True)
            tgt = (SEG_BASE + i + 3 + rel) & 0xFFFFF
            if tgt == phys:
                hits.append((SEG_BASE + i, 'call' if op == 0xE8 else 'jmp'))
    print("== xref to phys 0x%05X (off 0x%04X) ==" % (phys, phys - SEG_BASE))
    if not hits:
        print("   (没有找到直接 call/jmp 指向该地址)")
    for a, k in hits:
        print("   %05X  %s" % (a, k))


def strings(img, off, n):
    seg = img[off:off + n]
    print("== bytes/str at off 0x%04X ==" % off)
    print("  hex:", ' '.join('%02X' % b for b in seg))
    print("  txt:", ''.join(chr(b) if 32 <= b < 127 else '.' for b in seg))


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return
    img = load(sys.argv[1])
    if sys.argv[2] == '--off':
        off = int(sys.argv[3], 16)
        cnt = int(sys.argv[4]) if len(sys.argv) > 4 else 96
        dis(img, off, cnt, SEG_BASE + off)
        return
    phys = int(sys.argv[2], 16)
    off = phys - SEG_BASE
    mode = sys.argv[3] if len(sys.argv) > 3 else ''
    if not (0 <= off < len(img)):
        print("!! phys 0x%05X 不在映像范围内（映像 %d 字节，覆盖 0xF0000..0x%05X）"
              % (phys, len(img), SEG_BASE + len(img) - 1))
        return
    if mode == '--xref':
        xref(img, phys)
    elif mode == '--str':
        n = int(sys.argv[4]) if len(sys.argv) > 4 else 96
        strings(img, off, n)
    else:
        cnt = int(mode) if mode else 96
        dis(img, off, cnt, phys)
        print()
        xref(img, phys)


if __name__ == '__main__':
    main()
