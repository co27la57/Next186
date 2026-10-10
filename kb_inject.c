// ============================================================================
// kb_inject.c — PetaLinux 用户态: 把按键翻译成 PS/2 scancode 注入 80186
// ----------------------------------------------------------------------------
// 两种输入源:
//   1) stdin 模式(主用, 本板无 USB 口):
//      ./kb_inject stdin 0x40400000
//      直接读当前终端(串口 / SSH)的按键, 解码后转发给 80186 —— 在 PetaLinux
//      终端里敲字, 字就出现在 80186 的 DOS 里。
//   2) evdev 模式(板子若有 USB 键盘时用):
//      ./kb_inject /dev/input/event0 0x40400000
//
// DOS 读的是 scancode 不是 ASCII, 所以本程序做完整解码:
//   - 可打印字符 -> set-1 scancode(大写自动带 Shift)
//   - Ctrl+A..Ctrl+Z -> Ctrl 修饰键(0x1d) + 字母键码(DOS 靠此识别 Ctrl+C)
//   - 方向键/Home/End -> E0 扩展序列(ESC[A/B/C/D 等终端转义序列解码)
//   - F1..F5 -> 功能键码
//   退出: Ctrl+]  (刻意避开 DOS 需要的 Ctrl+C)
//
// 编译 (PetaLinux 交叉工具链):
//   arm-linux-gnueabihf-gcc -O2 -o kb_inject kb_inject.c
//   file kb_inject   # 应显示 ARM
//
// 寄存器:
//   0x00 INJ_DATA  [W]  写 1 字节 scancode
//   0x04 INJ_STATUS[R]  bit0=非空 bit1=未满 bit[15:8]=计数
//   0x08 INJ_CTRL  [W]  bit0=注入使能 bit1=屏蔽物理PS/2
// ============================================================================
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/mman.h>
#include <linux/input.h>
#include <termios.h>   // stdin 原始模式(stdin 模式用)

#define REG_DATA   0x00
#define REG_STATUS 0x04
#define REG_CTRL   0x08

static volatile uint32_t *regs;

// 写一个 scancode 字节, 等待队列有空间
// ★ 必须有超时: 若外设地址不对(读到垃圾), 裸 while 会永久卡死,
//   导致再也读不到 stdin, Ctrl+] 也就无法退出 —— 之前正是这个坑。
static int inject_fail_count = 0;
static void inject_scancode(uint8_t sc) {
    int spins = 0;
    while (!(regs[REG_STATUS/4] & (1u << 1))) {
        if (++spins > 400) {                 // 400 * 50us = 20ms 超时
            if (++inject_fail_count <= 3 || (inject_fail_count % 50) == 0)
                fprintf(stderr,
                    "[kb_inject] 队列一直无空间(已%d次) — 外设没响应? "
                    "检查基址是否为 0x40400000、bitstream 是否已更新\n",
                    inject_fail_count);
            return;                          // 跳过, 绝不死等
        }
        usleep(50);
    }
    inject_fail_count = 0;
    regs[REG_DATA/4] = sc;      // 写低 8 位
}

// ---- Linux keycode -> PS/2 set-1 scancode 表 (常见键) ----
static const uint8_t kbd_map[128] = {
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,   // 0-15
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,   // 16-31
    0x1c,0,  0x32,0x21,0x23,0x24,0x2b,0x34,0x33,0x35,0x2a,0x2c,0x31,0x1d,0x2d,0x1e, // 32-47
    0x2e,0x12,0x21,0x22,0x23,0x24,0x2b,0x34,0x33,0x35,0x2a,0x2c,0x31,0x1d,0x2e,0x1e, // 48-63
    0x29,0x14,0x3a,0x3b,0x3c,0x3d,0x3e,0x3f,0x38,0x28,0x18,0x0d,0x0e,0x0f,0x10,0x0d, // 64-79
    0x1e,0x1c,0x1f,0,  0x39,0x27,0x2f,0x11,0,  0,  0,  0,  0,  0,  0,  0,  0,   // 80-95
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,   // 96-111
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0    // 112-127
};

// 扩展键(方向/功能键)单独处理: Linux code -> PS/2 E0 前缀 + code
static int is_ext_key(unsigned code) {
    /* 方向键等 */
    if (code >= KEY_RIGHT && code <= KEY_DOWN) return 1;   // 105-108
    if (code == KEY_HOME || code == KEY_END) return 1;
    if (code == KEY_PAGEUP || code == KEY_PAGEDOWN) return 1;
    if (code == KEY_INSERT || code == KEY_DELETE) return 1;
    if (code >= KEY_F1 && code <= KEY_F12) {
        /* F1-F10 走普通区, F11/F12 走 E0 */
        if (code >= KEY_F11) return 1;
    }
    return 0;
}

