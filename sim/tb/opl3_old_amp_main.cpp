// sim/tb/opl3_old_amp_main.cpp —— 旧核（opl3.v + opl3seq.v + 内部 Z80）实际输出幅度
// ---------------------------------------------------------------------------
// 目的：用**同一组寄存器**分别跑新旧两核，直接比数值（这是我之前的方法死角：
//       只用"单算子理论满幅都是 ~4095"推断，没有实测过）。
//
// 时序要点（踩过坑）：
//   * opl3_in 是 fall-through FIFO，wrreq = ce && wr 是**电平**信号 ——
//     若 ce 保持多个 cpu_clk，同一条命令会被写入多次，几百条就把 256 深 FIFO 撑满，
//     Z80 永远消费不完（症状：qempty 一直为 0、channels=0、left 恒 0）。
//     ⇒ 这里 ce 只保持 1 个 cpu_clk。
//   * stb44100 必须是**每 1134 个 clk 一个 1 拍脉冲**（50MHz / 44.1kHz），
//     用"每 64 步翻转一次"会把音频推进速度搞成 35 倍。
//
// 寄存器序列与 sim/tb/opl3_ym_amp_main.cpp 逐字节相同。
// 跑法（cwd=imports/，需要 ./*.mem）：
//   python sim/build.py --top opl3_dbg2 --out sim/run/opl3_old_amp \
//     opl3.v opl3seq.v NextZ80CPU.v NextZ80ALU.v NextZ80Reg.v \
//     sim/tb/opl3_sim_blackboxes.v sim/tb/xpm_fifo_async_stub.v \
//     sim/tb/opl3_dbg2.v sim/tb/opl3_old_amp_main.cpp
//   ./sim/run/opl3_old_amp/opl3_dbg2.exe
// ---------------------------------------------------------------------------
#include "Vopl3_dbg2.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>

static Vopl3_dbg2* dut;
static long long clks = 0;          // 完整时钟数

static void half() { dut->clk ^= 1; dut->cpu_clk ^= 1; dut->eval(); }
static void run_clk(long long n) {
    for (long long i = 0; i < n; i++) {
        dut->stb44100 = ((clks % 1134) == 0);   // 44.1kHz 单拍脉冲
        half(); half();
        clks++;
    }
}

static void write_port(unsigned a, unsigned d) {
    dut->addr = a & 3; dut->din = d & 0xFF;
    dut->ce = 1; dut->wr = 1;
    half(); half();                       // 恰好 1 个 clk，1 个上升沿 -> 1 次入队
    dut->ce = 0; dut->wr = 0; dut->din = 0;
    half(); half();
    clks++;
}
static void write_reg(unsigned reg, unsigned val) {
    write_port((reg & 0x100) ? 2 : 0, reg & 0xff);
    write_port((reg & 0x100) ? 3 : 1, val);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vopl3_dbg2;
    dut->clk = 0; dut->cpu_clk = 0;
    dut->addr = 0; dut->din = 0; dut->ce = 0; dut->wr = 0;
    dut->stb44100 = 0; dut->reset = 1;
    dut->eval();

    printf("=== 旧核 opl3 实际输出幅度 ===\n");
    run_clk(1000);
    dut->reset = 0;
    run_clk(200000);                       // 等内部 Z80 固件初始化
    printf("    Z80 初始化后: qempty=%d ready=%d channels=0x%x\n",
           (int)dut->dbg_qempty, (int)dut->dbg_ready, (int)dut->dbg_channels);

    // ---- 与 opl3_ym_amp_main.cpp 逐字节相同的序列 ----
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
    printf("[1] 4 通道 TL=0 已写入，qempty=%d\n", (int)dut->dbg_qempty);

    run_clk(100000);                       // 让 Z80 处理命令 + 包络 attack 起来

    // ---- 测量 0.1 s（44.1kHz 下约 4410 个样本）----
    long long n = 0, nz = 0, changes = 0;
    int Lmin = 1 << 30, Lmax = -(1 << 30), Rmin = 1 << 30, Rmax = -(1 << 30);
    int lastl = (short)dut->left;
    for (long long i = 0; i < 4410000; i++) {
        run_clk(1);
        int l = (int)(short)dut->left, r = (int)(short)dut->right;
        if (l < Lmin) Lmin = l; if (l > Lmax) Lmax = l;
        if (r < Rmin) Rmin = r; if (r > Rmax) Rmax = r;
        if (l || r) nz++;
        if (l != lastl) { changes++; lastl = l; }
        n++;
    }
    printf("\n--------------- 结果（旧核）---------------\n");
    printf("left : %6d .. %6d\n", Lmin, Lmax);
    printf("right: %6d .. %6d\n", Rmin, Rmax);
    printf("峰值幅度 = %d  (占 16bit 满幅 %.2f%%)\n",
           (Lmax > -Lmin ? Lmax : -Lmin), 100.0 * (Lmax > -Lmin ? Lmax : -Lmin) / 32767.0);
    printf("非零样本 %.1f%%\n", 100.0 * nz / (double)n);
    printf("    诊断(末): qempty=%d ready=%d channels=0x%x\n",
           (int)dut->dbg_qempty, (int)dut->dbg_ready, (int)dut->dbg_channels);
    printf("------------------------------------------\n");
    dut->final(); delete dut;
    return 0;
}
