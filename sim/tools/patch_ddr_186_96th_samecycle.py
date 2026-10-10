#!/usr/bin/env python3
# -*- coding: ascii -*-
"""96th fix - the cache request and the cache address must come from the SAME cycle.

ROOT CAUSE (proven, 2026-09-27)
-------------------------------
The no-card devmem dump showed the self-test data is 100% CORRECT in DDR
(0x080F0000..0x080F03FF = 256/256 words == byte@m=(m>>2)&0xFF, zero mismatches),
and VRAM reads back as the proper text "Searchin".  So the write-back, the AXI
write and the PS DDR are all innocent.  Yet the on-board fill probe returns
w0=0x0000 / wl=0x0C00 and the CPU reads [0x80]=0x00.
=> THE FILL READS THE WRONG DDR ADDRESS.

Why: in ddr_186.v the "does the cache own the bus" decision uses the request
DELAYED BY ONE CYCLE, while the address uses the CURRENT cache_hi_addr:

    s_ddr_rd <= ddr_rd;                                   // 1 cycle late
    wire cache_owns = (s_ddr_wr || s_ddr_rd) && !cache_cmd_done;
    sdraddr <= ... {memmap_mux, cache_hi_addr[9:0], 5'b0};// CURRENT
    cntrl0_user_command_register <= s_ddr_wr ? 2'b01 : 2'b11;

So in the cycle right after the cache drops its request, s_ddr_rd is still 1
while cache_hi_addr has already moved on to the NEXT transaction's line.  The
DDR FSM then samples "fill" together with the NEXT line's address -> the cache
line is filled from the wrong physical address.  That is exactly the observed
"+N lines" displacement, why it is selective (it needs the sampling edge to land
in that one-cycle window), and why the harness never reproduced it.

The 95th comment claimed the type was taken "in real time" - s_ddr_* is NOT real
time, that is the defect.

FIX
---
Use the real-time request in the ownership test and in the command type, so the
request, the command type and the address all describe the same cycle.
Two lines.  Bonus: it also removes the stale-command window that the 95th fix had
to paper over with cache_cmd_done.
"""
import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
TARGET = os.path.join(ROOT, 'ddr_186.v')
BACKUP = os.path.join(ROOT, 'sim', 'run', 'ddr_186.v.pre96th')

OLD_OWNS = "wire cache_owns = (s_ddr_wr || s_ddr_rd) && !cache_cmd_done;"
NEW_OWNS = "wire cache_owns = (ddr_wr || ddr_rd) && !cache_cmd_done;   // 96th: real-time request, so cmd/type/address are same-cycle"
OLD_TYPE = "else if(cache_owns) cntrl0_user_command_register <= s_ddr_wr ? 2'b01 : 2'b11;"
NEW_TYPE = "else if(cache_owns) cntrl0_user_command_register <= ddr_wr ? 2'b01 : 2'b11;  // 96th: real-time (was s_ddr_wr, 1 cycle stale)"


def main():
    if '--revert' in sys.argv:
        if not os.path.exists(BACKUP):
            sys.exit('no backup at %s' % BACKUP)
        shutil.copyfile(BACKUP, TARGET)
        print('reverted from %s' % BACKUP)
        return
    txt = open(TARGET, 'r', newline='').read()
    if NEW_OWNS in txt:
        print('already patched')
        return
    if OLD_OWNS not in txt:
        sys.exit('ANCHOR FAIL: cache_owns expression not found')
    if OLD_TYPE not in txt:
        sys.exit('ANCHOR FAIL: command-type expression not found')
    if not os.path.exists(BACKUP):
        shutil.copyfile(TARGET, BACKUP)
        print('backup -> %s' % BACKUP)
    txt = txt.replace(OLD_OWNS, NEW_OWNS)
    txt = txt.replace(OLD_TYPE, NEW_TYPE)
    open(TARGET, 'w', newline='').write(txt)

    txt = open(TARGET, 'r', newline='').read()
    print('CRLF=%d bare-LF=%d' % (txt.count('\r\n'),
                                  len(re.findall(r'(?<!\r)\n', txt))))
    body = '\n'.join(l.split('//')[0] for l in txt.replace('\r\n', '\n').split('\n'))
    print('begin/end = %d/%d' % (len(re.findall(r'\bbegin\b', body)),
                                 len(re.findall(r'\bend\b', body))))
    probes = {}
    for m in re.finditer(r'mark_debug[^\n]*?reg\s*(\[[^\]]*\])?\s*(\w+)', txt):
        wd = 1
        if m.group(1):
            mm = re.match(r'\[(\d+):(\d+)\]', m.group(1))
            if mm:
                wd = int(mm.group(1)) - int(mm.group(2)) + 1
        probes[m.group(2)] = wd
    print('probes = %d signal / %d bit (unchanged expected)' % (len(probes), sum(probes.values())))
    print('s_ddr_* still declared/used (probe uses them):',
          'yes' if 's_ddr_wr' in txt else 'NO')


if __name__ == '__main__':
    main()
