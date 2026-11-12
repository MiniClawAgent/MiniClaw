# MiniClaw 当前状态（单一事实源）

> **判断项目「现在是什么样」只看这一份文件。**
> 上次全面核对：2026-11-12（代码基线 HEAD `250bad0`，工作区状态见 §8）。
> 与代码冲突时**以代码为准**，并回来修正本文件。

---

## 1 产品定位

MiniClaw 是一款**本地优先的 iOS 通用智能体应用**（不是编程助手）。它把以下能力装进一个 App：

- 大模型接入：3 个适配器覆盖 OpenAI 兼容族（8 家）/ Anthropic / Gemini，支持 OAuth、思考档位、前缀缓存优化
- 内置 Linux：iSH 移植（AArch64 guest + Asbestos 解释器，无需 JIT），给 Agent 一个真 shell
- 工具：41 个 `AgentTool`（文件、浏览器、子代理、记忆、MCP、Apple 系统能力、联网搜索等）
- 会话渲染：UICollectionView 自绘布局 + TextKit1 + cmark-gfm + SwiftMath 的流式渲染管线
- 扩展：Widget（含灵动岛/锁屏）、ShareExtension、AppIntents、深链

已上架 App Store（v1.0，实装 build 见 §3）。

---

## 2 仓库与产物布局

工作区根：`/Users/neartop/MiniClowDevelopment`

| 路径 | 性质 | 说明 |
|---|---|---|
| `MiniClaw/` | **git 仓库** | Xcode 工程根 |
| `MiniClaw/MiniClaw/` | 源码树 A | App 主体，253 个 Swift / 约 8.8 万行；另有 iSH 桥 ObjC 约 600 行 |
| `MiniClaw/MiniClawKit/` | 源码树 B | `KitLogger` + `SwiftMathRenderer`，被 embed 的 framework（2 文件 / 298 行） |
| `Kit/` | 第三方源码 | SwiftMath + swift-cmark，`project.yml` 以 `../Kit` 引用，**不在 git 内** |
| `第三方源码/` | 第三方源码 | `ish-arm64`（真身）、`ios-agent-ref`（列表/高度上游参考） |
| `MiniClaw/docs/` | 文档 | 唯一文档入口，见 `docs/README.md` |
| `.workbuddy/memory/` | 团队记忆 | 每日工作日志与长期笔记（非源码） |

> ⚠️ 全库检索必须**两棵源码树都查**。仓库根曾有一个只剩空 `Sync` 的 `Services/`，已确认为历史残留（2026-11-12 起不再视为源码）。

---

## 3 版本与 target

| 项 | 值 |
|---|---|
| 版本 | `MARKETING_VERSION = 1.0`，`CURRENT_PROJECT_VERSION = 12` |
| 唯一真相源 | `project.yml` 与入库 `project.pbxproj` 的工程级 Debug/Release **两处都要改**（pbxproj 才是构建权威） |
| Bundle ID | `com.neartop.miniclaw.app` |
| Team | `LZ84D5PQ38` |
| 5 个 target | `MiniClaw`(app) / `MiniClawKit`(framework) / `MiniClawWidget` / `ShareExtension` / `MiniClawTests` |
| 扩展版本 | 三份 Info.plist 均填 `$(CURRENT_PROJECT_VERSION)` / `$(MARKETING_VERSION)`，靠工程级设置继承 |

---

## 4 启动链路（顺序有意为之，不可随意调整）

`MiniClawApp.init()` 中每一步都有依赖原因；在 `init`/属性初始化里做可能 throw 的 IO 会导致 App 打不开（纪律 P1 / 禁止事项 3）：

