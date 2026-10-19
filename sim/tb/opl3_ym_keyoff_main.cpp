// sim/tb/opl3_ym_keyoff_main.cpp —— 复现"停止演奏后通道还在响"
// ---------------------------------------------------------------------------
// 现场：播放时某个通道卡在发声，音乐停止后还在响、音高异常。
//
// 机理假设（本台架用来验证）：
//   重放某个寄存器字节时，CS/WR 有效约 2us，而核心内部的写脉冲在 ~1.1us 后才出现。
//   如果这期间 CPU 来读状态口 0x388（游戏会不停轮询），原实现里
//       core_addr = io_rd ? cpu_addr : rep_d[9:8]
//   会把地址瞬间切走，而 wr_n 仍有效 ⇒ 写脉冲落到**错误的寄存器**。
//   key-off 写错地方 ⇒ 通道永远不关。
//
// 台架流程：
//   ① 正常起一个音（key-on），测幅度；
//   ② 发 key-off（0xB0 bit5=0），**在重放期间疯狂读 0x388**；
//   ③ 等释放结束后测幅度 —— 应该回到 ~0。
//   如果通道没关掉，幅度会保持在高位。
//
// 跑法（cwd=imports/）：
//   python sim/build.py --top opl3_ym --out sim/run/opl3_ym_keyoff --run \
//     opl3_ym.v ymf262.sv ym_lib.v sim/tb/opl3_ym_keyoff_main.cpp
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
// 一次状态口读（游戏每帧会做很多次）
static void read_status() {
    dut->cpu_addr = 0; dut->cpu_din = 0;
    dut->cpu_ce = 1; dut->cpu_wr = 0;
    run_ns(200);
    dut->cpu_ce = 0;
    run_ns(200);
}

static int peak(double ms) {
    int mn = 1 << 30, mx = -(1 << 30);
    double t = 0; const double dt = 1e9 / (2.0 * MCLK_HZ);
    while (t < ms * 1e6) {
        step(); t += dt;
        int l = (short)dut->left;
        if (l < mn) mn = l; if (l > mx) mx = l;
    }
    return mx > -mn ? mx : -mn;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (const char* e = getenv("MCLK_MHZ")) MCLK_HZ = atof(e) * 1e6;

    dut = new Vopl3_ym;
    dut->mclk = 0; dut->rst = 0;
    dut->cpu_ce = 0; dut->cpu_wr = 0; dut->cpu_addr = 0; dut->cpu_din = 0;
    dut->vol_ce = 0; dut->mst_ce = 0;
    dut->eval();

    printf("=== key-off 可靠性测试（重放期间持续读状态口）===\n");
    run_ns(1000); dut->rst = 1; run_ns(100000);

    // 起音：通道0，两算子 TL=0，AR=15，RR=15（这样才能快速释放）
    reg_(0, 0x20, 0x21); reg_(0, 0x40, 0x00); reg_(0, 0x60, 0xf0); reg_(0, 0x80, 0xff);
    reg_(0, 0x23, 0x21); reg_(0, 0x43, 0x00); reg_(0, 0x63, 0xf0); reg_(0, 0x83, 0xff);
    reg_(0, 0xc0, 0x00); reg_(0, 0xa0, 0x98);
    reg_(0, 0xb0, 0x31);                  // key-on
    run_ns(300000);
    int p_on = peak(20);
    printf("[1] 起音后峰值 = %d\n", p_on);

    // key-off：0xB0 的 bit5 清零
    printf("[2] 发 key-off，并在重放期间持续读 0x388 ...\n");
    bus_write(0, 0xb0);                   // 地址字节入队
    // ★ 关键：在这两个字节被重放期间疯狂读状态口
    for (int i = 0; i < 60; i++) read_status();
    bus_write(1, 0x11);                   // 数据字节（bit5=0）入队
    for (int i = 0; i < 200; i++) read_status();   // 覆盖整个重放窗口

    run_ns(20000000);                     // 等包络释放（RR=15 => 很快）
    int p_off = peak(20);
    printf("[3] key-off 之后峰值 = %d\n", p_off);
    printf("    残余比例 = %.1f%%\n", p_on ? 100.0 * p_off / p_on : 0.0);

    if (p_off < p_on / 20)
        printf("=> ✔ 通道已关闭（key-off 生效）\n");
    else
        printf("=> ✘ 通道没关掉！key-off 被写到了错误的寄存器\n");

    printf("    ovf(丢字节标志) = %d\n", (int)dut->ovf);
    dut->final(); delete dut;
    return 0;
}
