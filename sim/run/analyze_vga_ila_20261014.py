import csv, pathlib, sys

ROOT = pathlib.Path(sys.argv[1])

FIELDS = {
    'row_col': (182, 17), 'row_count': (173, 9), 'repln': (169, 4),
    'lnb': (161, 8), 'sdraddr': (137, 24), 'fifo': (128, 9),
    'vcount': (118, 10), 'hcount': (108, 10), 'hpan': (104, 4),
    'vgatext': (102, 2), 'vga13': (100, 2), 'planar': (98, 2),
    'half': (96, 2), 'scraddr': (80, 16), 'vga_offset': (72, 8),
    'sys_ack': (70, 2), 'rd_valid': (69, 1), 'wr_valid': (68, 1),
    'crw': (67, 1), 'col': (62, 5), 'max_read': (59, 3),
    'endscan': (58, 1), 'endline': (57, 1), 'endframe': (56, 1),
    'fs': (55, 1), 'rowreset': (54, 1), 'fifo_fs': (45, 9),
    'repln_fs': (41, 4), 'lnb_fs': (33, 8), 'mode_fs': (25, 8),
    'cfg_fs': (24, 24), 'cache_seen': (0, 1),
}

def get(v, hi, width):
    return (v >> (hi - width + 1)) & ((1 << width) - 1)

for f in sorted(ROOT.rglob('waveform.csv')):
    rows = list(csv.reader(f.open(encoding='utf-8-sig')))
    if len(rows) < 3:
        continue
    header = rows[0]
    trig_i = header.index('Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_vga_trigger')
    data_i = header.index('Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_vga_probe[198:0]')
    decoded=[]
    for row in rows[2:]:
        v=int(row[data_i],16); t=int(row[trig_i],16)
        # Vivado's CSV formatter already presents the packed probe numerically
        # in source-bit order; do not reverse the 199-bit integer here.
        d={k:get(v,*spec) for k,spec in FIELDS.items()}
        d['sample']=int(row[0]); d['trigger']=t
        decoded.append(d)
    print(f'FILE {f.parent.name}')
    for idx in [0, 1, 2, 3, 4, 10, 128, 256, 384, 512, 513, 514, 515, 516, 517, 518, 519, 520, 521, 522, 640, 768, 900, 1023]:
        if idx >= len(decoded): continue
        d=decoded[idx]
        print(' S={sample:4d} trig={trigger} vc={vcount:3d} hc={hcount:4d} row={row_col:05x} rc={row_count:3d} rp={repln:x} lnb={lnb:02x} fifo={fifo:03x} sdr={sdraddr:06x} mode={vgatext:x}{vga13:x}{planar:x}{half:x} fs={fs} rst={rowreset} modefs={mode_fs:02x} cfg={cfg_fs:06x}'.format(**d))
    for k in ('trigger','fs','rowreset','endscan','endline','endframe'):
        ev=[d for d in decoded if d[k]]
        if ev:
            print(' EVENT',k,[(d['sample'],d['vcount'],hex(d['row_col']),d['row_count'],hex(d['fifo']),hex(d['mode_fs']),hex(d['cfg_fs'])) for d in ev[:12]], 'count=',len(ev))
    for d in decoded:
        if d['sample'] in (128,129,130,253,254,255,256):
            print(' FULL',d)
    print()
