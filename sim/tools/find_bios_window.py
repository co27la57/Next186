#!/usr/bin/env python3
# -*- coding: ascii -*-
"""Search the 1KB BIOS image (extracted from bios_rom) for the byte pair that
the v5 probe saw as the fill's LAST word: dbg_fill_wl = 0x0C00 -> bytes (0x00, 0x0C).

Also reports every 64-byte window whose first halfword is 0x0000 and whose last
halfword is 0x0C00 - i.e. exactly the 64B line the board's fill read back.
"""
import re
import os
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))


def image_from(path, var):
    txt = open(path, 'r', newline='').read()
    img = bytearray(1024)
    seen = {}
    pat = re.escape(var) + r"\[\s*8'h([0-9A-Fa-f]{2})\s*\]\s*=\s*32'h([0-9A-Fa-f]{8})"
    for m in re.finditer(pat, txt):
        line = m.group(0)
        code = line.split('//')[0]
        if '=' not in code:
            continue
        i = int(m.group(1), 16)
        w = int(m.group(2), 16)
        seen[i] = w
    for i, w in seen.items():
        img[i * 4 + 0] = (w >> 0) & 0xFF
        img[i * 4 + 1] = (w >> 8) & 0xFF
        img[i * 4 + 2] = (w >> 16) & 0xFF
        img[i * 4 + 3] = (w >> 24) & 0xFF
    return img, len(seen)


def main():
    img, n = image_from(os.path.join(ROOT, 'cache_controller.v'), 'bios_rom')
    print('bios_rom entries parsed: %d (expect 256)' % n)
    hits = [i for i in range(1023) if img[i] == 0x00 and img[i + 1] == 0x0C]
    print('byte pair (00,0C) at offsets:', ['0x%03X' % h for h in hits])
    print('  offsets mod 64 :', sorted(set(h % 64 for h in hits)))
    print('  offsets mod 32 (halfword idx in a 64B line):',
          sorted(set((h // 2) % 32 for h in hits)))
    found = False
    for base in range(0, 1024 - 63, 64):
        if img[base] == 0 and img[base + 1] == 0 and img[base + 62] == 0 and img[base + 63] == 0x0C:
            print('EXACT MATCH: 64B window at image offset 0x%03X' % base)
            found = True
    if not found:
        print('no 64B window in the BIOS matches [w0=0000 .. w15=**0C00]')
    # also: which 64B windows END with the halfword 0x0C00 (bytes 62,63)?
    ends = [base for base in range(0, 1024 - 63, 64)
            if img[base + 62] == 0x00 and img[base + 63] == 0x0C]
    print('64B windows whose last halfword = 0x0C00:',
          ['0x%03X' % b for b in ends] if ends else 'none')
    # dump the tail of each such window for eyeballing
    for b in ends:
        print('  window 0x%03X words 12..15: %s' % (
            b, ' '.join('%02X%02X%02X%02X' % tuple(img[b + 4 * w:b + 4 * w + 4][::-1][::1])
                        for w in range(12, 16))))
    return 0


if __name__ == '__main__':
    sys.exit(main())
