#include "Vopl3_ym_dbg.h"
#include "verilated.h"
#include <cstdio>
static Vopl3_ym_dbg* dut;
static void step() { dut->clk50 ^= 1; dut->eval(); }
static void run(int n) { for (int i=0;i<n;i++) step(); }
static void bus_write(int a,int d){ dut->cpu_addr=a&3; dut->cpu_din=d&0xff; dut->cpu_ce=1; dut->cpu_wr=1;
    run(8); dut->cpu_ce=0; dut->cpu_wr=0; run(40); }
static void reg(int b,int r,int v){ bus_write(b?2:0,r); bus_write(b?3:1,v); }
static void dump(const char* tag){
    printf("%-14s keyon=%d phase=0x%05x egstate=%d eglevel=0x%03x tl0=%d ar0=%d multi0=%d fnum0=0x%03x block=%d fb=%d tl1=%d ar1=%d\n",
        tag, dut->dbg_keyon, dut->dbg_phase0, dut->dbg_egstate0, dut->dbg_eglevel0,
        dut->dbg_tl0, dut->dbg_ar0, dut->dbg_multi0, dut->dbg_fnum0, dut->dbg_block0,
        dut->dbg_fb0, dut->dbg_tl1, dut->dbg_ar1);
}
int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    dut=new Vopl3_ym_dbg;
    dut->clk50=0; dut->rst=0; dut->cpu_ce=0; dut->cpu_wr=0; dut->cpu_addr=0; dut->cpu_din=0; dut->eval();
    run(200); dut->rst=1; run(20000);
    dump("复位后");
    reg(0,0x20,0x21); reg(0,0x40,0x10); reg(0,0x60,0xf0); reg(0,0x80,0x77);
    reg(0,0x23,0x21); reg(0,0x43,0x00); reg(0,0x63,0xf0); reg(0,0x83,0x77);
    reg(0,0xc0,0x00); reg(0,0xa0,0x98); reg(0,0xb0,0x31);
    run(20000); dump("写完后");
    { long w0=0,w1=0; int l0=dut->dbg_wr0, l1=dut->dbg_wr1;
      for(int i=0;i<40000;i++){ step(); if(dut->dbg_wr0!=l0){l0=dut->dbg_wr0; if(l0)w0++;} if(dut->dbg_wr1!=l1){l1=dut->dbg_wr1; if(l1)w1++;} }
      printf("写后 40000 拍内: write0 脉冲=%ld  write1 脉冲=%ld  (期望各 11)\n", w0, w1); }
    for(int k=0;k<6;k++){ run(10000); dump("运行中"); }
    printf("left=0x%04x right=0x%04x pow=0x%012llx\n", dut->left, dut->right, (unsigned long long)dut->dbg_pow);
    printf("FIFO: wptr=%d rptr=%d repcnt=%d  core: io_write=%d io_cs=%d data_latch=0x%02x ra_addr_latch=0x%03x\n",
        dut->dbg_wptr, dut->dbg_rptr, dut->dbg_repcnt, dut->dbg_iowrite, dut->dbg_iocs, dut->dbg_dlatch, dut->dbg_raddr_l);
    printf("FIFO[0]=0x%03x FIFO[1]=0x%03x  io_a0=%d write0=%d write1=%d core_addr=%d\n",
        dut->dbg_fifo0, dut->dbg_fifo1, dut->dbg_ioa0, dut->dbg_wr0, dut->dbg_wr1, dut->dbg_core_addr);
    dut->final(); delete dut; return 0;
}