// 返回: 0=普通键 1=E0扩展键
static int ext_scancode(unsigned code, uint8_t *sc) {
    switch (code) {
        case KEY_RIGHT:  *sc = 0x4d; return 1;
        case KEY_LEFT:   *sc = 0x4b; return 1;
        case KEY_UP:     *sc = 0x48; return 1;
        case KEY_DOWN:   *sc = 0x50; return 1;
        case KEY_HOME:   *sc = 0x47; return 1;
        case KEY_END:    *sc = 0x4f; return 1;
        case KEY_PAGEUP: *sc = 0x49; return 1;
        case KEY_PAGEDOWN: *sc = 0x51; return 1;
        case KEY_INSERT: *sc = 0x52; return 1;
        case KEY_DELETE: *sc = 0x53; return 1;
        case KEY_F11:    *sc = 0x57; return 1;
        case KEY_F12:    *sc = 0x58; return 1;
        default: return 0;
    }
}

// 普通功能键 F1-F10 (set-1: make 无前缀)
static const uint8_t fkeys[10] = {0x3b,0x3c,0x3d,0x3e,0x3f,0x40,0x41,0x42,0x43,0x44};
static int fkey_scancode(unsigned code, uint8_t *sc) {
    if (code >= KEY_F1 && code <= KEY_F10) { *sc = fkeys[code - KEY_F1]; return 1; }
    return 0;
}

// ---------------- stdin 模式: ASCII -> PS/2 set-1 ----------------
// 用于"USB主机口还没配好"时, 直接把当前终端(串口/SSH)的按键转发给 80186,
// 从而验证 ARM->AXI->8042->80186 整条链路, 不依赖 USB 主机口。
static const uint8_t sc_a_z[26] = {
    0x1e,0x30,0x2e,0x20,0x12,0x21,0x22,0x23,0x17,0x24,0x25,0x26,
    0x32,0x31,0x18,0x19,0x10,0x13,0x1f,0x14,0x16,0x2f,0x11,0x2d,0x15,0x2c
};
static const uint8_t sc_0_9[10] = {0x0b,0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09,0x0a};

static int ascii_to_scancode(char c, uint8_t *sc, int *need_shift) {
    *need_shift = 0;
    if (c >= 'a' && c <= 'z') { *sc = sc_a_z[c-'a']; return 1; }
    if (c >= 'A' && c <= 'Z') { *sc = sc_a_z[c-'A']; *need_shift = 1; return 1; }
    if (c >= '0' && c <= '9') { *sc = sc_0_9[c-'0']; return 1; }
    switch (c) {
        case ' ':  *sc = 0x39; return 1;   // space
        case '\n': case '\r': *sc = 0x1c; return 1;   // Enter
        case '\b': case 0x7f: *sc = 0x0e; return 1;   // Backspace
        case '\t': *sc = 0x0f; return 1;   // Tab
        case 0x1b: *sc = 0x01; return 1;   // Esc
        case '.':  *sc = 0x34; return 1;
        case ',':  *sc = 0x33; return 1;
        case '/':  *sc = 0x35; return 1;
        case ';':  *sc = 0x27; return 1;
        case '-':  *sc = 0x0c; return 1;
        case '=':  *sc = 0x0d; return 1;
        default: return 0;
    }
}

// 发送"按下+松开"(需要 Shift 时自动带 Shift 按下/松开)
static void inject_key(uint8_t sc, int shift) {
    if (shift) inject_scancode(0x2a);             // Shift 按下
    inject_scancode(sc);                          // make
    inject_scancode(sc | 0x80);                   // break
    if (shift) inject_scancode(0x2a | 0x80);      // Shift 松开
}

// 发送"Ctrl + 某键"(DOS 里 Ctrl+C 等必须是 Ctrl 修饰 + 键码, 不能发 ASCII 0x03)
static void inject_ctrl_key(uint8_t sc) {
    inject_scancode(0x1d);                        // Ctrl 按下 (0x1d)
    inject_scancode(sc);                          // make
    inject_scancode(sc | 0x80);                   // break
    inject_scancode(0x1d | 0x80);                 // Ctrl 松开
}

