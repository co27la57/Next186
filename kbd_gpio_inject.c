// ============================================================================
// kbd_gpio_inject.c — PetaLinux 终端按键 → PS EMIO GPIO → 80186 的 DOS
// ----------------------------------------------------------------------------
// 为什么用 GPIO 而不是 AXI:
//   之前用 "AXI4-Lite 从机 + SmartConnect + M_AXI_GP0" 传 scancode, 实测证实会
//   挪动 DDR 读返回时序, 导致 VGA 扫描取数窗口错位而花屏。改用 PS EMIO GPIO 后
//   全程不碰 AXI / 不影响 DDR 仲裁, VGA 不受影响。
//
// 为什么用 sysfs 而不是直接 mmap GPIO 寄存器:
//   GPIO 控制器的 DIRM/OEN/DATA 各 bank 偏移容易记错, 写错会"静默失效"(最难查)。
//   sysfs(/sys/class/gpio) 由内核驱动处理寄存器细节, 绝对可靠;
//   速度约每字节 1ms, 而键盘只需几十字节/秒, 完全够用。
//   ★ 保持 value 文件描述符常开 + pwrite, 避免每次重开文件。
//
// GPIO 编号: Zynq 中 MIO = 0..53, **EMIO 从 54 开始**。
//   若 BD 中 EMIO 宽度=4, 则 GPIO_O[0]=54, [1]=55, [2]=56, [3]=57。
//
// 接线(3 线):
//   GPIO base+0 = SCLK   位时钟(上升沿锁存)
//   GPIO base+1 = SDAT   串行数据(MSB first)
//   GPIO base+2 = SVAL   字节有效(传输期间高, 下降沿=字节完成)
//   (base+3 可选: 接 KBD_VK_ENABLE; 若在 BD 里把 VK_ENABLE 接常量 1 则不用)
//
// 编译: gcc -O2 -o kbd_gpio_inject kbd_gpio_inject.c   (或 ARM 交叉编译 + -static)
// 运行: ./kbd_gpio_inject            # 默认 base=54
//       ./kbd_gpio_inject -b 54      # 指定 EMIO 起始 GPIO 编号
//       ./kbd_gpio_inject -v         # 打印每个发出的字节
//       ./kbd_gpio_inject -K         # 键位对照: 顺序键入 4 行已知字符串, 回读屏幕对账
//       ./kbd_gpio_inject -g 8000    # 字节间隔(us), 默认 3000
//       ./kbd_gpio_inject -R 24      # 原始扫描码探针: 只发 0x24 + break, 回车触发
// 退出: Ctrl+]
//
// ★ 扫描码集: 本板 BIOS 是 SCANCODE1 版本(见 images/BIOS/BIOS_Next186.asm 第 52 行
//   `SCANCODE1 equ 1`), 接受的**只有 set-1**。已用 sim/tools/bios_keymap.py 从
//   预编译 BIOS 二进制里把 KeyIndex/KeyCode 表抠出来验证:
//       0x02..0x0B -> '1'..'0'   0x1E -> 'a'   0x24 -> 'j'
//       0x1C -> CR(0Dh)          0x0E -> BS(08h)
//   ⇒ 发送侧必须全部用 set-1, 不能混 set-2 (旧版数字表就是混的, 已修)。
// ============================================================================
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <termios.h>
#include <dirent.h>
#include <ctype.h>
#include <signal.h>
#include <sys/mman.h>

#define SYSFS_GPIO "/sys/class/gpio"
#define DEFAULT_BASE 54

/* ★ 8086 的键盘状态字 (BDA 0040:0017) 的物理地址
 * ------------------------------------------------------------------
 * 映射已实测确认: 物理 = 0x08000000 + (段<<4)
 *   证据: devmem 0x08000400 16 -> 0x03F8  (BDA 0040:0000 = COM1 基址)
 *         devmem 0x08000417 16 -> 键盘状态字
 *   所以 0040:0017 -> 0x08000417  (★ 不是 0x417, 那个地址落在别的 DDR 区域)
 *
 * 为什么要在注入前清它: 该字是 Shift/Ctrl/Alt/CapsLock/NumLock 的**锁存**状态。
 * 一旦某个修饰键的 break 字节(0xAA/0x9D/0xB8/0xB6)在传输中丢失, 这里就永久
 * 保持"按下"。此后 BIOS 的 int09 会让**每一个**按键都去取 KeyCode 表的
 * ctrl/shift 列 -> 满屏乱码、回车/退格失效、映射全部错乱。
 * 2026-10-10 实测到过该字 = 0x8005 (RShfDown|CtrlDown 同时锁死)。 */
