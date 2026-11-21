# M6Shell 项目交接 / 2026-11-19

给下一个会话继续用。先读这一份，不要重新推导。

## 1. 当前结论

- App：**M6Shell 9.45 / versionCode 136**，包名 `com.bvlansu.shell`，release 签名。
- 最终 APK：`C:\Users\阿斯顿\Desktop\M6Shell_归档_20261119\M6Shell-9.45.apk`
  - 大小 17,111,893 B
  - md5 `967de933ab0a9be54ebea86a43934d6e`
- 源码：`D:\githubs\ksu-app`（分支 `main`，HEAD `601fd6b`，**工作区有未提交改动**：9.45 深色模式、SUSFS、ko variants 等）。
- ko 构建仓：`D:\githubs\m6-os11-ksu`，远端 `uliok/m6-os11-ksu`，权威分支 `rel-150`。
- 当前设备：BVL-AN16 / ACPR024524000114 / MagicOS 10（Android 16）/ 内核 `6.1.157-android14-11-g84ffa64b710b`。
- 当前管理器：**FinaSU**（`me.yuki.fina`）；`kernelsu 385024 2 - Live (E)`；`getenforce=Enforcing`。
- root 是 **CVE-2026-98260 临时 root**；`adb root` 在 production build 上失败，`adb shell` 仍是 uid 2000；需要 root 命令时用管理器内的 root 终端 / aShellYou。

## 2. 目录与产物