// 发送扩展键(E0 前缀): 方向键/Home/End/Ins/Del 等
static void inject_ext_key(uint8_t sc) {
    inject_scancode(0xE0);
    inject_scancode(sc);                          // make
    inject_scancode(0xE0);
    inject_scancode(sc | 0x80);                   // break
}

// ============================================================================
// 终端按键解码 -> DOS 可用的 scancode
//   返回 1 = 请求退出, 0 = 继续
//   esc_state: 0=普通, 1=已收到 ESC, 2=已收到 ESC[
// ============================================================================
static int handle_stdin_byte(int b, int *esc_state) {
    // ---- ESC 序列(方向键等) ----
    if (*esc_state == 2) {
        *esc_state = 0;
        switch (b) {
            case 'A': inject_ext_key(0x48); return 0;   // ↑
            case 'B': inject_ext_key(0x50); return 0;   // ↓
            case 'C': inject_ext_key(0x4d); return 0;   // →
            case 'D': inject_ext_key(0x4b); return 0;   // ←
            case 'H': inject_ext_key(0x47); return 0;   // Home
            case 'F': inject_ext_key(0x4f); return 0;   // End
            case '1': *esc_state = 3; return 0;         // F1..F4: ESC[1~ 等
            case '2': *esc_state = 4; return 0;
            case '3': *esc_state = 5; return 0;
            case '4': *esc_state = 6; return 0;
            case '5': *esc_state = 7; return 0;         // F5: ESC[15~ / ESC[17~
            default: return 0;                          // 忽略其它序列
        }
    }
    if (*esc_state >= 3 && *esc_state <= 7) {
        // 吞掉 "~" 或后续数字, 并按 F1..F5 发出
        int fn = *esc_state - 3;                        // 0..4 -> F1..F5
        if (b == '~') {
            *esc_state = 0;
            static const uint8_t fkey[5] = {0x3b,0x3c,0x3d,0x3e,0x3f};
            inject_key(fkey[fn], 0);
            return 0;
        }
        // ESC[1 5 ~ 这类多字符, 继续吞
        if (b >= '0' && b <= '9') return 0;
        *esc_state = 0;
        return 0;
    }
    if (*esc_state == 1) {
        if (b == '[') { *esc_state = 2; return 0; }
        *esc_state = 0;
        inject_key(0x01, 0);                            // 单独 ESC -> Esc 键
        return 0;
    }

    // ---- 退出键: Ctrl+] (0x1d), 避免和 DOS 需要的 Ctrl+C 冲突 ----
    if (b == 0x1d) return 1;

    if (b == 0x1b) { *esc_state = 1; return 0; }        // ESC 起始

    // ---- 回车 / 退格 / Tab (必须排在 Ctrl 范围判断之前) ----
    if (b == 0x0d || b == 0x0a) { inject_key(0x1c, 0); return 0; }  // Enter
    if (b == 0x08 || b == 0x7f) { inject_key(0x0e, 0); return 0; }  // Backspace
    if (b == 0x09)              { inject_key(0x0f, 0); return 0; }  // Tab

    // ---- Ctrl+A .. Ctrl+Z (0x01..0x1a) -> Ctrl 修饰 + 字母键 ----
    //     DOS 靠 shift 状态位识别 Ctrl+C, 不能只发 ASCII 控制字符
    if (b >= 0x01 && b <= 0x1a) {
        char letter = (char)('a' + (b - 1));
        uint8_t sc; int shift;
        if (ascii_to_scancode(letter, &sc, &shift)) inject_ctrl_key(sc);
        return 0;
    }

    // ---- 可打印字符 ----
    if (b >= 0x20 && b < 0x7f) {
        uint8_t sc; int shift;
        if (ascii_to_scancode((char)b, &sc, &shift)) inject_key(sc, shift);
        return 0;
    }
    return 0;
}

