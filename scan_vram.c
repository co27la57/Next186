// ============================================================================
// scan_vram.c — 扫描 80186 的 1MB 地址空间, 定位真正的文本显存位置
// ----------------------------------------------------------------------------
// 用途: 屏幕显示的内容 ≠ 我们知道的那个 B8000 区域时, 用它找出
//       "显示实际从哪里取字符", 不用 ILA 探针也能定位。
//
// 原理: PC 文本模式 VRAM 的布局是 [字符][属性][字符][属性]...
//       - 偶数字节 = 可打印 ASCII (0x20-0x7E)
//       - 奇数字节 = 属性 (< 0x80, 典型 0x07)
//       连续 64 字节以上满足此特征 => 几乎肯定是文本 VRAM。
//
// 编译 (板子上有 gcc 就直接在板子上编; 否则用 PetaLinux 机器交叉编译):
//   gcc -O2 -o scan_vram scan_vram.c
//   arm-linux-gnueabihf-gcc -O2 -static -o scan_vram scan_vram.c
//
// 运行: ./scan_vram
// ============================================================================
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

#define ARM_BASE 0x08000000UL    /* 80186 地址 0 对应的 ARM 物理地址 */
#define SCAN_SIZE 0x100000UL     /* 扫描 80186 全部 1MB */
#define MIN_RUN   64             /* 最短认定为 VRAM 的连续长度 */

static int printable(unsigned char c) { return c >= 0x20 && c < 0x7f; }

int main(void) {
    int fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0) { perror("open /dev/mem (需要 root)"); return 1; }

    volatile unsigned char *m = mmap(NULL, SCAN_SIZE, PROT_READ, MAP_SHARED, fd, ARM_BASE);
    if (m == MAP_FAILED) { perror("mmap"); return 1; }

    printf("扫描 80186 1MB (ARM 0x%08lX - 0x%08lX), 找文本模式签名...\n",
           (unsigned long)ARM_BASE, (unsigned long)(ARM_BASE + SCAN_SIZE - 1));

    unsigned long i = 0;
    int found = 0;

    while (i + MIN_RUN < SCAN_SIZE) {
        unsigned long run = 0;
        /* 偶数位可打印, 奇数位 <0x80 => 文本模式特征 */
        while (i + run + 1 < SCAN_SIZE &&
               printable(m[i + run]) && m[i + run + 1] < 0x80) {
            run += 2;
        }
        if (run >= MIN_RUN) {
            printf("\n[命中] ARM=0x%08lX   80186=0x%05lX   长度=%lu 字节\n",
                   (unsigned long)(ARM_BASE + i), i, run);
            printf("   解码: \"");
            for (unsigned long k = 0; k < run && k < 200; k += 2)
                putchar(m[i + k]);
            printf("\"\n");
            found++;
            i += run;
        } else {
            i += 2;
        }
    }

    if (!found)
        printf("\n未找到文本模式区域。\n"
               " => 当前可能是【图形模式】(A0000 区, 无字符/属性交替特征),\n"
               "    或显存已被清零/内容非 ASCII。\n");

    return 0;
}
