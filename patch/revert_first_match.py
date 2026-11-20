#!/usr/bin/env python3
"""把 FinaSU 1.6.4 的 first-match 回退成 last-match。

背景：1.6.4 的 `find_kernel_symbol_exact_cb` 从 `return 0`（走完所有同名符号，
留最后一个）改成 `return 1`（命中即停，取第一个）。本机（MagicOS 11 /
6.1.157-android14-11-g84ffa64b710b）上 `security_compute_av` 一类符号存在重复
实例，first-match 会 hook 到错的那个，表现为 SELinux 策略重写后 app 拿不到
`service_manager find`（activity/package binder 全 null，进程被 SIGKILL）。

用法：revert_first_match.py <KernelSU 源码根目录>
"""
import os
import sys


def main(root):
    p = os.path.join(root, "kernel/infra/symbol_resolver.c")
    if not os.path.isfile(p):
        print("skip: no kernel/infra/symbol_resolver.c")
        return 0
    with open(p, "r", encoding="utf-8", errors="replace") as f:
        s = f.read()
    marker = "find_kernel_symbol_exact_cb"
    i = s.find(marker)
    if i < 0:
        print("skip: no find_kernel_symbol_exact_cb")
        return 0
    j = s.find("\n}", i)
    if j < 0:
        print("skip: callback body not found")
        return 0
    seg = s[i:j]
    if "return 1;" not in seg:
        print("skip: already last-match (return 0)")
        return 0
    s = s[:i] + seg.replace("return 1;", "return 0;", 1) + s[j:]
    with open(p, "w", encoding="utf-8", newline="\n") as f:
        f.write(s)
    print("reverted first-match -> last-match")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
