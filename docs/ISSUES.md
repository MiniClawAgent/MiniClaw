# MiniClaw 开放问题台账

> **唯一**的开放问题清单。修完一条把状态改成 `已关闭` 并补证据，不新增第二份清单。
> 证据优先写「文件:行号」，报告类证据写归档文件名。
> 详细机制与实测数据见 `流畅度优化报告-20260919.md`（下称「9-19 报告」，条目编号 A/B 系列沿用该报告）。
> 上次核对：2026-11-12（代码基线 HEAD `250bad0`；文档提交不改变代码行为）。

严重度口径：**P0** = 挂死 / 只能杀 App / 确定性崩溃；**P1** = 明确卡顿、崩溃窗口或数据完整性风险；**P2** = 有条件的性能/一致性/资源问题；**P3** = 卫生、文档、待实测。

---

## 1 P0（正确性，最优先）

**当前无开放 P0。** 最近关闭两项（证据见 §4）：

- **I-01** 子代理预热闸门 `enter()` 永久阻塞（`dispatch_subagent` 挂死、只能杀 App）
- **I-02** 工具超时竞速导致 `executeTool` 永不返回

> 同族残余已降级为 P2：部分工具内部仍有不可取消的 continuation（I-38），但引擎不再被它拖死。

---

## 2 P1（崩溃窗口 / 数据完整性 / 明确卡顿）

| ID | 问题 | 证据 | 状态 |
|---|---|---|---|
| I-03 | **检查点写在工具执行之前**：落盘内容可含 `assistant(tool_calls)` 而无对应 `tool` 回复；此时被杀，冷恢复会把非法序列发给端点，400 在重试策略里是 fatal | `Services/AgentLoopEngine.swift:1113-1135`（已亲核落盘点早于 `executeToolsConcurrently`） | 开放 |
| I-05 | `activeRequestTask` 无锁：主线程 `cancel()/pause()` 与 run Task 并发读写，流式中点停止有崩溃窗口 | `Services/AgentLoopEngine.swift:29,397-398,418-419,798` | 开放 |
| I-06 | `BackgroundTaskCoordinator`：`waitIfSuspended()` 单槽 continuation 无条件覆盖；token 无引用计数 ⇒ 多会话并行时一方 resume 丢失、`end()` 误结束他人后台任务 | `Services/Background/BackgroundTaskCoordinator.swift:70-80,104-137` | 开放 |
| I-07 | 停止路径主线程双重 `queue.sync` + SQLite 写：长会话点「停止」可卡一帧到数百 ms | `Services/AgentLoopEngine.swift:396` → `AgentTask.swift:114-118` → `Storage/SQLiteStore.swift:588` | 开放 |
| I-08 | **后台裸写非 `@MainActor` 的 `SettingsStore`**：`ConfigTool.execute` 在 `Task.detached` 执行，26 处直接写 `@Published settings`，与真机已记录的 `EXC_BAD_ACCESS` 同类 | `Tools/ConfigTool.swift:53,78,93,203,231,252-264,276,294`、`Services/SettingsStore.swift:20-24,35-38` | 开放 |
| I-09 | `ToolExecution`：`stateLock` 不护 `block.content`，后台锁内读、主线程锁外写 ⇒ 长输出工具偶发内存错误 | `Services/ToolExecution.swift:117-138`、`Views/Chat/List/RenderModels.swift:230-236` | 开放 |
| I-10 | 首页每行 body 同步 SQLite（`loadBlob` 的 `queue.sync`），代价随队列占用上不封顶 | `Views/Home/SessionRowView.swift:44,163-167` → `AgentTask.swift:224-233` | 开放 |
| I-11 | `persist` 每次无条件 `DELETE` 全表 + 逐条重插（写放大 ∝ 会话长度）；暂停/终态走 `sync` 双跳 | `Storage/SQLiteStore.swift:362-374,391-417`、`Services/SessionManager.swift:66-80` | 开放 |
| I-12 | 启动加载**所有会话所有消息**（含三个 BLOB 列）并常驻内存；真机 790/855 MB 现场与之一致 | `Storage/SQLiteStore.swift:464-469,485-489`、`SessionManager.swift:20` | 开放 |
| I-13 | 首页 `seedHeights(.all)` 在「身份未变早退」之前执行全表播种；`contentKey` 的全字素扫描也排在守卫前（触发源是 `$messages` sink ≈4Hz） | `MessageCollectionCoordinator+Snapshot.swift:305,361`、`+Heights.swift:291-319` | 开放 |
| I-14 | 流式主线程昂贵计算排在节流之前：Bridge 全量 sorted/convert/指纹（10Hz 付全价、4Hz 得结果）；Markdown prepare/hash 在早退之前 | `Views/Chat/Bridge/MiniClawChatBridge.swift:90,245,329`、`Render/MarkdownView.swift:729-741,791-793` | 开放 |
| I-15 | `MarkdownView.rendererCache` 无淘汰（按 messageId 只增不减，间接保活 8 个子缓存） | `Render/MarkdownView.swift:456,459,464`（已亲核 3 处仅读/写/声明） | 开放 |
| I-16 | `MemoryIndexer` 任一文件 mtime 变化即全量重切块 + 全量 embedding + 整包 JSON 原子写；embedding 失败不推进 mtime ⇒ 每次检索重发全量 | `Services/MemoryIndexer.swift:93-168,220-230` | 开放 |
| I-17 | 后台任务到期只 `setTaskCompleted(false)`，不取消紧随其后的 `Task`；删除 daily 文件早于写 `MEMORY.md`，强杀可能落在删除窗口 | `Services/Background/BackgroundScheduler.swift:68-77,86-94,194,274` | 开放 |
| I-18 | 请求体落盘调试块仍在线上（代码自注「定位完成后删除本块」） | `Services/Providers/OpenAIProviderAdapter.swift:158-183`（已亲核 `reqdump_` 写盘 :175） | 开放 |

