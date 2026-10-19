// sim/tb/opl3_slotprobe_main.cpp — 验证 opl3seq 新增的槽位参数探针
// ---------------------------------------------------------------------------
// 目的：确认 dbg_slot_tll/dbg_slot_vol/dbg_slot_id 在 STATE 12/13 正确锁存，
//   即每遍(pass)对每个 (CH,OP) 槽位各锁一次，且值与 OPL3Struct 内容一致。
//   顺带在纯待机(不灌命令)下看各槽位上电初值（预期全零，与 opl3.mem 分析互证）。
// 跑法（cwd=imports/）：
//   python sim/build.py --top opl3_dbg --out sim/run/opl3_slotprobe --run \
//     opl3.v opl3seq.v NextZ80CPU.v NextZ80ALU.v NextZ80Reg.v \
//     sim/tb/opl3_sim_blackboxes.v sim/tb/xpm_fifo_async_stub.v \
//     sim/tb/opl3_dbg.v sim/tb/opl3_slotprobe_main.cpp
// ---------------------------------------------------------------------------
#include "Vopl3_dbg.h"
#include "verilated.h"
#include <cstdio>
#include <map>

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

    printf("=== OPL3 槽位参数探针验证（dbg_slot_tll/vol/id @ STATE 12/13）===\n");
    run(2000);
    dut->reset = 0;
    printf("[1] 等内部 Z80 初始化 130 万 clk ...\n");
    run(1300000);

    // 统计 latch 事件：dbg_slot_id 每变化一次算一次锁存
    printf("[2] 观测 60 万 clk（stb44100 每 128 拍翻转 => 音序器持续跑）...\n");
    std::map<int, int> slot_seen;      // slot_id -> 次数
    std::map<int, int> slot_tll;       // slot_id -> 最后一次 tll
    std::map<int, int> slot_vol;       // slot_id -> 最后一次 vol
    int last_id = -1;
    long long latch_events = 0;
    int sbdiv = 0;
    for (long long i = 0; i < 600000; i++) {
        step();
        if (++sbdiv >= 64) { sbdiv = 0; dut->stb44100 ^= 1; }
        int id = dut->dbg_slot_id;
        if (id != last_id) {           // 锁存跳变 = 新槽位被处理
            last_id = id;
            latch_events++;
            slot_seen[id]++;
            slot_tll[id] = dut->dbg_slot_tll;
            slot_vol[id] = dut->dbg_slot_vol;
        }
    }

    printf("\n--------------- 结果 ---------------\n");
    printf("锁存事件总数 = %lld，出现过的不同 slot_id = %zu（预期 36 = 18CH x 2OP）\n",
           latch_events, slot_seen.size());
    printf("slot 清单（id = {OP,CH[4:0]}）：\n");
    for (auto& kv : slot_seen) {
        int op = (kv.first >> 5) & 1, ch = kv.first & 0x1F;
        printf("  OP%d CH%-2d : 锁存 %6d 次, TLL=0x%04x, VOL=0x%03x\n",
               op, ch, kv.second, slot_tll[kv.first], slot_vol[kv.first]);
    }
    int miss = 0;
    for (int ch = 0; ch < 18; ch++)
        for (int op = 0; op < 2; op++)
            if (!slot_seen.count((op << 5) | ch)) miss++;
    if (miss == 0 && slot_seen.size() == 36)
        printf("=> ★ 36 个槽位全部被锁存，探针工作正常\n");
    else
        printf("=> ★ 有 %d 个槽位未出现（检查 STATE 常量或 stb44100 驱动）\n", miss);
    printf("-------------------------------------\n");
    dut->final(); delete dut;
    return 0;
}
