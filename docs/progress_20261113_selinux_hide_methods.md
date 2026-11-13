# 2026-11-13 SELinux 隐藏方案调研（Magic6 Pro / MagicOS 11 / 6.1.157-g84ffa64b710b）

## 0. 结论

**有更好的方法，而且不一定要再碰内核镜像页。**

- 现成可用：**SUSFS `avc_spoof`**（kprobe `slow_avc_audit`，同时替换 ssid/tsid），只解决 AVC 日志。
- 已验证可行的新方向：**LKM + kprobe 拦 selinuxfs 函数**，不改 fops 指针、不写内核镜像，失败可 unregister。
- 已写好但没上过机的：**9.1「出厂策略真相源 + PTE 翻只读位」版 selinux_hide**（CI run 43368289046 正在编）。
- 当前 ko 里的上游 `selinux_hide` 用 `ksu_patch_text` 改 `context_write/access_write/sel_open_handle_status` 的 fops 指针，在本机镜像保护下无效（历史已证，见 `progress_20261105_selinux_hide_blocked.md`）。

## 1. 现在暴露什么（检测面）

| 面 | 现状 | 谁能看到 |
|---|---|---|
| `/sys/fs/selinux/context` / `access` | 对 `u:r:ksu:s0`、`u:object_r:ksu_file:s0` 返回 allowed | app_zygote / 检测器（DirtySepolicy、春秋） |
| `/sys/fs/selinux/status` | 策略注入后 `sequence` / `policyload` 非 0 | 同上，判「策略被换过」 |
| `/sys/fs/selinux/policy` | 含 KSU 注入的类型 | 同上 |
| `/sys/fs/selinux/enforce` | 真实值；开火窗口期是 0 | 轮询型检测器能抓到 Permissive 窗口 |
| dmesg AVC | `scontext=u:r:ksu:s0` 的 deny 行 | 有 dmesg/日志通道的检测器 |
| `/proc/modules` | `kernelsu` 可见（SUSFS 只隐藏自己） | shell / 有读取权限的进程 |
| `/sys/module/kernelsu` | 存在 | 同上 |
| mounts | SUSFS 隐藏自己的挂载；KSU 的 su 路径挂载未隐藏 | 同上 |
| `/sys/kernel/debug/kprobes/list` | 若 debugfs 挂载且可读，能看到 kprobe | root / 部分 shell（本机通常 root-only） |

## 2. 方案对比

| 方案 | 覆盖 | 原理 | 风险/代价 | 状态 |
|---|---|---|---|---|
| A. 上游 KSU `selinux_hide` | context/access/status | `ksu_patch_text` 改 selinuxfs fops 指针 | 本机镜像页保护 → 写入静默失败 | **无效** |
| B. 9.1 真相源 + PTE 路径 | context/access/status/policy | PTE 翻 AP[2] 只读位 → 写 fops；类型名按出厂策略判定 | 需验证 PTE 是否真能写；误写镜像页有 panic 风险 | **✅ 真机已验证**（run 43368289046） |
| C. LKM + kprobe 拦 selinuxfs | context/access/status/enforce/policy/AVC | kprobe 挂在 `sel_write_context` / `sel_write_access` / `sel_read_enforce` / `sel_read_policy` / `sel_open_handle_status`，pre_handler 判定/改写返回值 | 不碰镜像页；开发量中等；kprobe list 对 root 可见 | **推荐兜底/长期** |
| D. SUSFS `avc_spoof` | AVC 日志 | kprobe `slow_avc_audit`，同时换 ssid/tsid | 覆盖最全，但 **sid 在模块 init 时解析**；我们的套件是 SUSFS 先于 KSU 加载，那时 `u:r:ksu:s0` 不存在 → 永远开不起来（除非改懒解析或改成 KSU 后再加载） | 需改造 |
| E. KSU `avc_spoof` | AVC（仅 tsid） | kprobe `slow_avc_audit`，只换 tsid | late-load 路径里默认自动启用（已可用），但漏 `scontext=ksu` 的行；可在 `avc_spoof.c` 里补 ssid | **默认可能已在跑** |
| F. 类型改名 | 策略字符串 | 改 ksud/注入策略里的 `ksu`、`ksu_file` 名字 | 不解决 sequence/status；动 ksud 有风险 | 补充 |
| G. Zygisk / LSPosed hook | 单 App | 用户态 hook `SELinux`/`File` | 依赖环境、易被绕过 | 最后手段 |

