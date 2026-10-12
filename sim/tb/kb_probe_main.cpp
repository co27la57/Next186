#include <verilated.h>
#include "Vkb_probe.h"
#include <cstdio>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vkb_probe* top = new Vkb_probe;
    top->clk = 0; top->rst_n = 0;
    for (int i = 0; i < 8; i++) { top->clk = !top->clk; top->eval(); }
    top->rst_n = 1;
    for (long i = 0; i < 20000; i++) {
        top->clk = !top->clk; top->eval();
    }
    delete top;
    return 0;
}
