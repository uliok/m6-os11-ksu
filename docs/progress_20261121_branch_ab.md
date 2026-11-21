# 2026-11-21 分支 A/B：SELinux 策略被写坏的真正来源

## 现象

装载后**立刻**（不是几分钟后）出现：

```
avc: denied { find } for pid=5272 uid=10277 name=activity
  scontext=u:r:untrusted_app:s0 tcontext=u:object_r:activity_service:s0
  tclass=service_manager permissive=0
```

表现为 `dumpsys package` / `am start` 全是 `Can't find service`，管理器起不来，
所有 app fork 后立刻被 KILL。framework 本身没死（system_server 一直在），
是 **SELinux 策略重写后 app 的 `service_manager find` 被拒**。

## 已排除

| 变量 | 做法 | 结果 |
|---|---|---|
| 方案 B（sys_call_table 表项） | `sp_table=0`（`nob`，run 44770617647） | 仍然崩 |
| 1.6.4 的 first-match | `last_match=true`（`last`，run 44775809908） | 仍然崩 |
| 管理器启动时机 | 装载前 force-stop、装载后不启动 | 与崩不崩无关 |
| SELinux Hide 特性 | 基线那发 `selinux_hide` 本来就是关的 | 不是它 |

## 决定性对照

基线 `finasu163av2_os11` 是从 **`av-filter` @ 6d9f58cb** 编的；
`tbl` / `lean` / `nob` / `last` 全部来自 **`feat/syscall-table-setresuid`**。

用 **av-filter 原样补丁集 + FinaSU v1.6.4** 编一发（run 44780896516，`finasu164avf`）：

| 项 | avf（av-filter + 1.6.4） | nob/last（feat + 1.6.4） |
|---|---|---|
| 大小 | 726,472 B（与基线同尺寸） | 726,968 B |
| su-check 探针 | 6 | 2（方案 A） |
| execwrap 锚点 | `rc = register_kprobe(&ksu_sp_setresuid_kp)` 之后 | `rc2 = register_kprobe(&ksu_su_exec_kp)` 之后 |
| 方案 B 脚手架 | 无 | 有（`#if 0`） |
| 装载结果 | **正常**：kernelsu Live、Enforcing、`dumpsys package` 可用、管理器 v1.6.5 正常启动，7 分钟 0 条 `avc denied service_manager` | 立刻 `Can't find service` |

## 结论

写坏策略的是 **feat 分支上的补丁改动**，不是 1.6.4、不是 first-match、不是方案 B：

- 方案 A（su-check 6→2）
- `apply_su_execwrap.py` 的锚点/注册顺序改动
- 方案 B 的 `#if` 脚手架（虽然编译为 0，但改变了生成代码的结构与注册顺序）

三者之一（或组合）会让 `apply_kernelsu_rules` 之后的策略丢掉
`untrusted_app → activity_service:service_manager find`。下一步用一发
「feat + 6 探针」把方案 A 单独摘出来即可定位。

## 产物

| 文件 | 说明 |
|---|---|
| `kernelsu_finasu164avf_os11.ko` | 726,472 B / md5 `34b931bcba4da9baa115e7b864f5fe90`，run 44780896516 |
| 分支 | `av-filter`（不是 feat） |


---

## 追加：为什么「留 VFS 层、删 syscall 层」必崩

`ksu_su_check_pre` 的做法是把 `regs->regs[1]` 当 `char __user **`，命中时用
`ksu_su_push_path()` 塞一个**用户态指针**进去改写路径：

- **syscall 层**（`__arm64_sys_faccessat` 等）：`regs[1]` 本来就是用户态路径指针，改写正确；
- **VFS 层**（`vfs_statx` / `do_faccessat`）：`regs[1]` 已经是内核里的 `struct filename *`，
  再塞用户态指针进去 = 把内核结构体指到用户地址，一解引用就写坏策略/框架。

`feat` 的「方案 A」恰好删了 4 个 syscall 层、留下 2 个 VFS 层（`do_faccessat` + `vfs_statx`），
方向反了，所以一装就 `avc denied service_manager`。`av-filter` 原样（6 个全在）不会触发
这条错误改写，所以正常。

## 追加：0 探针版（test/noprobe）真机结果

做法：基于 `av-filter`，只把 6 个 `register_kprobe(&ksu_su_check_kps[_i])` 置空，
数组/handler 保留但不注册；`execve` / `do_execveat_common` / `setresuid` 不动。

真机（BVL-AN16 / os11）实测：

| 项 | 结果 |
|---|---|
| 模块 | `kernelsu 380928 1 - Live (E)`，Enforcing |
| 框架 | `dumpsys package` 可用、管理器 v1.6.5 正常启动，10 分钟 0 条 `avc denied service_manager` |
| `kprobes/list` | `faccessat/vfs_statx/newfstatat/statx` 命中 **0 条**；只剩 `__arm64_sys_execve`、`do_execveat_common`、`__arm64_sys_setresuid` |
| `ls -l /system/bin/su` | `No such file or directory`（按真实磁盘返回） |
| `env /system/bin/su -c id`（shell 发起） | `uid=0(root) ... context=u:r:ksu:s0` ✅ |

产物：

| 目标 | 文件 | md5 |
|---|---|---|
| os11 | `kernelsu_finasu164nop_os11.ko`（722,936 B） | `c1f04eaf0d46df1604485c5dd08c490f` |
| os11sp7 | `kernelsu_finasu164nopsp7_os11sp7.ko`（722,936 B） | `33442e37a8df8b58bba5642cc6714fc0` |

分支：`test/noprobe`（基于 `av-filter`）。SP7 那份尚未真机验证（等 g7db56fb8f741 的机器）。