#define BDA_KBD_FLAGS 0x08000417UL

static void clear_kbd_state(void) {
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        fprintf(stderr, "[kbd_gpio] 打开 /dev/mem 失败(%s), 跳过键盘状态字清理\n",
                strerror(errno));
        return;
    }
    {
        unsigned long pg  = BDA_KBD_FLAGS & ~0xFFFUL;
        unsigned long off = BDA_KBD_FLAGS & 0xFFFUL;
        void *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)pg);
        if (p == MAP_FAILED) {
            fprintf(stderr, "[kbd_gpio] mmap 0x%08lX 失败(%s), 跳过清理\n", pg, strerror(errno));
        } else {
            *(volatile unsigned short *)((char *)p + off) = 0;
            munmap(p, 4096);
            fprintf(stderr, "[kbd_gpio] 已清 8086 键盘状态字 (0040:0017 @ 0x%08lX)\n",
                    BDA_KBD_FLAGS);
        }
    }
    close(fd);
}

static int val_fd[9];   /* 8 根数据线 + 1 根选通 的 value 文件描述符(常开) */

/* 自动探测 gpiochip 的 base 偏移。
 * 板子上实测: /sys/class/gpio/gpiochip512, ngpio=118
 *   => sysfs 的 GPIO 编号 = base + 引脚序号, 即 EMIO 54/55/56 -> 566/567/568
 * 所以这里必须加上 base, 直接 export 54 会失败。 */
static int detect_gpiochip_base(int need_pins) {
    DIR *d = opendir(SYSFS_GPIO);
    if (!d) { fprintf(stderr, "opendir %s: %s\n", SYSFS_GPIO, strerror(errno)); exit(1); }
    struct dirent *e;
    int best_base = -1;
    while ((e = readdir(d))) {
        if (strncmp(e->d_name, "gpiochip", 8) != 0) continue;
        char pb[256], vb[256];
        snprintf(pb, sizeof(pb), "%s/%s/base",  SYSFS_GPIO, e->d_name);
        snprintf(vb, sizeof(vb), "%s/%s/ngpio", SYSFS_GPIO, e->d_name);
        int base = 0, ngpio = 0;
        FILE *f = fopen(pb, "r");
        if (f) { if (fscanf(f, "%d", &base) != 1) base = 0; fclose(f); }
        f = fopen(vb, "r");
        if (f) { if (fscanf(f, "%d", &ngpio) != 1) ngpio = 0; fclose(f); }
        /* 要求能覆盖到 base+need_pins */
        if (ngpio > 0 && base + need_pins < base + ngpio) {
            fprintf(stderr, "[kbd_gpio] 找到 gpiochip %s: base=%d ngpio=%d (覆盖引脚 %d..%d)\n",
                    e->d_name, base, ngpio, base, base + ngpio - 1);
            best_base = base;
            break;
        }
    }
    closedir(d);
    return best_base;
}

static void wr(const char *path, const char *val) {
    int fd = open(path, O_WRONLY);
    if (fd < 0) { fprintf(stderr, "open %s: %s\n", path, strerror(errno)); exit(1); }
    if (write(fd, val, strlen(val)) < 0) {
        /* export 已存在时可忽略 */
        if (strstr(path, "export") == NULL) {
            fprintf(stderr, "write %s: %s\n", path, strerror(errno)); exit(1);
        }
    }
    close(fd);
}

