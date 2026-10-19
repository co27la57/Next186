// sim/tb/opl3_ym_burst_main.cpp —— 写 FIFO 溢出验证
// ---------------------------------------------------------------------------
// 背景：适配层用 64 深 FIFO + 8us/字节重放，排空吞吐只有 125k 字节/秒。
//       186 的 OUT 指令间隔约 200~320ns（3~5M 次/秒），游戏初始化 OPL3 往往
//       连写 100~300 个寄存器 ⇒ FIFO 必然溢出 ⇒ 丢的正是 TL/ADSR/patch 参数，
//       而未写的通道 TLL 保持 0（= 最大音量）⇒ "部分乐器特别大"。
//
// 本台架：按真实 186 的节奏 burst 写 N 个字节，统计实际入队多少、丢多少。
// 跑法（cwd=imports/）：
//   python sim/build.py --top opl3_ym_probe --out sim/run/opl3_ym_burst --run \
//     opl3_ym.v ymf262.sv ym_lib.sv sim/tb/opl3_ym_probe.v sim/tb/opl3_ym_burst_main.cpp
// ---------------------------------------------------------------------------
#include "Vopl3_ym_probe.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cmath>

static Vopl3_ym_probe* dut;
static double MCLK_HZ = 50e6;

static void step() { dut->mclk ^= 1; dut->eval(); }
static void run_ns(double ns) {
    long long n = (long long)llround(ns * 2.0 * MCLK_HZ / 1e9);
    if (n < 2) n = 2;
    if (n & 1) n++;
    for (long long i = 0; i < n; i++) step();
}

// 一次 186 的 OUT 周期：ce/wr 有效 gap_ns，然后间隔 rest_ns
static void out_cycle(int addr2, int data, double gap_ns, double rest_ns) {
    dut->cpu_addr = addr2 & 3; dut->cpu_din = data & 0xff;
    dut->cpu_ce = 1; dut->cpu_wr = 1;
    run_ns(gap_ns);
    dut->cpu_ce = 0; dut->cpu_wr = 0;
    run_ns(rest_ns);
}

// 7bit 环形指针差 = 已入队未读字节数
static int fifo_used() { return (int)((dut->dbg_wptr - dut->dbg_rptr) & 0x7ff); }

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (const char* e = getenv("MCLK_MHZ")) MCLK_HZ = atof(e) * 1e6;
    double gap  = getenv("GAP_NS")  ? atof(getenv("GAP_NS"))  : 160.0;
    double rest = getenv("REST_NS") ? atof(getenv("REST_NS")) : 160.0;
    int    nbytes = getenv("NBYTES") ? atoi(getenv("NBYTES")) : 200;

    dut = new Vopl3_ym_probe;
    dut->mclk = 0; dut->rst = 0;
    dut->cpu_ce = 0; dut->cpu_wr = 0; dut->cpu_addr = 0; dut->cpu_din = 0;
    dut->eval();

    printf("=== 写 FIFO 突发容量测试  MCLK=%.1f MHz  OUT 周期=%.0fns 连续 %d 字节 ===\n",
           MCLK_HZ / 1e6, gap + rest, nbytes);
    run_ns(1000); dut->rst = 1; run_ns(100000);

    int peak_used = 0;
    double elapsed = 0.0;
    int accepted = 0;
    for (int i = 0; i < nbytes; i++) {
        int wp = dut->dbg_wptr;
        out_cycle(0, i & 0xff, gap, rest);      // 地址/数据轮换，模拟真实 patch 写
        elapsed += gap + rest;
        if (dut->dbg_wptr != wp) accepted++;    // 指针前进 = 这个字节真的入队了
        int used = fifo_used();
        if (used > peak_used) peak_used = used;
    }
    printf("  突发耗时 %.1f us   FIFO 峰值占用 %d/1024   实际入队 %d / %d 字节\n",
           elapsed / 1000.0, peak_used, accepted, nbytes);
    if (accepted < nbytes)
        printf("  => ★ 丢弃 %d 字节（%.0f%%）—— patch 参数会缺失，未写到的通道 TLL=0 即最大音量\n",
               nbytes - accepted, 100.0 * (nbytes - accepted) / nbytes);
    else
        printf("  => 未溢出\n");

    // 排空需要多久
    int used_now = fifo_used();
    double drain_ns = 0;
    while (fifo_used() > 0 && drain_ns < 100e6) { run_ns(1000); drain_ns += 1000; }
    printf("  残余 %d 字节排空耗时 %.0f us\n", used_now, drain_ns / 1000.0);

    dut->final(); delete dut;
    return 0;
}
