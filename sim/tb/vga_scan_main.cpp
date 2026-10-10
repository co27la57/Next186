// sim/tb/vga_scan_main.cpp — vga_scan 台架的最小驱动
// 台架的全部工作都在 vga_scan.v 的 initial 块里(纯几何计算 + $display),
// 这里只需要把 Verilator 的 initial 块执行起来。
#include "Vvga_scan.h"
#include "verilated.h"
#include <cstdio>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vvga_scan* dut = new Vvga_scan;

    // initial 块在首次 eval 时执行; $finish 会置 gotFinish()。
    for (int i = 0; i < 8 && !Verilated::gotFinish(); i++) {
        dut->eval();
    }

    dut->final();
    delete dut;
    return 0;
}
