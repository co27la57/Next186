// Run from imports/ so the production $readmemh files are found.
// Uses production opl3/opl3seq/NextZ80/Next186_BlackBoxes and a FWFT FIFO stub
// matching the explicit production FIFO setting. It does not certify XPM CDC
// implementation details.
//
// PowerShell, working directory = imports (all commands use existing tools):
// $env:ZIG_GLOBAL_CACHE_DIR = "$PWD/sim/run/opl3_led/zig-global"
// $env:ZIG_LOCAL_CACHE_DIR = "$PWD/sim/run/opl3_led/zig-local"
// & 'C:/Users/Administrator/.workbuddy-ai/binaries/python/envs/default/Scripts/python.exe' sim/build.py --top opl3_led_tb --out sim/run/opl3_led --run sim/tb/opl3_led_tb.v sim/tb/opl3_led_main.cpp opl3.v opl3seq.v NextZ80CPU.v NextZ80ALU.v NextZ80Reg.v Next186_BlackBoxes.v sim/tb/xpm_fifo_async_stub.v
//
// Full-core diagnostic: change --out to sim/run/opl3_led_full and append
// --extra=-GDIRECTED_TEST=0. This exercises the complete synthetic CPU/audio
// path; it is separate from the directed monitor regression below.
#include "Vopl3_led_tb.h"
#include "verilated.h"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstdint>

static Vopl3_led_tb *dut;
static unsigned long long cycles = 0, audio_ticks = 0;
static unsigned hit_count[4] = {}, peak[4] = {};
static unsigned expected_hold[4] = {};
static unsigned long long last_hit_tick[4] = {};
static unsigned errors = 0;
static constexpr unsigned AUDIO_PERIOD = 1134; // 50 MHz / about 44.1 kHz

static void tick() {
    dut->clk = dut->cpu_clk = 0;
    dut->stb44100 = (cycles % AUDIO_PERIOD) == 0;
    dut->eval();
    const unsigned hits = dut->sample_hit;
    const bool audio_tick = dut->audio_tick;
    const bool reset = dut->reset;
    if (audio_tick) ++audio_ticks;
    if (dut->seq_state == 21 && dut->sample_channel >= 1 && dut->sample_channel <= 4) {
        const unsigned ch = dut->sample_channel - 1;
        const int value = static_cast<short>(dut->channel_sample);
        peak[ch] = std::max(peak[ch], static_cast<unsigned>(std::abs(value)));
    }
    for (unsigned ch = 0; ch < 4; ++ch) {
        if (hits & (1u << ch)) {
            ++hit_count[ch];
            last_hit_tick[ch] = audio_ticks;
        }
        if (reset) expected_hold[ch] = 0;
        else if (hits & (1u << ch)) expected_hold[ch] = 2205;
        else if (audio_tick && expected_hold[ch]) --expected_hold[ch];
    }
    dut->clk = dut->cpu_clk = 1;
    dut->eval();
    unsigned expected = 0;
    for (unsigned ch = 0; ch < 4; ++ch)
        if (!reset && expected_hold[ch]) expected |= 1u << ch;
    if (dut->channel_active != expected) {
        if (errors < 12) std::printf("FAIL hold/reset at cycle %llu: LEDs=%x expected=%x\n",
                                   cycles, dut->channel_active, expected);
        ++errors;
    }
    ++cycles;
}

static void run(unsigned clocks) { while (clocks--) tick(); }

static void write_port(unsigned addr, unsigned value) {
    dut->addr = addr;
    dut->din = value;
    dut->ce = dut->wr = 1;
    tick(); // exactly one CPU write edge, not repeated FIFO entries
    dut->ce = dut->wr = 0;
    run(20000); // ample time for firmware handling and queue drain
}

static void write_reg(unsigned reg, unsigned value) {
    write_port((reg & 0x100) ? 2 : 0, reg & 0xff);
    write_port((reg & 0x100) ? 3 : 1, value);
}

static void require(bool condition, const char *label) {
    std::printf("%s %s\n", condition ? "PASS" : "FAIL", label);
    if (!condition) ++errors;
}

static void print_channels(const char *label) {
    std::printf("%s: LEDs=%x peak=[%u,%u,%u,%u] hits=[%u,%u,%u,%u] ready=%u queue_empty=%u pc=%04x\n",
                label, dut->channel_active, peak[0], peak[1], peak[2], peak[3],
                hit_count[0], hit_count[1], hit_count[2], hit_count[3],
                dut->ready, dut->qempty, dut->cpu_addr);
}

static void clear_observations() {
    for (unsigned ch = 0; ch < 4; ++ch) peak[ch] = hit_count[ch] = 0;
}

