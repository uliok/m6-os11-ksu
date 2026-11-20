# KSU kprobe 暴露面评估与「去探针」方案

设备：BVL-AN16 / MagicOS 11 / `6.1.157-android14-11-g84ffa64b710b`
样本：`dist/ko-44077754661/.../kernelsu_finasu163av2sp7_os11sp7.ko`（726,472 B）
日期：2026-11-20

---

## 0. 结论先说

1. **kprobe 本身对普通 App 不是可枚举的暴露面。** 唯一的枚举口是
   `/sys/kernel/debug/kprobes/list`：`0400 root`，而且要 debugfs 挂载。App 域既没权限也没挂载点。
   `kprobe_events` 也不会列出 `register_kprobe()` 注册的探针（那是 tracefs 自己的事）。
2. **真正的暴露面是这 14 个探针里「跑在热路径上的那 6 个」。** 这台机器的内核
   `CONFIG_FUNCTION_TRACER is not set`，kprobe 走的是 **BRK 型**（不是 ftrace 型）：
   每次命中都是一次异常陷入。`vfs_statx` / `do_faccessat` 是全系统每次 stat/access 都过的点，
   等于给整机加了一层全局开销——这既能量出时延，也是实打实的性能损耗。
3. **模块痕迹只剩 `/proc/modules`。** `core/init.c:273` 的 `kobject_del()` 已经把
   `/sys/module/kernelsu` 摘掉了（前提：`CONFIG_KSU_DEBUG` 关闭）。`/proc/modules` 还在，
   但 App 域通常读不到（脚本里验证）；本机 `/proc/kallsyms` 连 shell 都 denied。
4. **要「清零探针」，这台机器上有现成可行的一条路**：把 syscall 钩子改成
   `sys_call_table` 指针替换，用 FinaSU 自带的 `ksu_patch_text()`
   （`feature/netisolate.c:580` 已经这么干了，`hook/arm64/patch_memory.c:176` 是原语）。
   这条路不写 text、不建 `struct kprobe`、`kprobes/list` 里一条都不会有。

一句话：**别去藏 kprobes/list（root-only，收益 0）；要减的是热路径探针，要换的是钩子后端。**

---

## 1. 为什么这台机器上 kprobe 特别「贵」

| 配置 | 值 | 含义 |
| --- | --- | --- |
| `CONFIG_KPROBES` | y | 可用 |
| `CONFIG_KPROBES_ON_FTRACE` | 未开 | **不是 ftrace 型** |
| `CONFIG_DYNAMIC_FTRACE` | 未开（只有 HAVE） | `register_ftrace_function` 不可用 |
| `CONFIG_FUNCTION_TRACER` | not set | 没有函数跟踪器 |
| `CONFIG_OPTPROBES` | 未开 | 没有 jump 优化 |
| `CONFIG_CFI_CLANG` | y | 换 syscall 表项时原型必须完全一致 |
| `CONFIG_ARM64_BTI_KERNEL` | not set | 内核自身不做 BTI 强制（inline hook 少一个坑） |

⇒ 每个探针 = 目标函数首指令被替换成 `BRK` + 一次异常 + notifier 链。
冷路径（execve、setresuid、reboot）无所谓；`vfs_statx` / `do_faccessat` 这种每秒几万次的点，
代价和可测性都完全不同。

---

## 2. 本套 ko 的探针清点（14 个）

来源：`patch/apply_sc_inject.py` + `finasu-src/kernel`，并已用 shipped ko 的字符串交叉核对。

