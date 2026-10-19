// sim/tb/opl3_clip_main.cpp — 测 opl3 的"硬削波"（离线）
// ---------------------------------------------------------------------------
// 目的：确认 opl3seq 的 16bit 限幅(limAcc)是否在真实演奏中被频繁触发。
//   limAcc = rAcc>32767 ? 0x7fff : rAcc<-32768 ? 0x8000 : rAcc[15:0]
//   即 rAcc 超出 16bit 时就"硬削波"。
//
// 跑法（cwd=imports/）：
//   python sim/build.py --top opl3_dbg --out sim/run/opl3_tb --run \
//     opl3.v opl3seq.v NextZ80CPU.v NextZ80ALU.v NextZ80Reg.v \
//     sim/tb/opl3_sim_blackboxes.v sim/tb/xpm_fifo_async_stub.v \
//     sim/tb/opl3_dbg.v sim/tb/opl3_clip_main.cpp
// ---------------------------------------------------------------------------
#include "Vopl3_dbg.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>

static Vopl3_dbg* dut;
static long long cyc = 0;

static void step() {
    dut->clk ^= 1; dut->cpu_clk ^= 1; dut->eval(); cyc++;
}
static void run(int n) { for (int i = 0; i < n; i++) step(); }

// 一次 CPU 写沿（严格一拍，避免重复入队）
static void write_port(unsigned a, unsigned d) {
    dut->addr = a & 3; dut->din = d & 0xFF; dut->ce = 1; dut->wr = 1;
    step();
    dut->ce = 0; dut->wr = 0; dut->din = 0;
    step();
}
static void write_reg(unsigned reg, unsigned val) {
    write_port((reg & 0x100) ? 2 : 0, reg & 0xff);
    write_port((reg & 0x100) ? 3 : 1, val);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vopl3_dbg;

    dut->clk = 0; dut->cpu_clk = 0;
    dut->addr = 0; dut->din = 0; dut->ce = 0; dut->wr = 0;
    dut->stb44100 = 0; dut->reset = 1;
    dut->eval();

    printf("=== opl3 硬削波测量 ===\n");
    run(2000);
    dut->reset = 0;

    // 等内部 Z80 初始化（约 55 万 clk 后开始 IORQ）
    printf("[1] 启动...\n");
    run(1300000);

    // ---- 写一套"4 通道最大声 + 加法双载波"的演奏序列（=用户 tb 的序列）----
    printf("[2] 写寄存器（4 通道，TL=0 最大声，加法双载波）...\n");
    write_reg(0x01, 0x20);
    write_reg(0x105, 0x00);
    write_reg(0x104, 0x00);
    write_reg(0xbd, 0x00);
    for (unsigned ch = 0; ch < 4; ch++) {
        write_reg(0xb0 + ch, 0x11);
        for (unsigned slot = ch; slot < ch + 16; slot += 3) {
            write_reg(0x20 + slot, 0x21);
            write_reg(0x40 + slot, 0x00);   // TL=0 最大
            write_reg(0x60 + slot, 0xf0);
            write_reg(0x80 + slot, 0x0f);
            write_reg(0xe0 + slot, 0x00);
        }
        write_reg(0xc0 + ch, 0x31);
        write_reg(0xa0 + ch, 0x98 + ch * 8);
    }
    for (unsigned ch = 0; ch < 4; ch++) write_reg(0xb0 + ch, 0x31);  // key on

    // ---- 观测 ----
    printf("[3] 观测 40 万个 clk：统计 limAcc 饱和率 / rAcc 范围 ...\n");
    long long sat_cycles = 0, total_cycles = 0;
    long long samples = 0, sat_samples = 0;
    int racc_min = 1 << 30, racc_max = -(1 << 30);
    int lim_min = 1 << 30, lim_max = -(1 << 30);
    int L_min = 1 << 30, L_max = -(1 << 30);
    const int N = 400000;
    int sbdiv = 0;
    for (int i = 0; i < N; i++) {
        step();
        if (++sbdiv >= 64) { sbdiv = 0; dut->stb44100 ^= 1; }

        int acc = (int)(((unsigned)dut->dbg_racc) & 0x7FFFFu);   // 19bit
        if (acc & 0x40000) acc -= 0x80000;                       // 手工符号扩展
        int lim = (int)(short)dut->dbg_limacc;
        int L   = (int)(short)dut->left;
        total_cycles++;
        if (lim == 32767 || lim == -32768) sat_cycles++;
        if (acc < racc_min) racc_min = acc;
        if (acc > racc_max) racc_max = acc;
        if (lim < lim_min) lim_min = lim;
        if (lim > lim_max) lim_max = lim;
        if (L < L_min) L_min = L;
        if (L > L_max) L_max = L;
        // A/B 在 STATE 22/25 被赋值 —— 这是"每通道一个样点"的时刻
        int st = (int)dut->dbg_seq_state;
        if (st == 22 || st == 25) {
            samples++;
            if (lim == 32767 || lim == -32768) sat_samples++;
        }
    }

    printf("\n--------------- 结果 ---------------\n");
    printf("rAcc 范围      : [%d .. %d]   (16bit 限幅线: -32768..32767)\n", racc_min, racc_max);
    printf("limAcc 范围    : [%d .. %d]\n", lim_min, lim_max);
    printf("left  范围     : [%d .. %d]\n", L_min, L_max);
    printf("clk 级饱和     : %lld / %lld  (%.2f%%)\n", sat_cycles, total_cycles,
           100.0 * sat_cycles / total_cycles);
    printf("样点级饱和     : %lld / %lld  (%.2f%)  [STATE 22/25 时刻]\n",
           sat_samples, samples, samples ? 100.0 * sat_samples / samples : 0.0);
    printf("超出 16bit 的程度: rAcc 峰值 %d (超出 %d)\n",
           (racc_max > -racc_min ? racc_max : -racc_min),
           (racc_max > -racc_min ? racc_max : -racc_min) - 32767);
    printf("-------------------------------------\n");

    dut->final();
    delete dut;
    return 0;
}
