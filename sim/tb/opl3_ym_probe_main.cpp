// sim/tb/opl3_ym_probe_main.cpp —— 直接测量内部 CLK14 与采样选通，钉死出样率
// 跑法（cwd=imports/）：
//   python sim/build.py --top opl3_ym_probe --out sim/run/opl3_ym_probe --run \
//     opl3_ym.v ymf262.sv ym_lib.sv sim/tb/opl3_ym_probe.v sim/tb/opl3_ym_probe_main.cpp
// ---------------------------------------------------------------------------
#include "Vopl3_ym_probe.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cmath>

static Vopl3_ym_probe* dut;
static double MCLK_HZ = 100e6;

static void step() { dut->mclk ^= 1; dut->eval(); }
static void run_ns(double ns) {
    long long n = (long long)llround(ns * 2.0 * MCLK_HZ / 1e9);
    if (n < 2) n = 2;
    if (n & 1) n++;
    for (long long i = 0; i < n; i++) step();
}

static void bus_write(int addr2, int data) {
    dut->cpu_addr = addr2 & 3;
    dut->cpu_din  = data & 0xff;
    dut->cpu_ce = 1; dut->cpu_wr = 1;
    run_ns(200);
    dut->cpu_ce = 0; dut->cpu_wr = 0;
    run_ns(300);
}
static void opl3_reg(int bank, int reg, int val) {
    bus_write(bank ? 2 : 0, reg);
    bus_write(bank ? 3 : 1, val);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (const char* e = getenv("MCLK_MHZ")) MCLK_HZ = atof(e) * 1e6;

    dut = new Vopl3_ym_probe;
    dut->mclk = 0; dut->rst = 0;
    dut->cpu_ce = 0; dut->cpu_wr = 0; dut->cpu_addr = 0; dut->cpu_din = 0;
    dut->eval();

    printf("=== opl3_ym_probe  MCLK=%.2f MHz ===\n", MCLK_HZ / 1e6);
    run_ns(1000);
    dut->rst = 1;
    run_ns(100000);

    opl3_reg(0, 0x20, 0x21); opl3_reg(0, 0x40, 0x10);
    opl3_reg(0, 0x60, 0xf0); opl3_reg(0, 0x80, 0x77);
    opl3_reg(0, 0x23, 0x21); opl3_reg(0, 0x43, 0x00);
    opl3_reg(0, 0x63, 0xf0); opl3_reg(0, 0x83, 0x77);
    opl3_reg(0, 0xc0, 0x00); opl3_reg(0, 0xa0, 0x98);
    opl3_reg(0, 0xb0, 0x31);

    run_ns(400000);            // FIFO 排空

    // ---- 统计 100ms 内的 CLK14 上升沿与 SMPBD 上升沿 ----
    double win_ns = 100000000.0;
    if (const char* w = getenv("WIN_NS")) win_ns = atof(w);
    long long clk_up = 0, smp_up = 0, smpac_up = 0, sy_up = 0;
    int pc14 = 0, psmp = 0, psmpac = 0, psy = 0;
    int lmin = 99999, lmax = -99999;
    double t = 0.0;
    const double dt = 1e9 / (2.0 * MCLK_HZ);
    while (t < win_ns) {
        step();
        t += dt;
        int c14 = dut->dbg_clk14, smp = dut->dbg_smpbd, smpac = dut->dbg_smpac, sy = dut->dbg_sy;
        if (c14  && !pc14)  clk_up++;
        if (smp  && !psmp)  smp_up++;
        if (smpac && !psmpac) smpac_up++;
        if (sy   && !psy)   sy_up++;
        pc14 = c14; psmp = smp; psmpac = smpac; psy = sy;
        int l = (short)dut->left;
        if (l < lmin) lmin = l; if (l > lmax) lmax = l;
    }

    double sec = win_ns / 1e9;
    printf("CLK14 上升沿 %lld -> %.4f MHz   (期望 14.3182 MHz)\n", clk_up, clk_up / sec / 1e6);
    printf("SMPBD 上升沿 %lld -> %.1f Hz     (期望 49716 Hz)\n", smp_up, smp_up / sec);
    printf("SMPAC 上升沿 %lld -> %.1f Hz\n", smpac_up, smpac_up / sec);
    printf("SY    上升沿 %lld -> %.1f Hz\n", sy_up, sy_up / sec);
    if (smp_up) printf("CLK14/采样 = %.2f  (期望 288)\n", (double)clk_up / (double)smp_up);
    printf("left 峰值 %d..%d\n", lmin, lmax);

    dut->final(); delete dut;
    return 0;
}
