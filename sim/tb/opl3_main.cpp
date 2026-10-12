// sim/tb/opl3_main.cpp — opl3 级离线验证（含内部总线/FIFO 诊断）
// ---------------------------------------------------------------------------
// 目的：
//   A) 先诊断"186 侧命令有没有进 OPL3"—— census Z80 总线活动 + 命令 FIFO 状态
//   B) 再灌 Adlib 寄存器序列，按 rd 脉冲采样 left/right
//
// 关键背景：opl3seq 只在 rd 脉冲(=stb44100 上升沿)推进一步，必须按上升沿采样。
// ---------------------------------------------------------------------------
#include "Vopl3_dbg.h"
#include "verilated.h"
#include <cstdio>

static Vopl3_dbg* dut;
static long long cyc = 0;

static long long fifo_busy = 0;      // qempty==0 的 clk 周期数（写命令期间）
static unsigned   last_qdata = 0;

static void step() {
    dut->clk ^= 1;
    dut->cpu_clk ^= 1;
    dut->eval();
    cyc++;
}
static void run(int n) { for (int i = 0; i < n; i++) step(); }

static void opl3_port_wr(unsigned a, unsigned d) {
    dut->addr = a & 3;
    dut->din  = d & 0xFF;
    dut->wr   = 1;
    dut->ce   = 1;
    for (int i = 0; i < 8; i++) { step(); if (!dut->dbg_qempty) { fifo_busy++; last_qdata = dut->dbg_qdata; } }
    dut->ce = 0; dut->wr = 0; dut->din = 0;
    for (int i = 0; i < 2; i++) { step(); if (!dut->dbg_qempty) { fifo_busy++; last_qdata = dut->dbg_qdata; } }
}
static void opl3_wrreg(unsigned reg, unsigned val) {
    opl3_port_wr(0, reg);
    opl3_port_wr(1, val);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vopl3_dbg;

    dut->clk = 0; dut->cpu_clk = 0;
    dut->addr = 0; dut->din = 0; dut->ce = 0; dut->wr = 0;
    dut->stb44100 = 0; dut->reset = 1;
    dut->eval();

    printf("=== opl3 级离线验证 (Verilator, 含内部诊断) ===\n");
    printf("[1] 复位保持 2000 clk ...\n");  run(2000);
    printf("[2] 释放复位，等内部 Z80 引导 ...\n");
    dut->reset = 0;
    run(4000);

    // ---------- A. Z80 / FIFO 活动普查（写任何命令之前）----------
    long long mreq_rd = 0, iorq_rd = 0, iorq_wr = 0;
    int amin = 0x7fffffff, amax = -1;
    int qe_prev = 1, qe_toggles = 0;
    // 总线变化追踪（去重）
    int  p_mreq = -1, p_iorq = -1, p_wr = -1;
    int  p_addr = -1;
    int  tr_n = 0;
    const int TR_MAX = 220;
    long long iorq_first = -1;
    int iorq_first_addr = 0;
    for (int i = 0; i < 2000000; i++) {
        step();
        int M = dut->dbg_cpu_mreq, IO = dut->dbg_cpu_iorq, W = dut->dbg_cpu_wr;
        int A = (int)dut->dbg_cpu_addr;
        if (M && !W) {
            mreq_rd++;
            if (A < amin) amin = A;
            if (A > amax) amax = A;
        }
        if (IO && !W) {
            iorq_rd++;
            if (iorq_first < 0) { iorq_first = i; iorq_first_addr = A; }
        }
        if (IO &&  W) iorq_wr++;
        if ((int)dut->dbg_qempty != qe_prev) { qe_toggles++; qe_prev = dut->dbg_qempty; }
        if ((i % 250000) == 249999)
            printf("    ... clk=%d: MREQ读=%lld  IORQ读=%lld\n", i + 1, mreq_rd, iorq_rd);
    }
    printf("\n----- A. 内部 Z80 / FIFO 普查 (2000000 clk, 尚未写命令) -----\n");
    if (iorq_first >= 0)
        printf("  ★ 首次 IORQ 读出现在 clk=%lld，端口地址=0x%04X\n", iorq_first, iorq_first_addr);
    printf("  Z80 MREQ 读 = %lld 次\n", mreq_rd);
    printf("  Z80 IORQ 读 = %lld 次,  IORQ 写 = %lld 次\n", iorq_rd, iorq_wr);
    printf("  Z80 取指地址范围 = 0x%04X .. 0x%04X\n", amin, amax);
    printf("  命令 FIFO qempty 跳变 = %d 次 (0=从未非空, >0=有进出)\n", qe_toggles);
    if (mreq_rd == 0)
        printf("  => ★ Z80 完全没有取指活动！内部 CPU 没在跑\n");
    else if (iorq_rd == 0)
        printf("  => ★ Z80 在跑但从不做 I/O 读：卡在只访存的循环里，命令队列无人取\n");
    else
        printf("  => Z80 正常跑（MREQ %lld / IORQ读 %lld）\n", mreq_rd, iorq_rd);

    // ---------- B. 写一条命令，看 FIFO 有没有反应 ----------
    printf("\n----- B. 写一条命令(0x01<-0x20)，监视 FIFO -----\n");
    long long before = fifo_busy;
    opl3_wrreg(0x01, 0x20);
    printf("  写入期间 qempty==0 的 clk 周期数 = %lld\n", fifo_busy - before);
    if (fifo_busy > before)
        printf("  => 命令已进入 FIFO（最后一次队内数据 qdata=0x%04X）\n", last_qdata);
    else
        printf("  => ★ FIFO 始终为空：我的写入根本没进去！\n");

    // ---------- C. 完整寄存器序列 + 按 rd 脉冲采样 ----------
    printf("\n----- C. 完整 Adlib 序列 + 按 rd 脉冲采样 -----\n");
    const unsigned init[][2] = {
        {0x01, 0x20}, {0x20, 0x21}, {0x40, 0x10}, {0x60, 0xF0},
        {0x80, 0x22}, {0xC0, 0x01}, {0xE0, 0x00},
        {0xA0, 0xFF}, {0xB0, 0x2F},
    };
    for (unsigned i = 0; i < sizeof(init)/sizeof(init[0]); i++)
        opl3_wrreg(init[i][0], init[i][1]);
    printf("  整轮写入期间 qempty==0 累计 = %lld clk 周期\n", fifo_busy);

    const int STBDIV = 64;
    const int NSAMPLE = 2000;
    int div = 0, got = 0;
    int smin = 32767, smax = -32768;
    long long snz = 0, ssum = 0;
    while (got < NSAMPLE) {
        step();
        if (++div >= STBDIV) {
            div = 0;
            dut->stb44100 ^= 1;
            if (dut->stb44100 == 1) {
                int L = (int)(short)dut->left;
                if (L) snz++;
                ssum += L;
                if (L > smax) smax = L;
                if (L < smin) smin = L;
                if (got < 128) printf("%6d%s", L, ((got % 16) == 15) ? "\n" : " ");
                got++;
            }
        }
    }
    printf("\n  按rd脉冲采样: 非零=%lld/%d  min=%d  max=%d  平均=%lld\n",
           snz, NSAMPLE, smin, smax, ssum / NSAMPLE);

    printf("\n--------------- 结果 ---------------\n");
    printf("left 摆幅 = [%d .. %d]\n", smin, smax);
    printf("写命令期间 FIFO 非空周期 = %lld\n", fifo_busy);
    printf("-------------------------------------\n");

    dut->final();
    delete dut;
    return 0;
}
