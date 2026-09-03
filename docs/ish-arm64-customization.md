# iSH (arm64) 第三方依赖重建手册

> 2026-09-03 建立。起因：项目整理时 `第三方源码/ish-arm64` 实体丢失（symlink 指向已删除的
> Desktop 路径），iSH 静态库、rootfs 与 MiniClaw 的 `sessionFsContext` 定制全部不可达，
> 工程无法编译。本文档是**仓库内唯一真相源**，第三方目录不在 git 管理范围内。

## 一、源码来源

- **真身仓库：`https://github.com/OpenMinis/ish-arm64`（master 分支）**
- ⚠️ 不是 `jiangdi0924/ish-arm64`（它的精简 fork，master 里**没有** `ISHShellExecutor`，
  README 提到但文件不存在）。OpenMinis 是其上游（PR #1 from OpenMinis/feature-arm64）。
- 必需文件：`app/ISHShellExecutor.h/.m`、`app/DebugServer.c/.h`、`vdso/arm64/`、
  `kernel/`、`fs/`、`emu/`、`asbestos/`、`tools/`、`meson.build`、`meson_options.txt`

## 二、下载（本机代理阻断 git 协议，走 codeload）

```sh
curl -L -o ish.tar.gz \
  https://codeload.github.com/OpenMinis/ish-arm64/tar.gz/refs/heads/master
tar xzf ish.tar.gz
# 解压出 ish-arm64-master/ → 放到 ../第三方源码/ish-arm64（相对 MiniClaw 仓库根）
```

## 三、编译静态库（meson 交叉编译）

工具链：Xcode 自带 clang + `brew install meson ninja`（libarchive/sqlite3 本机已有）。

cross file 已存档于本目录 **`ios-arm64-cross.txt`**，复制到 `第三方源码/` 下使用：

```sh
cd 第三方源码/ish-arm64
meson setup build-arm64-ios --cross-file ../ios-arm64-cross.txt \
  -Dguest_arch=arm64 -Dengine=asbestos -Dlog_handler=dprintf
ninja -C build-arm64-ios
```

- 产物：`build-arm64-ios/libish.a`（约 1.9M）、`libish_emu.a`（880K）、`libfakefs.a`（52K），
  全 arm64；`cpu-offsets.h` 自动生成。全程约 3 秒。
- meson 选项 ↔ `project.yml` 宏一一对应：
  `-Dguest_arch=arm64`→`GUEST_ARM64=1`；`-Dengine=asbestos`（默认）→`ENGINE_ASBESTOS=1`；
  `-Dlog_handler=dprintf`（默认）→`LOG_HANDLER_DPRINTF=1`。
- ⚠️ **`tools/fakefsify` 在交叉编译下必然失败**（host 工具被按 iOS 目标链接，撞 macOS 版
  libarchive）——三个 .a 不受影响。需要 fakefsify 时另开 native build：

```sh
meson setup build-host -Dguest_arch=arm64 && ninja -C build-host tools/fakefsify
```

## 四、生成 rootfs

```sh
./build-host/tools/fakefsify ~/alpine-minirootfs-3.24.0-aarch64.tar.gz rootfs
```

产出 `rootfs/{data/, meta.db, meta.db-shm, meta.db-wal}`（约 10MB），与
`MiniClawiSH.h` 注释「contains `data/` and `meta.db`」一致。

## 五、应用 MiniClaw 定制（sessionFsContext）

上游 `ISHShellExecutor` 从未有 `sessionFsContext`（该文件在 OpenMinis 仓库只有 2 次提交，
2026-05-16）。MiniClaw 的会话文件隔离依赖它 —— **patch 已存档于本目录
`ish-arm64-customization.patch`**：

```sh
cd 第三方源码/ish-arm64
patch -p1 < ../../MiniClaw/docs/ish-arm64-customization.patch
```

定制内容：
1. `executeCommand:environment:lineCallback:completion:sessionFsContext:` 与
   `executeExecutable:...sessionFsContext:` 两个新方法（旧方法保留转发，向后兼容）。
2. `do_execve` 前注入 chdir：fsContext≠0 → 调 Swift 桥接 `miniclaw_session_guest_root`
   （`SessionFileRouter.swift` 的 `@_cdecl` 导出，链接期解析）取会话根
   `/var/MiniClaw/sessions/<uuid>` → 内联 open_dir 逻辑（`open_dir` 是 fs.c 的
   **static** 函数，外部不可调）→ `fs_chdir(task->fs, dir)`。失败仅记日志，回退默认 cwd。
3. includes 增补：`kernel/fs.h`（MAX_PATH/generic_open/generic_statat/O_RDONLY_）、
   `fs/path.h`（AT_PWD）、`misc.h`（IS_ERR）。

语义源（工程内，勿动）：`MiniClaw/Services/SessionFileRouter.swift` 三个 `@_cdecl`：
`miniclaw_session_resolve_host_path` / `miniclaw_session_reverse_host_path` /
`miniclaw_session_guest_root`。

## 六、验证

```sh
cd <仓库根 MiniClaw/>
xcodebuild -scheme MiniClaw -project MiniClaw.xcodeproj \
  -destination 'generic/platform=iOS' -configuration Debug \
  CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS="-Xfrontend -disable-sandbox" build
```

（iSH 静态库是 device 架构，模拟器 destination 必然链接失败，属环境限制；
Swift 宏沙箱问题需 `-disable-sandbox`，仅本地验证用，勿写进 project.yml。）

## 七、检查清单（重建后逐项打勾）

- [ ] `../第三方源码/ish-arm64/build-arm64-ios/libish.a` 存在且 `lipo -info` 为 arm64
- [ ] `libish_emu.a`、`libfakefs.a` 同上
- [ ] `build-arm64-ios/cpu-offsets.h` 已生成
- [ ] `rootfs/data/` + `rootfs/meta.db` 存在
- [ ] `nm libish.a | grep "T _fakefs_bind_mount"` 与 `T _fakefs_set_path_reverse_hook` 有输出
- [ ] patch 已应用（`grep sessionFsContext app/ISHShellExecutor.h` 有输出）
- [ ] device build BUILD SUCCEEDED
