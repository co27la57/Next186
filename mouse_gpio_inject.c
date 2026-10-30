// ============================================================================
// mouse_gpio_inject.c — PetaLinux 终端按键/鼠标 → PS EMIO GPIO → 80186 的 DOS
//                        (kbd_gpio_inject.c 的副本, 新增**鼠标通道**)
// ----------------------------------------------------------------------------
// ★ 为什么要合一: 键盘和鼠标共用同一组 EMIO(8 数据 + 1 选通), 两个进程同时写
//   会互相踩。所以本程序把两条通道都接管了 —— 打字走键盘通道, 方向键走鼠标通道。
//
// ★ 通道区分(与 kbd_gpio_rx.v.mouse 严格对应): **选通高电平宽度**
//     键盘字节: 拉高后立刻拉低           (高电平 ≈ 一次 sysfs 写 ≈ 0.1ms)
//     鼠标字节: 拉高后 usleep(MOUSE_STB_US=3000) 再拉低  (高电平 ≈ 3.1ms)
//   PL 侧阈值 MOUSE_STB_MIN_US = 1000us。量级差 30 倍, 且 sysfs 延迟只会把脉冲
//   **拉长**, 是安全方向。老的 kbd_gpio_inject 二进制照旧可用(全是短脉冲=键盘)。
//
// ★ 鼠标包格式(标准 PS/2 3 字节包, BIOS int74 就是按 3 字节拼的):
//     byte0 = Yov<<7 | Xov<<6 | Ysign<<5 | Xsign<<4 | 1<<3 | M<<2 | R<<1 | L
//     byte1 = X 位移(int8, 右为正)
//     byte2 = Y 位移(int8, **上为正**, 与屏幕坐标相反)
//
// ★ 链路上的三道闸(缺一不可, 否则 DOS 里看不到鼠标):
//   1) BIOS POST 必须收到 FA/AA/00 才会打印 "PS2 Mouse detected" 并置设备字 bit2
//      —— 由 KB_8042.v.mouse 的虚拟鼠标应答器代答;
//   2) DOS 里要有 INT33 驱动(FreeDOS 的 CTMOUSE / FDCONFIG 里加一行),
//      驱动通过 INT15h/C2h 发 0xF4 打开数据上报;
//   3) 只有 0xF4 之后 PL 才放行注入的鼠标包(防止 POST 期间移动包顶掉 BAT/ID)。
//   ⇒ 冒烟测试: 先确认屏幕出现 "PS2 Mouse detected", 再加载驱动, 再动鼠标。
//
// 用法:
//   ./mouse_gpio_inject            # 交互: 字母/数字=打字, 方向键/WASD=移动鼠标,
//                                  #       '1'左键 '2'右键 '3'中键(按一次=点一下)
//   ./mouse_gpio_inject -M         # 鼠标自检: 每 120ms 发一个 +X 移动包, 画直线
//   ./mouse_gpio_inject -M 2       # 2=画方框(同时动 X 和 Y), 3=只按左键
//   ./mouse_gpio_inject -f /dev/input/mice   # 直通 PetaLinux 的真实鼠标
//   ./mouse_gpio_inject -x 5 -y 0  # 手动发一个 (dx=+5, dy=0) 的包
//   ./mouse_gpio_inject -k         # 纯键盘模式(等价于老的 kbd_gpio_inject)
//   (其余 -b/-v/-s/-g/-r/-R/-V/-K/-B/-t 与老程序完全一致)
// 退出: Ctrl+]
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
#include <poll.h>
#include <time.h>
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

static int dry_run = 0;   /* -n: 只跑状态机, 不碰 GPIO(配合 -X 自检) */

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
    if (dry_run) return;
    if (pwrite(val_fd[pin], &c, 1, 0) != 1) {
        fprintf(stderr, "pwrite gpio value: %s\n", strerror(errno));
    }
}

static int rd_fd[9];   /* value 文件的只读 fd, 供 -V 回读校验 */

static int get_pin(int idx) {
    char c = 0;
    if (pread(rd_fd[idx], &c, 1, 0) != 1) return -1;
    return c == '0' ? 0 : (c == '1' ? 1 : -2);
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
    {
        char rp[256];
        snprintf(rp, sizeof(rp), "%s/gpio%d/value", SYSFS_GPIO, gpio_num);
        rd_fd[idx] = open(rp, O_RDONLY);
    }
}

static int verbose = 0;
static int slow = 0;      /* -s: 字节间加长延时, 用于排查丢字节 */
static int gap_us = 20000; /* -g <us>: 字节之间 / make 与 break 之间的间隔
 * ★ 2026-10-10 由 3000 提到 50000: 实测 -R 模式(硬编码 200ms 间隔)连发 5 个
 *   'a' 全部正确, 而 -K 模式(原来 3ms 间隔)只有前 16 个字符正确、之后全乱。
 *   16 正好等于 8086 键盘类型缓冲的容量(16 项, BDA 0040:001A Head / 001C Tail)。
 *   => 3ms 太快, 缓冲区被灌满, 之后 int16h 取不动 -> 8042 的 OBF 停在 1
 *      -> 整条注入链路背压。
 * ★ 2026-10-29: 默认改回 20000(20ms)。原因: 交互路径已改成"按住语义", 终端
 *   的自动重复字节被合并成一次 make(见 hold_press), 注入速率不再跟终端重复率
 *   赛跑, 20ms 足够安全; 而 50ms 会让一次按键(make+break)要 100ms, 按住时
 *   tty 队列会越积越长, 表现为"松手后还在吐字符"。
 *   可用 -g 现场调: -g 12000 更激进, -g 50000 更保守。 */

/* GPIO 使用: base+0..7 = 数据位 data[0..7], base+8 = 选通 strob */
#define NDATA 8