| # | symbol | 触发频率 | 作用 | 建议 |
| --- | --- | --- | --- | --- |
| 1 | `__arm64_sys_reboot` | 冷（管理器 supercall） | 装 `[ksu_driver]` fd | 保留 |
| 2 | `input_event` | 开机后每次按键/触摸，`boot_completed` 自动注销 | 音量下键进安全模式 | 不用安全模式就编掉 |
| 3 | `slow_avc_audit` | 每次 AVC 拒绝 | avc_spoof（SELinux 审计伪装） | 改成按需注册 |
| 4 | `__arm64_sys_setresuid` | 每次 setuid 系（zygote 每 spawn 一个 App 一次） | 给管理器塞 fd，**管理器「已安装」全靠它** | **不能去** |
| 5 | `do_execveat_common` | 每次 exec | 把 `/system/bin/su` 改写成 ksud 路径 | 可去（改 syscall 表） |
| 6 | `__arm64_sys_execve` | 每次 exec | **纯诊断日志**（`ksu-dbg ENTRY`） | **直接删** |
| 7 | `begin_new_exec` | 每次 exec | 改 `bprm->cred` 换身份 | 可去（override_creds 已覆盖，需 A/B） |
| 8 | `exec_binprm` | 每次 exec | `begin_new_exec` 被内联时的兜底 | 验证有命中后删一个 |
| 9 | `__arm64_sys_faccessat` | 每次 access | 隐藏 su 文件 | 保留（sucompat 开时） |
| 10 | `__arm64_sys_faccessat2` | 每次 access | 同上 | 保留（sucompat 开时） |
| 11 | `__arm64_sys_newfstatat` | 每次 stat | 同上 | 保留（sucompat 开时） |
| 12 | `__arm64_sys_statx` | 每次 statx | 同上 | 保留（sucompat 开时） |
| 13 | `do_faccessat` | **全系统每次 access** | VFS 层兜底 | **删** |
| 14 | `vfs_statx` | **全系统每次 stat** | VFS 层兜底 | **删** |

另有两个 kretprobe（`syscall_regfunc` / `syscall_unregfunc`），只在 dispatcher 装得上时才注册；
本机 `ksu_syscall_hook_manager_init()` 早退（`-ENOENT`），**实际不存在**。

裁剪后的稳态：

- sucompat 关：`reboot` + `setresuid`（+ avc 开时 `slow_avc_audit`）= **2～3 个**
- sucompat 开：再加 7 个 exec/stat 探针 = **9～10 个**
- 方案 B 全换表项后：syscall 类 **0 个**，只剩 `slow_avc_audit`（可选）

---

## 3. 谁能看到什么

| 面向 | 普通 App | shell | root | 说明 |
| --- | --- | --- | --- | --- |
| `/sys/kernel/debug/kprobes/list` | ✗ | ✗ | ✓（若 debugfs 挂载） | 唯一枚举口，0400 |
| `kprobe_events` | 空 | 空 | 空 | KSU 用 `register_kprobe`，不写 tracefs |
| `/proc/modules` | 多数 ROM ✗ | ✓ | ✓ | 模块名 `kernelsu`，`kobject_del` 管不到它 |
| `/sys/module/kernelsu` | ✗ | ✗ | ✗ | 已被 `kobject_del()` 摘掉（非 DEBUG 构建） |
| `/proc/kallsyms` | 多数 ✗ | 本机 ✗ | ✓ | 模块符号带 `[kernelsu]` |
| stat/access 时延 | **可测** | 可测 | 可测 | BRK 型探针，热路径尤其明显 |
| access/stat/execve 行为一致性 | **可测** | 可测 | 可测 | 探针改写路径时最容易出破绽 |

真正会被检测 App 抓到的，是最后两行（行为 + 时延），不是「有没有 kprobe」。
所以「把 kprobes/list 藏起来」这件事没有意义——它本来就是 root-only。

> 待真机确认：`/proc/modules` 对 `untrusted_app` 到底可不可读（AOSP 默认是 denied，
> 但各家 ROM 会改）。`scripts/ksu-surface-scan.sh` 会给出 shell 侧结果；
> App 侧要在检测 App 里跑同一组 `access()`，或看 `dmesg | grep avc`。

---

## 4. 方案 A：立刻减面（不动钩子后端，风险最低）

预期：14 → 11；sucompat 关时降到 3。改完要重启 ko 验证。