## 3. 关键新认识

1. `CONFIG_KPROBES=y`，且 SUSFS 已经成功 `register_kprobe("slow_avc_audit")`——**kprobe 在这颗内核上是可用的**。
2. 之前 `tracectl` 失败是因为 tracefs/ftrace 被关（`available_tracers=nop`、无 `ftrace_enabled`），不是 kprobe 不可用。
3. 所以 selinuxfs 的三个 fops **不必改指针**：直接 kprobe 对应函数，在 pre_handler 里：
   - `sel_write_context`：读用户 buffer，类型名不在出厂策略里 → `regs[0] = -EINVAL`，返回 1 跳过原函数；
   - `sel_write_access`：读 scon/tcon/tclass，任一类型不在出厂策略 → `-EINVAL`；
   - `sel_read_enforce`：`*ppos == 0` 时拷 `"1\n"`，返回 2；
   - `sel_open_handle_status`：kretprobe 后把 `file->private_data` 指向的 status 页改成 seq=0/policyload=0/enforcing=1；
   - `sel_read_policy`：按 ppos 从出厂策略 blob 拷给用户；
   - `slow_avc_audit`：ssid/tsid 替换（SUSFS 已做）。

这样完全避开 PTE 写入和镜像页保护，失败最多是 hook 不生效，可以 unregister 回滚，不会 panic。

## 3.5 参考实现：kprobe 重定向（xring-CVE-2026-98260-OS4.0 / ksufd.c）

`ChaYeWuu/xring-CVE-2026-98260-OS4.0` 的 `native/ksufd.c` 是同一思路的现成实现，关键点：

1. 在 `ksu_patch_text()` 入口挂 kprobe，拦截 KSU 对 `write_op[]` / `sel_handle_status_ops->open` 的写：
   记录 `dst`（槽地址）、`orig`（槽里原函数）、`ksu_fn`（KSU 的替换函数），然后**假装写成功**（返回 0）。
2. 在 `orig`（真正的 `.text` 函数，如 `sel_write_context`）入口挂 kprobe，命中时把 `pc` 改成
   `ksu_fn`（或我们的 wrapper），并带 owner 防重入——不写任何只读槽。
3. 额外挂 `selinux_setprocattr` + KSU 的 `my_setprocattr`：app uid 写 `u:r:ksu:s0` 到
   `/proc/self/attr/current` 时直接返回 `-EINVAL`，盖住「类型是否存在」的 13/22 侧信道。
4. 开关状态跟随 KSU 对 setprocattr 槽的那次 patch：开/关时同步 arm/disarm。

这套代码是针对 6.18.21 / 另一颗内核写的，不能直接加载；但**结构可以照搬**到我们的
`selinux_hide.c`：把 `ksu_ro_write(context_write, …)` / `ksu_ro_write(access_write, …)` /
`ksu_ro_write(status_slot, …)` 换成「kprobe 挂在 `*slot` 上 + PC 重定向到 `my_write_*`」，
其余 truth-source 逻辑不动。


## 4. 推荐路线

**第 1 步（零风险，先确认现状）**
- KSU 自带 `avc_spoof` 在 **late-load 路径**里会由 `ksu_avc_spoof_late_init()` 自动启用（默认 `ksu_avc_spoof_enabled=true`），
  注册 `slow_avc_audit` kprobe，**只替换 tsid**。先看 dmesg 有没有
  `avc_spoof: su SID: … ksu SID: … priv_app SID: …` 和 `slow_avc_audit spoofing enabled`。
- 要覆盖 `scontext=u:r:ksu:s0` 的 deny 行，需要在 `avc_spoof.c` 的 pre_handler 里同时替换 **ssid**
  （6.4+ 是 `PT_REGS_PARM1`），或用 SUSFS 的版本。
