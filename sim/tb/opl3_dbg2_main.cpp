#include "Vopl3_dbg2.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>
static Vopl3_dbg2 *d; static unsigned long long cyc=0;
static void step(){ d->clk ^=1; d->cpu_clk ^=1; d->eval(); cyc++; }
static void run(unsigned n){while(n--)step();}
static void sample(const char* tag){
 static int prevq=1; static int prevst=-1; static int prevaddr=-1;
 if (d->dbg_cpu_iorq || d->dbg_seq_wr || d->dbg_channel_hit || d->dbg_seq_rd || d->dbg_qempty!=prevq || d->dbg_state!=prevst || d->dbg_seq_addr!=prevaddr){
   if(d->dbg_cpu_iorq || d->dbg_cpu_mreq && d->dbg_cpu_wr || d->dbg_seq_wr || d->dbg_channel_hit || d->dbg_qempty!=prevq)
     printf("%llu %s CPU A=%04x M=%d IO=%d WR=%d CE=%d DO=%02x DI=%02x qempty=%d qdata=%04x rdq=%d state=%d seqrd=%d ram a=%03x wr=%d wd=%04x rd=%04x hit=%x left=%d\n",cyc,tag,(int)d->dbg_cpu_addr,(int)d->dbg_cpu_mreq,(int)d->dbg_cpu_iorq,(int)d->dbg_cpu_wr,(int)d->dbg_cpu_ce,(int)d->dbg_cpu_dout,(int)d->dbg_cpu_din,(int)d->dbg_qempty,(int)d->dbg_qdata,(int)d->dbg_fifo_rdreq,(int)d->dbg_state,(int)d->dbg_seq_rd,(int)d->dbg_seq_addr,(int)d->dbg_seq_wr,(int)d->dbg_seq_wdata,(int)d->dbg_seq_rdata,(int)d->dbg_channel_hit,(short)d->left);
 }
 prevq=d->dbg_qempty; prevst=d->dbg_state; prevaddr=d->dbg_seq_addr;
}
static void stepLog(const char*tag){d->clk^=1;d->cpu_clk^=1;d->eval();cyc++;sample(tag);}
static void wr(unsigned a,unsigned v){ d->addr=a&3;d->din=v;d->ce=d->wr=1; for(int i=0;i<8;i++)stepLog("host"); d->ce=d->wr=0;d->din=0;for(int i=0;i<4;i++)stepLog("host"); }
static void regw(unsigned r,unsigned v){wr((r&0x100)?2:0,r);wr((r&0x100)?3:1,v);}
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);d=new Vopl3_dbg2;d->clk=d->cpu_clk=0;d->addr=d->din=d->ce=d->wr=d->stb44100=0;d->reset=1;d->eval();run(2000);d->reset=0;run(1200000);printf("boot cyc %llu\n",cyc);
 regw(0x20,0x21); regw(0x40,0x00); regw(0x60,0xf0); regw(0x80,0x0f); regw(0xc0,0x31); regw(0xa0,0x98); regw(0xb0,0x31);
 for(int i=0;i<200000;i++){ if((i%128)==0)d->stb44100=1; else d->stb44100=0; stepLog("run"); }
 printf("done cyc %llu state=%d ready=%d left=%d right=%d ch=%x qempty=%d\n",cyc,(int)d->dbg_state,(int)d->dbg_ready,(short)d->left,(short)d->right,(int)d->dbg_channels,(int)d->dbg_qempty); d->final();delete d;}

