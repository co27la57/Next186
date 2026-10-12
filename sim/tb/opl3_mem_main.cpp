// sim/tb/opl3_mem_main.cpp — 离线验证 opl3_mem（双口 BRAM + opl3.mem 加载 + 读延迟）
//
// 验证点：
//   1. opl3.mem 是否被 $readmemh 正确载入（A 口逐字节读前 6 字节，应 = C3 00 01 00 00 C3）
//   2. 双口字/字节映射（B 口 16bit 字 = {奇数地址, 偶数地址}，little-endian）
//   3. A/B 共享同一片存储（写 B 口能从 A 口读出，反之亦然）
//   4. ★ 读延迟到底是 0 拍（组合读）还是 1 拍（寄存读）—— 这是移植的关键差异
#include "Vopl3_mem.h"
#include "verilated.h"
#include <cstdio>

static Vopl3_mem* dut;
static int errs = 0;

static void tick() {
    dut->clock = 0; dut->eval();
    dut->clock = 1; dut->eval();
}

static void chk(const char* name, unsigned got, unsigned exp, int wide16) {
    if (got != exp) {
        if (wide16) printf("FAIL %-28s got=%04X exp=%04X\n", name, got, exp);
        else        printf("FAIL %-28s got=%02X  exp=%02X\n", name, got, exp);
        errs++;
    } else {
        if (wide16) printf("PASS %-28s = %04X\n", name, got);
        else        printf("PASS %-28s = %02X\n", name, got);
    }
}

static unsigned a_read(unsigned addr) {
    dut->wren_a = 0; dut->wren_b = 0;
    dut->address_a = addr;
    tick();
    return (unsigned)dut->q_a;
}
static unsigned b_read(unsigned waddr) {
    dut->wren_a = 0; dut->wren_b = 0;
    dut->address_b = waddr;
    tick();
    return (unsigned)dut->q_b;
}
static void a_write(unsigned addr, unsigned val) {
    dut->wren_a = 1; dut->wren_b = 0;
    dut->address_a = addr; dut->data_a = val & 0xFF;
    tick();
    dut->wren_a = 0;
}
static void b_write(unsigned waddr, unsigned val) {
    dut->wren_a = 0; dut->wren_b = 1;
    dut->address_b = waddr; dut->data_b = val & 0xFFFF;
    tick();
    dut->wren_b = 0;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vopl3_mem;

    dut->clock = 0;
    dut->wren_a = 0; dut->wren_b = 0;
    dut->address_a = 0; dut->address_b = 0;
    dut->data_a = 0; dut->data_b = 0;
    dut->eval();
    tick(); tick();   // 让 $readmemh 之后的输出稳定

    printf("=================================================\n");
    printf(" opl3_mem 离线验证 (Verilator)\n");
    printf("=================================================\n\n");

    printf("--- 1. opl3.mem 是否加载 (A口读前6字节, 应=C3 00 01 00 00 C3) ---\n");
    chk("A[0] mem第1行", a_read(0), 0xC3, 0);
    chk("A[1] mem第2行", a_read(1), 0x00, 0);
    chk("A[2] mem第3行", a_read(2), 0x01, 0);
    chk("A[3] mem第4行", a_read(3), 0x00, 0);
    chk("A[4] mem第5行", a_read(4), 0x00, 0);
    chk("A[5] mem第6行", a_read(5), 0xC3, 0);
    printf("\n");

    printf("--- 2. 双口映射 (B口16bit字, 低字节在偶地址) ---\n");
    chk("B word0 = {A[1],A[0]}", b_read(0), 0x00C3, 1);
    chk("B word1 = {A[3],A[2]}", b_read(1), 0x0001, 1);
    chk("B word2 = {A[5],A[4]}", b_read(2), 0xC300, 1);
    printf("\n");

    printf("--- 3. A/B 共享存储 + 字节序 ---\n");
    b_write(1, 0x1234);
    chk("写B word1=1234 -> A[2]低字节", a_read(2), 0x34, 0);
    chk("写B word1=1234 -> A[3]高字节", a_read(3), 0x12, 0);
    a_write(0, 0x5A);
    chk("写A[0]=5A -> 回读A[0]", a_read(0), 0x5A, 0);
    chk("写A[0]=5A -> B word0",   b_read(0), 0x005A, 1);
    printf("\n");

    printf("--- 4. ★ 读延迟测量 (原Quartus=UNREGISTERED 0拍) ---\n");
    dut->wren_a = 0; dut->wren_b = 0;
    unsigned v6 = a_read(6);
    unsigned v7 = a_read(7);
    printf("  基准: A[6]=%02X  A[7]=%02X (来自opl3.mem)\n", v6, v7);
    // 当前停在地址7(q_a=v7)。改成地址6，但先不给时钟边沿：
    dut->address_a = 6;
    dut->clock = 0; dut->eval();
    printf("  改地址=6 但未给边沿: q_a = %02X\n", (unsigned)dut->q_a);
    if ((unsigned)dut->q_a == v6)
        printf("    => 立刻变化 = 组合读(0拍)，与原版一致\n");
    else
        printf("    => 仍为 %02X，未立刻变 = 不是组合读\n", (unsigned)dut->q_a);
    dut->clock = 1; dut->eval();
    printf("  给出第1个posedge后:  q_a = %02X (期望 %02X)\n", (unsigned)dut->q_a, v6);
    if ((unsigned)dut->q_a == v6)
        printf("    => ★ 读延迟 = 1 拍 (寄存读)\n");
    else
        printf("    => ★ 读延迟异常 (>1拍 或 未更新)\n");
    printf("\n");

    printf("=================================================\n");
    if (errs == 0) printf(" 结果: 全部断言 PASS (0 错误)\n");
    else           printf(" 结果: %d 处断言 FAIL\n", errs);
    printf("=================================================\n");

    dut->final();
    delete dut;
    return errs != 0;
}