- SUSFS 的 `avc_spoof` **不能靠“晚点写 1”解决**：它在 `susfs_avc_spoof_init()` 里就解析 sid，
  SUSFS 先于 KSU 加载时 sids=0，之后 `avc_register()` 会直接拒绝。要用它只能：
  (a) 改 SUSFS 源码把 sid 解析挪到 enable 时；(b) 改成 KSU 之后再加载 SUSFS。

**第 2 步（验证 9.1）**
- CI run 43368289046 构建 `sukisu430r2seh`（SukiSU 4.3.0-r2 + `selinux_patch=true`）。
- 真机加载后 `ksud feature set selinux_hide 1`，看 dmesg 是否出现
  `selinux_hide: pte-path ... got=0x... want=0x...`（got==want 才算写进去）。
- 跑 DirtySepolicy / 春秋，和不装模块的基线逐条对比。
- 如果 PTE 真能写 → 直接用 B，不需要新 LKM。

**第 3 步（PTE 失败时）**
- 做 C：以 SUSFS 的 kprobe helper + 9.1 的 truth-source 代码为骨架，先实现
  context/access/status/enforce 四个点，policy 读随后。
- 控制节点 `/proc/selinux_hide`，支持 0/1 开关和 `hide_off` 急救文件。

**第 4 步（补充）**
- `ksu` / `ksu_file` 类型改名（F），减少策略字符串暴露。
- SUSFS `hide_modules` 或 kprobe 把 `kernelsu` 从 `/proc/modules` 隐藏（如果检测器会看）。
- kprobe list 清理：debugfs 通常 root-only，优先级低。

## 5. 验证口径

1. **基线**：不装 ko，跑 DirtySepolicy / 春秋，记录输出（尤其 status 的 `sequence=` / `policyload=`）。
2. **装链后**：输出与基线逐条一致，只允许差「USB 调试已开启」这类与 SELinux 无关的项。
3. **系统健康**：`app_zygote` 不崩（`logcat -b crash` 无 SIGABRT）、App 能起、`getenforce=Enforcing`。
4. **窗口期**：在 exploit 的 Permissive 窗口里，用轮询脚本读 `/sys/fs/selinux/enforce`，应始终读到 1（需要 enforce hook）。
5. **AVC**：`dmesg | grep avc` 不应出现 `scontext=u:r:ksu:s0` / `tcontext=u:r:ksu:s0`。

## 6. 风险与注意

- 9.1 的 PTE 路径会写内核镜像页：如果保护在 EL2，可能静默失败或 panic，先在测试 ko 上验证，不要直接进主线。
- kprobe pre_handler 在原子上下文：不能睡，读用户 buffer 用 `copy_from_user_nofault` / `strncpy_from_user_nofault`。
- `/sys/fs/selinux/enforce` 的 fake 对所有 app 生效；值固定 1，与真实 Enforcing 一致，正常 app 无感，但 Permissive 窗口里会「说谎」。
- 出厂策略 blob（`/vendor/etc/selinux/precompiled_sepolicy`，2.17 MB）常驻 vmalloc，可接受。
- 类型名匹配要用「裸 ASCII + 前后非名字字符」的边界判断，避免 `frameworkutils` 里的 `ksu` 子串误判（9.1 已处理）。

## 7. 真机验收（2026-11-13 18:10，BVL-AN16）

**ko**：`run 43368289046` 产物 `kernelsu_sukisu430r2seh_os11.ko`（730,040 B，md5 `dc62f05f4fb0cf463fe4888e67ee7fbd`），
SukiSU 4.3.0-r2 + `selinux_patch=true`（truth-source + PTE）。

**加载日志（dmesg）**

```
selinux_hide: stock policy /vendor/etc/selinux/precompiled_sepolicy loaded 2173795 bytes
fops /sys/fs/selinux/context: inode=... orig_fop=... ours=...
fops /sys/fs/selinux/access:  inode=... orig_fop=... ours=...
fops /sys/fs/selinux/policy:  orig=... ours=...
fops /sys/fs/selinux/status:  orig=... ours=... page=...
kretprobe selinux_setprocattr OK
fops do ctx=0 acc=0 stock=0 status=0 state=1
DIRECTSTORE status_open slot=... now=...
```

`ctx/acc/stock/status = 0` 表示四处 PTE 写入全部成功；`kretprobe selinux_setprocattr OK` 是额外补的
`attr/current` 面。

