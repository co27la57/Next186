// sim/tb/opl3_ym_poly_main.cpp —— 多通道叠加行为验证
// ---------------------------------------------------------------------------
// 目的：新核（真实 YMF262 模型）单通道满幅只有 ±4085（12.5% FS），
//       但 9 个通道同时满幅就是 4085*9 = 36765 > 32767。
//       旧核 opl3seq.v 用 limAcc 硬钳位（饱和），真实 YMF262 是 16bit DAC，
//       叠加超范围会回绕(wraparound) —— 听感就是"特别大且爆"。
//       这个台架量：① 单通道峰值 ② 9 通道全满峰值 ③ 是否触顶回绕。
//
// 跑法（cwd=imports/）：
//   python sim/build.py --top opl3_ym --out sim/run/opl3_ym_poly --run \
//     opl3_ym.v ymf262.sv ym_lib.sv sim/tb/opl3_ym_poly_main.cpp
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
static void bus_write(int addr2, int data) {
    dut->cpu_addr = addr2 & 3; dut->cpu_din = data & 0xff;
    dut->cpu_ce = 1; dut->cpu_wr = 1;
    run_ns(200);
    dut->cpu_ce = 0; dut->cpu_wr = 0;
    run_ns(300);
}
static void reg(int bank, int r, int v) { bus_write(bank ? 2 : 0, r); bus_write(bank ? 3 : 1, v); }

// OPL3 9 通道的算子寄存器偏移表
static const int opoff[9] = {0x00,0x01,0x02,0x08,0x09,0x0A,0x10,0x11,0x12};

// 打开通道 ch：两算子 TL=0（最响）、AR=15、无衰减、key-on
static void open_ch(int ch, int fnum_lo, int fnum_hi_blk_key) {
    int o0 = opoff[ch], o1 = opoff[ch] + 3;
    reg(0, 0x20 + o0, 0x21);   // MULT=1
    reg(0, 0x40 + o0, 0x00);   // TL=0 -> 最响
    reg(0, 0x60 + o0, 0xf0);   // AR=15, DR=0
    reg(0, 0x80 + o0, 0x0f);   // SL=0, RR=0（不衰减）
    reg(0, 0x20 + o1, 0x21);
    reg(0, 0x40 + o1, 0x00);   // TL=0
    reg(0, 0x60 + o1, 0xf0);
    reg(0, 0x80 + o1, 0x0f);
    reg(0, 0xC0 + ch,  0x00);  // 纯 FM, 无反馈
    reg(0, 0xA0 + ch,  fnum_lo);
    reg(0, 0xB0 + ch,  fnum_hi_blk_key);
}

struct Stat { int lmin, lmax, rmin, rmax; long long samples; };
static Stat measure(double ms) {
    Stat s; s.lmin = 999999; s.lmax = -999999; s.rmin = 999999; s.rmax = -999999; s.samples = 0;
    double t = 0.0; const double dt = 1e9 / (2.0 * MCLK_HZ);
    while (t < ms * 1e6) {
        step(); t += dt; s.samples++;
        int l = (short)dut->left, r = (short)dut->right;
        if (l < s.lmin) s.lmin = l; if (l > s.lmax) s.lmax = l;
        if (r < s.rmin) s.rmin = r; if (r > s.rmax) s.rmax = r;
    }
    return s;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (const char* e = getenv("MCLK_MHZ")) MCLK_HZ = atof(e) * 1e6;
    dut = new Vopl3_ym;
    dut->mclk = 0; dut->rst = 0;
    dut->cpu_ce = 0; dut->cpu_wr = 0; dut->cpu_addr = 0; dut->cpu_din = 0;
    dut->eval();

    printf("=== opl3_ym 多通道叠加验证  MCLK=%.1f MHz ===\n", MCLK_HZ/1e6);
    run_ns(1000); dut->rst = 1; run_ns(100000);

    // ---- ① 单通道（通道0）----
    open_ch(0, 0x98, 0x31);
    run_ns(500000);
    Stat a = measure(200);
    printf("[1通道] left %6d..%6d   right %6d..%6d\n", a.lmin, a.lmax, a.rmin, a.rmax);

    // ---- ② 再开 8 个通道，共 9 通道，全部 TL=0 最响 ----
    for (int ch = 1; ch < 9; ch++)
        open_ch(ch, 0x40 + ch * 0x11, 0x31 + ((ch & 1) ? 0 : 0));
    run_ns(1000000);                    // 等 FIFO 排空（90 字节 x 8us = 720us）+ 余量
    Stat b = measure(200);
    printf("[9通道] left %6d..%6d   right %6d..%6d\n", b.lmin, b.lmax, b.rmin, b.rmax);
    printf("        9 x 单通道峰值 = %d  (16bit 上限 32767)\n", a.lmax * 9);
    if (b.lmax >= 32767 || b.lmin <= -32768)
        printf("        => ★ 触顶：16bit DAC 饱和/回绕区\n");
    else
        printf("        => 未触顶\n");

    // ---- ③ 回绕检测：统计相邻样本跳变幅度 ----
    //   若发生回绕，会出现 |Δ| 接近 65536 的突跳（正满幅直接跳到负满幅）
    int pl = (short)dut->left, pr = (short)dut->right;
    long long bigjump = 0, n = 0, clip = 0;
    double t = 0.0; const double dt = 1e9 / (2.0 * MCLK_HZ);
    while (t < 200e6) {
        step(); t += dt; n++;
        int l = (short)dut->left, r = (short)dut->right;
        int dl = l - pl, dr = r - pr;
        if (dl > 20000 || dl < -20000 || dr > 20000 || dr < -20000) bigjump++;
        if (l >= 32767 || l <= -32768 || r >= 32767 || r <= -32768) clip++;
        pl = l; pr = r;
    }
    printf("        样本 %lld, 大跳变(>20000) %lld 次, 触顶样本 %lld 次\n", n, bigjump, clip);

    dut->final(); delete dut;
    return 0;
}