| 路径 | 内容 |
|---|---|
| `D:\githubs\ksu-app` | M6Shell Android App（Kotlin/Compose，`com.bvlansu.shell`） |
| `D:\githubs\ksu-app\app\src\main\assets\variants\` | 各管理器的 `kernelsu*.ko` |
| `D:\githubs\ksu-app\dist\M6Shell-9.45.apk` | 9.45 发布 APK |
| `D:\githubs\ksu-app\docs\progress_20261113_susfs_lkm.md` | SUSFS LKM 接入、隐藏 su 入口、日志持久化 |
| `D:\githubs\m6-os11-ksu` | ko 构建 CI / SELinux wrapper / 设备内核适配 |
| `D:\githubs\m6-os11-ksu\docs\progress_20261117.md` | 春秋 SELinux 全量 access 过滤 |
| `D:\githubs\cve-2026-98260` | CVE 提权链（B2 / B 变体） |
| `D:\githubs\ksu-app\docs\HANDOFF_20261119.md` | 本文件 |
| `C:\Users\阿斯顿\Desktop\M6Shell_归档_20261119\` | 最终 APK、旧 APK、本交接文档 |
| `C:\Users\阿斯顿\Desktop\SUSFS_归档_20261119\` | SUSFS guard LKM 分析、规则核验 |

## 3. App 当前能力

- 支持管理器：SukiSU Nova、SukiSU、KernelSU、BakaSU、FinaSU、KernelSU-Next；`AndroidManifest.xml` 的 `<queries>` 和 `MANAGERS` / `KO_UAPI` 三张表必须同步。
- 原版 KernelSU 未集成 SUSFS：选中 `me.weishu.kernelsu` 时强制关闭 SUSFS 开关。
- 深色模式：**高级设置 → 外观**，三档 `跟随系统 / 浅色 / 深色`；存 `m6shell` 的 `theme_mode`；主界面、关于页、两个手写 Dialog 都适配，状态栏图标同步。
- SUSFS 开关：只在 KSU `load_ko` 前加载 `susfs_guard_lkm.bin`，**只加载 LKM，不下发规则**；失败不阻断 root；重启消失。
- 隐藏式 su 入口：默认关闭；用户明确说过“开启之后实际会导致隐藏性下降，默认关闭”。
- SELinux 全量过滤：`patch/selinux_hide_wrappers.inc` 用 `backup_sepolicy` 重算 `security_compute_av_user`；重挂 `context/access/policy/status`；`avdSeqNo` 单字符修正；DirtySepolicy 干净，春秋 SELinux 项已过。
- 关于页不展示“本套件自研部分”；只列上游。

## 4. 6.1 ko 现状

`D:\githubs\ksu-app\app\src\main\assets\variants` 当前：

| 管理器 | g84 | g7db | 默认 `kernelsu.ko` |
|---|---|---|---|
| SukiSU Nova | 743,800 / `93e1e89a...` | 743,800 / `81013d22...` | g84 |
| FinaSU | 726,472 / `9374b442...` | 726,472 / `a9eaf21e...` | g84 |
| KernelSU-Next | 614,808 / `6755a7f7...` | 614,808 / `7beb6fe7...` | g84 |
| SukiSU Ultra | 730,040（旧） | 730,040（旧） | 旧 |
| BakaSU | 564,256（旧） | 564,256（旧） | 旧 |
| KernelSU | 456,512（旧） | 456,512（旧） | 旧 |

前三个是 2026-11-17 的 av2 全量过滤构建；后三个还没按 av2 重编/替换。

## 5. 设备现场（2026-11-19）

- 当前管理器 FinaSU；App 9.45 已安装。
- M6Shell 自带 SUSFS guard LKM 已加载：
  - `/sys/module/susfs_guard_lkm` 存在
  - `kgo.31739.log`：`resolved 117/117`、`init_module(... params "expose_proc=1")`、`OK`、`proc_node=1`
  - `/data/local/tmp` 的隐藏规则已生效：root 的 `/proc/susfs_path` 里有 `path=/data/local/tmp ...`，`hide_from_apps=1`
- `deploy.log` 的 `SUSFS：sysfs=1 node=0` 是 adb shell 的视角，不是 LKM 没加载；root 才能读 `/proc/susfs_*`。
- 下载的 `SUSFS_guard_LKM_v2.6.0(9).zip` **没有安装**；它和 M6Shell 的 6.1 LKM 是同一个文件（md5 `777e3ba0...`）。
- FinaSU 的路径隐藏页保存了 `/data/local/tmp`；新增规则即时，修改/删除按页面提示处理；软重启不会卸载 LKM，需要重载参数时用完整重启。
- SUSFS 规则会把 `/data/local/tmp` 权限 relax 到 0777；`hide_from_apps=1` 只隐藏 App，shell/root 仍可见，正常。

### SUSFS 配置现状（2026-11-19 追加）

FinaSU 管理器里已保存并应用到本次启动：

- 路径隐藏：**`/data/adb`**、**`/data/local/tmp`**（2 条）
- 扩展 → 隐藏模块名称：**`kernelsu`**（内核已确认；`/proc/modules` 已看不到 `kernelsu`，但 `/sys/module/kernelsu` 仍在）
- 扩展 → 隐藏挂载前缀：**`/data/adb`**（内核已确认）
- 基础设置：隐藏 SUSFS 挂载 = **不管理**（开启会返回 `SUSFS returned error -2`，不要开）；SUSFS 日志 = **关闭**；AVC 伪装 = **关闭**；uname/cmdline = 不管理

影响：

- M6Shell 的 `grep kernelsu /proc/modules` 验收会失败，但 root 模块实际在 `/sys/module/kernelsu`，不是没加载；后续 App 应优先看 sysfs。
- `/data/adb` 的路径/挂载隐藏对 App 生效；shell/root 仍可访问，这是 `hide_from_apps=1` 的正常行为。
- `/data/local/tmp` 对 App 隐藏，但 shell 仍可见；M6Shell 的 `.w9` 由 shell 执行，不受影响。
- 未配置 maps / 文件重定向 / props 伪装；这些不是当前必需，避免误伤。

root 复核命令：

```sh
cat /proc/susfs_path
cat /proc/susfs_hide_modules
cat /proc/susfs_hide_mounts
cat /proc/susfs_enable_log
cat /proc/susfs_avc_spoof
```

### adb 端调用 root（2026-11-19 追加）

- `adb root` 不可用：`adbd cannot run as root in production builds`。
- `adb shell su -c 'id'` 直调会报 `su: inaccessible or not found`：这里的 `su` 是 KernelSU 的 **sucompat 伪文件**，mksh 查不到实体文件；不是 root 没生效。
- 已验证可用写法（PowerShell / Git Bash）：

```powershell
adb shell 'timeout 10 su -c "id"'
```

输出：

```text
uid=0(root) gid=0(root) groups=0(root) context=u:r:ksu:s0
```

- 交互 root shell：

```sh
adb shell
timeout 3600 su
```

- 读 root-only 文件 / 二进制：

```sh
adb exec-out 'timeout 10 su -c "cat /path/to/file"' > local.file
```

- 写 root-only 路径：

```sh
adb push local.file /data/local/tmp/local.file
adb shell 'timeout 10 su -c "cp /data/local/tmp/local.file /data/adb/target"'
```

- `su98260` 是 CVE 提权窗口期的临时工具，KSU 加载后运行会报 `connect root daemon: Permission denied`，不要拿它当 adb root。
- 第一次执行可能被 FinaSU 拦截，需要在手机上的「超级用户」里允许 `Shell` / `com.android.shell`；当前设备已允许，所以上面命令直接回 root。

### SUSFS 实际值（root 复核）

FinaSU UI 的路径/日志写入与 LKM 实际值不完全同步；用 `adb shell 'timeout 10 su -c "..."'` 直写 `/proc` 后，当前实际为：

```text
/proc/susfs_path:  /data/adb, /data/local/tmp；hide_from_apps=1
/proc/susfs_hide_modules: susfs_guard_lkm, kernelsu
/proc/susfs_hide_mounts: /data/adb/
/proc/susfs_enable_log: 0
/proc/susfs_avc_spoof: 0
```

`/data/adb` 与 `/data/local/tmp` 的路径规则、`kernelsu` 模块隐藏、`/data/adb/` 挂载隐藏现在都以内核 `/proc` 实际值为准；FinaSU UI 只作为配置入口，不要只信 UI 的“已保存”。

## 6. 已完成 / 已验证

- 9.44 → av2 全量 SELinux access filter；DirtySepolicy OK；春秋 Native check-Eros v4.6.3 的 SELinux 项消失（只剩 USB/风险应用/TEE）。
- 9.45 深色模式：主界面、状态卡、运行日志、高级设置、提权路线、关于页都已适配；已截图验证。
- 桌面 APK 整理：旧 9.44/9.45-dark 在 `M6Shell_归档_20261119\旧版APK`，最终 9.45 在归档目录。
- `m6-os11-ksu` 远端 `rel-150` 已包含：
  - `358d098` merge 全量 access 过滤
  - `96e2e2a` progress_20261117
  - `03829fc` progress_20261119（SUSFS guard LKM 分析 / `/data/local/tmp` 核验）

## 7. 未完成 / 下次优先

1. **FinaSU / KernelSU-Next / SP7 真机复测**：目前只有 Nova g84 的 av2 结果；FinaSU 现在在跑，Next 与 g7db 变体还没逐台确认。
2. **SUSFS 规则层**：M6Shell 只加载 LKM，不会自动下发隐藏规则；现在 `/data/local/tmp` 是 FinaSU 写的。若要让 M6Shell 自带隐藏，需要把规则应用纳入 `susfs_load.sh`/新脚本，不要误以为开关=完整隐藏。
3. **`ksu-app` 未提交**：工作区有 9.45 深色模式、SUSFS、ko variants 改动；旧远端 `knowlily/m6-shell` 可能不可用，下一窗口确认要不要迁到新账号/新仓库再提交。
4. **SUSFS guard LKM v2.6.0 第三方模块**：未安装；6.1 分支是按 `6.1.166-dirty` 编的，目标是 `6.1.157`；`susfs_insmod` 不签名，`CONFIG_MODULE_SIG_FORCE=y`，不要在没有恢复路径时装。
5. **临时 root**：完整重启后要重新走 CVE/一键提权；`post-fs-data` 不会自动跑，临时 root 场景用 `oneshot`/一键。

## 8. 常用命令

```powershell
# 构建 App
cd D:\githubs\ksu-app
$env:GRADLE_USER_HOME='D:/gradle-home'
.\gradlew assembleRelease --no-daemon
# 输出：app\build\outputs\apk\release\app-release.apk

