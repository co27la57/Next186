import re, sys

src = open('KB_8042.v', encoding='utf-8', errors='ignore').read()
lines = src.split('\n')

# 找出所有 always 块的范围
blocks = []
depth = 0
start = None
for i, l in enumerate(lines):
    if re.search(r'\balways\s*@', l):
        if start is None:
            start = i
        depth = 1
        # 单行 always(无 begin) 不常见, 这里假设有 begin
        continue
    if start is not None:
        depth += l.count('begin') - l.count('end')
        if depth <= 0 and 'end' in l:
            blocks.append((start, i))
            start = None

print("检测到 always 块数:", len(blocks))

# 检查每个 vk_* / 关键 reg 是否只在一个 always 块内被赋值
regs = ['vk_cmd_seen', 'vk_cmd', 'vk_state', 'vk_out', 'vk_out_v',
        'OBF', 'MOBF', 's_data', 'cmdbyte', 'wr_kb']

fails = []
for r in regs:
    # 找所有 "<=" 赋值(排除比较运算符)
    assigns = []
    for i, l in enumerate(lines):
        for m in re.finditer(r'(?<![\w\]\)])\s*' + re.escape(r) + r'\s*<=', l):
            # 排除 <= 出现在 if(...<=...) 判断里: 简单判断行内是否有 if/&&/(
            assigns.append(i)

    if not assigns:
        continue
    # 判断这些赋值落在哪些 always 块
    owners = set()
    for a in assigns:
        for (s, e) in blocks:
            if s <= a <= e:
                owners.add((s, e))
    # 落在块外的赋值(比如在 assign 或 initial)单独标记
    outside = [a for a in assigns if not any(s <= a <= e for (s, e) in blocks)]

    status = "OK" if len(owners) <= 1 else "MULTI-DRIVER"
    print("  %-12s 赋值处=%-3d 所属always块数=%d  %s" % (r, len(assigns), len(owners), status))
    if len(owners) > 1:
        fails.append("%s 在 %d 个 always 块中被赋值 -> 多驱动" % (r, len(owners)))

print()
if fails:
    print("FAIL:")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("PASS: 无多驱动")
