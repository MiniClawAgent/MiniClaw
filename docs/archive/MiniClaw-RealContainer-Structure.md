# MiniClaw 真机实际文件目录结构（实测）

> 数据源：通过 `xcrun devicectl device copy from` 从已配对的真机
> **「唐唐的iPhone 16Pro」(UDID `EA9FE04D-ABF4-5228-A66F-C0595C5C57C1`)**
> 上 App `com.neartop.miniclaw` 的沙盒容器直接拉取，**非代码推断**。
> 抓取时间：2026-07-22。

## 总占用
- `Documents/MiniClaw/`：**280 KB**
- `Library/Application Support/MiniClaw/`（iSH 容器）：**9.8 MB**

---

## A. `Documents/MiniClaw/`（App 主文件根 / Agent 文件系统根）

```
Documents/MiniClaw/
├── workspace/      0 文件     ★ Agent 唯一共享工作区（所有会话共用），shell 默认 cwd
├── attachments/    0 文件     用户附件（图片/音频/视频），Agent 文件工具可写
├── shared/         0 文件     跨会话 / 跨项目共享文件
├── offloads/       0 文件     大文件转存区
├── browser/        1 文件     内置浏览器运行数据（实测：downloaded_xxx 缓存文件）
├── config/         4 文件     配置落地：mounts.json / providers.json / settings.json / settings_audit.json
├── models/         1 文件     模型目录（实测文件名为 model_catalog.json）
├── memory/         2 文件     长期记忆：SOUL.md（人格）+ MEMORY.md（跨会话事实）
├── rules/          3 文件     项目规则：.bundled-rules-manifest.json / 00-rule-loading.md / GLOBAL.md
├── skills/         3 文件     技能包：.bundled-skills-manifest.json / code-reviewer/ / skill-creator/
├── mounts/         0 文件     外部挂载点（MountStore 逻辑映射，虚拟为 /var/MiniClaw/mounts/<name>）
├── runs/           0 文件     AgentTask 检查点：runs/<sessionID>.json（按会话 ID 命名，平铺）
├── queue/          0 文件     队列/草稿：queue/<sessionID>.json、<sessionID>.draft.json
└── logs/          37 文件     App 运行日志（实测含 MiniClow-2026-07-22.log + 若干 crash-*.log + .crashalive）
```

### 各目录实际用途（带实测证据）
| 目录 | 谁来用 / 怎么用 | 实测证据 |
|---|---|---|
| `workspace/` | Agent 的 `file_read`/`write`/`shell` 工具默认读写处；**所有会话共用同一份**，多会话相对路径会互相覆盖 | 空（本机尚未产生 Agent 文件） |
| `attachments/` | 聊天里发图片/录音/视频给 AI 时落盘 | 空 |
| `shared/` | 跨会话长期保留的共享文件 | 空 |
| `offloads/` | 大文件（模型权重、大附件）转存 | 空 |
| `browser/` | 内置浏览器缓存/数据 | `downloaded_7D70…4rdanhhplaaaaa` |
| `config/` | 设置页写入的供应商/模型/偏好/挂载配置 | `mounts.json` `providers.json` `settings.json` `settings_audit.json` |
| `models/` | 模型列表/能力缓存 | `model_catalog.json` |
| `memory/` | 记忆系统：SOUL=人格、MEMORY=跨会话事实（每日日志仅在写入时生成，故当前无每日文件） | `SOUL.md` `MEMORY.md` |
| `rules/` | 项目规则；`.bundled-rules-manifest.json` 标记内置规则（每次启动被覆盖） | `00-rule-loading.md` `GLOBAL.md` |
| `skills/` | 技能包；同上内置标记 | `code-reviewer/` `skill-creator/` |
| `mounts/` | `MountStore` 逻辑映射表（只给 Agent 文件工具看，**不**真挂进 iSH） | 空 |
| `runs/` `queue/` | 按 `<sessionID>.json` 命名的平铺文件（非按会话拆目录） | 空（暂无检查点） |
| `logs/` | `AppLogger` 运行/崩溃日志 | `MiniClow-2026-07-22.log` `crash-20260722-*.log` `.crashalive` |

> ⚠️ **与代码推断的差异**：
> 1. 实际多了一个 **`logs/`** 目录——它由 `AppLogger` 创建，不在 `FileSystemManager.createDirectoryStructure()` 的 13 个目录清单里。
> 2. `config/` 实测多了一个 **`mounts.json`**（MountStore 持久化），代码注释只提了 providers/settings/settings_audit 三个。
> 3. `models/` 实测文件名是 **`model_catalog.json`**，而非代码注释里的 `models_dev_cache.json`。
> 4. `memory/` 暂无每日 `YYYY-MM-DD.md`——每日日志是写入时才生成，当前设备尚未产生。

---

## B. `Library/Application Support/MiniClaw/`（iSH / Alpine 容器）

```
Library/Application Support/MiniClaw/
└── ish-rootfs/                      9.8 MB   ← 从 App bundle 部署而来的 iSH 容器
    ├── meta.db / meta.db-shm / meta.db-wal   iSH fakefs 元数据（mount 用）
    └── data/                        ← 容器内真正的 "/"，即 Alpine 系统盘
        ├── bin/ sbin/ lib/ usr/ etc/ var/ home/ root/ …（标准 Linux 根）
        └── etc/apk/
            ├── repositories   包管理源（实测：官方 Alpine CDN v3.21 main/community）
            ├── world          已安装包清单
            ├── arch          aarch64
            ├── keys/         Alpine 签名公钥
            └── protected_paths.d/
```

### 关键实测内容
- **Alpine 版本**：`data/etc/alpine-release` → `3.21.0` ✅
- **APK 软件源** `data/etc/apk/repositories`：
  ```
  https://dl-cdn.alpinelinux.org/alpine/v3.21/main
  https://dl-cdn.alpinelinux.org/alpine/v3.21/community
  ```
- **DNS** `data/etc/resolv.conf`：注入了 `nameserver 8.8.8.8` / `nameserver 1.1.1.1`（此前修复联网的那一处，已生效）✅

### ⚠️ 关于 `data/var/MiniClaw`
快照里 `var/MiniClaw` 是**空的**。这是预期行为：它是 `fakefs_bind_mount` 把宿主 `Documents/MiniClaw` **实时桥接**进容器的挂载点，**只在 iSH 内核 boot 运行期间存在**；App 被杀后挂载卸载，静态拷贝里就看不到内容。容器内程序访问 `/var/MiniClaw` 看到的就是上面 A 部分的那些目录。

---

## 如何复现本抓取
```bash
DEVICE=EA9FE04D-ABF4-5228-A66F-C0595C5C57C1   # 唐唐的iPhone 16Pro（本机已配对）
BID=com.neartop.miniclaw
xcrun devicectl device copy from --device $DEVICE \
  --domain-type appDataContainer --domain-identifier $BID \
  --source "Documents/MiniClaw" --destination /tmp/mc/Documents_MiniClaw
xcrun devicectl device copy from --device $DEVICE \
  --domain-type appDataContainer --domain-identifier $BID \
  --source "Library/Application Support/MiniClaw" --destination /tmp/mc/AppSupport_MiniClaw
```