### A1. 删两个热路径兜底（`ksu_su_check_kps[]` 末尾两项）

```c
 static struct kprobe ksu_su_check_kps[] = {
     {.symbol_name = "__arm64_sys_faccessat",  .pre_handler = ksu_su_check_pre},
     {.symbol_name = "__arm64_sys_faccessat2", .pre_handler = ksu_su_check_pre},
     {.symbol_name = "__arm64_sys_newfstatat",  .pre_handler = ksu_su_check_pre},
     {.symbol_name = "__arm64_sys_statx",      .pre_handler = ksu_su_check_pre},
-    /* 兜底：万一 bionic 的入口不叫 __arm64_sys_*，这两个是 VFS 层必经点 */
-    {.symbol_name = "do_faccessat",           .pre_handler = ksu_su_check_pre},
-    {.symbol_name = "vfs_statx",              .pre_handler = ksu_su_check_pre},
 };
```

理由：Android 上 bionic 的 `access/stat` 一定走上面的 `__arm64_sys_*` 入口；
VFS 层兜底只对「内核内部自己调 vfs_statx」有意义，而隐藏 su 是给用户态 App 看的。

### A2. 删诊断探针

`ksu_exec_entry_kp`（`__arm64_sys_execve`）只打印 `ksu-dbg ENTRY`，没有功能。
连 `ksu_exec_entry_pre` / `ksu_exec_entry_kp` / 注册调用一起删。

### A3. `exec_binprm` 改成条件注册

先看 `ksu-dbg` 日志确认 `begin_new_exec` 有命中；有命中就删 `ksu_bprm_exec_kp`。
若担心被内联，保留它也无妨——exec 是冷路径，一个探针的代价可以忽略。

### A4. sucompat 关闭时真的注销（而不是 handler 里 return 0）

现在 `ksu_sp_sucompat_on=false` 只是让 handler 早退，探针还在，热路径照样进异常。
改成开关驱动注册/注销，注销走 workqueue（`unregister_kprobe` 要睡眠上下文）：

```c
static DEFINE_MUTEX(ksu_sp_hook_lock);
static bool ksu_sp_su_hooks_on;

static struct kprobe *ksu_sp_su_hook_set[] = {
    &ksu_su_exec_kp, &ksu_bprm_begin_kp, &ksu_bprm_exec_kp,
    &ksu_su_check_kps[0], &ksu_su_check_kps[1],
    &ksu_su_check_kps[2], &ksu_su_check_kps[3],
};

static void ksu_sp_su_hooks_apply(bool on)
{
    int i;
    mutex_lock(&ksu_sp_hook_lock);
    if (on && !ksu_sp_su_hooks_on) {
        for (i = 0; i < ARRAY_SIZE(ksu_sp_su_hook_set); i++)
            register_kprobe(ksu_sp_su_hook_set[i]);
        ksu_sp_su_hooks_on = true;
    } else if (!on && ksu_sp_su_hooks_on) {
        for (i = 0; i < ARRAY_SIZE(ksu_sp_su_hook_set); i++)
            unregister_kprobe(ksu_sp_su_hook_set[i]);
        ksu_sp_su_hooks_on = false;
    }
    mutex_unlock(&ksu_sp_hook_lock);
}

static void ksu_sp_su_hooks_work_fn(struct work_struct *w)
{
    ksu_sp_su_hooks_apply(ksu_sp_sucompat_on);
}
static DECLARE_WORK(ksu_sp_su_hooks_work, ksu_sp_su_hooks_work_fn);

/* feature set handler 里 */
ksu_sp_sucompat_on = !!value;
schedule_work(&ksu_sp_su_hooks_work);
```

`ksu_sp_hooks_init()` 里只无条件注册 `setresuid`；su 那一组走
`ksu_sp_su_hooks_apply(ksu_sp_sucompat_on)`，并把 `ksu_sp_su_hooks_on` 初始化为对应状态。

### A5. `slow_avc_audit` 改成按需

