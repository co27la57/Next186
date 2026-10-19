// sim/tb/opl3_ym_vol_main.cpp —— 验证 0x38C 音量通路（50MHz 边沿检测能否抓到窄脉冲）
// ---------------------------------------------------------------------------
// 背景：最初把音量寄存器放在 ddr_186 里用 `posedge clk_cpu`(25MHz) 采样，
//       上板后 `OPLVOL 3` 写不进去（ID=A 说明位流是新的、读回也通）。
//       机理推断：CPU_CE 的有效窗口可能只有 ~20ns，正好落在两个 25MHz 上升沿之间。
//       本台架把音量逻辑放进 opl3_ym 的 50MHz 域后再验一次：
//         ① 给一个 **20ns 宽**的 vol_ce 脉冲，看 att 是否变成 3；
//         ② 看 left/right 幅度是否按 ÷8 缩小。
//
// 跑法（cwd=imports/）：
//   python sim/build.py --top opl3_ym --out sim/run/opl3_ym_vol --run \
//     opl3_ym.v ymf262.sv ym_lib.sv sim/tb/opl3_ym_vol_main.cpp
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
static void reg_(int bank, int r, int v) {
    bus_write(bank ? 2 : 0, r); bus_write(bank ? 3 : 1, v);
}

// 模拟一次 0x38C 写：vol_ce 只保持 pulse_ns
static void vol_write(int val, double pulse_ns) {
    dut->cpu_addr = 0; dut->cpu_din = val & 0xff;
    dut->cpu_ce = 0;            // 不是 OPL3 端口，OPL3 写通路不能动
    dut->cpu_wr = 1;
    dut->vol_ce = 1;
    run_ns(pulse_ns);
    dut->vol_ce = 0;
    run_ns(200);
}

struct Res { int lmin, lmax; };
static Res measure(double ms) {
    Res r; r.lmin = 1 << 30; r.lmax = -(1 << 30);
    double t = 0; const double dt = 1e9 / (2.0 * MCLK_HZ);
    while (t < ms * 1e6) {
        step(); t += dt;
        int l = (short)dut->left;
        if (l < r.lmin) r.lmin = l; if (l > r.lmax) r.lmax = l;
    }
    return r;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (const char* e = getenv("MCLK_MHZ")) MCLK_HZ = atof(e) * 1e6;

    dut = new Vopl3_ym;
    dut->mclk = 0; dut->rst = 0;
    dut->cpu_ce = 0; dut->cpu_wr = 0; dut->cpu_addr = 0; dut->cpu_din = 0;
    dut->vol_ce = 0;
    dut->eval();

    printf("=== 0x38C 音量通路验证  MCLK=%.1f MHz ===\n", MCLK_HZ / 1e6);
    run_ns(1000); dut->rst = 1; run_ns(100000);

    // 标准单音
    reg_(0, 0x20, 0x21); reg_(0, 0x40, 0x3f); reg_(0, 0x60, 0xf0);
    reg_(0, 0x80, 0x0f); reg_(0, 0x23, 0x21); reg_(0, 0x43, 0x00);
    reg_(0, 0x63, 0xf0); reg_(0, 0x83, 0x0f); reg_(0, 0xc0, 0x00);
    reg_(0, 0xa0, 0x98); reg_(0, 0xb0, 0x31);
    run_ns(500000);

    Res a = measure(50);
    printf("[att=0] left %6d .. %6d   峰值 %d\n", a.lmin, a.lmax,
           (a.lmax > -a.lmin ? a.lmax : -a.lmin));

    // ---- 关键：20ns 宽的写脉冲（= 半个 25MHz 周期）----
    printf("---- 发一个 20ns 宽的 vol_ce 脉冲，值=3 ----\n");
    vol_write(3, 20.0);
    printf("   att 读回 = %d   vol_hit = %d\n", (int)dut->att, (int)dut->vol_hit);

    run_ns(100000);
    Res b = measure(50);
    printf("[att=3] left %6d .. %6d   峰值 %d\n", b.lmin, b.lmax,
           (b.lmax > -b.lmin ? b.lmax : -b.lmin));

    int pa = (a.lmax > -a.lmin ? a.lmax : -a.lmin);
    int pb = (b.lmax > -b.lmin ? b.lmax : -b.lmin);
    printf("\n衰减比 = %.2f  (期望 ≈8)\n", pa ? (double)pa / (pb ? pb : 1) : 0.0);

    // ---- 再试更窄的脉冲，找边界 ----
    for (double w : {10.0, 6.0, 4.0}) {
        vol_write(0, w);                       // 先清零
        int a0 = (int)dut->att;
        vol_write(5, w);
        int a5 = (int)dut->att;
        printf("  脉宽 %4.0f ns: 写 0 -> att=%d, 写 5 -> att=%d %s\n",
               w, a0, a5, a5 == 5 ? "✔" : "✘ 漏了");
    }

    printf("\n=> %s\n", (int)dut->vol_hit ? "vol_hit=1，写确实被 50MHz 域捕捉到" : "vol_hit=0，仍未捕捉");
    dut->final(); delete dut;
    return 0;
}
