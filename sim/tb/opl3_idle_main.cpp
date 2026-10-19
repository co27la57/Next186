// sim/tb/opl3_idle_main.cpp — 测 OPL3 的"纯待机"输出（不写任何命令）
// ---------------------------------------------------------------------------
// 目的：确认 OPL3 在【完全不灌命令】时 left/right 是不是 0。
//   若不是 0（有直流/常量）=> 它就是待机沙沙声的嫌疑源（混音会把它加进去）。
// 跑法（cwd=imports/）：
//   python sim/build.py --top opl3_dbg --out sim/run/opl3_idle --run \
//     opl3.v opl3seq.v NextZ80CPU.v NextZ80ALU.v NextZ80Reg.v \
//     sim/tb/opl3_sim_blackboxes.v sim/tb/xpm_fifo_async_stub.v \
//     sim/tb/opl3_dbg.v sim/tb/opl3_idle_main.cpp
// ---------------------------------------------------------------------------
#include "Vopl3_dbg.h"
#include "verilated.h"
#include <cstdio>

static Vopl3_dbg* dut;
static long long cyc = 0;
static void step() { dut->clk ^= 1; dut->cpu_clk ^= 1; dut->eval(); cyc++; }
static void run(int n) { for (int i = 0; i < n; i++) step(); }

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vopl3_dbg;
    dut->clk = 0; dut->cpu_clk = 0;
    dut->addr = 0; dut->din = 0; dut->ce = 0; dut->wr = 0;
    dut->stb44100 = 0; dut->reset = 1;
    dut->eval();

    printf("=== OPL3 纯待机输出测量（不写任何命令）===\n");
    run(2000);
    dut->reset = 0;
    printf("[1] 等内部 Z80 初始化 130 万 clk ...\n");
    run(1300000);

    printf("[2] 观测 100 万 clk：left/right 是否恒 0 ...\n");
    int Lmin = 1 << 30, Lmax = -(1 << 30), Rmin = 1 << 30, Rmax = -(1 << 30);
    int limmin = 1 << 30, limmax = -(1 << 30);
    long long nz = 0, n = 0;
    int sbdiv = 0;
    for (long long i = 0; i < 1000000; i++) {
        step();
        if (++sbdiv >= 64) { sbdiv = 0; dut->stb44100 ^= 1; }
        int L = (int)(short)dut->left;
        int R = (int)(short)dut->right;
        int lim = (int)(short)dut->dbg_limacc;
        if (L || R) nz++;
        n++;
        if (L < Lmin) Lmin = L; if (L > Lmax) Lmax = L;
        if (R < Rmin) Rmin = R; if (R > Rmax) Rmax = R;
        if (lim < limmin) limmin = lim; if (lim > limmax) limmax = lim;
    }
    printf("\n--------------- 结果 ---------------\n");
    printf("left  : min=%6d max=%6d\n", Lmin, Lmax);
    printf("right : min=%6d max=%6d\n", Rmin, Rmax);
    printf("limAcc: min=%6d max=%6d\n", limmin, limmax);
    printf("非零 clk = %lld / %lld (%.2f%%)\n", nz, n, 100.0 * nz / n);
    if (nz == 0)
        printf("=> ★ OPL3 待机输出恒为 0（不贡献直流/噪声）\n");
    else
        printf("=> ★ OPL3 待机时输出非零（值域 %d..%d）—— 可能是沙沙声来源\n", Lmin, Lmax);
    printf("-------------------------------------\n");
    dut->final(); delete dut;
    return 0;
}
