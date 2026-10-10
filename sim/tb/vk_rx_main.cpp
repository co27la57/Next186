// sim/tb/vk_rx_main.cpp - clock driver for the kbd_gpio_rx handshake test.
#include "Vvk_rx.h"
#include "verilated.h"

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vvk_rx* dut = new Vvk_rx;

    dut->clk = 0; dut->rst_n = 0;
    for (int i = 0; i < 10; i++) { dut->clk = !dut->clk; dut->eval(); }

    dut->rst_n = 1;
    for (long c = 0; c < 4000000 && !Verilated::gotFinish(); c++) {
        dut->clk = !dut->clk;
        dut->eval();
    }

    dut->final();
    delete dut;
    return 0;
}
