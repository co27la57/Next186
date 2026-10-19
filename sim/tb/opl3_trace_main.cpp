#include "Vopl3_dbg2.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
static Vopl3_dbg2 *d; static unsigned long long cyc=0;
static void edge(){ d->clk=0;d->cpu_clk=0;d->eval();d->clk=1;d->cpu_clk=1;d->eval();cyc++; }
static void run(unsigned n){while(n--)edge();}
static void hostwr(unsigned a,unsigned v){d->addr=a&3;d->din=v;d->ce=d->wr=1;edge();d->ce=d->wr=0;d->din=0;}
static void regw(unsigned r,unsigned v){hostwr((r&0x100)?2:0,r);hostwr((r&0x100)?3:1,v);}
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);d=new Vopl3_dbg2;d->clk=d->cpu_clk=0;d->addr=d->din=d->ce=d->wr=d->stb44100=0;d->reset=1;d->eval();run(2000);d->reset=0;run(1100000);puts("boot done");
 unsigned lastq=0xffff; int prev_rd=0; long long iowr=0, iord=0, mwr=0;
 // Put one known command, capture the queue transfer and all resulting memory writes.
 hostwr(0,0x20); hostwr(1,0x21);
 for(unsigned i=0;i<500000;i++){edge();
  if(d->dbg_cpu_iorq && d->dbg_cpu_wr){iowr++; printf("IOWR cyc=%llu A=%04x DO=%02x CE=%d q=%04x\n",cyc,(int)d->dbg_cpu_addr,(int)d->dbg_cpu_dout,(int)d->dbg_cpu_ce,(int)d->dbg_qdata);}
  if(d->dbg_cpu_iorq && !d->dbg_cpu_wr){iord++;}
  if(d->dbg_fifo_rdreq && !prev_rd){ printf("FIFORD cyc=%llu q=%04x qempty=%d ready=%d\n",cyc,(int)d->dbg_qdata,(int)d->dbg_qempty,(int)d->dbg_ready);}
  prev_rd=d->dbg_fifo_rdreq;
  if(d->dbg_cpu_mreq && d->dbg_cpu_wr && d->dbg_cpu_ce){mwr++; int a=d->dbg_cpu_addr; if((a>=0x15e0&&a<0x1700)||(a>=0x0ae0&&a<0x0c00)) printf("MEMWR cyc=%llu A=%04x DO=%02x q=%04x state=%d seqa=%03x\n",cyc,a,(int)d->dbg_cpu_dout,(int)d->dbg_qdata,(int)d->dbg_state,(int)d->dbg_seq_addr);}
 }
 printf("done cyc=%llu iowr=%lld iord=%lld mwr=%lld state=%d ready=%d qempty=%d q=%04x left=%d right=%d ch=%x\n",cyc,iowr,iord,mwr,(int)d->dbg_state,(int)d->dbg_ready,(int)d->dbg_qempty,(int)d->dbg_qdata,(short)d->left,(short)d->right,(int)d->dbg_channels);
 // Feed proper setup and key-on, but leave enough time for every queue pair.
 const unsigned regs[][2]={{0x01,0x20},{0x20,0x21},{0x40,0x00},{0x60,0xf0},{0x80,0x0f},{0xc0,0x31},{0xe0,0x00},{0xa0,0x98},{0xb0,0x31}};
 for(auto &p:regs)regw(p[0],p[1]);
 for(unsigned i=0;i<6000000;i++){d->stb44100=(i%1134)==0;edge(); if(d->dbg_channel_hit) printf("HIT cyc=%llu hit=%x state=%d chidx=%d sample=%04x left=%d\\n",cyc,(int)d->dbg_channel_hit,(int)d->dbg_state,(int)d->dbg_seq_addr,(int)d->dbg_seq_rdata,(short)d->left); } printf("postsetup state=%d ready=%d qempty=%d left=%d right=%d ch=%x\\n",(int)d->dbg_state,(int)d->dbg_ready,(int)d->dbg_qempty,(short)d->left,(short)d->right,(int)d->dbg_channels);
 d->final();delete d;}