static void set_pin(int pin, int val) {
    /* val_fd[] 按 索引0..7=数据位, 8=选通 顺序打开; 用 pwrite 避免 lseek */
    char c = val ? '1' : '0';
    if (pwrite(val_fd[pin], &c, 1, 0) != 1) {
        fprintf(stderr, "pwrite gpio value: %s\n", strerror(errno));
    }
}

static void export_pin(int gpio_num, int idx) {
    char path[256], buf[64];

    /* 1) export (已存在会返回 EBUSY, 可忽略) */
    snprintf(buf, sizeof(buf), "%d", gpio_num);
    snprintf(path, sizeof(path), "%s/export", SYSFS_GPIO);
    wr(path, buf);

    /* 2) 确认是否真的出现了 */
    snprintf(path, sizeof(path), "%s/gpio%d", SYSFS_GPIO, gpio_num);
    if (access(path, F_OK) != 0) {
        fprintf(stderr,
            "\n[kbd_gpio] 错误: GPIO %d 在 sysfs 中不存在(export 失败)。\n"
            "  原因: 设备树未把 Zynq 的 EMIO 引脚暴露给 sysfs。\n"
            "  先诊断:\n"
            "    ls /sys/class/gpio/\n"
            "    cat /sys/class/gpio/gpiochip*/ngpio      # 应 >= 57 才含 EMIO\n"
            "    dmesg | grep -i gpio\n"
            "  需要在设备树给 gpio@e000a000 节点加 EMIO 描述(见 README)或\n"
            "  xlnx,num-lanes 覆盖到 EMIO 位。\n", gpio_num);
        exit(1);
    }

    snprintf(path, sizeof(path), "%s/gpio%d/direction", SYSFS_GPIO, gpio_num);
    wr(path, "out");

    snprintf(path, sizeof(path), "%s/gpio%d/value", SYSFS_GPIO, gpio_num);
    val_fd[idx] = open(path, O_WRONLY);
    if (val_fd[idx] < 0) {
        fprintf(stderr, "[kbd_gpio] open %s: %s\n", path, strerror(errno));
        exit(1);
    }
}

static int verbose = 0;
static int slow = 0;      /* -s: 字节间加长延时, 用于排查丢字节 */
static int gap_us = 50000; /* -g <us>: 字节之间 / make 与 break 之间的间隔
 * ★ 2026-10-10 由 3000 提到 50000: 实测 -R 模式(硬编码 200ms 间隔)连发 5 个
 *   'a' 全部正确, 而 -K 模式(原来 3ms 间隔)只有前 16 个字符正确、之后全乱。
 *   16 正好等于 8086 键盘类型缓冲的容量(16 项, BDA 0040:001A Head / 001C Tail)。
 *   => 3ms 太快, 缓冲区被灌满, 之后 int16h 取不动 -> 8042 的 OBF 停在 1
 *      -> 整条注入链路背压。50ms 已是 -R 模式的 1/4, 留足余量。
 *   可用 -g 现场调: -g 20000 更激进, -g 100000 更保守。 */

/* GPIO 使用: base+0..7 = 数据位 data[0..7], base+8 = 选通 strob */
#define NDATA 8

/* 发送一个字节(8 位并行 + 选通)
 * 先写 8 根数据线, 再拉高选通 -> PL 在选通上升沿锁存已稳定的字节。
 * 结构上不可能丢位(串行位帧方案实测会偶发丢 bit)。
 *
 * ★ 2026-10-10: PL 侧 vk_valid 是单拍脉冲, 8042 缓冲非空时该脉冲会被整体丢弃,
 *   所以这里必须**放慢**: 每个字节之间留出足够时间让 BIOS 的 INT 09 把上一字节
 *   从端口 0x60 取走。默认 3ms 对 DOS 的键盘处理绰绰有余。 */
static void send_byte(uint8_t byte) {
    int i;
    const int D = 3000;   /* 空转延时, 约 2-4us */
    /* 1) 写 8 根数据线(选通保持低) */
    for (i = 0; i < NDATA; i++) {
        set_pin(i, (byte >> i) & 1);
        for (int d = 0; d < D; d++) __asm__ __volatile__("");
    }
    /* 2) 拉高选通 -> PL 锁存 */
    set_pin(NDATA, 1);
    for (i = 0; i < D; i++) __asm__ __volatile__("");
    /* 3) 拉低选通, 结束本次传输 */
    set_pin(NDATA, 0);
    if (verbose)
        fprintf(stderr, "[tx] 0x%02x\n", byte);
    usleep(slow ? 30000 : gap_us);
}