**ctxprobe（setuid 10278，模拟检测器 uid）**

```
context 'u:r:ksu:s0'            -> -1 errno=22 (EINVAL)
context 'u:object_r:ksu_file:s0'-> -1 errno=22 (EINVAL)
context 'u:r:magisk:s0'         -> -1 errno=22 (EINVAL)
context 'u:r:shell:s0'          -> 12 (ok)
context 'u:object_r:system_file:s0' -> 25 (ok)
access  'u:r:ksu:s0 u:r:ksu:s0 2'   -> -1 errno=22
access  'u:r:shell:s0 u:r:su:s0 2'  -> 24 (ok)
attr/current 'u:r:ksu:s0'       -> -1 errno=22
status: version=1 sequence=0 enforcing=1 policyload=0 deny_unknown=1
policy first 64KB: ksu-substr=0
```

**低 uid 对照（uid=0）**：`u:r:ksu:s0` / `ksu_file` 正常成功，`magisk` EINVAL —— 系统调用者看到真实结果。

**DirtySepolicy 2.2**（LSPosed 官方 release）：

```
OK: no dirty sepolicy found
INFO: sequence=0 policyload=0
```

没有 `WARNING: found Magisk / found KernelSU / found LSPosed`，`app_zygote` 未崩（无 SIGABRT），
说明「出厂策略真相源」没有误杀系统域。

**当前设备状态**：KSU `kernelsu 577536 0 - Live (E)`、SELinux `Enforcing`、SUSFS LKM 在、
`/system_ext/bin/su` 可用；App 升到 `9.39-selhide`（vc121），管理器 SukiSU v4.3.0-r2（ko 41150），
Shizuku 由 Stellar 提供（api 13）。

**注意**：`selinux_hide` 是 KSU 特性（id=4），默认关闭。本机是之前实验留下的
`/data/adb/ksu/.feature_config` 已置 1，所以 insmod 时直接生效。换新机/清数据后需要：
`/system_ext/bin/su -c '/data/adb/ksud feature set selinux_hide 1'`
（或管理器里打开 SELinux Hide），再验证一次。


## 8. 后续

- **覆盖范围**：原版 `tiann/KernelSU` 没有集成 SUSFS，不给它编这套；只覆盖四家 fork：
  - SukiSU 4.3.0-r2：✅ 已验收（run `43368289046`）
  - FinaSU v1.6.1：run `43408767740`（构建中）
  - KernelSU-Next v3.4.2：run `43408780920`（构建中）
  - BakaSU v4.2.0-rc3：run `43409733978`（构建中；补丁已兼容它的 `write_op` 强转与无 status-unhook）
- **隐藏式 su 入口默认关闭**：`/system_ext/bin/su` 的 tmpfs 覆盖会多一个可见文件/挂载点，降低隐藏性；
  `PREF_SU_ENTRY` 默认 `false`（`prefs.getBoolean(..., false)`），文案已标注「会降低隐藏性」。
  关掉它不影响本机的 SELinux 隐藏（ko 在 init/forced 配置阶段就把 selinuxfs 的 fops 换好了）。
- **selinux_hide 的开启**：本机是 `.feature_config` 已置 1（之前实验留下的），insmod 时直接生效；
  新机/清数据后由管理器里的 SELinux Hide 开关打开，或 su 入口开启时由 App 验收阶段自动执行
  `/data/adb/ksu/bin/ksud feature set selinux_hide 1`。
- **AVC ssid**：KSU `avc_spoof` 只换 tsid；在 `avc_spoof.c` 的 pre_handler 里补 ssid
  （6.4+ 是 `PT_REGS_PARM1`），或在 SUSFS `susfs_avc_spoof.c` 里把 sid 解析挪到 enable 时。
- **kprobe 重定向版**（C）留作兜底：如果以后换到 PTE 写不进去的内核，按 `ksufd.c` 的结构
  把 `ksu_ro_write(...)` 换成「kprobe 挂在 `*slot` 上 + PC 重定向」。
- **回归口径**：每次换内核/换 ko 都跑一遍 ctxprobe（app uid + uid 0 两组）和 DirtySepolicy，
  以 `OK: no dirty sepolicy found` + `sequence=0 policyload=0` 为准。