/* ★ 鼠标字节的选通高电平宽度(us)。必须远大于 PL 侧阈值 MOUSE_STB_MIN_US(1000),
 *   同时尽量小以提高鼠标刷新率: 一个包 3 字节 => 3*3.1ms ≈ 9.3ms ≈ 107 包/秒。 */
#define MOUSE_STB_US 3000
/* 一个包内字节之间的间隔(选通拉低之后) */
#define MOUSE_GAP_US 500

/* 发送一个字节(8 位并行 + 短选通) => 键盘通道
 * 先写 8 根数据线, 再拉高选通 -> PL 在选通**下降沿**按脉宽判定通道并锁存。
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

/* ---- 鼠标通道: 同一个字节, **长选通** => PL 判为鼠标字节 ---- */
static void send_mouse_byte(uint8_t byte) {
    int i;
    const int D = 3000;
    for (i = 0; i < NDATA; i++) {
        set_pin(i, (byte >> i) & 1);
        for (int d = 0; d < D; d++) __asm__ __volatile__("");
    }
    set_pin(NDATA, 1);
    /* ★ 关键: 高电平保持 ~3ms, 远超 PL 侧 1ms 阈值 */
    usleep(MOUSE_STB_US);
    set_pin(NDATA, 0);
    if (verbose) fprintf(stderr, "[tx-mouse] 0x%02x\n", byte);
}

/* 发一个标准 3 字节鼠标包。
 *   dx/dy: 位移, 右/上为正(int8, 超出自动饱和)
 *   btn  : bit0=左键 bit1=右键 bit2=中键
 * ★ Y 方向: PS/2 的 Y 正方向是**上**, 所以屏幕坐标要取反 —— 调用方传"屏幕 dy"
 *   (下为正)的话在这里取反即可; 本函数约定 dy>0 = 向上移动。 */