/* 一次完整的按键: make -> 间隔 -> break。
 * break 之后再补发一次: BIOS 对 break 字节只做标志处理(>=0x59 被清零, 不入队),
 * 重复无害; 但若前一个 break 被丢掉, 按键就会"粘住", 那才是 DOS 卡死的典型成因。 */
static void send_key(uint8_t sc) {
    send_byte(sc);            /* make  */
    usleep(slow ? 30000 : gap_us);
    send_byte(sc | 0x80);     /* break */
    if (verbose) fprintf(stderr, "[key] 0x%02x + break\n", sc);
}

/* Shift 松开。BIOS 的 int09 只有见到 0xAA 才会清掉 RShfDown/LShfDown;
 * 传输中丢一个 break, Shift 就会**永久**保持"按下", 此后每一个按键都被 BIOS
 * 取 KeyCode 表的 shift 列 => 满屏乱码 + 回车/退格失效。
 * 重复发一次是幂等的(第二个 0xAA 只是重复清标志), 但能把"丢一个"压到可忽略。 */
static void send_shift_release(void) {
    send_byte(0xAA);
    send_byte(0xAA);
}

/* ---- 按键解码: 终端字节 -> PS/2 set-1 scancode ---- */
/* ===========================================================================
 * 扫描码表 = 标准 PC PS/2 set-1 (Make code)
 *
 * ★ 关于 BIOS_Next186.asm 的 KeyCode 表(曾误读):
 *   该表每行 4 个 dw, 格式为:
 *       dw 246ah, 244ah, 240ah, 2400h ;3b - J
 *            └─高字节 0x24─┘ └低字节=ASCII 0x6a='j'┘   注释里的 "3b" 是
 *                                                          **表的索引号**, 不是扫描码!
 *   即该 BIOS 用的**就是标准 PC 扫描码**(低字节 ASCII, 高字节 标准set-1扫描码)。
 *   查表法: 看每行 dw 的**高字节**; 低字节是 ASCII; 注释 "XX - 字符" 中 XX 是索引。
 *   (曾因误把索引当扫描码, 导致按键全乱 —— 已回退)
 * ======================================================================== */

/* a-z -> PS/2 set-1 扫描码 */
static const uint8_t sc_a_z[26] = {
    0x1e,0x30,0x2e,0x20,0x12,0x21,0x22,0x23,0x17,0x24,0x25,0x26,
    0x32,0x31,0x18,0x19,0x10,0x13,0x1f,0x14,0x16,0x2f,0x11,0x2d,0x15,0x2c
};

/* 数字 1..0 -> PS/2 set-1 扫描码
 * ★ 2026-10-10 修复: 旧表是 PS/2 **set-2** 的顶行数字码 (0x16,0x1e,0x26,0x25,...),
 *   只在"0"那一项混进了 set-1 的 0x0b, 整张表自相矛盾。
 *   而板上跑的 BIOS 是 **SCANCODE1** 版本(set-1):
 *     实测从 images/BIOS_Next186.bin 抠表验证 (sim/tools/bios_keymap.py):
 *       0x02..0x0B -> '1'..'0'   (正确)
 *       0x24 -> 'j'  0x1C -> CR  0x0E -> BS
 *   用旧表的结果: '1'->0x16->'u', '2'->0x1e->'a', '4'->0x25->'k',
 *                 '6'->0x36->RShift, '7'->0x3d->F3, '9'->0x46->ScrollLock
 *   ⇒ 全部错位。set-1 顶行数字就是 0x02..0x0B。 */
static const uint8_t sc_0_9[10] = {
    0x0b,/*0*/ 0x02,/*1*/ 0x03,/*2*/ 0x04,/*3*/ 0x05,/*4*/
    0x06,/*5*/ 0x07,/*6*/ 0x08,/*7*/ 0x09,/*8*/ 0x0a/*9*/
};