`ksu_avc_spoof_init()` 现在无条件 `register_kprobe`。把注册挪到
`avc_spoof_set(1)`、注销挪到 `avc_spoof_set(0)`，init 里只注册 feature handler。
它只在 AVC 拒绝时触发，收益不大，但顺手。

---

## 5. 方案 B：把 syscall 钩子全部换成 `sys_call_table` 指针替换（推荐）

**为什么可行**：`feature/netisolate.c:580` 已经在用同一条路：

```c
static int ni_patch(const struct ni_hook *hook, syscall_fn_t replacement)
{
    return ksu_patch_text(&hook->table[hook->nr], &replacement,
                          sizeof(replacement), KSU_PATCH_TEXT_FLUSH_DCACHE);
}
```

`ksu_patch_text()`（`hook/arm64/patch_memory.c:176`）用 `phys_from_virt()` 拿物理地址 +
`stop_machine` 写，绕开 RO 映射。之前 dispatcher 失败是因为走 `set_memory_rw`/fixmap，
不是这条路。设备上 netisolate 能工作，就说明这条路在这台机器上通。

### 要换的表项

| nr | 原函数 | 替换成 | 备注 |
| --- | --- | --- | --- |
| `__NR_setresuid` | `__arm64_sys_setresuid` | `ksu_sp_sys_setresuid` | 保留 fd 安装语义 |
| `__NR_execve` | `__arm64_sys_execve` | `ksu_sp_sys_execve` | 改路径 + `override_creds` |
| `__NR_newfstatat` | `__arm64_sys_newfstatat` | `ksu_sp_sys_newfstatat` | 隐藏 su |
| `__NR_faccessat` | `__arm64_sys_faccessat` | `ksu_sp_sys_faccessat` | 隐藏 su |
| `__NR_faccessat2` | `__arm64_sys_faccessat2` | `ksu_sp_sys_faccessat2` | API 30+ |
| `__NR_statx` | `__arm64_sys_statx` | `ksu_sp_sys_statx` | 隐藏 su |
| `__NR_reboot` | `__arm64_sys_reboot` | `ksu_sp_sys_reboot` | supercall（可选，保留 kprobe 也行） |

### 骨架

```c
typedef long (*ksu_syscall_fn_t)(const struct pt_regs *);
static ksu_syscall_fn_t *ksu_sp_sys_call_table;
static ksu_syscall_fn_t ksu_sp_orig_setresuid, ksu_sp_orig_execve, /* ... */;

static int ksu_sp_patch_syscall(int nr, ksu_syscall_fn_t fn, ksu_syscall_fn_t *orig)
{
    *orig = READ_ONCE(ksu_sp_sys_call_table[nr]);
    return ksu_patch_text(&ksu_sp_sys_call_table[nr], &fn, sizeof(fn),
                          KSU_PATCH_TEXT_FLUSH_DCACHE);
}

static long ksu_sp_sys_setresuid(const struct pt_regs *regs)
{
    ksu_handle_setresuid((uid_t)regs->regs[0], (uid_t)regs->regs[1], (uid_t)regs->regs[2]);
    return ksu_sp_orig_setresuid(regs);
}
```

解析表地址：

```c
ksu_sp_sys_call_table = ksu_resolve_symbol_for_functable_hook("sys_call_table");
```

### 三个必须注意的点

1. **KCFI**（`CONFIG_CFI_CLANG=y`）：替换函数原型必须严格是
   `long (const struct pt_regs *)`，否则间接调用时 typeid 校验直接 trap。
   netisolate 的 `ni_native_replacements` 就是活样板。
2. **调用约定**：表项里拿到的是内核 `pt_regs *`，不是 kprobe 那种「wrapper 的 regs[0] 再解一层」。
   现有 `ksu_hook_setresuid/execve/faccessat` 的写法可以直接搬（它们本来就是给 dispatcher 写的）。