---

## 3 P2 / P3

| ID | 问题 | 证据 | 状态 |
|---|---|---|---|
| I-19 | 首页冷启动先渲染「欢迎使用」空态再跳列表（`isLoadingSessions` 与 `SessionManager.load()` 无握手） | `Views/Home/HomeView.swift:24,157-168,299-301`（9-19 B33） | 开放 |
| I-20 | `_sharedMeasuredHeights` 进程级高度 memo 无容量上限（会话切换刻意保留） | `Views/Chat/List/MessageListLayout.swift:206,1169,1176,1184`（已亲核只有单键删与全清） | 开放 |
| I-21 | guest 侧会话前缀表 4 项、宿主 `sessionSubdirs` 5 项（缺 `subagent`，后者注释自称必须一致） | `Services/iSH/MiniClawiSH.m:229` vs `Services/SessionFileRouter.swift:28` | 开放 |
| I-22 | MCP 发现缓存 `invalidate(serverId:)` 只清 entries/disk，不清 `failures` ⇒ 改配置后 60s 内仍被负缓存跳过 | `Services/RemoteMCPTool.swift:152-156,18-19`（已亲核） | 开放 |
| I-23 | 死配置：`appendV1Suffix` / `imageEndpointMode` 可配置可落盘，但请求构造零消费点 | `Models/ProviderModels.swift:22,178-180`、`Tools/ConfigTool.swift:398-399`（已亲核全库无消费） | 开放 |
| I-24 | 死代码：`MountStore.resolveMountGuestPath`、`MiniClawEngineWebView`、`MiniClawCookieAudit.shared`、`BrowserDownloadCenter.agentReport` 均零调用 | 见各文件（已亲核：`resolveMountGuestPath` 仅定义+日志） | 开放 |
| I-26 | `MiniClawCLI` 仍按 SwiftData `@Model` 使用 `ChatSession/ChatMessage`，主 App 已迁 Codable + `MiniClaw-Sessions/<uuid>/` ⇒ 该 target 编不过也读不到数据 | `MiniClawCLI/SessionStore.swift:2,18,94-95`（已亲核） | 开放 |
| I-27 | `ResumePolicy` 仍是纯元数据（`resumePolicy(for:)` 零调用点）⇒ `memory_write` 声明的 `.requiresUserConfirmation` 不生效，真正门是默认关闭的 `confirmBeforeToolCall` | `Services/ToolProtocol.swift:223-224`、`Tools/MemoryTools.swift:8`（已亲核零调用） | 开放 |
| I-28 | 用户气泡「测量与渲染不同源」（渲染纯 SwiftUI Text，测量走 cmark/CT）；memo 键含 `text.hashValue`（每进程随机）⇒ 跨启动必 miss。另：`+Heights.swift:160-166` 注释自称「已改由 MarkdownSurface 渲染」与实现不符 | `Views/Chat/List/ChatMessageRow.swift:208`、`+Heights.swift:157,160-229`（已亲核键与渲染点） | 开放 |
| I-30 | 两套并行渲染/工具卡实现：主列表 `AssistantBlockView`+`ToolCapsuleView` ↔ 子代理页 `MessageBubbleView`+`ToolCallCardView`（修一处不自动同步） | `Views/Chat/`（9-19 报告亦记） | 开放 |
| I-31 | 新挂载实际默认可写，与文档「默认只读」相反 | `Services/MountStore.swift:115` vs `Models/MountPermissionModels.swift:14` | 开放 |
| I-32 | `ConfigTool` 的 defaults 域含健康/家庭读、写、控制总闸 ⇒ AI 可改能力开关（只受 `miniclawConfigWrite` 约束），与「AI 不能给自己授权」的设计目标冲突 | `Tools/ConfigTool.swift:264`、`Services/SettingsStore.swift:52` | 开放 |
| I-33 | rootfs 部署校验只有「存在 + size>0」，无哈希；中断拷贝可能被误判为已部署 | `Services/LinuxShellRuntime.swift:110-117` | 开放 |
| I-36 | 测试覆盖缺口：8 个测试文件，无 MCP / 记忆 / 插件 / iSH 行为测试 | `MiniClawTests/` | 开放 |
| I-37 | 浏览器 Cookie/登录态跨会话共享（`.default()` dataStore + 共享 processPool），会话隔离只在标签/URL 层 | `Services/Browser/MiniClawBrowserEngine.swift:310` | 已知设计现状 |
| I-38 | 工具侧不可取消 continuation 仍无自带超时兜底（HomeKit/Location/HealthKit/Maps/Speech）：引擎已不再被拖死，但超时后残留任务不释放 | `Tools/HomeKitTools.swift:102-105` 等同族；9-19 报告 §3.3 C1 | 开放 |
| I-39 | **`browser` 工具因 params 形状被模型写坏而必然失败**：`params` 在 schema 里无 properties，模型把 url 写到顶层且 params 给空串 ⇒ navigate 静默判缺参、零网络请求；失败时无任何日志 | `Tools/BrowserTool.swift`（schema / normalizedActionParams / 失败日志）；现场见 2026-11-14 设备会话库 | 已关闭 `05e0d7b` |

