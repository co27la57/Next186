import csv,pathlib,sys
root=pathlib.Path(sys.argv[1])
def g(v,hi,w): return (v>>(hi-w+1))&((1<<w)-1)
for f in sorted(root.rglob('waveform.csv')):
 rows=list(csv.reader(f.open(encoding='utf-8-sig'))); h=rows[0]
 di=h.index('Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_vga_probe[198:0]')
 vals=[]
 for r in rows[2:]:
  v=int(r[di],16); vals.append({
   's':int(r[0]),'row':g(v,198,17),'rc':g(v,181,9),'repln':g(v,172,4),'lnb':g(v,168,8),
   'fifo':g(v,136,9),'vc':g(v,127,10),'hc':g(v,117,10),'mode':g(v,103,2)<<6|g(v,101,2)<<4|g(v,99,2)<<2|g(v,97,2),
   'scr':g(v,95,16),'off':g(v,79,8),'fs':g(v,55,1),'rst':g(v,54,1),'fifo_fs':g(v,53,9),'repln_fs':g(v,44,4),'lnb_fs':g(v,40,8),'mode_fs':g(v,32,8),'cfg_fs':g(v,24,24),
   'sdr':g(v,160,24),'crw':g(v,67,1),'col':g(v,66,5),'maxr':g(v,61,3)})
 fs=[x for x in vals if x['fs']]; rst=[x for x in vals if x['rst']]
 print(f.parent.name,'FS',[(x['s'],hex(x['row']),x['rc'],x['repln'],x['lnb'],hex(x['fifo_fs']),x['repln_fs'],x['lnb_fs'],hex(x['mode_fs']),hex(x['cfg_fs']),hex(x['sdr'])) for x in fs[:3]],'RST',[(x['s'],x['vc'],hex(x['row']),x['rc'],x['repln'],x['lnb'],hex(x['sdr'])) for x in rst[:3]])