static void send_mouse_packet(int dx, int dy, int btn) {
    uint8_t b0 = 0x08;                    /* bit3 恒为 1 */
    if (dx < 0) { b0 |= 0x10; }           /* Xsign */
    if (dy < 0) { b0 |= 0x20; }           /* Ysign */
    b0 |= (uint8_t)((btn & 0x07) << 0);   /* 低 3 位 = M,R,L */
    if (dx >  127) dx =  127; if (dx < -128) dx = -128;
    if (dy >  127) dy =  127; if (dy < -128) dy = -128;
    send_mouse_byte(b0);
    usleep(MOUSE_GAP_US);
    send_mouse_byte((uint8_t)(dx & 0xFF));
    usleep(MOUSE_GAP_US);
    send_mouse_byte((uint8_t)(dy & 0xFF));
    if (verbose)
        fprintf(stderr, "[mouse] dx=%d dy=%d btn=%d -> %02x %02x %02x\n",
                dx, dy, btn, b0, (uint8_t)(dx & 0xFF), (uint8_t)(dy & 0xFF));
    usleep(MOUSE_GAP_US);
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

/* ===========================================================================
 * 按住(hold)语义 + 方向键路由  —— 2026-10-29
 * ---------------------------------------------------------------------------
 * A) 方向键曾被无条件映射成鼠标移动, 于是所有用方向键的 DOS 游戏
 *    (Lotus / 赛车 / 平台) 都没方向键可用。现在:
 *      · 默认 **方向键 = 光标键** (make 0x48/0x50/0x4B/0x4D)
 *      · 鼠标改由 **Ctrl+方向键** (ESC[1;5A..D) 或 **Ctrl+T 切换的鼠标层** 驱动
 *      · -a 启动即处于鼠标层; -k 纯键盘(方向键永远是光标键, 不响应 Ctrl+T)
 *
 * B) 终端只有"按下"事件, 没有"抬起"。老代码 send_key() 是 make → gap → break,
 *    8086 侧看到的是一次几毫秒的点击 —— "踩油门/打方向"这类**需要按住**的操作
 *    根本做不到: BIOS 的键盘标志字 0040:0017/0018 立刻被 break 清掉。
 *    现在改成"按住到超时": 收到字节发 make, 只要 rep_ms 内还有同一按键的字节
 *    到达就刷新(SSH 终端按住键会按系统重复率不断发同一个字节), 超时才发 break。
 *    ⇒ 按住方向键 = 真的按住; 松手 = 自动 break。
 * ===========================================================================*/
#define MAX_HELD 16
static uint8_t held_sc[MAX_HELD];
static long    held_at[MAX_HELD];      /* 最后一次看到该键的时刻 */
static uint8_t held_rep[MAX_HELD];     /* 连续"自动重复"的次数 */
static uint8_t held_latch[MAX_HELD];   /* 1 = 已锁存: 不再因超时松手 */
static int     held_n  = 0;
static int     rep_ms  = 45;    /* -H <ms>: 同一按键间隔小于它 => 视为"按住中的重复",
                                 *   只刷新时间戳, 不再发 make(否则终端重复率 30Hz
                                 *   会把 16 项的 BIOS 键盘缓冲灌爆, 也会在松手后
                                 *   积压一大串待注入的字节) */
static int     rel_ms  = 85;    /* 多久没再收到同一按键 => 认为松手 (启动时 = rep_ms+40) */
static int     arrow_mouse = 0; /* 0=方向键走键盘(默认) 1=方向键走鼠标 */
static int     rel_hold_ms = 260; /* -T <ms>: 方向键/Shift 的松开超时(比打字长, 更像真键盘) */
static int     latch_mode  = 1;   /* -L 0|ud|all|hex,hex: 0=关, 1=只"纵向"↑↓(默认),
                                   *   2=所有键, 3=用 latch_keys[] 里的自定义扫描码 */
static uint8_t latch_keys[16];
static int     latch_nkeys = 0;
static int     latch_after = 3;   /* -C <n>: 连续自动重复 n 次 => 判定"真的按住", 锁存 */
static void    hold_release_all(void);

static long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

static void hold_release_idx(int i);   /* 前向声明: hold_press 里要用 */

static int held_find(uint8_t sc) {
    for (int i = 0; i < held_n; i++) if (held_sc[i] == sc) return i;
    return -1;
}

static int is_arrow_sc(uint8_t sc) {
    return sc == 0x48 || sc == 0x50 || sc == 0x4B || sc == 0x4D;   /* 上/下/左/右 */
}
/* 方向键和 Shift 用更长的"松开超时": 手感像真键盘, 也给终端的首次重复延迟留余量 */
static int is_hold_key(uint8_t sc) {
    return is_arrow_sc(sc) || sc == 0x2a || sc == 0x36;
}
static int key_timeout(uint8_t sc) {
    return is_hold_key(sc) ? rel_hold_ms : rel_ms;
}
/* 哪些键允许"锁存"(按住不放)?
 * 默认只有 ↑/↓(扫描码 48/50): 赛车里的加速/刹车是"一直踩着"的, 而 ←/→ 是
 * "松手就要回正"的 —— 左右若也锁存, 打完方向车会一直转, 所以左右永远靠超时松手。 */
static int key_can_latch(uint8_t sc) {
    if (latch_mode == 0) return 0;
    if (sc == 0x2a || sc == 0x36) return 0;          /* Shift 永不锁存 */
    if (latch_mode == 2) return 1;
    if (latch_mode == 3) {
        for (int i = 0; i < latch_nkeys; i++) if (latch_keys[i] == sc) return 1;
        return 0;
    }
    return sc == 0x48 || sc == 0x50;                 /* 默认: 只锁存 ↑/↓ */
}

/* 按下(或刷新)一个键: 只在第一次真的发 make。
 * ★ 同键在 rep_ms 内再来 => 就是终端在发"自动重复", 只刷新时间戳, **一个字节都不发**。
 *   这条是"按住 k 不再吐一大串 k / 松手后还在吐"的关键: 旧代码每个重复字节都
 *   走一次 send_key()(make + gap + break), 而 gap 默认 50ms, 于是注入速度只有
 *   20 字节/秒, 终端却按 30 字节/秒灌进来 => tty 队列越积越长, 松手后继续吐。 */
static void hold_press(uint8_t sc) {
    long t = now_ms();
    int i = held_find(sc);
    if (i >= 0) {
        long dt = t - held_at[i];
        if (dt <= rep_ms) {                        /* 同一键的自动重复 */
            held_at[i] = t;
            if (held_rep[i] < 200) held_rep[i]++;
            /* ★ 连续重复 latch_after 次 => 这是"真的按住", 锁存, 之后不再超时松手 */
            if (!held_latch[i] && latch_after > 0 && key_can_latch(sc) &&
                held_rep[i] >= latch_after) {
                held_latch[i] = 1;
                if (verbose) fprintf(stderr, "[hold] 锁存 0x%02x (按住, 不再自动松手)\n", sc);
            }
            return;
        }
        if (held_latch[i]) {                       /* 锁存键: 再按一次 = 松开 */
            if (verbose) fprintf(stderr, "[hold] 解锁 0x%02x\n", sc);
            hold_release_idx(i);
            return;
        }
        hold_release_idx(i);                       /* 隔太久: 这是又一次按键 */
    }
    if (held_n >= MAX_HELD) {                 /* 极端情况: 先放掉一个没锁存的 */
        int v = 0;
        for (int k = 0; k < held_n; k++) if (!held_latch[k]) { v = k; break; }
        send_byte(held_sc[v] | 0x80);
        held_sc[v] = held_sc[held_n-1]; held_at[v] = held_at[held_n-1];
        held_rep[v] = held_rep[held_n-1]; held_latch[v] = held_latch[held_n-1];
        held_n--;
    }
    send_byte(sc);
    held_sc[held_n]    = sc;
    held_at[held_n]    = t;
    held_rep[held_n]   = 0;
    held_latch[held_n] = 0;
    held_n++;
    if (verbose) fprintf(stderr, "[hold] down 0x%02x\n", sc);
}

static void hold_release_idx(int i) {
    uint8_t sc = held_sc[i];
    if (sc == 0x2a) send_shift_release();     /* Shift 的 break 发两次, 防丢 */
    else            send_byte(sc | 0x80);
    if (verbose) fprintf(stderr, "[hold] up   0x%02x\n", sc);
    held_sc[i]    = held_sc[held_n-1];
    held_at[i]    = held_at[held_n-1];
    held_rep[i]   = held_rep[held_n-1];
    held_latch[i] = held_latch[held_n-1];
    held_n--;
}

/* 把超时未刷新的键全部放掉 */
static void hold_expire(void) {
    long t = now_ms();
    for (int i = held_n - 1; i >= 0; i--) {
        if (held_latch[i]) continue;                       /* 锁存的键不超时 */
        if (t - held_at[i] >= key_timeout(held_sc[i])) hold_release_idx(i);
    }
}

static void hold_release_all(void) {
    while (held_n > 0) hold_release_idx(held_n - 1);
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
        /* ---- 需要 Shift 的符号(US 键盘布局): 基码与对应无 Shift 键相同 ----
         * 2026-10-19 修复: 老表只收录无 Shift 标点, 这些符号全落 default 被跳过
         * (用户实测 ':' 打不出来; 大小写正常是因为 A-Z 单独走 *shift=1 分支)。
         * 数字行符号用 sc_0_9[] 取基码, 与板上 BIOS 键位表保持一致。 */
        case ':':  *sc = 0x27; *shift = 1; return 1;   /* Shift+; */
        case '"':  *sc = 0x28; *shift = 1; return 1;   /* Shift+' */
        case '{':  *sc = 0x1a; *shift = 1; return 1;   /* Shift+[ */
        case '}':  *sc = 0x1b; *shift = 1; return 1;   /* Shift+] */
        case '|':  *sc = 0x2b; *shift = 1; return 1;   /* Shift+\ */
        case '<':  *sc = 0x33; *shift = 1; return 1;   /* Shift+, */
        case '>':  *sc = 0x34; *shift = 1; return 1;   /* Shift+. */
        case '?':  *sc = 0x35; *shift = 1; return 1;   /* Shift+/ */
        case '~':  *sc = 0x29; *shift = 1; return 1;   /* Shift+` */
        case '_':  *sc = 0x0c; *shift = 1; return 1;   /* Shift+- */
        case '+':  *sc = 0x0d; *shift = 1; return 1;   /* Shift+= */
        case '!':  *sc = sc_0_9[1]; *shift = 1; return 1;   /* Shift+1 */
        case '@':  *sc = sc_0_9[2]; *shift = 1; return 1;   /* Shift+2 */
        case '#':  *sc = sc_0_9[3]; *shift = 1; return 1;   /* Shift+3 */
        case '$':  *sc = sc_0_9[4]; *shift = 1; return 1;   /* Shift+4 */
        case '%':  *sc = sc_0_9[5]; *shift = 1; return 1;   /* Shift+5 */
        case '^':  *sc = sc_0_9[6]; *shift = 1; return 1;   /* Shift+6 */
        case '&':  *sc = sc_0_9[7]; *shift = 1; return 1;   /* Shift+7 */
        case '*':  *sc = sc_0_9[8]; *shift = 1; return 1;   /* Shift+8 */
        case '(':  *sc = sc_0_9[9]; *shift = 1; return 1;   /* Shift+9 */
        case ')':  *sc = sc_0_9[0]; *shift = 1; return 1;   /* Shift+0 */
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

/* ===========================================================================
 * 终端转义序列解码 (2026-10-19)
 * ---------------------------------------------------------------------------
 * 背景: SSH 终端把功能键发成多字节序列, 老代码只认 ESC [ A/B/C/D(方向键),
 *   其余序列被"跳过 ESC 再把剩余字节当字母打" => F1 变成 "op", F2 变 "oq"...
 *   (Windows 3.0 安装程序因此完全没法用 F 键)
 *
 * 支持的序列(覆盖 xterm / PuTTY / Linux 控制台三种常见形态):
 *   F1-F4   = ESC O P / Q / R / S            (SS3)
 *   F1-F5   = ESC [ [ A / B / C / D / E      (Linux 控制台)
 *   F1-F12  = ESC [ 11~ .. ESC [ 24~         (xterm CSI ~; 注意无 16/22)
 *   Insert  = ESC [ 2~   Delete = ESC [ 3~
 *   PgUp    = ESC [ 5~   PgDn   = ESC [ 6~
 *   Home    = ESC [ H 或 ESC [ 1~   End = ESC [ F 或 ESC [ 4~
 *   Shift+Tab = ESC [ Z
 * 方向键 ESC [ A/B/C/D 仍由调用方映射(默认模式=鼠标, -k 模式=光标键)。
 * ===========================================================================*/

/* 读 ESC 之后的序列字节(不含 ESC): 每个字节最多等 50ms。
 * 终端一次性把整个序列写进 pty, 所以后续字节的 poll 都会立即成功。
 * 返回读到的字节数(0 = 真的是单独的 ESC 键)。 */
static int read_esc_seq(char *seq, int max) {
    struct pollfd pf = { .fd = STDIN_FILENO, .events = POLLIN, .revents = 0 };
    int n = 0;
    while (n < max) {
        if (poll(&pf, 1, 50) != 1 || !(pf.revents & POLLIN)) break;
        if (read(STDIN_FILENO, &seq[n], 1) != 1) break;
        n++;
        if (seq[n-1] == '~') break;                              /* CSI ~ 型结束 */
        if (n == 2 && seq[0] == 'O') break;                      /* ESC O x 型结束 */
        if (n == 2 && seq[0] == '[' && strchr("ABCDHFPQRSZ", seq[1])) break;
        if (n == 3 && seq[0] == '[' && seq[1] == '[') break;     /* ESC [ [ x 型 */
    }
    return n;
}

/* 序列 -> PS/2 set-1 make 扫描码; 0 = 不认识 */
static int esc_seq_to_sc(const char *s, int n) {
    if (n == 2 && s[0] == 'O') {                                 /* SS3: F1-F4 */
        switch (s[1]) {
            case 'P': return 0x3B; case 'Q': return 0x3C;
            case 'R': return 0x3D; case 'S': return 0x3E;
        }
        return 0;
    }
    if (n >= 2 && s[0] == '[') {
        if (s[1] == '[' && n == 3) {                             /* Linux 控制台 F1-F5 */
            switch (s[2]) {
                case 'A': return 0x3B; case 'B': return 0x3C; case 'C': return 0x3D;
                case 'D': return 0x3E; case 'E': return 0x3F;
            }
            return 0;
        }
        if (s[n-1] == '~') {                                     /* CSI <num> ~ */
            int num = 0;
            for (int i = 1; i < n-1; i++) {
                if (s[i] < '0' || s[i] > '9') return 0;
                num = num * 10 + (s[i] - '0');
            }
            switch (num) {
                case  1: return 0x47;   /* Home   */
                case  2: return 0x52;   /* Insert */
                case  3: return 0x53;   /* Delete */
                case  4: return 0x4F;   /* End    */
                case  5: return 0x49;   /* PgUp   */
                case  6: return 0x51;   /* PgDn   */
                case 11: return 0x3B; case 12: return 0x3C; case 13: return 0x3D;
                case 14: return 0x3E; case 15: return 0x3F; case 17: return 0x40;
                case 18: return 0x41; case 19: return 0x42; case 20: return 0x43;
                case 21: return 0x44; case 23: return 0x57; case 24: return 0x58;
            }
            return 0;
        }
        if (n == 2) {                                            /* Home/End 单字节型 */
            if (s[1] == 'H') return 0x47;
            if (s[1] == 'F') return 0x4F;
        }
    }
    return 0;
}


/* ===========================================================================
 * -X 自检: 用"真实终端时序"喂按键, 再读 DOS 的 0040:0017 键盘标志字验证。
 *
 * 为什么要这个: 终端的自动重复**只给最后按下的那个键**。按住↑再按←, ↑的重复流
 * 断了 —— 旧的"超时即松手"会把↑当成松开(油门掉)。这个自检直接看 8086 侧认为
 * 哪些键是按下的, 一眼就能看出"上+左"能不能同时成立。
 * ========================================================================*/
static unsigned bda_kbd_flags(void) {
    int fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0) return 0xFFFF0000u;
    unsigned long pg  = BDA_KBD_FLAGS & ~0xFFFUL;
    unsigned long off = BDA_KBD_FLAGS & 0xFFFUL;
    void *p = mmap(NULL, 4096, PROT_READ, MAP_SHARED, fd, (off_t)pg);
    unsigned v = 0xFFFF0000u;
    if (p != MAP_FAILED) {
        v = *(volatile unsigned char *)((char *)p + off)
          | (*(volatile unsigned char *)((char *)p + off + 1) << 8);
        munmap(p, 4096);
    }
    close(fd);
    return v;
}

static void show_flags(long t, const char *tag) {
    if (dry_run) {                     /* 干跑: 打印注入程序内部的"按住的键"表 */
        fprintf(stderr, "[X] %5ldms  %-20s 按住:", t, tag);
        if (!held_n) fprintf(stderr, " (无)");
        for (int i = 0; i < held_n; i++)
            fprintf(stderr, " %02x%s", held_sc[i], held_latch[i] ? "(锁存)" : "");
        fprintf(stderr, "\n");
        return;
    }
    unsigned f = bda_kbd_flags();
    if (f & 0xFFFF0000u) { fprintf(stderr, "[X] /dev/mem 读不到\n"); return; }
    fprintf(stderr, "[X] %5ldms  %-20s 0017=%04X  上%d 下%d 左%d 右%d\n",
            t, tag, f, !!(f & 0x10), !!(f & 0x20), !!(f & 0x40), !!(f & 0x80));
}

static void run_selftest(void) {
    fprintf(stderr,
        "[X] 自检: 按住[上]1.5s, 期间在 1.5s 时按下[左], 2.6s 松开[左]。\n"
        "[X] 期望: 1.65s 起 上=1 且 左=1 (同时按住); 3.0s 时 左=0 但 上仍=1 (锁存)。\n"
        "[X] 需要 DOS 在跑, 否则标志字恒为 0。\n");
    long t0 = now_ms();
    long up_next = 0, left_next = -1;
    int up_first = 1, left_first = 1;
    const long UP_STOP = 1500, LEFT_START = 1500, LEFT_STOP = 2600, END = 3600;
    int did_unlatch = 0;

    struct { long t; const char *tag; } smp[] = {
        { 120, "按住上(首次重复前)"}, { 700, "按住上(应已锁存)"},
        {1400, "按住上"},             {1650, "刚按下左"},
        {2100, "上+左"},              {2550, "上+左(重复中)"},
        {2950, "已松开左(上应仍在)"}, {3250, "再按一次↑=解锁"},
        {3450, "结束"},
    };
    int si = 0, n = (int)(sizeof(smp) / sizeof(smp[0]));
    for (;;) {
        long t = now_ms() - t0;
        if (up_next >= 0 && t >= up_next && up_next <= UP_STOP) {
            hold_press(0x48);                       /* 上 */
            up_next = up_first ? (up_first = 0, up_next + 500) : up_next + 33;
        }
        if (t >= LEFT_START && left_next < 0) left_next = LEFT_START;
        if (left_next >= 0 && t >= left_next && left_next <= LEFT_STOP) {
            hold_press(0x4B);                       /* 左 */
            left_next = left_first ? (left_first = 0, left_next + 500) : left_next + 33;
        }
        if (t >= 3250 && !did_unlatch) { did_unlatch = 1; hold_press(0x48); }  /* 再按一次↑ */
        hold_expire();
        if (si < n && t >= smp[si].t) { show_flags(t, smp[si].tag); si++; }
        if (t > END) break;
        usleep(5000);
    }
    hold_release_all();
    fprintf(stderr, "[X] 完成, 已放掉所有键\n");
}

int main(int argc, char **argv) {
    int pin0 = DEFAULT_BASE;   /* EMIO 内的引脚序号(0..117), 默认 54 */
    int i, test_mode = 0, keymap_check = 0, sweep_mode = 0, sweep_from = 0, verify_mode = 0;
    int raw = -1, raw_mode = 0;   /* 原始扫描码探针: raw=扫描码, raw_mode: 1=只发make, 2=make+break */
    int mouse_test = -1;          /* -M [n]: 鼠标自检模式, n 缺省 1 */
    int man_dx = 0, man_dy = 0, man_btn = 0, man_mode = 0;  /* -x/-y/-c 手动发一个包 */
    int step = 4;                 /* 方向键每次移动的像素数 */
    const char *mice_dev = NULL;  /* -f /dev/input/mice: 直通真实鼠标 */
    int kbd_only = 0;             /* -k: 纯键盘模式(等价于老的 kbd_gpio_inject) */
    int selftest = 0;             /* -X: 自检(时间序注入 + 读 0040:0017) */
    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-b") && i + 1 < argc) pin0 = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-v"))     verbose = 1;
        else if (!strcmp(argv[i], "-t"))     test_mode = 1;
        else if (!strcmp(argv[i], "-s"))     slow = 1;
        else if (!strcmp(argv[i], "-K"))     keymap_check = 1;
        else if (!strcmp(argv[i], "-B"))     sweep_mode = 1;
        else if (!strcmp(argv[i], "-V"))     verify_mode = 1;
        else if (!strcmp(argv[i], "-b0") && i + 1 < argc) sweep_from = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-g") && i + 1 < argc) gap_us = atoi(argv[++i]);
        /* ---- 鼠标相关 ---- */
        else if (!strcmp(argv[i], "-M")) {
            mouse_test = 1;
            if (i + 1 < argc && isdigit((unsigned char)argv[i+1][0]) && argv[i+1][0] != '-')
                mouse_test = atoi(argv[++i]);
        }
        else if (!strcmp(argv[i], "-x") && i + 1 < argc) { man_dx = atoi(argv[++i]); man_mode = 1; }
        else if (!strcmp(argv[i], "-y") && i + 1 < argc) { man_dy = atoi(argv[++i]); man_mode = 1; }
        else if (!strcmp(argv[i], "-c") && i + 1 < argc) { man_btn = atoi(argv[++i]); man_mode = 1; }
        else if (!strcmp(argv[i], "-S") && i + 1 < argc) step = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-f") && i + 1 < argc) mice_dev = argv[++i];
        else if (!strcmp(argv[i], "-k"))     kbd_only = 1;
        else if (!strcmp(argv[i], "-X"))     selftest = 1;
        else if (!strcmp(argv[i], "-n"))     dry_run  = 1;   /* 干跑: 不碰 GPIO */
        else if (!strcmp(argv[i], "-a"))     arrow_mouse = 1;   /* 启动即"方向键=鼠标" */
        else if (!strcmp(argv[i], "-H") && i + 1 < argc) {   /* 重复窗口 ms */
            rep_ms = atoi(argv[++i]);
            if (rep_ms < 15)  rep_ms = 15;
            if (rep_ms > 200) rep_ms = 200;
            rel_ms = rep_ms + 40;
        }
        /* ---- 按住/锁存 ---- */
        else if (!strcmp(argv[i], "-T") && i + 1 < argc) {   /* 方向键松开超时 ms */
            rel_hold_ms = atoi(argv[++i]);
            if (rel_hold_ms < 60)  rel_hold_ms = 60;
            if (rel_hold_ms > 900) rel_hold_ms = 900;
        }
        else if (!strcmp(argv[i], "-C") && i + 1 < argc) {   /* 连续重复几次触发锁存 */
            latch_after = atoi(argv[++i]);
            if (latch_after < 0)   latch_after = 0;
            if (latch_after > 100) latch_after = 100;
        }
        else if (!strcmp(argv[i], "-L")) {   /* 锁存范围: 缺省↑↓ / all / 0 / 16进制扫描码表 */
            if (i + 1 < argc && argv[i+1][0] != '-') {
                const char *v = argv[++i];
                if (!strcmp(v,"0") || !strcmp(v,"off"))      latch_mode = 0;
                else if (!strcmp(v,"all"))                   latch_mode = 2;
                else if (!strcmp(v,"ud"))                    latch_mode = 1;
                else {                                        /* 例: -L 48,50,1e */
                    char buf[64]; int n = 0;
                    snprintf(buf, sizeof buf, "%s", v);
                    for (char *t = strtok(buf, ",;"); t && n < 16; t = strtok(NULL, ",;"))
                        latch_keys[n++] = (uint8_t)strtol(t, NULL, 16);
                    latch_nkeys = n; latch_mode = 3;
                }
            } else latch_mode = 1;
        }
        /* -r <hex> 只发 make; -R <hex> 发 make+break —— 用于探测 80186 的真实解释 */
        else if (!strcmp(argv[i], "-r") && i + 1 < argc) { raw = (int)strtol(argv[++i], NULL, 16); raw_mode = 1; }
        else if (!strcmp(argv[i], "-R") && i + 1 < argc) { raw = (int)strtol(argv[++i], NULL, 16); raw_mode = 2; }
    }

    if (dry_run) { run_selftest(); return 0; }   /* -n: 纯状态机自检, 不需要 GPIO */

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

    if (selftest) { run_selftest(); for (int k = 0; k <= NDATA; k++) set_pin(k, 0); return 0; }
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

    /* ---- -V 校验模式: 写完 9 根线立刻从 sysfs 读回, 验证 PS->EMIO 这一段 ----
     * 若读回与写入一致, 说明 PS 侧完全正确, 问题在 PL/BD 或 8042/BIOS;
     * 若读回就不一致, 问题在 PS 的 GPIO 写入/sysfs 层, 与 PL 无关。 */
    if (verify_mode) {
        static const int t[] = {0x24, 0x23, 0x05, 0xA4, 0xA3};
        unsigned k, v;
        fprintf(stderr, "[verify] idx : bit7..bit0 strobe   (期望 -> 读回)\n");
        for (k = 0; k < sizeof(t)/sizeof(t[0]); k++) {
            v = (unsigned)t[k];
            for (i = 0; i < NDATA; i++) set_pin(i, (int)((v >> i) & 1));
            usleep(2000);
            set_pin(NDATA, 0);  usleep(2000);
            set_pin(NDATA, 1);  usleep(2000);
            fprintf(stderr, "  0x%02X ->", v);
            for (i = NDATA - 1; i >= 0; i--) fprintf(stderr, " %d", get_pin(i));
            fprintf(stderr, "  stb=%d", get_pin(NDATA));
            {
                int bad = 0, rd;
                for (i = 0; i < NDATA; i++) { rd = get_pin(i); if (rd != (int)((v>>i)&1)) bad++; }
                if (get_pin(NDATA) != 1) bad++;
                fprintf(stderr, "   %s\n", bad ? "MISMATCH!" : "OK");
            }
            set_pin(NDATA, 0);
            usleep(2000);
        }
        for (int q = 0; q <= NDATA; q++) set_pin(q, 0);
        fprintf(stderr, "[verify] 结束\n");
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

    /* ---- 手动发一个鼠标包: -x <dx> -y <dy> -c <btn> ---- */
    if (man_mode) {
        fprintf(stderr, "[mouse] 手动包: dx=%d dy=%d btn=%d\n", man_dx, man_dy, man_btn);
        send_mouse_packet(man_dx, man_dy, man_btn);
        for (int q = 0; q <= NDATA; q++) set_pin(q, 0);
        return 0;
    }

    /* ---- 鼠标自检: -M [n] ----
     * 用途: 在装 DOS 驱动之前/之后确认"鼠标字节到底有没有被 DOS 收到"。
     *   1 = 每 120ms 向右 +4  (光标应持续右移, 撞到右边界后停住)
     *   2 = 画方框            (光标应走一个矩形)
     *   3 = 每 600ms 点一次左键
     * 若 PL 链路通了但 DOS 没反应 => 检查屏幕上有没有 "PS2 Mouse detected";
     * 没那行说明 POST 没检测到鼠标(应答序列问题), 有那行说明差一个 INT33 驱动。 */
    if (mouse_test >= 0) {
        signal(SIGINT, SIG_DFL);
        fprintf(stderr, "[mouse] 自检模式 %d (Ctrl+C 退出)\n", mouse_test);
        if (mouse_test == 1) {
            for (;;) { send_mouse_packet(step, 0, 0); usleep(120000); }
        } else if (mouse_test == 2) {
            int phase = 0, n = 0;
            for (;;) {
                int dx = 0, dy = 0;
                switch (phase) {
                    case 0: dx =  step; break;
                    case 1: dy = -step; break;   /* PS/2 的 Y 正方向朝上 => 向下用负 */
                    case 2: dx = -step; break;
                    case 3: dy =  step; break;
                }
                send_mouse_packet(dx, dy, 0);
                if (++n >= 20) { n = 0; phase = (phase + 1) & 3; }
                usleep(60000);
            }
        } else {
            for (;;) {
                send_mouse_packet(0, 0, 1);   /* 左键按下 */
                usleep(60000);
                send_mouse_packet(0, 0, 0);   /* 松开 */
                usleep(600000);
            }
        }
    }

    /* ---- 直通真实鼠标: -f /dev/input/mice ----
     * PetaLinux 的 /dev/input/mice(mousedev) 给的正好就是标准 PS/2 3 字节包:
     *   b0 = 0x08 | Ysign<<5 | Xsign<<4 | M<<2 | R<<1 | L,  b1 = dx, b2 = dy
     * 所以直接原样转发即可, 不做任何换算。 */
    if (mice_dev) {
        int mfd = open(mice_dev, O_RDONLY);
        if (mfd < 0) {
            fprintf(stderr, "[mouse] 打开 %s 失败: %s\n", mice_dev, strerror(errno));
            return 1;
        }
        signal(SIGINT, SIG_DFL);
        fprintf(stderr, "[mouse] 直通 %s (Ctrl+C 退出)\n", mice_dev);
        for (;;) {
            unsigned char p[3];
            ssize_t r = read(mfd, p, 3);
            if (r != 3) { if (r < 0 && errno == EINTR) continue; usleep(1000); continue; }
            send_mouse_byte(p[0]);
            usleep(MOUSE_GAP_US);
            send_mouse_byte(p[1]);
            usleep(MOUSE_GAP_US);
            send_mouse_byte(p[2]);
            if (verbose)
                fprintf(stderr, "[mouse] %02x %02x %02x\n", p[0], p[1], p[2]);
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

    fprintf(stderr, "[mouse] 交互模式: 打字照常; 方向键=光标键 重复窗口=%dms 打字松开=%dms 方向键松开=%dms\n",
            rep_ms, rel_ms, rel_hold_ms);
    {
        const char *ls = latch_mode == 0 ? "关" : latch_mode == 2 ? "所有键" :
                         latch_mode == 3 ? "自定义" : "仅 ↑/↓";
        fprintf(stderr, "[mouse]           按住: 连续重复 %d 次即锁存[%s] —— 可与其它键同时按, 再按一次同键=松开\n",
                latch_after, ls);
    }
    fprintf(stderr, "[mouse]           Ctrl+G = 放掉所有锁存的键\n");
    fprintf(stderr, "[mouse]           鼠标: Ctrl+方向键 移动;  Ctrl+T 切换【方向键=鼠标】层 (当前:%s)\n",
            arrow_mouse ? "鼠标" : "键盘");
    fprintf(stderr, "[mouse]           Ctrl+L=左键单击  Ctrl+R=右键单击  Ctrl+B=中键单击\n");
    fprintf(stderr, "[mouse]           Ctrl+] 退出\n");

    char c;
    /* ★ 改成 poll + 超时: 只有这样才能在"没有新字节进来"时把按住的键放掉,
     *   实现"按住=真按住, 松手=自动 break"(见文件上方 hold 语义说明)。 */
    struct pollfd pfd = { .fd = STDIN_FILENO, .events = POLLIN, .revents = 0 };
    for (;;) {
        int pr = poll(&pfd, 1, 10);
        if (pr == 0) { hold_expire(); continue; }        /* 10ms 一次的"松手"检查 */
        if (pr < 0) { if (errno == EINTR) continue; break; }
        hold_expire();                                   /* 输入很密时也要按时放键 */
        if (read(STDIN_FILENO, &c, 1) != 1) break;
        if ((unsigned char)c == 0x1d) break;      /* Ctrl+] */

        /* ---- Ctrl+G: 放掉所有锁存的键(万一卡住踩油门) ---- */
        if ((unsigned char)c == 0x07) {
            int n = 0;
            for (int k = held_n - 1; k >= 0; k--)
                if (held_latch[k]) { hold_release_idx(k); n++; }
            fprintf(stderr, "\n[mouse] Ctrl+G: 放掉 %d 个锁存键\n", n);
            continue;
        }

        /* ---- Ctrl+T: 切换"方向键路由"层 ---- */
        if ((unsigned char)c == 0x14 && !kbd_only) {
            hold_release_all();                   /* 切层前先放掉按住的键, 免得粘住 */
            arrow_mouse = !arrow_mouse;
            fprintf(stderr, "\n[mouse] 方向键 -> %s\n", arrow_mouse ? "鼠标" : "光标键(键盘)");
            continue;
        }

        /* ---- 终端转义序列: 功能键/导航键 -> PS/2 扫描码; 方向键按路由层处理 ---- */
        if ((unsigned char)c == 0x1b) {
            char seq[8];
            int n = read_esc_seq(seq, sizeof(seq));
            if (n == 0) {                                    /* 50ms 内无后续 = 真的是 ESC 键 */
                uint8_t e; int sh;
                if (ascii_to_sc(0x1b, &e, &sh)) hold_press(e);
                continue;
            }
            /* 方向键: ESC[A..D = 纯方向键; ESC[1;mA = 带修饰键(Ctrl/Shift) */
            {
                int arrow = -1, ctrl = 0, shifted = 0;
                if (n == 2 && seq[0] == '[' &&
                    (seq[1]=='A' || seq[1]=='B' || seq[1]=='C' || seq[1]=='D')) {
                    arrow = seq[1] - 'A';
                } else if (n == 5 && seq[0]=='[' && seq[1]=='1' && seq[2]==';' &&
                           (seq[4]=='A' || seq[4]=='B' || seq[4]=='C' || seq[4]=='D')) {
                    /* xterm 修饰键: 2=Shift 3=Alt 5=Ctrl 6=Shift+Ctrl ... */
                    int m = seq[3] - '0';
                    ctrl    = (m == 5 || m == 6 || m == 7 || m == 8);
                    shifted = (m == 2 || m == 4 || m == 6 || m == 8);
                    arrow = seq[4] - 'A';
                }
                if (arrow >= 0) {
                    static const uint8_t cur[4] = {0x48, 0x50, 0x4D, 0x4B}; /* 上/下/右/左  ← 索引是 ESC[A..D = 上/下/右/左, C=右 必须给 0x4D */
                    if (!kbd_only && (ctrl || (arrow_mouse && !shifted))) {
                        if      (arrow==0) send_mouse_packet(0,  step, 0);   /* 上 */
                        else if (arrow==1) send_mouse_packet(0, -step, 0);   /* 下 */
                        else if (arrow==2) send_mouse_packet( step, 0, 0);   /* 右 */
                        else               send_mouse_packet(-step, 0, 0);   /* 左 */
                    } else {
                        if (shifted) hold_press(0x2a);      /* Shift+方向 = 选择 */
                        hold_press(cur[arrow]);
                    }
                    continue;
                }
            }
            if (n == 3 && seq[0]=='[' && seq[1]=='[' && seq[2]=='Z') {   /* Shift+Tab */
                hold_press(0x2a); hold_press(0x0f);
                continue;
            }
            {
                int sc = esc_seq_to_sc(seq, n);
                if (sc) {
                    hold_press((uint8_t)sc);
                    if (verbose) fprintf(stderr, "[fkey] %d 字节序列 -> sc=0x%02x\n", n, sc);
                } else if (verbose) {
                    fprintf(stderr, "[fkey] 未识别序列(%d 字节):", n);
                    for (int i = 0; i < n; i++) fprintf(stderr, " %02x", (unsigned char)seq[i]);
                    fprintf(stderr, "\n");
                }
            }
            continue;
        }
        /* ---- 鼠标: 按键单击(用 Ctrl+字母, 这些字节不在打字表里, 不会冲突) ---- */
        if (!kbd_only) {
            unsigned char u = (unsigned char)c;
            int btn = -1;
            if      (u == 0x0c) btn = 1;   /* Ctrl+L 左键 */
            else if (u == 0x12) btn = 2;   /* Ctrl+R 右键 */
            else if (u == 0x02) btn = 4;   /* Ctrl+B 中键 */
            if (btn >= 0) {
                send_mouse_packet(0, 0, btn);   /* 按下 */
                usleep(60000);
                send_mouse_packet(0, 0, 0);     /* 松开 */
                continue;
            }
        }

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
        if (shift) hold_press(0x2a);              /* Shift 按下(同样靠超时松开) */
        hold_press(sc);                           /* make 由 hold_expire 负责 break */
    }
    hold_release_all();                           /* 退出前把按住的键全部放掉 */
    tcflush(STDIN_FILENO, TCIFLUSH);              /* 丢掉队列里残留的字节 */
    tcsetattr(STDIN_FILENO, TCSANOW, &old);
    for (int k = 0; k <= NDATA; k++) set_pin(k, 0);
    fprintf(stderr, "\n[kbd_gpio] 退出, 终端已还原\n");
    return 0;
}