1. `AppState.shared = appState`
2. `SessionManager.shared.load()`
3. `_ = FileSystemManager.shared`（建运行时目录 + 同步内置资源）
4. `AppLogger.shared.installCrashHandlers()`
5. `MetricKitCollector.shared.start()`
6. `CrashReporter.shared.checkAbnormalExit()`
7. `LinuxShellRuntime.prewarmBootInBackground()`
8. `SubagentStore.load()` → `SubagentRuntimeRegistry.rebuild()`
9. 快照 `skillEnabledStates` → 后台 `syncBundledResourcesInBackground()` → `SubAgentProfileStore.reload`
10. `SyncBootstrap.setup()`（只注册，不启动；`iCloudEnabled` 默认 false）
11. `BackgroundScheduler.registerAndSchedule()`

> 刻意不做：启动期请求麦克风权限（真机曾因 TCC 回调不在主队列导致 AVAudioSession 断言崩溃）。

---

## 5 子系统地图（改什么先看哪）

| 想改什么 | 入口 |
|---|---|
| Agent 循环 / 停止条件 / 重试 / 检查点 | `Services/AgentLoopEngine.swift`（2692 行） |
| 工具协议 / 排序 / 路由 | `Services/ToolProtocol.swift`、`AgentRunService.buildToolRouter` |
| 提示词分段 / 缓存断点 | `Services/AgentRunService+SystemPrompt.swift`、`AgentPromptCore.swift` |
| 模型适配器 / 端点 / 思考档位 | `Services/Providers/`、`Models/ProviderModels.swift` |
| 记忆写入 / 复盘 / 整理 | `Services/MemoryManager.swift`、`SessionReviewService.swift`、`MemoryConsolidator.swift` |
| 技能 / 插件 / 内置工具声明 | `Services/SkillManager.swift`、`ToolPluginManager.swift`、`Resources/BundledPlugins/` |
| MCP | `Services/MCPClient.swift`、`MCPConfigStore.swift`、`MCPOAuthManager.swift`、`RemoteMCPTool.swift` |
| 联网搜索（DeepSeek Search API） | `Tools/WebSearchTool.swift`；内置工厂在 `ToolPluginManager.swift`，包声明在 `Resources/BundledPlugins/com.miniclaw.builtin.tools.mpk` |
| 列表高度 / 滚动 / 冻结 | `Views/Chat/List/MessageListLayout.swift`、`MessageCollectionCoordinator+{Snapshot,Scrolling,Heights}.swift` |
| Markdown / 公式 / 附件渲染 | `Views/Chat/Render/MarkdownView.swift` → `MarkdownTextView.swift` |
| 容器 / 会话文件隔离 | `Services/LinuxShellRuntime.swift`、`SessionFileRouter.swift`、`Services/iSH/MiniClawiSH.m` |
| 构建 / 工程文件 | `project.yml`（定义）、`MiniClaw.xcodeproj/project.pbxproj`（权威） |

---

## 6 关键不变量（改错会出连锁问题）

**缓存前缀**
- 工具 schema 必须按工具名排序；随角色变化的工具排最后。
- 稳定段最前且所有子代理逐字节一致；易变段只允许追加，禁止插入。
- 请求体编码一律 `.sortedKeys`。
- 易变段落盘在 `ChatMessage.apiContextSuffix` 并逐字回放（2026-09-15 根因整改，取代旧的「拼在消息末尾」方案）；发送侧与历史回放侧都必须走 `apiContent`。

**Agent 循环**
- 提示注入（空转 warn / 检索收敛）必须晚于**全部** tool 结果落盘，否则打断 `assistant(tool_calls) → tool` 紧邻关系，端点 400。
- 权威循环上下文是 `AgentTask.messages`，不能从会话历史重建（tool 配对会丢）。
- 检查点三重守卫：`!isSubagentEngine && sessionID != nil && keepRunning()`；子代理引擎不写检查点。
- UI 回调唯一出口 `deliverOnMain`：一律 `main.async`，不 `main.sync`，不做主线程短路。

