#include <verilated.h>
#include "Vstage2_switch.h"
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vstage2_switch* top = new Vstage2_switch;
    for (long i = 0; i < 1000; i++) { top->clk = !top->clk; top->eval(); }
    delete top;
    return 0;
}