static int ascii_to_sc(char c, uint8_t *sc, int *shift) {
    *shift = 0;
    if (c >= 'a' && c <= 'z') { *sc = sc_a_z[c-'a']; return 1; }
    if (c >= 'A' && c <= 'Z') { *sc = sc_a_z[c-'A']; *shift = 1; return 1; }
    if (c >= '0' && c <= '9') { *sc = sc_0_9[c-'0']; return 1; }
    /* 标准 PS/2 set-1 特殊键扫描码 */
    switch (c) {
        case ' ':  *sc = 0x39; return 1;   // SPC
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
        case '[':  *sc = 0x1a; return 1;
        case ']':  *sc = 0x1b; return 1;
        case '\\': *sc = 0x2b; return 1;
        case '\'': *sc = 0x28; return 1;
        case '`':  *sc = 0x29; return 1;
        default: return 0;
    }
}

/* 按 ASCII 字符串逐字符键入(带 Shift 处理), 同时把"期望字符"打到 stderr,
 * 便于把 DOS 屏幕上的实际结果与期望逐字符对齐 —— 这是判断映射是否错位的
 * 最快办法(不需要任何仪器)。 */
static void type_string(const char *s) {
    for (; *s; s++) {
        uint8_t sc; int shift;
        unsigned char c = (unsigned char)*s;
        if (c == '\n') { send_key(0x1c); fprintf(stderr, "  [exp] <CR>\n"); continue; }
        if (!ascii_to_sc((char)c, &sc, &shift)) {
            fprintf(stderr, "  [exp] (skip 0x%02x)\n", c);
            continue;
        }
        if (shift) send_byte(0x2a);       /* LShift 按下 */
        send_key(sc);
        if (shift) send_shift_release();  /* LShift 松开(发两次) */
        fprintf(stderr, "  [exp] '%c'  sc=%02x%s\n", isprint(c) ? c : '?', sc, shift ? " +Shift" : "");
    }
}

