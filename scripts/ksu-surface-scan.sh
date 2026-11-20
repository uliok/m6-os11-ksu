#!/system/bin/sh
# ksu-surface-scan.sh — 只读扫描 KernelSU 在本机的可观测痕迹（不改任何东西）
#
# 用法：
#   adb push ksu-surface-scan.sh /data/local/tmp/
#   adb shell sh /data/local/tmp/ksu-surface-scan.sh          # shell 视角
#   adb shell su -c 'sh /data/local/tmp/ksu-surface-scan.sh'  # root 视角（能看 kprobes/list）
#
# 目的：给出「哪些痕迹谁能看到」的基线，改探针前后各跑一次做对比。

sec() { echo; echo "===== $1"; }
has() { if [ -e "$1" ]; then echo "  [有]   $1"; else echo "  [无]   $1"; fi; }
rd()  { if [ -r "$1" ]; then echo "  [可读] $1"; else echo "  [不可读] $1"; fi; }

sec "0. 环境"
echo "  uid=$(id -u 2>/dev/null) ctx=$(cat /proc/self/attr/current 2>/dev/null)"
uname -a
echo "  build.type=$(getprop ro.build.type) release=$(getprop ro.build.version.release)"
echo "  selinux=$(getenforce 2>/dev/null)"
echo "  kptr_restrict=$(cat /proc/sys/kernel/kptr_restrict 2>/dev/null)"
echo "  dmesg_restrict=$(cat /proc/sys/kernel/dmesg_restrict 2>/dev/null)"
echo "  perf_event_paranoid=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null)"

sec "1. LKM 痕迹"
if [ -r /proc/modules ]; then
    echo "  [可读] /proc/modules"
    echo "  kernelsu 行数=$(grep -ci kernelsu /proc/modules 2>/dev/null)"
    grep -i kernelsu /proc/modules 2>/dev/null | head -3
else
    echo "  [不可读] /proc/modules"
fi
has /sys/module/kernelsu
ls -ld /sys/module/kernelsu 2>&1 | sed 's/^/  /'
echo "  /sys/module 里名字带 ksu 的："
ls /sys/module 2>/dev/null | grep -i -E 'ksu|kernelsu' | sed 's/^/    /' || true

sec "2. kallsyms"
if [ -r /proc/kallsyms ]; then
    echo "  [可读] /proc/kallsyms"
    echo "  ksu 相关符号数=$(grep -ci -E 'ksu|kernelsu' /proc/kallsyms 2>/dev/null)"
    grep -i -E 'kernelsu|ksu_' /proc/kallsyms 2>/dev/null | head -8 | sed 's/^/    /'
    echo "  模块符号（[kernelsu]）："
    grep -F '[kernelsu]' /proc/kallsyms 2>/dev/null | head -5 | sed 's/^/    /'
else
    echo "  [不可读] /proc/kallsyms"
fi

sec "3. debugfs / kprobes（唯一的探针枚举口）"
mount 2>/dev/null | grep -E 'debugfs|tracefs' | sed 's/^/  /'
has /sys/kernel/debug
has /sys/kernel/debug/kprobes
rd /sys/kernel/debug/kprobes/list
if [ -r /sys/kernel/debug/kprobes/list ]; then
    echo "  --- kprobes/list ---"
    cat /sys/kernel/debug/kprobes/list | sed 's/^/    /'
    echo "  总数=$(wc -l < /sys/kernel/debug/kprobes/list)"
    echo "  --- 与本套 ko 相关的条目 ---"
    grep -E 'execve|setresuid|faccessat|statx|newfstatat|begin_new_exec|exec_binprm|input_event|slow_avc_audit|reboot' \
        /sys/kernel/debug/kprobes/list 2>/dev/null | sed 's/^/    /'
else
    echo "  list 不可读（debugfs 未挂载或非 root）"
fi
if [ -w /sys/kernel/debug/kprobes/enabled ]; then
    echo "  [可写] kprobes/enabled（能全局 disarm，但内容仍可见）"
else
    echo "  [不可写] kprobes/enabled"
fi

sec "4. tracefs"
for d in /sys/kernel/tracing /sys/kernel/debug/tracing; do
    if [ -d "$d" ]; then
        echo "  [目录] $d"
        [ -r "$d/kprobe_events" ] && echo "    kprobe_events 行数=$(wc -l < "$d/kprobe_events" 2>/dev/null)"
        [ -r "$d/available_filter_functions" ] && echo "    available_filter_functions 可读（$(wc -l < "$d/available_filter_functions" 2>/dev/null) 行）"
    fi
done

sec "5. 设备节点 / 杂项"
ls -l /dev 2>/dev/null | grep -i ksu | sed 's/^/  /' || true
grep -i ksu /proc/misc 2>/dev/null | sed 's/^/  /' || true
getprop 2>/dev/null | grep -i -E 'ksu|kernelsu' | sed 's/^/  /' || true

sec "6. 用户态痕迹"
ps -A 2>/dev/null | grep -i -E 'ksud|kernelsu' | grep -v grep | sed 's/^/  /' || true
for p in /data/adb /data/adb/ksu /data/adb/modules /data/adb/ksud; do
    ls -ld "$p" 2>&1 | sed 's/^/  /'
done
ls -l /data/adb/ksu 2>/dev/null | head -5 | sed 's/^/  /' || true

sec "7. 内核日志（需要 dmesg_restrict=0）"
dmesg 2>/dev/null | grep -i -E 'kprobe|kernelsu|ksu:' | tail -15 | sed 's/^/  /' || echo "  dmesg 不可读"

sec "8. 汇总"
echo "  说明：kprobe 的唯一枚举口是 /sys/kernel/debug/kprobes/list（0400 root + debugfs 挂载）。"
echo "  普通 App 能触到的面只有 /proc/modules、/sys/module、/proc/kallsyms —— 上面逐项已给出可读性。"
