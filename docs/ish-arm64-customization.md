# iSH (arm64) 第三方依赖重建手册

> 2026-09-03 建立。起因：项目整理时 `第三方源码/ish-arm64` 实体丢失（symlink 指向已删除的
> Desktop 路径），iSH 静态库、rootfs 与 MiniClaw 的 `sessionFsContext` 定制全部不可达，
> 工程无法编译。本文档是**仓库内唯一真相源**，第三方目录不在 git 管理范围内。

## 一、源码来源

- **真身仓库：`见 第三方源码/ish-arm64-来源.md（不入 git）`（master 分支）**
- ⚠️ 不是 `jiangdi0924/ish-arm64`（它的精简 fork，master 里**没有** `ISHShellExecutor`，
  README 提到但文件不存在）。该 fork 是其上游（PR #1 from 上游/feature-arm64）。
- 必需文件：`app/ISHShellExecutor.h/.m`、`app/DebugServer.c/.h`、`vdso/arm64/`、
  `kernel/`、`fs/`、`emu/`、`asbestos/`、`tools/`、`meson.build`、`meson_options.txt`

## 二、下载（本机代理阻断 git 协议，走 codeload）

```sh
curl -L -o ish.tar.gz \
  见 第三方源码/ish-arm64-来源.md（不入 git）
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

上游 `ISHShellExecutor` 从未有 `sessionFsContext`（该文件在 iSH 上游仓库只有 2 次提交，
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
4. [`fs/fake.c`] 变更通知队列的 label 改为中性标识 `com.neartop.miniclaw.ish.fakechange`。
   原 label 含第三方产品名，会作为**字符串字面量链进 App 二进制**（`strings` 可见）；
   dispatch queue 的 label 仅用于诊断（崩溃日志/调试器），改名无功能影响。
   改后须重建 `libish.a`：`cd 第三方源码/ish-arm64/build-arm64-ios && ninja libish.a`
   （注意：直接 `ninja` 会在 host 工具 `tools/fakefsify` 处失败——它把 macOS 版
   libarchive 链进 iOS target，属已知环境问题，与本改动无关；**只构建 `libish.a` 目标即可**）。

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

## 六、2026-09-17：去除第三方产品名残留（第二轮）

**起因**：复查时发现 App 二进制里仍带 `Library/MinisChat` 与裸 `minis` 两个字符串，
链自 `libish.a`（不是 MiniClaw 自己的源码——那里已由 2026-09-13 那轮清理干净）。

**定位**：全在 iSH 的 **debug 打印过滤条件**里（不影响功能）：

| 文件 | 内容 | 处置 |
|---|---|---|
| `fs/fake.c:1032` | `if (strstr(entry_path,"minis") \|\| strstr(entry_path,"Library/MinisChat")) fprintf(stderr, "fakefs_readdir: …")` | **整段删除**（debug 打印） |
| `fs/real.c:421,426` | 同型：`if (strstr(buf,"minis")) fprintf(stderr, "realfs_getpath: …")` | **两条删除** |

**同轮做的注释/示例中性化**（这些不进二进制，但同属"源码里的第三方产品名"）：
`fs/fake.c`（3 处）、`fs/real.c`（1 处）、`fs/fake.h`（1 处）、
`kernel/native_offload.c`（2 处）、`kernel/exec.c`（1 处）、
`tests/regress/{run.sh,README.md,regress_cp.sh}`（4 处示例路径）——
其中 `/var/minis` 改为本项目实际使用的 `/var/MiniClaw`（`ShellTool` 侧的路径铁律一致）。

**⚠️ 刻意保留（不是遗漏）**：`README.md` / `README_arm64.md` / `README_arm64_zh.md` 里
对上游 **OpenMinis** 的署名（GPLv3 fork 的身份与出处）。
**删掉上游署名不会降低"被指抄袭"的风险，反而更高**：本 iSH 是 GPLv3 作品，
许可证要求保留版权与许可声明；而"防指抄袭"最有效的做法是**准确署名**
（MiniClaw 的「鸣谢」页已把 iSH 列为依赖并写明 GPLv3）。

**重建与验证**：

```sh
cd 第三方源码/ish-arm64
ninja -C build-arm64-ios libish.a libish_emu.a libfakefs.a   # 约 4 秒
```

- 只重建 `libish.a`（我的改动只在 `fs/fake.c`、`fs/real.c`，均编入它）；
  `libfakefs.a` 由 `fs_fake-db/migrate/rebuild.c` 组成，**不含** `fs/fake.c` ⇒ ninja 报 "no work to do" 是正确的。
- ⚠️ 注意：整目录 `ninja -C build-arm64-ios` 会在 **`tools/fakefsify`** 上失败
  （把 Homebrew 的 **macOS** 版 `libarchive.a` 往 iOS 目标里链）——这是**构建 rootfs 镜像用的宿主工具**，
  与本 App 链接无关，属环境问题。故上面只构建三个静态库目标。
- 验证：三个库 `strings | grep -ci minis` 均为 **0**；重建 App 后
  `grep -ril openminis/MinisChat MiniClaw.app` = **0 个文件**。
