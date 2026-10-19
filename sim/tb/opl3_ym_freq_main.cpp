// sim/tb/opl3_ym_freq_main.cpp — opl3_ym 的 MCLK 频率扫描台架
// ---------------------------------------------------------------------------
// 目的：回答一个问题 —— ymf262 核的 MCLK 能不能从 100MHz 降到 ~62.5MHz 而
//       **出样率仍然是 49716 Hz**？
//   背景：核心是「单时钟(posedge MCLK) + c1/c2(CLK 相位) 使能」结构，
//         理论上只要每个 35ns 使能窗口里能稳定采到 >=2 个 MCLK 沿就行。
//         但为了 100MHz 要在 xc7z010-1 上收时序，实测 WNS=-3.99ns（约需 <=71MHz），
//         所以必须确认降频不改变音频速度。
//
// 跑法（cwd=imports/）：MCLK_MHZ 与环境里 -GINC_14M 必须匹配
//   python sim/build.py --top opl3_ym --out sim/run/opl3_ym_f100 --run \
//     --extra -GINC_14M=614948834 \
//     opl3_ym.v ymf262.sv ym_lib.sv sim/tb/opl3_ym_freq_main.cpp
//   （运行时 MCLK_MHZ=100）
// ---------------------------------------------------------------------------
#include "Vopl3_ym.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cmath>

static Vopl3_ym* dut;
static long long cyc = 0;             // 半沿计数
static double    MCLK_HZ = 100e6;

static void step() { dut->mclk ^= 1; dut->eval(); cyc++; }
static void run_hs(long long n) { for (long long i = 0; i < n; i++) step(); }

// 按「纳秒」推进：与 MCLK 频率无关，保证各频率下 I/O 时序语义一致
static void run_ns(double ns) {
    long long n = (long long)llround(ns * 2.0 * MCLK_HZ / 1e9);
    if (n < 2) n = 2;
    if (n & 1) n++;                   // 保证整周期，mclk 相位对齐
    run_hs(n);
}

// 模拟 186 的 I/O 写周期（clk_cpu 25MHz：有效 160ns，间隔 240ns，共 400ns）
static void bus_write(int addr2, int data) {
    dut->cpu_addr = addr2 & 3;
    dut->cpu_din  = data & 0xff;
    dut->cpu_ce   = 1;
    dut->cpu_wr   = 1;
    run_ns(200);
    dut->cpu_ce   = 0;
    dut->cpu_wr   = 0;
    run_ns(300);
}

static void opl3_reg(int bank, int reg, int val) {
    bus_write(bank ? 2 : 0, reg);
    bus_write(bank ? 3 : 1, val);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (const char* e = getenv("MCLK_MHZ")) MCLK_HZ = atof(e) * 1e6;

    dut = new Vopl3_ym;
    dut->mclk = 0; dut->rst = 0;
    dut->cpu_ce = 0; dut->cpu_wr = 0; dut->cpu_addr = 0; dut->cpu_din = 0;
    dut->eval();

    printf("=== opl3_ym MCLK 频率扫描  MCLK=%.2f MHz ===\n", MCLK_HZ / 1e6);

    run_ns(1000);
    dut->rst = 1;
    run_ns(100000);                   // 复位后稳定 100us

    // 标准 Adlib 单音（通道0, 2-op FM, key-on）
    opl3_reg(0, 0x20, 0x21);
    opl3_reg(0, 0x40, 0x3f);      // 调制器拉满衰减 -> 近似纯正弦（每周期 2 次过零，便于测音高）
    opl3_reg(0, 0x60, 0xf0);
    opl3_reg(0, 0x80, 0x77);
    opl3_reg(0, 0x23, 0x21);
    opl3_reg(0, 0x43, 0x00);
    opl3_reg(0, 0x63, 0xf0);
    opl3_reg(0, 0x83, 0x77);
    opl3_reg(0, 0xc0, 0x00);
    opl3_reg(0, 0xa0, 0x98);
    opl3_reg(0, 0xb0, 0x31);

    run_ns(400000);                   // 等写 FIFO 排空（22 字节 x 8us = 176us）

    // ---- 统计窗口：2 ms ----
    double WIN_NS = 2000000.0;
    if (const char* w = getenv("WIN_NS")) WIN_NS = atof(w);
    int  lmin = 32767, lmax = -32768, rmin = 32767, rmax = -32768;
    long long nL = 0, nR = 0, nz = 0, samples = 0, zc = 0;
    int lastl = (short)dut->left, lastr = (short)dut->right;
    int prevl = lastl;                // 上一次采样值，用于过零判断
    double t_ns = 0.0;
    const double dt_ns = 1e9 / (2.0 * MCLK_HZ);   // 一个半沿的纳秒数
    while (t_ns < WIN_NS) {
        step();
        t_ns += dt_ns;
        samples++;
        int l = (short)dut->left, r = (short)dut->right;
        if (l != lastl) { nL++; lastl = l; }      // 左/右分开计数：各 = 出样率
        if (r != lastr) { nR++; lastr = r; }
        // 过零次数（只用采样值变化时判断；不受"相邻样本相同"的漏计影响）
        if (l != prevl) { if ((l >= 0) != (prevl >= 0)) zc++; prevl = l; }
        if (l || r) nz++;
        if (l < lmin) lmin = l; if (l > lmax) lmax = l;
        if (r < rmin) rmin = r; if (r > rmax) rmax = r;
    }

    double sec = WIN_NS / 1e9;
    // fnum=0x198=408, block=4 => f_out = fnum * fs / 2^16；纯正弦每周期 2 次过零
    double fout   = (zc / 2.0) / sec;   // 每周期 2 次过零
    double fs_est = fout * 65536.0 / 408.0;
    printf("left : min=%6d max=%6d  更新 %lld 次\n", lmin, lmax, nL);
    printf("right: min=%6d max=%6d  更新 %lld 次\n", rmin, rmax, nR);
    printf("实测音高 = %.2f Hz (过零 %lld 次)  ->  反推出样率 = %.1f Hz\n", fout, zc, fs_est);
    printf("出样率偏差: %+.2f%%   (理论 49716 Hz)   [更新计数里被漏掉的相同相邻样本 %+.1f%%]\n",
           100.0 * (fs_est - 49716.0) / 49716.0,
           100.0 * (nL / sec - fs_est) / (fs_est > 0 ? fs_est : 1));
    printf("非零占比 %.1f%%\n", 100.0 * nz / (double)samples);
    if (lmax > lmin || rmax > rmin) printf("=> 有波形\n"); else printf("=> 输出恒定\n");
    dut->final(); delete dut;
    return 0;
}