**渲染与高度**
- 高度单一写入口 `HeightEntry.setEntry`，优先级 `measured > precalc > estimated`，低不覆盖高。
- `currentEntry` 内容版本键不一致即视为无条目（上滑裁尾的治本点）。
- 三个唯一出入口：`seedHeights` / `invalidateHeight`+`remapHeights` / `applyDeferredHeights`+`takePendingAboveShift`。
- 三根正交轴不可合并：几何冻结 `deferSelfSizing` ∥ 数据冻结 `streamingUIUpdatesSuspended` ∥ offset 静默窗。
- 引擎下限 `engineFloor = engineTextHeight + 4`，不得含 cell 当前高度。

**持久化与并发**
- 启动期不得同步打开可能损坏的存储；`save/insert` 禁止裸 `try?`。
- 后台线程读 `SettingsStore` 一律先 `MainActor.run` 快照，禁止裸读（真机 EXC_BAD_ACCESS 教训）。
- 锁内只读写，回调一律锁外。

---

## 7 构建与验证

**首选 Xcode MCP**（工程操作、构建、日志、调试、设备交互一律优先走 MCP；与 Xcode 状态同源，且不受 CLI 沙箱干扰）：

```
XcodeOpenWorkspace → XcodeSwitchRunDestination(真机/Any iOS Device) → BuildProject
```

**CLI 回退（唯一版本，见 `ENGINEERING_DISCIPLINE.md` §2.1）**：

```bash
cd /Users/neartop/MiniClowDevelopment/MiniClaw && \
CLANG_MODULE_CACHE_PATH=/Users/neartop/.miniclaw-build/modulecache \
SWIFT_MODULECACHE_PATH=/Users/neartop/.miniclaw-build/modulecache \
MODULE_CACHE_DIR=/Users/neartop/.miniclaw-build/modulecache \
xcodebuild build -project MiniClaw.xcodeproj -scheme MiniClaw \
  -destination 'generic/platform=iOS' -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  OTHER_SWIFT_FLAGS="-Xfrontend -disable-sandbox" \
  -derivedDataPath /Users/neartop/.miniclaw-build
```

硬约束：
- **禁止跑 `xcodegen generate`**（pbxproj 是权威；重生成会吃掉 `DEBUG`，64 处 `#if DEBUG` 静默消失）。
- 派生目录固定 `/Users/neartop/.miniclaw-build`，增量构建，不清不换（清缓存先问）。
- 增删/移动源文件：Python 直改 pbxproj，删文件用 `XcodeRM`。
- 模拟器 destination 必然链接失败（iSH 静态库 device-only）。
- 改动 `#if DEBUG` 内符号的引用后必须验 Release（MCP 只驱动 Debug，这类错误在 MCP 通道里隐形）。

---

## 8 当前仓库状态（2026-11-12 核对）

| 项 | 状态 |
|---|---|
| HEAD | `250bad0`（2026-11-12，I-25/I-34/I-35 卫生修复） |
| 未推送 | **本地领先 `origin/main` 43 个提交**（缺推送凭据，按用户指示未 push） |
| 未跟踪 | 无 |
| 上架 | v1.0 已上架；审核整改（2.1 HomeKit / 2.5.1 HealthKit 标识）已随 build 12 提交 |
| 最近修复 | I-01 预热闸门挂死、I-02 工具超时竞速、I-04 executionTimeout 覆盖（均经 Xcode MCP 构建验证） |

---

## 9 文档与协作规矩

- 文档唯一入口：`docs/README.md`；当前问题只看 `docs/ISSUES.md`。
- 一次性报告完成后进 `docs/archive/` 并登记；**不新增并行的问题清单**。
- 每次代码修改后必须构建验证（`BUILD SUCCEEDED`）才能交付；构建产物在工程外。
- 修复遵守 S5「治本不补丁」：先问上游机制、消除重复事实，不接受「把常数改准」。
- 提交粒度一变量一提交，commit message 写清根因与验证方式。
