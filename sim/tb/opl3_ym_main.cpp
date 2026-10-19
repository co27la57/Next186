// sim/tb/opl3_ym_main.cpp — opl3_ym（ymf262 核）离线功能验证
// ---------------------------------------------------------------------------
// 目的：在 Next186 的时钟配置（MCLK=50MHz + 14.318MHz 相位累加）下验证新 OPL3：
//   ① 走 186 的 I/O 总线时序（ce/wr/addr 保持一个 I/O 周期）能正确写入寄存器；
//   ② 写一个标准 Adlib 单音（2-op FM，通道0，key-on）后 left/right 有波形；
//   ③ 出样周期 ≈ 50MHz/49716Hz ≈ 1005 拍（验证 14.318MHz 时钟与出样率）。
// 跑法（cwd=imports/）：
//   python sim/build.py --top opl3_ym --out sim/run/opl3_ym --run \
//     opl3_ym.v ymf262.sv ym_lib.sv sim/tb/opl3_ym_main.cpp
// ---------------------------------------------------------------------------
#include "Vopl3_ym.h"
#include "verilated.h"
#include <cstdio>

static Vopl3_ym* dut;
static long long cyc = 0;
static void step() { dut->mclk ^= 1; dut->eval(); cyc++; }
static void run(int n) { for (int i = 0; i < n; i++) step(); }

// 模拟 186 的 I/O 写周期：地址/数据先稳定，ce/wr 保持约 40 拍 clk50（=160ns @25MHz clk_cpu）
static void bus_write(int addr2, int data) {
    dut->cpu_addr = addr2 & 3;
    dut->cpu_din  = data & 0xff;
    dut->cpu_ce   = 1;
    dut->cpu_wr   = 1;
    run(40);
    dut->cpu_ce   = 0;
    dut->cpu_wr   = 0;
    run(60);
}

// OPL3 寄存器写：先写 index(0x388/0x38A)，再写 data(0x389/0x38B)
static void opl3_reg(int bank, int reg, int val) {
    bus_write(bank ? 2 : 0, reg);
    bus_write(bank ? 3 : 1, val);
}

// 读状态口 0x388（验证回读通路）
static int opl3_status(void) {
    dut->cpu_addr = 0;
    dut->cpu_ce = 1; dut->cpu_wr = 0;
    run(2);
    int v = dut->cpu_dout;
    dut->cpu_ce = 0;
    run(4);
    return v;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vopl3_ym;
    dut->mclk = 0; dut->rst = 0;
    dut->cpu_ce = 0; dut->cpu_wr = 0; dut->cpu_addr = 0; dut->cpu_din = 0;
    dut->eval();

    printf("=== opl3_ym (ymf262) 离线验证 ===\n");
    run(200);
    dut->rst = 1;                 // 释放复位（对应 rstcount[18] 变 1）
    run(20000);
    printf("[1] 复位释放后状态口 0x388 = 0x%02x（应为 0x00，无定时器中断）\n", opl3_status());

    printf("[2] 写标准 Adlib 单音（通道0, 2-op FM, key-on）...\n");
    opl3_reg(0, 0x20, 0x21);      // OP0: MULT=1, EG=1
    opl3_reg(0, 0x40, 0x10);      // OP0: TL=16
    opl3_reg(0, 0x60, 0xf0);      // OP0: AR=15, DR=0
    opl3_reg(0, 0x80, 0x77);      // OP0: SL=7, RR=7
    opl3_reg(0, 0x23, 0x21);      // OP1: MULT=1, EG=1
    opl3_reg(0, 0x43, 0x00);      // OP1: TL=0
    opl3_reg(0, 0x63, 0xf0);      // OP1: AR=15
    opl3_reg(0, 0x83, 0x77);      // OP1: SL=7, RR=7
    opl3_reg(0, 0xc0, 0x00);      // FB=0, CNT=0 (FM)
    opl3_reg(0, 0xa0, 0x98);      // fnum[7:0]
    opl3_reg(0, 0xb0, 0x31);      // fnum[9:8] + block + KEY-ON

    printf("[3] 运行 1200000 拍（等 FIFO 以 8us/字节重放完 22 字节，再统计音频）...\n");
    int lmin = 32767, lmax = -32768, rmin = 32767, rmax = -32768;
    long long nz = 0, changes = 0;
    int lastl = 0, lastr = 0, last_change_cyc = (int)cyc;
    int period_sum = 0, period_n = 0;
    run(400000);   // 先等写 FIFO 排空（22 字节 x 8us = 176us = 176000 拍）+ 余量
    for (long long i = 0; i < 800000; i++) {
        step();
        int l = (short)dut->left, r = (short)dut->right;
        if (l != lastl || r != lastr) {
            if (changes > 0) { period_sum += (int)(cyc - last_change_cyc); period_n++; }
            last_change_cyc = (int)cyc;
            changes++;
            lastl = l; lastr = r;
        }
        if (l || r) nz++;
        if (l < lmin) lmin = l; if (l > lmax) lmax = l;
        if (r < rmin) rmin = r; if (r > rmax) rmax = r;
    }
    printf("\n--------------- 结果 ---------------\n");
    printf("left : min=%6d max=%6d\n", lmin, lmax);
    printf("right: min=%6d max=%6d\n", rmin, rmax);
    printf("非零占比: %.1f%%   出样更新次数=%lld\n", 100.0 * nz / 800000.0, changes);
    if (period_n) printf("平均出样周期: %.1f 拍 (理论 50e6/49716 = %.1f)\n",
                         (double)period_sum / period_n, 100e6 / 49716.0);
    if (lmax > lmin || rmax > rmin)
        printf("=> ★ 音频有波形输出，核心工作正常\n");
    else
        printf("=> ★ 输出恒定，核心可能没跑起来（查 MCLK/复位/寄存器写）\n");
    printf("-------------------------------------\n");
    dut->final(); delete dut;
    return 0;
}
