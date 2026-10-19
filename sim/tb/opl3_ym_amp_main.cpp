// sim/tb/opl3_ym_amp_main.cpp —— 新核（ymf262）在**同一组寄存器**下的实际输出幅度
// ---------------------------------------------------------------------------
// 寄存器序列与 sim/tb/opl3_old_amp_main.cpp 逐字节相同，用来做新旧核的幅度直测对比。
// （旧的 opl3_ym_poly_main.cpp 用 9 通道、0xC0=0x00，与旧核台架不可比，故另写一份）
//
// 跑法（cwd=imports/）：
//   python sim/build.py --top opl3_ym --out sim/run/opl3_ym_amp --run \
//     opl3_ym.v ymf262.sv ym_lib.sv sim/tb/opl3_ym_amp_main.cpp
// ---------------------------------------------------------------------------
#include "Vopl3_ym.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cmath>

static Vopl3_ym* dut;
static double MCLK_HZ = 50e6;

static void step() { dut->mclk ^= 1; dut->eval(); }
static void run_ns(double ns) {
    long long n = (long long)llround(ns * 2.0 * MCLK_HZ / 1e9);
    if (n < 2) n = 2;
    if (n & 1) n++;
    for (long long i = 0; i < n; i++) step();
}
static void write_port(int addr2, int data) {
    dut->cpu_addr = addr2 & 3; dut->cpu_din = data & 0xff;
    dut->cpu_ce = 1; dut->cpu_wr = 1;
    run_ns(200);
    dut->cpu_ce = 0; dut->cpu_wr = 0;
    run_ns(300);
}
static void write_reg(unsigned reg, unsigned val) {
    write_port((reg & 0x100) ? 2 : 0, reg & 0xff);
    write_port((reg & 0x100) ? 3 : 1, val);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (const char* e = getenv("MCLK_MHZ")) MCLK_HZ = atof(e) * 1e6;

    dut = new Vopl3_ym;
    dut->mclk = 0; dut->rst = 0;
    dut->cpu_ce = 0; dut->cpu_wr = 0; dut->cpu_addr = 0; dut->cpu_din = 0;
    dut->eval();

    printf("=== 新核 ymf262 实际输出幅度  MCLK=%.1f MHz ===\n", MCLK_HZ / 1e6);
    run_ns(1000); dut->rst = 1; run_ns(100000);

    // ---- 与 opl3_old_amp_main.cpp 逐字节相同的序列 ----
    write_reg(0x01, 0x20);
    write_reg(0x105, 0x00);
    write_reg(0x104, 0x00);
    write_reg(0xbd, 0x00);
    for (unsigned ch = 0; ch < 4; ch++) {
        write_reg(0xb0 + ch, 0x11);
        for (unsigned slot = ch; slot < ch + 16; slot += 3) {
            write_reg(0x20 + slot, 0x21);
            write_reg(0x40 + slot, 0x00);   // TL=0 最响
            write_reg(0x60 + slot, 0xf0);
            write_reg(0x80 + slot, 0x0f);
            write_reg(0xe0 + slot, 0x00);
        }
        write_reg(0xc0 + ch, 0x31);
        write_reg(0xa0 + ch, 0x98 + ch * 8);
    }
    for (unsigned ch = 0; ch < 4; ch++) write_reg(0xb0 + ch, 0x31);   // key on
    printf("[1] 4 通道 TL=0 已写入（%d 次寄存器写）\n", 4 + 4 * (1 + 6 * 5 + 2) + 4);

    run_ns(2000000);   // 让 FIFO 排空 + 包络起来（attack 到满约需数百 us）

    // ---- 测量 200ms ----
    int Lmin = 1 << 30, Lmax = -(1 << 30), Rmin = 1 << 30, Rmax = -(1 << 30);
    long long n = 0, nz = 0, changes = 0;
    int lastl = (short)dut->left;
    double t = 0.0; const double dt = 1e9 / (2.0 * MCLK_HZ);
    while (t < 200e6) {
        step(); t += dt; n++;
        int l = (int)(short)dut->left, r = (int)(short)dut->right;
        if (l < Lmin) Lmin = l; if (l > Lmax) Lmax = l;
        if (r < Rmin) Rmin = r; if (r > Rmax) Rmax = r;
        if (l || r) nz++;
        if (l != lastl) { changes++; lastl = l; }
    }
    printf("\n--------------- 结果（新核）---------------\n");
    printf("left : %6d .. %6d\n", Lmin, Lmax);
    printf("right: %6d .. %6d\n", Rmin, Rmax);
    printf("峰值幅度 = %d  (占 16bit 满幅 %.2f%%)\n",
           (Lmax > -Lmin ? Lmax : -Lmin),
           100.0 * (Lmax > -Lmin ? Lmax : -Lmin) / 32767.0);
    printf("ovf(丢字节)=%d  vol_hit=%d\n", (int)dut->ovf, (int)dut->vol_hit);
    printf("非零样本 %.1f%%   left 变化 %lld 次 / %lld 样本\n",
           100.0 * nz / (double)n, changes, n);
    printf("------------------------------------------\n");
    dut->final(); delete dut;
    return 0;
}
