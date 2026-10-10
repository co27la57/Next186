// sim/linkup/sim_main.cpp - minimal C++ harness for the toolchain link-up test.
#include "Vblinky.h"
#include "verilated.h"
#include <cstdio>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vblinky* dut = new Vblinky;

    dut->rst = 1;
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();

    dut->rst = 0;
    for (int i = 0; i < 20; i++) {
        dut->clk = 0; dut->eval();
        dut->clk = 1; dut->eval();
        printf("cycle %2d  cnt=%3d\n", i, (int)dut->cnt);
    }

    dut->final();
    delete dut;
    printf("LINKUP-OK\n");
    return 0;
}