int main(int argc, char **argv) {
    int pin0 = DEFAULT_BASE;   /* EMIO 内的引脚序号(0..117), 默认 54 */
    int i, test_mode = 0, keymap_check = 0, sweep_mode = 0, sweep_from = 0;
    int raw = -1, raw_mode = 0;   /* 原始扫描码探针: raw=扫描码, raw_mode: 1=只发make, 2=make+break */
    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-b") && i + 1 < argc) pin0 = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-v"))     verbose = 1;
        else if (!strcmp(argv[i], "-t"))     test_mode = 1;
        else if (!strcmp(argv[i], "-s"))     slow = 1;
        else if (!strcmp(argv[i], "-K"))     keymap_check = 1;
        else if (!strcmp(argv[i], "-B"))     sweep_mode = 1;
        else if (!strcmp(argv[i], "-b0") && i + 1 < argc) sweep_from = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-g") && i + 1 < argc) gap_us = atoi(argv[++i]);
        /* -r <hex> 只发 make; -R <hex> 发 make+break —— 用于探测 80186 的真实解释 */
        else if (!strcmp(argv[i], "-r") && i + 1 < argc) { raw = (int)strtol(argv[++i], NULL, 16); raw_mode = 1; }
        else if (!strcmp(argv[i], "-R") && i + 1 < argc) { raw = (int)strtol(argv[++i], NULL, 16); raw_mode = 2; }
    }

    /* sysfs 的 GPIO 编号 = gpiochip base + 引脚序号(板子上 base=512) */
    int base = detect_gpiochip_base(pin0 + NDATA);
    if (base < 0) {
        fprintf(stderr,
            "[kbd_gpio] 错误: 未找到能覆盖引脚 %d 的 gpiochip。\n"
            "  请确认设备树已暴露足够的 EMIO(需 ngpio >= %d, 本方案要 9 位)。\n",
            pin0 + NDATA, pin0 + NDATA);
        return 1;
    }

    /* 8 根数据线 + 1 根选通 */
    {
        int k;
        for (k = 0; k < NDATA; k++) export_pin(base + pin0 + k, k);
        export_pin(base + pin0 + NDATA, NDATA);   /* 选通 */
    }
    for (int k = 0; k <= NDATA; k++) set_pin(k, 0);

    /* ★ 先清掉 8086 可能残留的修饰键锁存状态, 否则整个键盘行为都是错的。
     *   见文件头 BDA_KBD_FLAGS 处的说明。 */
    clear_kbd_state();

    fprintf(stderr, "[kbd_gpio] 并行模式: data[7:0]=GPIO %d..%d, strob=GPIO %d (base=%d)\n",
            base + pin0, base + pin0 + NDATA - 1, base + pin0 + NDATA, base);
    fprintf(stderr, "[kbd_gpio] 在本终端敲字 -> 转发给 80186 的 DOS。Ctrl+] 退出\n");

    /* ---- 原始扫描码探针模式: 直接发任意扫描码, 绕过按键映射 ----
     * 用途: 精确判断 "80186 收到 0x24 到底显示什么", 从而把问题定位到
     *       (a) 发送侧 / (b) 传输侧 / (c) 8042 侧 / (d) BIOS 解释表。
     * 用法: ./kbd_gpio_inject -r 0x24   (只发 make, 每次一个, 慢速)
     *       ./kbd_gpio_inject -R 0x24   (发 make+break)
     * 回车继续, Ctrl+] 退出。 */
    if (raw_mode && raw >= 0) {
        struct termios tio, old;
        fprintf(stderr, "[probe] 原始扫描码模式: sc=0x%02x (%s), 慢速, 回车=发一次, Ctrl+]退出\n",
                raw, raw_mode == 1 ? "仅make" : "make+break");
        tcgetattr(STDIN_FILENO, &old);
        tio = old;
        tio.c_iflag &= ~(unsigned)(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IXON);
        tio.c_oflag &= ~(unsigned)OPOST;
        tio.c_lflag &= ~(unsigned)(ECHO | ECHONL | ICANON | ISIG | IEXTEN);
        tio.c_cflag &= ~(unsigned)(CSIZE | PARENB);
        tio.c_cflag |= CS8;
        tio.c_cc[VMIN] = 1; tio.c_cc[VTIME] = 0;
        tcsetattr(STDIN_FILENO, TCSANOW, &tio);

        fprintf(stderr, "[probe] 建议对照: 0x24=标准j  0x23=h 0x21=f 0x05=?'4'  0x1c=标准a\n");
        char k;
        while (read(STDIN_FILENO, &k, 1) == 1) {
            if ((unsigned char)k == 0x1d) break;      /* Ctrl+] */
            if (k == '\r' || k == '\n') {
                usleep(200000);
                send_byte((uint8_t)raw);              /* make */
                if (raw_mode == 2) {
                    usleep(200000);
                    send_byte((uint8_t)(raw | 0x80)); /* break */
                }
                fprintf(stderr, "[probe] 已发 0x%02x%s\n", raw,
                        raw_mode == 2 ? " + break" : " (仅make)");
            }
        }
        tcsetattr(STDIN_FILENO, TCSANOW, &old);
        for (int q = 0; q <= NDATA; q++) set_pin(q, 0);
        fprintf(stderr, "\n[probe] 退出, 终端已还原\n");
        return 0;
    }

    /* ---- 扫描模式: 把 0x00..0x7F 全部依次发一遍(每个之间回车) ----
     * 用来一次性拿到"发送字节 -> DOS 实际显示"的完整映射, 从而直接反推出
     * 传输链路上到底发生了什么变换。配合 sim/tools/vga_text_dump.sh 读屏即可。 */
    if (sweep_mode) {
        int v;
        fprintf(stderr, "[kbd_gpio] 扫描模式: 发送 0x%02X..0x%02X, 每个后跟回车\n", sweep_from, (sweep_from+31)&0x7F);
        fprintf(stderr, "[kbd_gpio] 读屏: sh /home/workspace/vga_text_dump.sh 0 25\n");
        for (v = sweep_from; v < sweep_from + 32 && v < 128; v++) {
            send_byte((uint8_t)v);
            usleep(slow ? 30000 : gap_us);
            send_byte(0x1c);            /* 回车分隔 */
            usleep(slow ? 30000 : gap_us);
            send_byte(0x9c);
            usleep(slow ? 30000 : gap_us);
        }
        for (int q = 0; q <= NDATA; q++) set_pin(q, 0);
        fprintf(stderr, "[kbd_gpio] 扫描结束\n");
        return 0;
    }

    /* ---- 键位对照模式: 顺序键入 4 行, 用户回读 DOS 屏幕即可定位错位 ----
     * 设计意图: 把"映射问题"变成一次可对账的打印, 不必猜。
     * 第1行验数字、第2行验字母、第3行验 j/4/h/f 这四个已知可疑键、
     * 第4行验 Shift(大写)通路。 */
    if (keymap_check) {
        fprintf(stderr, "[kbd_gpio] 键位对照模式, 请回读 DOS 屏幕上出现的 4 行\n");
        fprintf(stderr, "第1行 期望: 1234567890\n");
        type_string("1234567890\n");
        fprintf(stderr, "第2行 期望: abcdefghijklmnopqrstuvwxyz\n");
        type_string("abcdefghijklmnopqrstuvwxyz\n");
        fprintf(stderr, "第3行 期望: j4hf\n");
        type_string("j4hf\n");
        fprintf(stderr, "第4行 期望: JJJJ\n");
        type_string("JJJJ\n");
        for (int q = 0; q <= NDATA; q++) set_pin(q, 0);
        fprintf(stderr, "[kbd_gpio] 键位对照结束\n");
        return 0;
    }

    /* ---- 测试模式: 每秒发一个 'a'(scancode 0x1E) ----
     * 用来区分"集成没通"(DOS 完全没反应) vs "键盘映射问题"。
     * 若 DOS 出现一串 a, 说明 8 位并行链路 OK, 剩下才是映射表问题。 */
    if (test_mode) {
        fprintf(stderr, "[kbd_gpio] 测试模式: 每秒发送一个 'a'(0x1E), Ctrl+C 退出\n");
        signal(SIGINT, SIG_DFL);
        for (;;) {
            send_key(0x1E);
            sleep(1);
        }
    }

    struct termios tio, old;
    tcgetattr(STDIN_FILENO, &old);
    tio = old;
    tio.c_iflag &= ~(unsigned)(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IXON);
    tio.c_oflag &= ~(unsigned)OPOST;
    tio.c_lflag &= ~(unsigned)(ECHO | ECHONL | ICANON | ISIG | IEXTEN);
    tio.c_cflag &= ~(unsigned)(CSIZE | PARENB);
    tio.c_cflag |= CS8;
    tio.c_cc[VMIN] = 1; tio.c_cc[VTIME] = 0;
    tcsetattr(STDIN_FILENO, TCSANOW, &tio);

    char c;
    while (read(STDIN_FILENO, &c, 1) == 1) {
        if ((unsigned char)c == 0x1d) break;      /* Ctrl+] */
        uint8_t sc; int shift;
        if (!ascii_to_sc(c, &sc, &shift)) {
            if (verbose) fprintf(stderr, "[skip] 0x%02x\n", (unsigned char)c);
            continue;
        }
        if (verbose) {
            fprintf(stderr, "[key] '%c'(0x%02x) -> sc=0x%02x%s\n",
                    isprint((unsigned char)c) ? c : '?', (unsigned char)c, sc,
                    shift ? " +Shift" : "");
        }
        if (shift) send_byte(0x2a);               /* Shift 按下 */
        send_key(sc);                             /* make -> 间隔 -> break */
        if (shift) send_shift_release();       /* Shift 松开(发两次) */
    }
    tcsetattr(STDIN_FILENO, TCSANOW, &old);
    for (int k = 0; k <= NDATA; k++) set_pin(k, 0);
    fprintf(stderr, "\n[kbd_gpio] 退出, 终端已还原\n");
    return 0;
}