static int directed_regression() {
    std::puts("Directed RAM-response test: real sequencer + real LED hold logic");
    dut->reset = 0;
    dut->test_samples = 0;
    dut->test_other_sample = 32767;
    dut->test_pan_enable = 0;
    run(AUDIO_PERIOD * 10);
    require(dut->channel_active == 0, "channels 4..17 cannot light LEDs 0..3");

    // Both sides of the signed threshold must reject magnitudes below 16.
    dut->test_samples = uint64_t(15) | (uint64_t(uint16_t(-15)) << 16) |
                        (uint64_t(1) << 32) | (uint64_t(uint16_t(-1)) << 48);
    clear_observations();
    run(AUDIO_PERIOD * 10);
    require(dut->channel_active == 0, "+15, -15, +1 and -1 remain dark");
    require(!(hit_count[0] | hit_count[1] | hit_count[2] | hit_count[3]),
            "sub-threshold channel samples produce no hits");

    for (unsigned ch = 0; ch < 4; ++ch) {
        const int value = (ch & 1) ? -16 : 16;
        dut->test_samples = uint64_t(uint16_t(value)) << (16 * ch);
        clear_observations();
        run(AUDIO_PERIOD * 10);
        print_channels("directed single channel");
        require(dut->channel_active == (1u << ch), "sample maps to exactly its own LED");
        for (unsigned other = 0; other < 4; ++other)
            require(other == ch ? hit_count[other] >= 8 : hit_count[other] == 0,
                    "sample-hit channel identity matches RAM word address");
        require(dut->left == 0 && dut->right == 0,
                "LED observes samples even when both audio pans are muted");

        dut->test_samples = 0;
        // Allow one outstanding synchronous RAM read to retire, then measure
        // the hold from the actual final hit's audio-tick timestamp.
        run(4);
        while (audio_ticks < last_hit_tick[ch] + 2204) tick();
        require(dut->channel_active == (1u << ch), "LED stays lit for first 2204 silent audio ticks");
        while (audio_ticks < last_hit_tick[ch] + 2205) tick();
        require(dut->channel_active == 0, "LED expires on silent audio tick 2205");
    }

    dut->test_samples = uint64_t(32767) | (uint64_t(uint16_t(-32768)) << 16) |
                       (uint64_t(16) << 32) | (uint64_t(uint16_t(-16)) << 48);
    run(AUDIO_PERIOD * 10);
    require(dut->channel_active == 15, "signed extrema and both threshold endpoints light all LEDs");
    dut->reset = 1;
    tick();
    require(dut->channel_active == 0, "reset clears all four lit LEDs in one clock");
    run(AUDIO_PERIOD * 3);
    require(dut->channel_active == 0, "reset suppresses new sample hits");
    std::printf("RESULT: %u errors, %llu clocks, %llu audio ticks; directed monitor regression\n",
                errors, cycles, audio_ticks);
    return errors ? 1 : 0;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vopl3_led_tb;
    dut->clk = dut->cpu_clk = 0;
    dut->addr = dut->din = dut->ce = dut->wr = dut->stb44100 = 0;
    dut->test_samples = dut->test_other_sample = dut->test_pan_enable = 0;
    dut->reset = 1;
    dut->eval();
    run(1000);
    require(dut->channel_active == 0, "reset clears all four LEDs");
    if (dut->directed_test) {
        const int result = directed_regression();
        dut->final();
        delete dut;
        return result;
    }
    dut->reset = 0;
    run(1000000);
    print_channels("boot");

    write_reg(0x01, 0x20); // waveform enable
    write_reg(0x105, 0x00); // OPL2-compatible, independent two-operator voices
    write_reg(0x104, 0x00); // no four-operator pairing
    write_reg(0xbd, 0x00); // no rhythm voices
    const unsigned modulator[4] = {0, 1, 2, 8};
    for (unsigned ch = 0; ch < 4; ++ch) {
        write_reg(0xb0 + ch, 0x11); // key off, block 4, fnum high 1
        for (unsigned op = 0; op < 2; ++op) {
            const unsigned slot = modulator[ch] + 3 * op;
            write_reg(0x20 + slot, 0x21); // sustain, frequency multiplier 1
            write_reg(0x40 + slot, 0x00); // maximum operator level
            write_reg(0x60 + slot, 0xf0); // fast attack, no decay
            write_reg(0x80 + slot, 0x0f); // no sustain attenuation, fast release
            write_reg(0xe0 + slot, 0x00); // sine
        }
        write_reg(0xc0 + ch, 0x31); // both sides; additive two-carrier algorithm
        write_reg(0xa0 + ch, 0x98 + ch * 8);
    }
    run(3000000);
    require(dut->channel_active == 0, "all key-off voices become silent");
    for (unsigned ch = 0; ch < 4; ++ch) {
        for (unsigned i = 0; i < 4; ++i) peak[i] = hit_count[i] = 0;
        write_reg(0xb0 + ch, 0x31);
        run(500000);
        print_channels("single voice on");
        require(dut->channel_active == (1u << ch), "only the selected voice lights its LED");
        require(hit_count[ch] > 10 && peak[ch] >= 16, "actual selected channel samples exceed threshold");
        write_reg(0xb0 + ch, 0x11);
        run(4000000); // 80 ms: fast envelope release plus 50 ms LED hold
        require(dut->channel_active == 0, "key-off and release expire the 50 ms hold");
    }
    for (unsigned ch = 0; ch < 4; ++ch) write_reg(0xb0 + ch, 0x31);
    run(500000);
    require(dut->channel_active == 15, "four independent voices light all four LEDs");
    dut->reset = 1;
    tick();
    require(dut->channel_active == 0, "reset clears lit LEDs immediately");
    std::printf("RESULT: %u errors, %llu clocks, %llu audio ticks; FIFO model is FWFT only\n",
                errors, cycles, audio_ticks);
    dut->final();
    delete dut;
    return errors ? 1 : 0;
}