3. **exec 换 cred 的逻辑要重排**：现在靠 `begin_new_exec` 改 `bprm->cred`。
   换成 execve 表项后，在调用原函数前 `override_creds(ksu_cred)`、失败返回后 `revert_creds`；
   execve 成功不会返回，新程序直接继承 root cred。
   **这一步必须在真机上 A/B**：如果 override_creds 不够，再保留一个 `begin_new_exec` 探针（冷路径，可接受）。

### 收益

- `/sys/kernel/debug/kprobes/list` 里 KSU 条目 **0**。
- 不写任何 text，只有 `.rodata` 里的 8 字节指针，`stop_machine` 保证原子。
- 热路径不再进异常，stat/access 的时延回到基线。

---

## 6. 方案 C：inline hook（不推荐，除非要做 KPM）

`ksu_patch_text` 能写 text（`selinux_hide` 用它改过函数指针槽），技术上能实现入口跳板。
但这台机器 `CONFIG_ARM64_BTI_KERNEL` 没开、`CFI_CLANG` 开着，要处理：

- 首指令可能是 `bti c` / `paciasp`，覆盖后间接调用（syscall 表是 `blr`）会踩 BTI/CFI；
- 跳板要还原被覆盖的指令、处理 PC 相对寻址；
- 每次热路径 stat 多一次跳转，仍然有可测开销。

同样的效果，方案 B 更简单、更稳。除非目标是做「不依赖 syscall 表」的 KPM，否则不建议。

---

## 7. 不建议做的

| 做法 | 为什么不做 |
| --- | --- |
| hook `kprobe_seq_show` 隐藏 list | 本身又是一层 hook；而且 list 是 0400 root，App 根本看不到 |
| `list_del(&THIS_MODULE->list)` 摘模块链表 | `rmmod`/引用计数/`module_refcount` 会崩 |
| 改 `THIS_MODULE->name` | `/proc/modules` 名字变了，但 kallsyms 的 `[kernelsu]` 标签、管理器匹配、vermagic 都可能受影响 |
| 关 `CONFIG_KALLSYMS` | 改内核配置要重编整机，且大量驱动依赖 |
| 全局 `echo 0 > kprobes/enabled` | 只有 root 能写；而且会让自己的钩子一起失效 |

---

## 8. 验收

1. 改前/改后各跑一次：
   ```sh
   adb push scripts/ksu-surface-scan.sh /data/local/tmp/
   adb shell sh /data/local/tmp/ksu-surface-scan.sh
   adb shell su -c 'sh /data/local/tmp/ksu-surface-scan.sh' > after-root.txt
   ```
   关键看：`kprobes/list` 条数、`grep` 到的符号名、`/proc/modules` 行、`/sys/module/kernelsu`。
2. 时延 A/B（同一台机、飞行模式、固定频率）：
   ```c
   // 10 万次 fstatat("/system/bin/su") 的平均 ns
   clock_gettime(CLOCK_MONOTONIC, &t0);
   for (i = 0; i < 100000; i++) syscall(__NR_newfstatat, AT_FDCWD, path, &st, 0);
   clock_gettime(CLOCK_MONOTONIC, &t1);
   ```
   方案 A 删掉 `vfs_statx` 后应有可见下降；方案 B 后回到无钩子基线。
3. 功能回归：
   - 管理器首页「已安装 / 工作中」
   - `su -c id` → `uid=0 context=u:r:ksu:s0`
   - 关掉 sucompat 后：App 里 `su` 不可用，但管理器通道正常
   - `stat/access("/system/bin/su")` 对普通 App 仍返回 ENOENT

---

## 9. 下一步

- [ ] 真机跑 `scripts/ksu-surface-scan.sh`，把 `/proc/modules`、`kallsyms`、debugfs 的可读性钉死
- [ ] 方案 A 先落地（改动小，可回滚），验证 su 全链路
- [ ] 方案 B 单独一支分支做 A/B，先只换 `setresuid`，再换 exec/stat
- [ ] 把 `begin_new_exec` 是否可去用日志证实后再删
