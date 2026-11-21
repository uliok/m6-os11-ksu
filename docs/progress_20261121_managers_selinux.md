# 三管理器 × 两内核档位：原版 / 去探针 ko 与 SELinux 隐藏补齐（2026-11-21）

## 背景

提权 App 下一版要支持「三家管理器 × 两套内核 ko」：

- 管理器：FinaSU、SukiSU Nova（原 SukiSU Ultra 改名）、KernelSU-Next
- 内核档位：`os11` = `6.1.157-android14-11-g84ffa64b710b`（本机 BVL-AN16）；`os11sp7` = `6.1.157-android14-11-g7db56fb8f741`（magic6pro）
- 每家两套 ko：**原版**（保留 6 个 stat/access su 探针）与 **去探针**（6 个探针不注册，`su` 直执仍可提权）

## 管理器矩阵

| 管理器 | 包名 | 版本 | uapi | 内核源码 |
|---|---|---|---|---|
| SukiSU Nova | `com.sukisu.nova` | v3.0.0（vc 35000） | 6 | `SukiSU-Nova/SukiSU-Nova` v3.0.0 |
| FinaSU | `me.yuki.fina` | v1.6.5（vc 33213） | 6 | `LyraVoid/FinaSU` v1.6.5 |
| KernelSU-Next | `com.rifsxd.ksunext` | v3.4.2（vc 33355） | 5 | `KernelSU-Next/KernelSU-Next` v3.4.2 |

设备上的 APK 与桌面两份 APK md5 一致（Nova `4fdeee3e…`、FinaSU `6619114a…`）。

## ko 产物

原版取自 `av-filter`，去探针取自 `test/noprobe`；构建参数统一 `hook_mode=manual`、`ksu_debug=true`、`ksu_version` 对齐管理器 vc。

| 管理器 | 变体 | 内核 | run | 大小 | md5 |
|---|---|---|---|---|---|
| FinaSU | 原版 | os11 | #47 44894873524 | 726,472 | `5f7dd5f914e2728508cca55ef9f788e6` |
| FinaSU | 原版 | os11sp7 | #48 44894881883 | 726,472 | `b8155725c03d2424ce81f4df2cbdcb88` |
| FinaSU | 去探针 | os11 | #41 44892735480 | 722,936 | `07526e1a0b44…` |
| FinaSU | 去探针 | os11sp7 | #42 44892743385 | 722,936 | `1521ec0dd2b3…` |
| SukiSU Nova | 原版 | os11 | #53 44899513268 | 743,800 | `bcf12495b9bbbe5f835c1ea60d7d0dde` |
| SukiSU Nova | 原版 | os11sp7 | #54 44899522145 | 743,800 | `3bb48b7ee6e74dc51768a59d28a10059` |
| SukiSU Nova | 去探针 | os11 | #55 44899531108 | 740,264 | `29bf62ebe09d0df627041dfbfee3d150` |
| SukiSU Nova | 去探针 | os11sp7 | #56 44899539989 | 740,264 | `7cb7eeca63f963f3b3fe85b0889a6a19` |
| KernelSU-Next | 原版 | os11/sp7 | 沿用旧件 | 614,808 | `6755a7f75dd1…` |
| KernelSU-Next | 去探针 | os11 | #57 44899552604 | 611,272 | `2e23fd1f3b9f03287497300da5929b2c` |
| KernelSU-Next | 去探针 | os11sp7 | #58 44899561647 | 611,272 | `ac7e50023cb302804655c0d9114c3d93` |

> KernelSU-Next 原版按用户要求保留旧件，不重编；#51/#52 两发已取消。

## SELinux 隐藏

三家管理器 APK 的 dex 都含 `selinux_hide`（每家 2 处），内核源码都带 `kernel/feature/selinux_hide.c`（`backup_sepolicy` / `security_compute_av` / `avc_has_perm` 全）。

关键差别在补丁：

- 上游实现用 `ksu_patch_text` 改数据（每家 6 处）。本机内核对数据段是空操作，所以必须打我们的三件套：
  - `apply_selinux_hide_backup_once.py`（backup_sepolicy 只抓一次）
  - `apply_selinux_hide_trace.py`（HOOKTRACE）
  - `apply_selinux_hide_direct_store.py`（direct-store + 自适应 wrapper，`ksu_patch_text` 归零）
- 本地对 Nova v3.0.0、Next v3.4.2 源码验证：
  - `patched: backup_sepolicy capture is now one-shot`
  - `patched hooks with HOOKTRACE`
  - `patched: direct-store + adaptive wrappers; ksu_patch_text left = 0`
  - 标记：`HOOKTRACE=4  DIRECTSTORE=8  ksu_patch_text=0`
- #43/#44、#45/#46、#49/#50 原为 `selinux_patch=false`（跳过了隐藏），已分别由 #55/#56、#57/#58、#53/#54 以 `selinux_patch=true` 重编补齐；FinaSU 一直带补丁。

## App 9.47（versionCode 138）

- 移除 `com.sukisu.ultra`（管理器列表、uapi 表、assets 变体；备份在 `ksu-app/_removed/`）
- 新增「去探针版 ko（实验）」开关，仅对 FinaSU / SukiSU Nova / KernelSU-Next 生效
- `Kernels.kt`：`noprobe=true` 时先找 `kernelsu-noprobe-<内核>.ko` / `kernelsu-noprobe.ko`，缺失自动退回原版
- assets 每家两套：`kernelsu-<内核>.ko`（原版）+ `kernelsu-noprobe-<内核>.ko`（去探针）
- 产物：`com.bvlansu.shell` 9.47 / 138，18,128,516 B，md5 `a0a198c5cd3f1a45660e4e0280e08dd3`，BVLANSU 签名

## 待办

- 真机装载：三家 × 原版/去探针逐个验证（`kprobes/list`、`su` 直执、`test -x /system/bin/su`、SELinux Hide 开关生效）
