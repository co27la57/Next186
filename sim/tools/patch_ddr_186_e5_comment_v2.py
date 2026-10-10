#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Update the 0x00E5 port comment in ddr_186.v for probe v2 (CRLF-safe)."""
import sys

PATH = "ddr_186.v"
CRLF = "\r\n"

OLD = (
    "\t//   0x00E5 (8b)  <- \u2605 95th self-test probe\uff1ascan256 \u540e\u518d\u8bfb offset 0x84 \u7684\u5b57\u8282" + CRLF +
    "\t//                   \u7528\u6765\u533a\u5206\u201c\u6574\u884c\u88ab\u6362\u6210\u53e6\u4e00\u884c\u7684\u5185\u5bb9\u201d(0x61)" + CRLF +
    "\t//                   / \u201c\u53e6\u4e00\u884c\u7684 word0 \u91cd\u590d\u201d(0x60) / \u201c\u53ea\u6709\u9996\u5b57\u8282\u9519\u201d(0x21)\u3002" + CRLF +
    "\t//                   \u5b57\u8282 0x84 \u5c5e\u4e8e\u7b2c 1 \u4e2a\u5b57\uff0c\u6240\u4ee5\u5b83\u80fd\u76f4\u63a5\u5206\u8fa8\u8fd9\u4e09\u79cd\u5f62\u6001\u3002" + CRLF
)

NEW = (
    "\t//   0x00E5 (8b)  <- \u2605 95th self-test probe v2\uff1ascan256 \u540e\u518d\u8bfb offset 0x180" + CRLF +
    "\t//                   \uff08line 6 \u81ea\u5df1\u7684\u69fd\u4f4d\uff09\u7684\u5b57\u8282\u3002" + CRLF +
    "\t//                   v1 \u5df2\u7ecf\u8bc1\u5b9e [0x80]=0x60 \u4e14 [0x84]=0x61 \u21d2 \u81ea\u6d4b\u56fe\u6848" + CRLF +
    "\t//                   \u6574\u4f53\u53f3\u79fb 0x100 \u5b57\u8282\uff08+4 \u884c\uff09\uff0cline 2 \u69fd\u4f4d\u88c5\u7684\u662f line 6 \u7684\u6574\u884c\u5185\u5bb9\u3002" + CRLF +
    "\t//                   \u672c\u8f6e\u5224\u636e\uff1a[0x180]==0x60 \u21d2 DDR \u5b8c\u597d\u3001\u662f\u586b\u5145\u8bfb\u9519\u5730\u5740\uff08\u8bfb\u4fa7\uff09\uff1b" + CRLF +
    "\t//                             \u5426\u5219 \u21d2 line 6 \u7684\u5199\u56de\u843d\u5230\u4e86\u522b\u5904\uff08\u5199\u4fa7\uff09\u3002" + CRLF
)


def main():
    revert = "--revert" in sys.argv
    raw = open(PATH, "r", encoding="utf-8", newline="").read()
    if raw.count("\r\n") != raw.count("\n"):
        print("ABORT: not pure CRLF")
        return 1
    old, new = (NEW, OLD) if revert else (OLD, NEW)
    if raw.count(old) != 1:
        print("ABORT: found %d occurrences (need 1)" % raw.count(old))
        return 1
    open(PATH, "w", encoding="utf-8", newline="").write(raw.replace(old, new))
    print("ddr_186.v 0xE5 comment %s" % ("reverted" if revert else "updated to v2"))
    return 0


sys.exit(main())