int main(int argc, char **argv) {
    const char *evdev = (argc > 1) ? argv[1] : "/dev/input/event0";
    uintptr_t base = (argc > 2) ? strtoul(argv[2], NULL, 0) : 0x40400000UL;
    int use_stdin = (argc > 1) &&
                    (!strcmp(argv[1], "stdin") || !strcmp(argv[1], "-"));

    // ★ 校验基址: strtoul 解析失败会返回 0, mmap(0) 会映射到物理地址 0
    //   (= DDR 起始), 既没效果又可能踩内存 —— 必须拦住。
    if (base < 0x1000 || (base & 0xFFF)) {
        fprintf(stderr,
            "[kb_inject] 错误: 基址 0x%lx 非法(参数解析失败?)\n"
            "           应为外设物理地址, 且 4K 对齐, 例如:\n"
            "             %s stdin 0x40400000\n"
            "           也可以只给一个参数, 用默认基址 0x40400000:\n"
            "             %s stdin\n",
            (unsigned long)base, argv[0], argv[0]);
        return 1;
    }

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("open /dev/mem (需要 root, 且内核 CONFIG_STRICT_DEVMEM=n 或用设备树节点)");
        return 1;
    }
    regs = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, base);
    if (regs == MAP_FAILED) {
        perror("mmap");
        return 1;
    }

    // 使能注入 + 屏蔽物理PS/2
    regs[REG_CTRL/4] = 0x3;   // bit0 enable, bit1 ps2_block
    fprintf(stderr, "[kb_inject] CTRL=0x3 (inject enabled, PS/2 blocked), base=0x%lx\n", (unsigned long)base);

    // ---------------- stdin 模式: 无需 evdev, 直接读终端 ----------------
    if (use_stdin) {
        struct termios tio, old;
        fprintf(stderr, "[kb_inject] STDIN 模式: 在本终端敲字 -> 转发给 80186 的 DOS\n");
        fprintf(stderr, "            Ctrl+] 退出并还原终端 (Ctrl+C 会正常传给 DOS)\n");
        tcgetattr(STDIN_FILENO, &old);
        tio = old;
        // 手写 raw 模式(不用 cfmakeraw, 避免 uclibc/musl 工具链不支持)
        tio.c_iflag &= ~(unsigned)(IGNBRK | BRKINT | PARMRK | ISTRIP |
                                  INLCR | IGNCR | ICRNL | IXON);
        tio.c_oflag &= ~(unsigned)OPOST;
        tio.c_lflag &= ~(unsigned)(ECHO | ECHONL | ICANON | ISIG | IEXTEN);
        tio.c_cflag &= ~(unsigned)(CSIZE | PARENB);
        tio.c_cflag |= CS8;
        tio.c_cc[VMIN] = 1;
        tio.c_cc[VTIME] = 0;
        tcsetattr(STDIN_FILENO, TCSANOW, &tio);

        char c;
        int esc_state = 0;
        while (read(STDIN_FILENO, &c, 1) == 1) {
            if (handle_stdin_byte((unsigned char)c, &esc_state)) break;  // Ctrl+] 退出
        }
        tcsetattr(STDIN_FILENO, TCSANOW, &old);
        fprintf(stderr, "\n[kb_inject] 退出, 终端已还原\n");
        return 0;
    }

    int kfd = open(evdev, O_RDONLY);
    if (kfd < 0) {
        fprintf(stderr, "open evdev (%s) 失败: %s\n", evdev, strerror(errno));
        fprintf(stderr, "提示: 用 'cat /proc/bus/input/devices' 查真实 eventN,\n");
        // ★ 不能打印 argv[2]: argc<=2 时读 argv[2] 是未定义行为,
        //   之前曾打出环境串 "SHELL=/bin/sh", 用户照抄后 base 被解析成 0。
        fprintf(stderr, "      或用 stdin 模式(推荐): %s stdin 0x%lx\n",
                argv[0], (unsigned long)base);
        return 1;
    }
    fprintf(stderr, "[kb_inject] reading %s ...\n", evdev);

    struct input_event ev;
    while (read(kfd, &ev, sizeof(ev)) == (ssize_t)sizeof(ev)) {
        if (ev.type != EV_KEY) continue;
        uint8_t sc = 0;
        if (ev.code > 127) continue;

        int is_ext = 0;
        int found = 0;
        // 优先: 扩展键 / 功能键
        if (ext_scancode(ev.code, &sc)) { is_ext = 1; found = 1; }
        else if (fkey_scancode(ev.code, &sc)) { found = 1; }
        else if (kbd_map[ev.code]) { sc = kbd_map[ev.code]; found = 1; }
        if (!found) continue;

        if (ev.value == 1) {          // 按下
            if (is_ext) { inject_scancode(0xE0); inject_scancode(sc); }
            else         { inject_scancode(sc); }
        } else if (ev.value == 0) {   // 松开 -> 发 break (|0x80)
            if (is_ext) { inject_scancode(0xE0); inject_scancode(sc | 0x80); }
            else         { inject_scancode(sc | 0x80); }
        }
        // ev.value==2 (自动重复) 忽略
    }
    return 0;
}
