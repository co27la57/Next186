import csv, pathlib, sys
f=next(pathlib.Path(sys.argv[1]).rglob('waveform.csv'))
rows=list(csv.reader(f.open(encoding='utf-8-sig')))
head=rows[0]; di=head.index('Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_vga_probe[198:0]')
for idx in (128,129,130,256,512):
    h=rows[2+idx][di]; v=int(h,16); b=f'{v:0199b}'
    print('SAMPLE',idx,'HEX',h)
    for label,s in [('normal',b),('reverse',b[::-1])]:
        hits=[]
        for off in range(0,190):
            x=int(s[off:off+10],2)
            if x in (0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,0xe000,0x6000): hits.append((off,x))
        print(label,'first',hits[:80])
