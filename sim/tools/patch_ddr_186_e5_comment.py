#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Refresh the stale 0x00E4 / 0x00E5 port comments in ddr_186.v (CRLF-safe).

The old text still described the 74th change ("both ports carry the self-test byte sum,
expected 0xEF55"), which no longer matches what the self test actually writes.
"""
import sys

PATH = "ddr_186.v"
CRLF = "\r\n"

OLD = (
    "\t//   0x00E4 (16b) <- memory round-trip self test result (74th change): fills the" + CRLF +
    "\t//   0x00E5 (8b)  <- memory round-trip self test result (74th change): fills the" + CRLF +
    "\t//                   8 KB buffer with a known pattern, flushes the cache, reads it" + CRLF +
    "\t//                   back and reports the byte sum. Expected = 0xEF55." + CRLF
)

NEW = (
    "\t//   0x00E4 (16b) <- \u5185\u5b58\u81ea\u6d4b\u4e0a\u62a5\uff08capstone \u6838\u5bf9\uff09\uff1a" + CRLF +
    "\t//                   AL = \u5bf9\u7167\uff08\u586b 1KB \u540e\u8bfb offset 0x40\uff0c\u671f\u671b 0x10\uff09" + CRLF +
    "\t//                   AH = \u6d4b\u91cf\uff08scan256 \u9010\u51fa\u5168\u90e8\u540e\u8bfb offset 0x80\uff0c\u671f\u671b 0x20\uff09" + CRLF +
    "\t//                   \u21d2 \u6574\u4f53\u671f\u671b 0x2010" + CRLF +
    "\t//   0x00E5 (8b)  <- \u2605 95th self-test probe\uff1ascan256 \u540e\u518d\u8bfb offset 0x84 \u7684\u5b57\u8282" + CRLF +
    "\t//                   \u7528\u6765\u533a\u5206\u201c\u6574\u884c\u88ab\u6362\u6210\u53e6\u4e00\u884c\u7684\u5185\u5bb9\u201d(0x61)" + CRLF +
    "\t//                   / \u201c\u53e6\u4e00\u884c\u7684 word0 \u91cd\u590d\u201d(0x60) / \u201c\u53ea\u6709\u9996\u5b57\u8282\u9519\u201d(0x21)\u3002" + CRLF +
    "\t//                   \u5b57\u8282 0x84 \u5c5e\u4e8e\u7b2c 1 \u4e2a\u5b57\uff0c\u6240\u4ee5\u5b83\u80fd\u76f4\u63a5\u5206\u8fa8\u8fd9\u4e09\u79cd\u5f62\u6001\u3002" + CRLF
)


def main():
    revert = "--revert" in sys.argv
    raw = open(PATH, "r", encoding="utf-8", newline="").read()
    if raw.count("\r\n") != raw.count("\n"):
        print("ABORT: file is not pure CRLF")
        return 1
    old, new = (NEW, OLD) if revert else (OLD, NEW)
    if raw.count(old) != 1:
        print("ABORT: found %d occurrences (need 1)" % raw.count(old))
        return 1
    open(PATH, "w", encoding="utf-8", newline="").write(raw.replace(old, new))
    print("ddr_186.v port comments %s" % ("reverted" if revert else "updated"))
    return 0


sys.exit(main())