> 9-19 报告 §1.3 里还有一批 P2/P3（B6 工具卡整文件读、B11 参数流式 O(L²)、B14 主题读盘、B16 文件浏览器主线程 IO、B18 插件导入、B19 图片全解码、B21 终端逐行 hop、B22 子代理页、B23 快照频率、B24 常驻内存、B26 挂载镜像无上限、B27 SQLite pragma、B28 rendererCache、B29 下载、B34/B35 适配器、B37 子代理落盘、A9/A10 QoS、A11 prewarm 无退避、A12 索引、A13 挂载定时器、A14 插件扫描、A16 标题任务不可取消）已逐条复核过，**未重复抄进本表**；实施时按 9-19 报告编号查机制与改法。

---

## 4 已关闭（本次或近期核实，不再维护条目）

| 事项 | 关闭依据 |
|---|---|
| I-01 子代理预热闸门 `enter()` 永久阻塞 | `3e8f2b6`：新增 `ResumeOnceBox`/`withCancellableTimeout`，等待者登记 + 超时直接 resume + `relinquishLead` 显式放行；BuildProject 28.7s |
| I-02 工具超时竞速导致 `executeTool` 永不返回 | `0f0b70c`：去掉 `withTaskGroup` 竞速，超时先定稿再 `execTask.cancel()`；BuildProject 18.3s |
| I-04 `executionTimeout` 覆盖失效 | `81ad246`：`nil` 真正表示「引擎不设超时」，dispatch/shell 的覆盖接通；BuildProject 14.0s |
| I-25 关于页开源组件失实 | `fdd4e39`：改为真实依赖（iSH / swift-cmark / SwiftMath）并指向「鸣谢」 |
| I-35 App 内隐私政策日期过期 | `bb15e4b`：「最后更新」2026 年 7 月 → 9 月（正文 9-18 已补健康/家庭章节） |
| I-34 export-ipa.sh 派生目录偏离纪律 | `250bad0`：改用 `$HOME/.miniclaw-build`（可覆盖）+ 补 `-Xfrontend` |
| 工作区 55 个改动 + 5 个删除未落库 | 已全部提交；本次核对 `git status` 仅文档变更 |
| `planTimeline/snapToRoundBoundary/freezeRoundBoundary/registerCollectionViewForNavBarScrollEdge` 只在工作区 | 均已在 HEAD（`git grep` 命中） |
| 「volatile 段拼在消息流末尾」的旧缓存方案 | 已被 `cbe34dd` 推翻：易变段落盘进 `ChatMessage.apiContextSuffix` 并回放 |
| `thinkingLevels` 全库无写入点（旧报告 §11.2-③） | `14d5071`（09-16）已补：Decl 增加字段 + `PluginModelCatalog` 透传 + `ChatView` 按配置读取；默认仍回退 low/medium/high，是否出现 xhigh/max 取决于 model 插件数据。注：`e530cb3`（09-17）删的是思考增量节流表，与本项无关 |
| 拖动期 cell 重叠 | `ff8f99c` 修复，真机验收通过 |
| 流式期空白最大 173–236pt | 收敛到 23pt，仅触摸期出现 |
| Release 编译失败（`#if DEBUG` 符号未 gate） | `338e807`；纪律已增补 |
| 健康「拒绝却显示已授权」、家庭「拒绝后一直转圈」 | `c6ecee9`，真机验证通过 |
| 审核 2.1（HomeKit）/ 2.5.1（HealthKit 标识）拒审 | `c6ecee9` + build 12，已上架 |
| MCP 发现缓存四个缺口 | `e29f17f` / `3a1c8dd` 等；`archive/MCP-工具发现缓存-真机实测记录.md` |
| 日志量 355 行/分 | `62b50c2` 降至 120 行/分 |
| 版本号三处不一致 | `5deae8c` 收敛到 `CURRENT_PROJECT_VERSION` |
| `render-pipeline-refactor-2026-09-13.md` 过期结论（`lastHeightByKey` 等） | 该文档已归档，不再作为现状依据 |
| `关于` 页硬编码开源组件清单 | 已改为链接 `鸣谢.md`；**但 `关于MiniClaw.md` 正文仍有失实条目，见 I-25** |

---

## 5 维护规则

1. 新问题先查本表，避免重复；同一问题不同视角合并到一条。
2. 修完：状态改「已关闭」，补 commit 与验证方式；**不要删除条目**（保留追溯），可移到 §4。
3. 每条必须能指向代码行或报告；「感觉有问题」不算条目。
4. 每批次结束核对一次：本表与 `CURRENT_STATE.md`、9-19 报告编号不得互相矛盾。