# 安装/确认
adb install -r D:\githubs\ksu-app\dist\M6Shell-9.45.apk
adb shell dumpsys package com.bvlansu.shell | findstr versionName
```

```bash
# ko CI（示例，参数按现有 workflow 的 inputs 调整）
gh workflow run build-ko-os11.yml -R uliok/m6-os11-ksu --ref rel-150 \
  -f target=os11 -f ksu_repo=SukiSU-Nova/SukiSU-Nova -f ksu_ref=v3.0.0 \
  -f ko_alias=... -f ksu_version=30000 -f mgr_pkg=com.sukisu.nova \
  -f hook_mode=manual -F selinux_patch=true -F no_modversions=true -F ksu_debug=true
```

## 9. 安全/保密

- `release.jks`、`keystore.properties`、签名口令 **不要**写进文档、不要推到任何远端。
- GitHub token 只用 `gh auth token`，不要落盘/复述。
- 不刷 boot、不改系统镜像、不解 BL；全部是内存态，重启恢复。
- 下一窗口如果要动 root/内核参数，先读 `honor-kernelsu-on-demand-root` 和 `m6-os11-ksu/docs/progress_20261104*.md`，不要凭记忆改 CVE 参数。

## 10. 相关归档

- SUSFS 分析：`C:\Users\阿斯顿\Desktop\SUSFS_归档_20261119\README.md`
- Obsidian：`Android逆向/SUSFS_guard_LKM_v2.6.0_分析.md`
- Obsidian：`Android逆向/M6Shell_项目交接_20261119.md`
- 代码仓远端：`https://github.com/uliok/m6-os11-ksu`，`rel-150`
