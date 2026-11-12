# MiniClaw 记忆 / 技能 / 插件 / MCP / 权限 架构技术报告

> 范围：`MiniClaw/MiniClaw/Services/`、`Tools/`、`Resources/BundledPlugins/`、`Resources/AboutDocs/`，以及 `Doc/MiniClaw_插件化架构重做_构思报告_2026-08-26.md`、`Doc/MiniClaw_插件开发指南.md`、`MiniClaw/docs/audit-2026-09-07.md`、`MiniClaw/docs/cleanup-report-2026-09-13.md`、`MiniClaw/docs/plans/scene-17-launch/plan.md`。
> 全部结论来自实读源码；凡「文档说有、代码里没有」的偏差均在 §6.2 单列。
> 术语对齐 `docs/MiniClaw术语表.md`：embedding 在文档中统一称「向量检索 / 嵌入」。

---

## 1. 记忆体系

### 1.1 目录布局（沙盒真实路径）

沙盒根 `Documents/MiniClaw`（`FileSystemManager.miniClawRoot`，`Services/FileSystemManager.swift:214`），记忆相关：

| 路径 | 常量 / 代码 | 内容 |
|---|---|---|
| `memory/MEMORY.md` | `memoryDir`(:228) | **唯一长期记忆文件**；缺失时用 `FileSystemManager.defaultMemoryMarkdown`(:208) 初始化 |
| `memory/YYYY-MM-DD.md` | `MemoryManager.writeDailyMemory`(:24) | 每日记忆，一天一文件，正则以 `^\d{4}-\d{2}-\d{2}\.md$` 识别 |
| `memory/SOUL.md` | `initializeSoulIfNeeded`(:537) | 人格（soul 插件产出，首次从内置 soul 包按语言拷贝） |
| `memory/SOUL.builtin.md` | `builtinSoulDraftURL`(:576) | 第三方 soul 生效期间的「内置灵魂草稿」（用户数据，不被覆盖） |
| `.cache/embeddings/index.json` | `embeddingsCacheDir`(:245) + `MemoryIndexer.indexURL`(:170) | 向量索引落盘（`IndexFile{mtimes,chunks,vectors}` JSON）；注释明确「刻意避开 memory/ 写入门禁」 |
| `.cache/memory-backups/` | `MemoryConsolidator.backup`(:383) | 整理/归档前的原文备份，保留最近 10 份（`maxBackups`） |

模型可见的虚拟路径为 `/var/MiniClaw/memory/...`（由 `MiniClawHost.memory` 单点声明，`FileSystemManager.swift:14`）。注意 `MemoryManager.editMemory`(:80-83) 的注释：虚拟路径**不是**真实目录，必须经 `resolveAgentPath` 映射后才能读，否则读不到。

### 1.2 写入与门禁

写入唯一通道是 `MemoryManager`（`Services/MemoryManager.swift`），AI 侧唯一入口是 `memory_write`：

- **串行队列**：`writeQueue`(:10) + `syncWrite`(:13) 把 daily/longTerm/edit 全部写操作串行化，消除并发 append 双 `FileHandle` 交错、`replace` 与 `append` 竞态，并顺带解决 `DateFormatter` 非线程安全（L6/L7）。
- **每日记忆** `writeDailyMemory`(:24)：条目格式 `"\n\n## HH:mm\n\n" + content`；文件不存在时先写本地化表头 `memory_daily_header`。
- **长期记忆** `writeLongTermMemory`(:41)：`mode .append` 追加（有内容时前置 `\n\n`）、`.replace` 整体覆盖；空内容抛 `FileError.writeFailed`。
- **定点修改** `editMemory`(:63)：`target` 为 `.longTerm` / `.daily`（daily 只针对**今天**的文件），先读全文、`contains(oldString)` 校验、替换后再过净化。
- **敏感信息净化** `sanitizeMemory`(:104)：① `envvarsPrivacyMode` 打开时把用户环境变量**值**替换为 `***`；② 三条正则过滤 `sk-/pk-/rk-` 长串、`Bearer xxx`、`password|api_key|token|secret…[:=]值` → `***REDACTED***`。
- **写入门禁**（`FileSystemManager.validateWrite`，:1067）：`FileWriteActor.memory` 分支只放行 `MEMORY.md` 与当日 `YYYY-MM-DD.md`，并**显式禁止 SOUL.md**（`guard isWritableMemory, url != soul`）。`FileWriteActor.agent` 分支（AI 的 file_write/file_edit）白名单为 `shared/`、`skills/`、会话独享子目录（workspace/attachments）、扁平回落目录，以及**已启用且 `isWritable` 的挂载**；`MINICLAW_SYSTEM_PROMPT` 的 `memory_system_section` 也把「禁止用 file_edit/file_write 改 memory/」写进提示词。

### 1.3 召回与注入（system prompt）

`AgentRunService+SystemPrompt.swift`：

- **稳定段**只放大段说明 `memory_system_section`（:83，内容见 `Localizable.xcstrings:33288`：长期/每日记忆用法、`memory_get` 语义、GLOBAL.md 不是记忆、只能用 memory_write 改记忆）。记忆**正文**一律进易变段，避免记忆更新打断 KV 缓存前缀。
- **近期记忆**（:165-170）：记忆总开关开启时 `MemoryManager.getRecentMemory(days: 2)`（今日+昨日），以 `agent_recent_memory_inject` 注入。
- **长期记忆**（`longTermMemorySection`，:208）：若 `memory.embeddingEnabled` 且 `MemoryIndexer.isEmbeddingAvailable()` → 用**当前会话最新一条用户消息**作 query，`MemoryIndexer.search(keyword:scope:.longTerm, topK: 8)`，命中则注入 `long_term_memory_fragments` + 片段 + 「完整记忆可用 memory_get」提示；**无命中或向量不可用则回落注入 MEMORY.md 全文**（全文等于出厂默认模板时不注入）。
- **跨会话摘要**（`crossSessionSummarySection`，:241）：取其它会话 `session.summary` 最近 5 条。
- 段内排序判据（:91-98 注释）：**变化频率升序**，越易变越靠后（工具清单 → 环境变量/挂载 → 跨会话摘要 → 近期记忆 → 长期记忆 → 环境快照 → 子代理段）。

### 1.4 MemoryIndexer（向量索引 + FTS 混合检索）

`Services/MemoryIndexer.swift`（`@unchecked Sendable` 单例，`NSLock` 保护 chunks/vectors/mtimes/builtAt/embeddingAvailable/rebuildInFlight）：

- **索引构建** `ensureIndex`(:93)：枚举 `MEMORY.md` + 全部每日文件，比较 mtime 决定是否重建；`rebuildInFlight` **单飞**防止 N 个并发 search 各自发起 embedding；切块 `chunkText`(:261) 按空行段落聚合、`maxChunkSize = 600`。
- **降级与重试语义**：embedding 失败时只更新 chunks、**不推进 `lastMtimes`/`builtAt`** → 下次 search 会重试，避免一次临时网络故障把向量检索永久降级为纯 FTS（:143-151）。
- **embedding 客户端** `EmbeddingClient.embed`(:305)：OpenAI 兼容 `POST <endpoint>`，`{"model","input":[texts]}`，`Authorization: Bearer <key>`，超时 60s，按返回 `index` 排序并要求向量数 == 输入数；端点/密钥/模型来自 `AppState.shared.resolveEmbeddingEndpoint()`（`MainActor`）。设置项在 `Models/ChatMemoryModels.swift:20 MemorySettings`：`embeddingEnabled` **默认 false**、`embeddingModel = text-embedding-3-small`、`embeddingProviderType = .openai`。
- **检索** `search(keyword:scope:topK:)`(:51)：总开关关 → 纯关键词；`embeddingEnabled == false` 或端点探测失败 → 纯关键词（用已建 chunks 或直接扫文件，`keywordSearch` :177）；否则 `hybridScore`(:210) = **0.6 × 归一化余弦 + 0.4 × 归一化 FTS 命中数**，取 topK（默认 8）。
- **落盘** `saveIndex`(:156)：锁内取快照 → `JSONEncoder` → 原子写 `index.json`。
- 与旧 API 的关系：`MemoryManager.searchMemory`(:129)（行号 + 上下文的旧检索）仍保留，但 `memory_get` 已切到 `MemoryIndexer`。

### 1.5 复盘 SessionReviewService

`Services/SessionReviewService.swift`（单例，`NSLockedSet<UUID>` 会话级去重）：

- **触发点**（两处）：
  - `Views/Chat/ChatView.swift:1177` 的 `.onDisappear`（`showSessionTerminal` / `showSessionBrowser` 时 early return，避免全屏覆盖误判为离开会话）；
  - `App/MiniClawApp.swift:126-128` 的 `scenePhase == .background`，遍历 `AppState.shared.chatRuntimes`，**跳过 `isPaused`**（半截回复会污染长期记忆）。
  - 两处都先判 `SettingsStore.shared.settings.memory.isEnabled`。
- **限额/跳过条件**（`runReview` :21-50）：无消息跳过；`runtime.isResponding == true` 跳过；`session.reviewedMessageCount >= messageCount` 跳过（该计数**持久化在会话模型上**，重启后不再重复复盘）；复盘端点固定走**副模型** `AppState.shared.resolveBackgroundModelEndpoint()`（未配置时回退主模型）；历史取最近 **40 条**（`buildHistory` :121，仅 user + 非空 assistant）。
- **受限 Agent**：`ToolRouter` 只注册 `MemoryWriteTool(bypassConfirmation: true)` 与 `MemoryGetTool`（:55-57）；`engine.configure(sessionID: UUID(), …)` 用**独立随机会话 ID**，避免检查点污染 `AgentTaskStore[真实 sessionID]` 被 `ChatView.recoverIfNeeded` 误渲染；`isSubagentEngine = true`（不弹确认框）；`onTokenUsage = {}`（复盘用量不计入用户统计）。
- **指令与提示词**：instruction（:71-80）要求「先 memory_get 查重 → 按写入分级规则沉淀 → 最后单独一行 `[SUMMARY] …`」；`reviewSystemPrompt`(:99) 写死分级：只有用户明确要求记住、跨会话稳定偏好/约定/技术决策、反复出现的行为模式、待跟进事项才写 `long_term`，单次搜索/浏览/当天临时任务一律 `daily`，并明确禁止「单次事件推断长期画像」与写入密钥。
- **摘要落库**：`parseSummary`(:134) 只在命中 `[SUMMARY]`（容错 `Summary:`）时取值，最长 300 字，格式不符返回空串（不写污染）；随后主线程写 `session.summary` + `session.reviewedMessageCount` 并 `SessionManager.persist`。
- **收尾**：`MemoryConsolidator.shared.consolidateIfNeeded()`（:94）。

### 1.6 MemoryConsolidator（跨会话整理）

`Services/MemoryConsolidator.swift`，要解决的问题写在文件头：复盘会不断往 MEMORY.md 追加要点，长期运行后语义重复、体积膨胀吃掉系统提示预算。

- **触发**：复盘后 `consolidateIfNeeded()`(:73)（后台 detached）；`Services/Background/BackgroundScheduler.swift:73` 的 `BGProcessingTask`（identifier 为 `consolidateTaskID`）也直接调 `consolidate(force: false)`。
- **三重门禁**（`consolidate` :81-119）：`memory.isEnabled`；非 force 时要求 `consolidationEnabled`（默认 true）；冷却 **6 小时**（`cooldown`，时间戳存 `UserDefaults["memory.consolidation.lastRunAt"]`）；MEMORY.md 字符数 < `consolidationMinChars`（默认 **3000**）时跳过；另有 `RunGate`(:544) 单飞。
- **四阶段流水线**（任一段失败都安全降级）：
  1. **阶段 0 过期日志归档** `archiveExpiredDailyLogs`(:210)：早于 `retentionDays`（默认 **30**）的每日日志，拼语料（上限 `maxArchiveInput = 40 000` 字符，**未进语料的文件绝不删**）交副模型蒸馏（prompt :246，规则：只留跨天成立的事实、丢弃一次性过程信息、数字/路径/命令原样保留；输出 < 40 字符视为失败）；成功后**逐个备份成功才删**（无备份不删数据），摘要并入 MEMORY.md 的 `## 归档` 节。
  2. **阶段 1 精确去重**：`parse`(:421) 把 Markdown 拆成 heading/item/paragraph 三类块（标题不参与去重），`removeExactDuplicates`(:484) 按 `normalizeKey`(:504)（剥列表标记/加粗、折叠空白、小写）去重。
  3. **阶段 2 语义归并** `mergeSemanticDuplicates`(:282)：仅当 `embeddingEnabled`；把可去重块向量化，余弦 ≥ `consolidationSimilarity`（默认 **0.90**）判为同一事实，保留**更长**的一条，位置沿用首次出现处。
  4. **阶段 3 主题重写** `rewriteByTopic`(:326)：副模型按主题重排（不得新增/推断/删除事实，冲突保留更晚的一条并标注「此前记录为：」）；**体量校验**：输出 ≥ 200 字符且 `out/content ≥ 0.45` 才接受，否则回退并置 `rewriteRejected`。
- **并发写保护**（:180-191）：模型调用期间 MEMORY.md 可能被追加；写回前比对 `current != original`，若为「前缀追加」则合并保留，若被整体改写则**放弃本次写回**保护新数据。
- 报告结构 `Report`(:34)：条目数、字符数、精确/语义去重数、归档文件数、是否重写/拒收，`text` 为本地化摘要（设置页手动 `force: true` 触发时展示）。

### 1.7 记忆工具（Tools/MemoryTools.swift）

| 工具 | schema 关键点 | 行为 |
|---|---|---|
| `memory_write` | `target: long_term\|daily`、`mode: append\|replace\|edit`、`content`、`old_string`、`new_string`；required = `target`+`mode` | `long_term` 支持 append/replace/edit；`daily` 只支持 append/edit（replace 报 `err_daily_modes`）；总开关关闭 → 返回「记忆已禁用」；`daily` 还受 `autoSaveDaily` 开关守卫（关闭时拒写，但**读取不受影响**）；错误统一 `ToolResult(success: false, text:)` |
| `memory_get` | `keyword`(必填) + `scope: long_term\|daily\|all` | 直接调 `MemoryIndexer.shared.search(keyword:scope:)`（topK 默认 8）；无命中返回「未找到记忆」；命中用 `\n\n---\n\n` 拼接 |

- `MemoryWriteTool` 的 `resumePolicy`：默认实例 `.requiresUserConfirmation`，`bypassConfirmation: true` 时 `.retryable`（仅供复盘分身）。`executionTimeout` 未覆盖 → 默认 120s（`ToolProtocol.swift:39`）。
- **真正执行确认的是引擎全局阀门**，不是 `resumePolicy`：`AgentLoopEngine.swift:1959-1975`，条件 `!isSubagentEngine && defaults.confirmBeforeToolCall && !autoApproved`。`defaults.confirmBeforeToolCall` **默认 false**（`Models/AppSettingsModels.swift:35`），且 `isSubagentEngine=true` 一律不弹窗 —— 所以复盘分身写记忆实际不会被拦截，`bypassConfirmation` 目前只是元数据声明。
- 记忆工具包的**启用态不是插件开关**，而与「设置-记忆-启用记忆」同源：`ToolPluginManager.memoryToolsEnabled()`(:159) / `setMemoryToolsEnabled`(:164)，插件列表开关与记忆设置页共用同一状态（单一真相源）。
- 首启时序兜底：`ToolPluginManager.enabledPluginTools`(:218) 在「沙盒里一个 tool 包都没有」时按内置能力**全量注册**（记忆工具仍受总开关约束），避免内置工具因后台同步未完成而消失。

---

## 2. 技能体系

### 2.1 布局与清单（技能 = `type: skill` 的插件）

- 统一插件沙盒布局 `plugins/<type>/<id>/`（`FileSystemManager.pluginsRoot` :233）；技能目录 `skillsDir = plugins/skill`(:237)。
- 旧布局已废除：`skills/`、`subagent-profiles/`、`rules/` 三个旧根目录**检测到即整树删除**（`purgeLegacyLayoutDirectories` :436，理由：App 未上架，不做兼容）。
- **强制 `plugin.json`**（`SkillModels.PluginManifest` :33）：`loadSkills` 对无清单目录直接 `continue`。解码用显式 `init(from:)` 全字段 `decodeIfPresent`（:87），治的是「第三方手写清单省略可选字段 → 整个插件静默消失」。
- `SKILL.md` 是 skill 类型惯例但**可选**：`loadSkills` 有则解析 frontmatter 作为 displayName/描述回退，无则全取清单。

### 2.2 SKILL.md 解析

`SkillFrontmatter`（`Services/SkillModels.swift:17`）：`name`、`description`、`compatibility?`、`version?`、`body`。解析器 `SkillManager.parseSkillMarkdown`（:758，`nonisolated` 纯函数供后台线程用）是最小 YAML 实现：识别 `---\n … \n---`，支持 `key: value`、单双引号、以及 `-`/`|`/`|-`/`>` 折叠标量（多行累积）；无 frontmatter 时整段作为正文。可选子目录约定：`scripts/ references/ assets/ evals/`。

### 2.3 加载与启用态

`SkillManager`（`@MainActor`，`Services/SkillManager.swift`）：

- `loadSkills()`(:42)：扫 `allPluginDirectories()`（跨全部类型），解析 `plugin.json`，产出 `SkillPackage{name, description, version, isEnabled, directoryName, source, installDate, icon, category, type}`；结果缓存 `skillsCache`，变化入口统一 `invalidateSkillsCache()`。
- **启用态规则**（:64-68）：`skillEnabledStates[displayName] ?? fallbackEnabled`，其中 `fallbackEnabled = isBuiltin ? manifest.enabledByDefault : false` —— 即**用户导入的插件默认关闭**，内置沿用清单声明；用户手动开/关状态永远优先。
- 来源判定：Bundle 的 `.bundled-manifest.json`（id→type 映射，`FileSystemManager.bundledPluginEntries` :250）里出现即为内置；`installDates` 首次记录后持久化。
- 描述优先级：`manifest.description` → `SKILL.md` frontmatter description → 本地化「无描述」；版本同理。
- `enabledSkills()`(:105) 额外过滤 `type == "skill"`（subagent/rule 不参与 `/指令` 命名空间）；`effectiveEnabled(name:source:)`(:113) 供视图逐帧读取。

### 2.4 注入与渐进式加载（cache-safe）

- **稳定段常驻**：`enabledSkillMetadata()`(:259) 只拼 `name + description`（模板 `skill_meta_section`），注入点 `AgentRunService+SystemPrompt.swift:57-60`；读盘在 `Task.detached(priority: .userInitiated)`。
- **正文按需**：模型判断相关 → 调 `skill_load`（`Tools/SkillLoadTool.swift`，在 `AgentRunService.buildToolRouter` :51 **无条件注册**，非插件）。工具本身**只返回一句短确认**，并把技能名记入 `SkillManager.markSkillLoaded(_:sessionID:)`(:302) 的会话级内存集合；随后 `AgentLoopEngine` 在拼 system 易变段时调 `SkillManager.loadedSkillBodies(for:)`(:311) 把完整正文注入**缓存断点之后** —— 既不影响 KV 缓存命中，也避免正文被工具历史/上下文压缩吞掉。集合按技能名排序（:313-316）保证跨进程字节稳定。
- `skillBodyCache`(:280) 按 name 缓存正文，跨会话复用；`skillBody(named:)`(:330) 走后台读盘且**不写缓存**（供「本轮强制技能」一次性注入，避免泄漏到后续轮次）。
- **`/技能名` 指令**：`skillSlashCommands()`(:231) 只列已启用技能，按 `skillUseCounts` 降序、同频按 name 升序；命中时 `buildSystemPrompt` 的 `extraSkillName`(:64) 会把该技能正文临时写进稳定段（优先级高于常规元数据）。
- 创建/删除/导入/导出：`createSkillDirectory`(:349)（同时写出 `plugin.json[type:skill]`）、`deleteSkill`(:396，跨类型定位 + mcp/model/soul/theme 善后）、`exportPluginMPK`(:443)、`updateSkill`(:483，仅服务 type=skill 且 id 必须匹配)、`importSkillFile`(:542)。

### 2.5 技能 vs 插件

| 维度 | 技能 | 插件（超集） |
|---|---|---|
| 定义 | `type == "skill"` 的插件 | `.mpk` 包，`type` ∈ skill/subagent/rule/soul/tool/mcp/model/theme |
| 内容 | `SKILL.md`（frontmatter + 指令正文） | 按 type：`tools/*.json`、`<role>.md`、语言目录 `.md`、`SOUL.md`、`servers.json`、`providers.json`、`theme.json` |
| 生效语义 | 叠加共存；启用后进 `/` 指令入口；正文 `skill_load` 渐进加载 | 见 §3.3/§3.5（soul 排他单选，mcp/model 无开关，tool 进可用工具清单…） |
| 消费方 | `SkillManager.enabledSkills()` + `SkillLoadTool` | `ToolPluginManager` / `SubAgentProfileStore` / `FileSystemManager.ruleMarkdownFiles` / `MCPConfigStore` / provider store |

---

## 3. 插件化架构

### 3.1 `.mpk` 格式与目录结构

`.mpk` = 标准 zip。固定布局（`Doc/MiniClaw_插件开发指南.md` §一）：

```
<plugin-id>/plugin.json          ← 强制，缺失/无 id/type 则整包拒绝
<plugin-id>/tools/<name>.json    ← type=tool（一包多工具，主键=文件名）
<plugin-id>/SKILL.md             ← type=skill
<plugin-id>/<name>.md            ← type=subagent / rule（rule 按语言子目录）
<plugin-id>/servers.json         ← type=mcp（业界 mcpServers 格式）
<plugin-id>/providers.json       ← type=model
<plugin-id>/theme.json + 图片    ← type=theme
```

导入侧允许 `plugin.json` 直接在包根（`SkillManager.findPluginDirectories` :695 递归找所有含 `plugin.json` 的目录并剔除嵌套项）；内置包统一子目录布局。解压复用 `Services/ZipArchive.swift`（含 zip-slip 与 inflate 防护，注释标明其抽取自 `SkillManager`）。

### 3.2 `plugin.json` 字段（`Skills/SkillModels.swift:33 PluginManifest`）

| 字段 | 默认 | 说明 / 消费情况 |
|---|---|---|
| `id` | "" | 全局唯一，作沙盒目录名；`sanitizeID`(:108) 把 `/` `\` 换成 `-` |
| `name` | "" | 展示名，也是 `skillEnabledStates` 的**键**（空则回落目录名） |
| `version` | "1.0.0" | 导入升级比较用（`compareVersion` :741 点分数字 semver 子集） |
| `type` | "skill" | 决定分发目录 `plugins/<type>/` 与消费方 |
| `category` | "skill" | 分类展示 + 默认 SF 图标（`pluginIcon` :836：model=cpu、skill=wrench.and.screwdriver、rule=checklist、subagent=person.2、soul=brain.head.profile、theme=paintpalette、mcp=link、tool=hammer，兜底 puzzlepiece） |
| `minCoreVersion` / `dependsOn` / `conflictsWith` | "1.0.0" / [] / [] | **已声明但全库零消费**（见 §6.3-5） |
| `enabledByDefault` | true | 内置包生效；导入包一律默认关闭 |
| `author` / `license` / `icon` / `description` | "" | `description` 内置必填（≤30 字），第三方缺省显示「无描述」 |

### 3.3 包类型与实际内置包

**生效语义总表**（`Doc/…构思报告…md` §十三 + 实测）：

| type | 生效语义 | 导入默认 | 开关位置 |
|---|---|---|---|
| skill | 叠加共存，进 `/` 指令入口 | 关 | 插件列表/详情页 |
| subagent | 叠加共存，启用 = 角色进派发集 | 关 | 插件列表/详情页 |
| rule | 叠加共存，按当前语言取用 | 关 | 插件列表/详情页 |
| soul | **排他单选**，启用即停用其他 soul，内置灵魂进草稿 | 关 | 插件列表/详情页 |
| tool | 叠加共存，启用 = 工具进可用清单 | 关 | 插件列表/详情页 |
| tool（记忆包） | **特例**：启用态 = 设置-记忆-启用记忆 | 开 | 插件页 = 记忆页 |
| mcp | **导入即合并**（无启停开关） | — | 无（列表不显示开关） |
| model | 模板显式添加，密钥用户自填 | — | 无 |
| theme | 无插件页开关，入口在外观页 | — | 外观页 |

**7 个内置 `.mpk`（`Resources/BundledPlugins/`，实测解包内容）**：

| 文件 | id / type | 内容 | 描述 |
|---|---|---|---|
| `com.miniclaw.builtin.memory.mpk` | `com.miniclaw.builtin.memory` / tool | `tools/memory_write.json`、`tools/memory_get.json`（均为 `{"name":…,"backend":"builtin"}`） | 「长期记忆与每日记忆的读写工具」，icon=brain |
| `com.miniclaw.builtin.tools.mpk` | `…builtin.tools` / tool | **22 个** `tools/*.json`：apple-clipboard / device / nlp / notification / open / photos / speak / healthkit / location / calendar / reminders / homekit / contacts / maps / media / speech / image / vision、open-in-safari、miniclaw_config、miniclaw-model-use、remote-host，全部 `backend: builtin` | 「Apple 系统能力与配置类工具集」 |
| `com.miniclaw.builtin.apigateway.mpk` | `…builtin.apigateway` / **model** | `providers.json` 两条模板：`{label:"OpenAI 兼容网关", providerType:custom, apiFormat:chatCompletions}`、`{label:"Anthropic 兼容网关", providerType:anthropic}`，`customBaseURL` 留空 | 「通用 API 网关预设…地址由你填写」 |
| `com.miniclaw.builtin.rules.mpk` | `…builtin.rules` / rule | `zh-Hans/GLOBAL.md`（5 153 B）：基本行为、执行纪律、工具调用风格、文件操作、环境变量安全、**记忆规则**（长期/每日、`- ` 列表项、禁写密钥、GLOBAL.md 不是记忆）、检索与查证纪律 | 「系统内置规则」 |
| `com.miniclaw.builtin.skill.plugin-creator.mpk` | `…skill.plugin-creator` / skill v1.6.0 | `SKILL.md`（18 340 B ≈ 330 行）：8 类型规范、打包命令、mcp/model 配方、设计标准与红线、AI 自主安装、原地升级 | 「装 MCP、接外部服务、做插件都先用它」 |
| `com.miniclaw.builtin.soul.mpk` | `…builtin.soul` / soul | `zh-Hans/SOUL.md` + `en/SOUL.md`（frontmatter `name: "MiniClaw"`, `style`, `lang: auto`） | 「出厂默认人格模板（可在灵魂页编辑个性化）」 |
| `com.miniclaw.builtin.subagents.mpk` | `…builtin.subagents` / subagent | `roles/{general,planner,research,writer}.md`，每份 frontmatter `name/description/read_only: false`，正文即角色系统提示词 | 「内置四个子代理角色：通用、规划、调研、写作」 |

附注：`Resources/BundledRules/` 目录**已空**（仅 `.DS_Store`），全库无代码引用（仅注释提及）；规则已全部改由 rule 类型 `.mpk` 提供。`Resources/AboutDocs/` 仍有 `关于MiniClaw.md`、`用户使用协议.md`、`用户隐私政策.md` 三份（约 1–2 KB/份），属 App 内展示文档，**未**成为 rule 插件。

### 3.4 安装 / 同步 / 加载全流程

**A. 内置包同步（每次启动，后台串行）**
`App/MiniClawApp.swift:45` → `FileSystemManager.syncBundledResourcesInBackground()`(:144) → `bundleSyncQueue`（串行，qos userInitiated）执行：

1. `syncBundledPlugins()`(:332)：从 Bundle 根与 `BundledPlugins/` 子目录两种布局收集 `.mpk`；逐个解压到临时目录 → `findPluginDirectory`（取路径最浅的含 `plugin.json` 目录）→ `pluginIDAndType`（这里**要求 id 与 type 均非空**）→ 拷贝到 `plugins/<type>/<id>`（**同名先删后拷**，避免半包残留）。
2. 清理「上次 manifest 有、本次没有」的内置包目录（`previousEntries`）。
3. `saveBundledPluginEntries` 写 `plugins/.bundled-manifest.json`（id→type，内置身份的唯一依据）。
4. `Task { @MainActor in SkillManager.shared.invalidateSkillsCache() }`（内置包落地后必须失效缓存，否则列表缺内置项、tool 声明读不到）。
5. 同一队列末尾 `initializeSoulIfNeeded()`(:537)：`memory/SOUL.md` **不存在时**才从内置 soul 包按语言拷贝（`applySoulPackage` :547，语言取用：当前语言 → `en` → 包根）。
6. 完成置 `_bundledSyncDone` 并唤醒 `waitForBundledSync()`(:159) 等待者；`buildSystemPrompt` 首轮前 `await fs.waitForBundledSync()`（`SystemPrompt:15`）。

**B. 用户/AI 导入**
`SkillManager.importSkillFile(from:)`(:542)：

- 只接受 `.mpk`/`.zip`；**单文件 `.md` 导入与更新均已弃用**（:560 直接返回 `skill_single_file_deprecated`，更新同理 :499）。
- 解压到 staging → `findPluginDirectories` → 对每个包读 `id` 与 `type`（`pluginIDAndType` :719，宽容：type 缺省 `skill`）→ 按 `plugins/<type>/<id>` 分发。
- **内置 id 拒绝覆盖**（`fs.bundledPluginIds().contains` :583）。
- 同 id 已存在时按版本处置（唐唐 2026-09-01）：新版 > 旧版 → **原地升级**（先复制旧包为临时备份，失败回滚；theme 升级后做资源校验，违规回滚；mcp 升级后 `servers.json` 幂等重合并）；版本相同 → 跳过；更低 → 拒绝（提示降级需先删除）。`ImportResult{imported, updated, skipped, message}`。
- 特殊类型副作用：`soul` 导入即 `setEnabled(soulName, true)`（装了就默认用，排他停用其他第三方 soul）；`mcp` 解析 `servers.json` 调 `MCPConfigStore.mergePluginServers(_:sourcePlugin:)`；`model` 注释声明解析包内 `providers.json` 幂等合并进供应商列表（合并实现不在 SkillManager 内）。
- **AI 自主安装**：`Tools/PluginTool.swift` 的 `miniclaw_plugin`（action = list/install/enable/disable）。install 先按 `defaults.aiPluginInstallRequiresConfirmation`（**默认 true**，`AppSettingsModels.swift:42`）经 `ToolConfirmationBridge` 弹窗；安装即启用（soul 除外，留给用户显式启用）；install/enable 的入参可为插件 id 或 name。

**C. 加载（消费方一次一览）**

| 类型 | 消费代码 | 关键行为 |
|---|---|---|
| tool | `ToolPluginManager.enabledPluginTools(sessionID:)` :218 | 扫 `plugins/tool/<id>/tools/*.json`；`backend == builtin` 查 `builtinFactories`(:178，白名单 20+ 项，如 memory_write/memory_get/apple-*/miniclaw_config/remote-host)，`backend == shell` 产出 `DeclarativeShellTool`；非法名/缺 command/未知 backend 跳过并 `[ToolPlugin]` 日志 |
| skill | `SkillManager.enabledSkills()` | 见 §2.3 |
| rule | `FileSystemManager.ruleMarkdownFiles(enabledStates:builtinIds:)` :494 | 语言目录 `zh-Hans/en/ja/ko`(:473)，当前语言 → `en` 回退(:477，2026-09-08 起内置规则精简为英文，回退目标同步改 en)；**无语言目录则整包 `.md` 直接生效**；注入 stable 段（`SystemPrompt:31-54`） |
| subagent | `SubAgentProfileStore.reload(enabledStates:builtinIds:)`（`Services/SubAgent/SubAgentProfileStore.swift:25`） | 递归收本插件目录下所有 `.md` 角色文件（plugin.json 之外），强制 `type == "subagent"`；`SkillManager.setEnabled`(:153) 与导入/删除后即时刷新 |
| soul | `FileSystemManager.applySoulPackage` / `backupBuiltinSoul` / `restoreBuiltinSoul`(:547/581/589) | 排他单选；启用第三方前把内置灵魂备份到 `SOUL.builtin.md`，切回内置时草稿优先、无草稿用出厂模板 |
| mcp | `MCPConfigStore.mergePluginServers` :271 | 见 §4.5 |
| model | 包内 `providers.json` → provider store；`SkillManager.deleteSkill`(:411) 删除插件时连带 `AppState.shared.removeProvider` | 删除闭环以 `sourcePlugin` 为锚点 |
| theme | `ThemeManager.validateThemeAssets` / `activeThemeID`（删除插件时清空） | 单张 ≤ 2 MB、长边 ≤ 3840，超限导入回滚 |

**D. 启停与删除**
`SkillManager.setEnabled(_:_:)`(:124)：写 `skillEnabledStates` → 失效缓存 → 刷新子代理角色表 → soul 域特殊处理（内置草稿备份/恢复、`soul.activePlugin` 记录当前第三方来源）。`deleteSkill(directoryName:)`(:396)：按目录名跨类型定位，删除后按清单 type 善后 —— `mcp` → `removeServers(sourcePlugin:)`（连带 Keychain 令牌）；`model` → 删除该插件来源的供应商；`soul` → 若删的是当前生效第三方则恢复内置并清 `activePlugin`；`theme` → 若删的是当前主题则清 `activeThemeID`。

### 3.5 插件能贡献什么（与实现/文档的对应）

- **工具**：`backend: "shell"` 的声明式命令工具是第三方唯一可用后端。执行细节（`Services/ToolPluginManager.swift:86-136`）：参数对象 `JSONSerialization(.sortedKeys)` → 包装为 `cat <<'MINICLAW_IN_<8位随机>' | <command>`（**单引号定界符零展开零转义**；注释记录真机翻车点：「管道必须与 cat 同一行」）；复用 `ShellRuntimeFactory.runtime`（与 `shell_execute` 同一沙箱面/会话隔离/超时杀进程组）；`ToolProgressScope.reporter` 逐行上报执行输出；隐私模式掩码 + 超阈值 `offloadIfLarge` 与内置同口径；非零退出码记 `[ToolPlugin] 工具执行失败 … exit=…`。
- **规则**：见 §3.4-C。
- **子代理角色**：一包多角色，主键=文件名；`read_only` 等 frontmatter 由 `SubAgentProfileStore` 解释。
- **人格 soul**：一包可含多语言 `SOUL.md`。
- **模型数据**：`providers.json` 是 App 内模型能力数据的**唯一事实来源**（`plugin-creator/SKILL.md` §model：App 已不内置任何厂商模型目录、不做兜底猜测）；每条模板含 `label/providerType/customBaseURL/apiFormat/appendV1Suffix` + 可选连接字段；另有 `models` 能力表（`modelId/contextLimit/maxOutputTokens/deepThinking/多模态开关/pricing…`，运行时用 `/v1/models` 拉到的 ID **精确匹配**，匹配不到走保守默认、不报错）与 `behavior` 请求行为声明（`capabilities` 如 `parallelToolCalls/responseFormat/promptCaching/preserveReasoningContent`、`thinkingParam` 思考开关映射、`extraBody`、`samplingRules`）；`behavior` 只对 OpenAI 兼容族生效。
- **记忆后端**：**目前没有可扩展的记忆后端 seam**；记忆工具包只是把内置 Swift 实现登记为插件（归属 + 启停），schema 与实现仍在 Swift 侧（`builtinFactories`），第三方无法提供记忆后端。架构报告 §三#8 的 `fragment(memory)` 记忆注入片段插件**未实装**。
- **网关**：`com.miniclaw.builtin.apigateway` 是 model 包，实际只是「两条供应商模板」的预设（地址留空由用户填），不是运行时代理。

### 3.6 插件开发指南要点（`Doc/MiniClaw_插件开发指南.md` + `plugin-creator/SKILL.md`）

- **打包**：`.mpk` = zip，**不要包含目录条目**（Apple `zip` 会写目录条目，可能导致解压异常）；推荐 Python `zipfile.ZipInfo` 逐文件写（指南 §五给了可复制片段）。
- **参数传递**：模型参数序列化为 JSON 经 **stdin** 交给命令，不进命令行 ⇒ 无需转义、无命令注入面；脚本侧 `read`/`cat` 读 stdin。
- **运行环境**：iSH（Alpine 用户态），基础命令 BusyBox（sh/cat/sed/awk/date/curl）；`apk add <pkg>` 可按需安装且跨会话保留（默认**不含 python3**，用到需先 `apk add python3`）；工作目录为会话目录 `/var/MiniClaw/sessions/<uuid>`（`cd` 不跨调用保留）；环境变量注入；网络跟随系统代理；stdout+stderr 合并为结果；超阈值转 offloads；超时默认 120s。
- **限制（指南 §3.4）**：**包内脚本不可达**（iSH 只看得到会话目录）→ 变通是用沙箱自带命令写一行流，或让 AI 先用 `file_write` 把脚本写进会话目录；无状态、非交互；不能调用 iOS 原生能力（那是 `builtin` 后端的地盘，且第三方不可用）。
- **密钥三态来源**（plugin-creator §mcp）：非敏感值写字面量；敏感值存在环境变量里写 `${VAR}`（url/headers/env/args 通用，`${...}` 变量名不限字符）；需要用户首次提供则声明 `auth: "bearer"` 或 `"oauth"`，**不要写值**。⚠️ 不要把 `${VAR}` 放在 `Authorization` 上 —— 会被识别成包内明文令牌直接存进 Keychain（存的是字面量），展开随之失效（实现依据 `MCPConfigStore.importClaudeDesktopConfig` :216-231）。
- **红线**（指南 §五）：禁原生代码（可执行二进制/JIT/私有 API/特殊 entitlements）；禁包内硬编码密钥；不得伪造 type 或占用 `com.miniclaw.*` 命名空间；命令用 POSIX sh；启停 tool 插件会让服务端 tools 段缓存断一次（设计内）。
- **更新**：必须递增 `plugin.json` 的 `version`，否则导入被跳过；内置包不可被导入覆盖。

---

## 4. MCP 集成

### 4.1 配置与凭据

- `MCPConfigStore`（`@MainActor ObservableObject`，`Services/MCPConfigStore.swift`）：持久化到 `config/mcp_servers.json`（`FileSystemManager.configDir`），`persist()` 在 `ioQueue` 后台编码 + 原子写；`servers: [MCPServerConfig]`（`Models/MCPModels.swift:3`，字段 id/name/endpointURL/transport/isEnabled/hasBearerToken/customHeaders/envVars/command/args/lastStatus/lastError/lastToolCount/lastCheckedAt/`sourcePlugin`/`requiresAuthorization`）。
- 凭据：静态 Bearer 存 Keychain（`MCPBearerTokenStore`，service `com.neartop.miniclaw.mcpbearertoken`，account = server UUID，`kSecAttrAccessibleAfterFirstUnlock`）；OAuth 令牌存另一个 Keychain（`MCPOAuthTokenStore`，service `com.neartop.miniclaw.mcpoauthtoken`）。`effectiveBearerToken(for:)`(:80)：**静态 Bearer 优先，其次 OAuth access token**（注释记录此前只读静态库导致 OAuth 授权成功仍 401）。
- 任何 upsert/remove/setEnabled 后都会 `MCPClientManager.invalidate(serverId:)` + `MCPToolDiscoveryCache.invalidate(serverId:)`（:46-59）。
- 导入/导出兼容 Claude Desktop 格式：`exportClaudeDesktopConfig`(:160) / `importClaudeDesktopConfig`(:190)，支持 `command`→stdio、`url`→http/legacySSE（URL 含 `/sse` 即 `legacySSE`）、`headers`、`env`，以及 `"auth": "oauth"` → `requiresAuthorization`。
- 环境变量展开：`expandMCPVars`（`MCPProtocol.swift:146`，`$VAR`/`${VAR}`，未命中保持原样）与 `resolveMCPEnv`(:157，server.envVars 优先，回退全局「环境变量」设置）；展开作用于 `endpointURL`、`customHeaders` 值、stdio 的 `command`/`args`。

### 4.2 传输与客户端

- 传输枚举 `MCPTransport { auto, http, legacySSE, stdio }`。
- `MCPClientManager`（actor，`Services/MCPClient.swift:28`）：按 `server.id` 缓存 client（`stdio` → `StdioMCPClient`，其余 → `RemoteMCPClient`）；`invalidate` 时 `shutdown()`。**令牌在 client 创建时固化**，所以 OAuth 拿到新 token 后必须 invalidate（`MCPOAuthManager` 授权成功处显式做）。
- `RemoteMCPClient`（actor，:57）：JSON-RPC 2.0，协议版本常量 `MCPDefaultProtocolVersion = "2024-11-05"`（`MCPProtocol.swift:3`）；握手 `initialize`（clientInfo = MiniClaw + App 版本）+ `notifications/initialized`，协商后的版本用于 `MCP-Protocol-Version` 头；`tools/list` 支持 `nextCursor` 分页（上限 100 轮 + 游标去重，防死循环）；`tools/call` 结果合并 `content[type=text].text` 与 `structuredContent`（`mergeContent` :494）。
  - **HTTP**：`POST` JSON，`Accept: application/json, text/event-stream`；响应为 SSE 时用 `extractJSON`(:509) 按 request id 挑事件，否则直返；`Mcp-Session-Id` 响应头回写并在后续请求带上。
  - **legacy SSE**：`GET` 长连（独立 `streamingSession`，超时 86 400/604 800s）解析 `event: endpoint` 得到消息端点（约束同源、无 user/password/fragment），消息走 POST；响应可能先于 POST 返回，故先登记 request id 再发 POST，并做 30s 响应超时/取消清理（:284-356）。
  - **安全**：`MCPRedirectDelegate`(:4) 只允许**同源** 30x 重定向，跨源直接停止，避免 Bearer 外泄；`isSameOrigin`(:471) 比较 scheme/host/port。
  - **保留头**：`Content-Type / Accept / MCP-Protocol-Version / Mcp-Session-Id / Authorization` 由系统托管，用户 `customHeaders` 命中即跳过（`applyCustomHeaders` :235）。
- `StdioMCPClient`（`Services/StdioMCPClient.swift`）：**仅 macOS** 编译（`#if os(macOS)`）——`Process` 拉起 command，换行分隔 JSON 走 stdin/stdout，30s RPC 超时，EOF/进程退出唤醒全部 waiter（注释：全维度审计高危项 4.1/4.2）。iOS 分支（:174 起）直接抛 `MCPClientError.unsupported`（「iOS 沙箱不允许拉起本地进程…请改用 HTTP(S)」）。

### 4.3 OAuth（MCPOAuthManager）

`Services/MCPOAuthManager.swift`（`final class … SFSafariViewControllerDelegate` + `ObservableObject`），`startAuthorization(server:)`(:230) 六步：

1. **RFC 9728** 受保护资源发现 `GET <server>/.well-known/oauth-protected-resource`（`discoverProtectedResource` :574），拿 `authorizationServers` 与 `resource`；失败回退 origin 域 **RFC 8414** 授权服务器元数据（`fetchAuthorizationServerMetadata` :591）。
2. **RFC 7591** 动态客户端注册（`registerClient`，`registrationEndpoint` 缺失或注册失败即抛 `missingMetadata`，**不再静默回落硬编码 client_id**，注释记录 ARDOT 实测 400）。
3. **PKCE S256**（`MCPOAuthPKCE` :159）+ `state`；**RFC 8707 resource indicator**（authorize/token 必带，缺了实测 `invalid_target`）；`redirect_uri` 为固定 loopback 常量 `http://localhost:18231/callback`；OAuth 2.1 语义下 authorize 不带 `client_secret`。
4. **App 内授权**：`SFSafariViewController`（从最顶层 VC 弹出，强持有防 ARC 释放）+ 本地 `NWListener` 绑 127.0.0.1:18231 收真实导航（:409 `startLoopbackListener` → 解析 HTTP 请求行 → 回本地完成页 → `handleRedirect` :499 校验 state/error/code）。
5. **code 换 token**（`exchangeCode`，带相同 resource）；`MCPOAuthTokenStore.save`（Keychain）。
6. **失效客户端缓存** `MCPClientManager.invalidate`（否则仍用旧/空 token，401 复发）。300s 流程超时兜底（`startFlowTimeout` :379）。

刷新与状态：`refreshToken(serverID:)`(:531) 用 refresh_token 换新；`isAuthorized`/`deleteAuthorization`(:218/222)；401 判定 `isMCPUnauthorizedError`(:105)。`MCPConfigStore.refresh(id:)`(:100) 的逻辑：401 → 先试 refresh_token 重试一次 → 仍 401 则置 `requiresAuthorization = true`（列表出现「认证」按钮）并记 `MCPClientError.httpStatus(401,…)`。

### 4.4 工具发现与暴露

- `MCPToolDiscoveryCache`（actor，`Services/RemoteMCPTool.swift:4`）：TTL **300s**；过期采用 **stale-while-revalidate**（先返回旧列表、后台刷新）；发现带 **3s 超时竞速**（`discoverWithTimeout` :70）；失败**负缓存 60s**（`failures`，规避不可达服务器每次拖满连接超时——注释记录真机 SendTrace 单次 14.3s、主线程阻塞 8.8s）。
- `RemoteMCPTool`(:108)：把远端 tool 暴露为 `AgentTool`。工具名 `mcp__<server前10>_<id前8>__<tool前22>_<fnv1a hash8>`（`providerSafeName` :153，确保各 LLM 供应商命名安全且稳定）；`toolProtocolSchema`(:187) 把原始 `inputSchema` 递归转 `JSONSchema(rawObject:)` 无损接入；`resumePolicy = .neverRetry`；`activityParameterName = "__miniclaw_activity"`（避开与服务端 schema 冲突的保留名，execute 时剔除；不覆盖时默认注入的 `activity` 字段可能污染远端参数）。
- 注册点：`AgentRunService.registerRemoteMCPTools(in:sessionID:)`(:76) —— 取 `store.servers.filter { isEnabled && 未被会话的 disabledMCPServerIDs 排除 }`，并行 `TaskGroup` 发现（等待时间 = 最慢单台），成功后 `toolRouter.register`，并回写 `updateDiscovery`。注意这里**没有重名拒绝**（与插件工具注册路径不对称，见 §6.3-6）。
- 触发时机：位于 `buildToolRouter` 之后、引擎启动之前（`AgentRunService` 内被调用），因此工具列表每轮可能变化，`buildSystemPrompt` 把「可用工具清单」放在**易变段**（`SystemPrompt:99-116`）而不是稳定前缀。

### 4.5 mcp 类型插件包

- 内容文件 `servers.json`（业界通用 `mcpServers` 片段，与 Claude Desktop / Cursor 同格式）。
- `MCPConfigStore.mergePluginServers(_:sourcePlugin:)`(:271) **幂等**：同名 server 覆盖非敏感字段（endpoint/transport/headers/env/command/args），**保留 id、Bearer 令牌与用户启用状态，并保留 `sourcePlugin`**（注释标明体检 P0-1：幂等更新不得洗掉删除闭环的锚点）；新 server 新增且**默认停用**并记录 `sourcePlugin`；返回 (added, updated) 供 UI 提示。导入与插件原地升级都会调它。
- `removeServers(sourcePlugin:)`(:311)：删除 mcp 插件时连带删除其导入的全部 server 与 Keychain 令牌（由 `SkillManager.deleteSkill` 触发）。
- 导入明文 Bearer 会记警告日志，建议作者改写为 `Authorization: Bearer ${ENV_NAME}`（:228-231）。

---

## 5. 权限与确认模型

MiniClaw 里「权限」是**四套互不替代**的机制，务必区分：

### 5.1 PermissionManager —— iOS 系统权限（不含工具授权）

`Services/PermissionManager.swift`（单例，`@unchecked Sendable`）：

- **公网联网**（`requestNetworkAccess` :49）：iOS 对公网联网**没有授权弹窗**；App 只有第一次真正联网后才出现在「设置 → 蜂窝网络」。所以这里主动对 `https://captive.apple.com/hotspot-detect.html` 发一次 HEAD 做**预热登记**，并用 `CTCellularData`（`observeCellularState` :68）读回限制状态写 `PermissionConfig.cellularData`；`unknown` 不覆盖已确定状态（:84-89）。
- **本地网络**（`requestLocalNetwork` :115）：唯一会弹窗的网络权限，且必须由 Bonjour 浏览触发 —— 用 `NWBrowser` 浏览 `_miniclaw._tcp`（Info.plist `NSBonjourServices` 已声明）。状态判定：`.ready → authorized`；仅 POSIX `EPERM/EACCES` 才记 `denied`（无网络也会 `.failed`，一律记 denied 会因「没网时点一下」把用户永久卡死）；`.waiting` 不写状态，60s 兜底超时（系统弹窗本身无超时）。
- **系统权限查询**（`refreshStatuses` :204，`@MainActor`）：location / calendar / reminders / photoLibrary / microphone / speechRecognition / healthKit；HomeKit 无查询 API、剪贴板始终可用。
  - **HealthKit 特别说明**（`healthStatus` :266）：iOS 对只读类型恒返回 `.sharingDenied`，故**不查询系统**，只返回本 App 记录的「是否已请求过」。
- **申请**（`requestPermission(_:)` :276）支持 `health/healthData/calendar/reminders/photos/location/microphone/speech/localNetwork/homeKit`；HealthKit **只申请读**（写授权由「设置 → 通用 → 允许 AI 写入健康数据」+ `apple-healthkit` 的 write/delete 按需申请）；定位走 delegate + 10s 轮询兜底（`LocationResumeBox` 保证只 resume 一次）；语音统一 `AVAudioSession.requestRecordPermission`（避免 `AVAudioApplication` 版本恢复点不在主队列导致 `_dispatch_assert_queue_fail`）。
- **通知**：`notificationAuthorized`（get async）与 `requestNotification()`(:423) 走 `UNUserNotificationCenter` 独立通道（不写 PermissionConfig）。
- 状态落 `PermissionConfig`（`Models/MountPermissionModels.swift:25`），被 `miniclaw_config` 的 `permissions` 域读写；注释记录了已删除的假状态字段（bluetooth/nfc/camera/notifications）。

### 5.2 挂载权限

- `MountPoint`（`Models/MountPermissionModels.swift:3`）：`isWritable` **默认 false = 只读**（字段由 `isReadOnly` 更名，语义更清晰且默认值对老数据同样安全）；`bookmark` 为 security-scoped bookmark，跨重启保留对外部文件夹的访问授权。
- 执行门禁在 `FileSystemManager.validateWrite`(:1079-1083)：`actor == .agent` 且 URL 落在某个挂载内时，`mount.isWritable == false` 直接抛 `FileError.mountReadOnly(mount.name)`；挂载外则走 shared/skills/会话独享目录白名单。
- 提示词同步说明：`SystemPrompt:133-152` 注入「已挂载的外部文件夹」段，逐条标注「可写 / 只读」，并说明只读写入会被拒绝、需去「设置 → 挂载」开启「允许写入」。
- `MountStore` 只负责挂载信息与镜像；挂载内写入的「权限不足 → 镜像目录建好却永远为空」是注释记录过的坑（`MountStore.swift:252`）。

### 5.3 工具确认（声明层 + 运行时层）

1. **静态声明 `ResumePolicy`**（`Services/ToolProtocol.swift:10`）：`retryable / queryBeforeRetry / requiresUserConfirmation / neverRetry`。文件头注释明确：**v1 只在安全点暂停**（流式回合结束或某工具执行完），恢复从检查点重放、不会在工具执行中途重试，所以该策略**在 v1 仅作元数据**，供 v2 的「执行中途暂停/自动重试」使用。实际取值举例：内置只读工具默认 `.retryable`；`DeclarativeShellTool` 与默认 `MemoryWriteTool` 为 `.requiresUserConfirmation`；`RemoteMCPTool` 为 `.neverRetry`。
2. **运行时全局阀门** `defaults.confirmBeforeToolCall`（`AppSettingsModels.swift:35`，**默认 false**）+ `ToolConfirmationBridge`（`Services/ToolConfirmationBridge.swift`）：`AgentLoopEngine.executeTool`(:1948-1976) 在参数解析后、真正执行前，条件 `!isSubagentEngine && confirmEnabled && !autoApproved` 时调 `ToolConfirmationBridge.request(toolName:summary:sessionID:sessionTitle:)`。桥的特性：
   - 待确认项以 **`sessionID` 为键**分槽（`slots`），全局弹窗挂在根视图，跨会话不互相覆盖，按 `item.id` 精确恢复；
   - 用户 5 分钟不响应自动拒绝（`timeoutTask`），保证调用方必有终态；
   - 「允许本次会话」→ `sessionAutoApproved` 集合，该会话后续工具不再弹；`revokeSession` 在会话删除时清理；`cancelAll` 用于进后台；
   - **确认开启时并发工具调用强制退化为串行**（`executeToolsConcurrently` :1820-1834），避免多个待确认项抢占单一确认槽；
   - 后台引擎（复盘分身、子代理，`isSubagentEngine == true`）**不弹确认框**（随机 UUID 会话无人归因，会永久挂起）。
   - `summary` 来自 `operationSummary(toolName:arguments:)`，只给人类可读摘要、不含完整命令。
3. **配置写权限** `PermissionConfig.miniclawConfigWrite`（默认 **false**）→ `Tools/ConfigTool.swift:52 writeAllowed()`；`set`/`add` 被拒时返回「写操作被权限拒绝」，`audit-revert` 不受此开关限制（按 id 回滚）。读侧掩码：`isSensitive`(:305) 命中 `apikey/secret/token` 时返回「受保护不可读」，`maskSensitive`(:310) 递归掩码。
4. **插件安装确认** `defaults.aiPluginInstallRequiresConfirmation`（默认 **true**）→ `PluginTool.install`(:88) 弹窗；拒绝后文档要求 AI 不要重试。
5. **记忆写入权限**：无独立开关，只有记忆总开关 `memory.isEnabled`（同时是记忆工具包的启用态，§1.7）。
6. **健康数据写入** `defaults.healthWriteEnabled`（默认 false，`AppSettingsModels.swift:39`）守卫 `apple-healthkit` 的 write/delete。

---

## 6. 当前架构状态与已知待办

### 6.1 已落地（对照 `Doc/MiniClaw_插件化架构重做_构思报告_2026-08-26.md`）

- 统一 `.mpk` + **强制 `plugin.json`**（§二·2.2、§九·1）；无旧兼容扫描路径。
- 统一沙盒布局 `plugins/<type>/<id>/`，旧 `skills/`、`subagent-profiles/`、`rules/` 根目录**整树清退**（未上架不做迁移）。
- 8 类实装：skill / subagent / rule / soul / tool / mcp / model / theme；生效语义与 §十三 表基本一致。
- 内置包启动同步（先删后拷 + `.bundled-manifest.json` + 移除清理 + 缓存失效）；用户导入默认关闭；同 id 版本升级/降级拒绝；内置不可覆盖。
- 记忆工具包与「设置-记忆-启用记忆」**单一真相源**；首启同步未完成时内置工具全量兜底。
- 工具双后端（`shell` 声明式 + `builtin` 内置登记）、参数经 stdin、重名拒绝注册（插件路径）、隐私掩码/offload/进度上报与内置同口径。
- `plugin-creator` 技能（v1.6.0）作为「AI 自主装插件」的元技能 + `miniclaw_plugin` 工具闭环。

### 6.2 文档与代码的偏差（实测）

| 文档处 | 文档说 | 代码实况 |
|---|---|---|
| 构思报告 §一/§六 | `tool.whitelist`、`fragment(fs/env/memory)`、`agent-mode`、`shell-tool`、`core.extension` | **均未实装**（`pluginIcon` 里保留了这些 category 的图标映射，只是兜底映射，非功能） |
| 构思报告 §四 | `models.json` 协议、内置 `com.miniclaw.builtin.models` 三族能力声明 | 实际内置 model 包是 `com.miniclaw.builtin.apigateway`，只有 `providers.json` 两条模板；能力数据改由插件 `providers.json` 的 `models` 数组承载（`plugin-creator/SKILL.md` §model 为准），**无** `models.json` |
| 构思报告 §六 | 内置 rules 拆 4 包（global/about/protocol/privacy）、内置 tool 拆 11 包 | 实际是**单一** `com.miniclaw.builtin.rules`（仅 `zh-Hans/GLOBAL.md`）+ 单一 `com.miniclaw.builtin.tools`（22 项）；`Resources/BundledRules/` 已空；关于/协议/隐私仍在 `Resources/AboutDocs/` 作为展示文档，未插件化 |
| 构思报告 §十一·A/B/C/D | `plugin.json` 加 `seams`、prompt 段 `sectionName`+`order`、`tools.guard` seam（approval/sandbox/timeout 三插件）、内置/用户分层 patch | **全未实现**：`PluginManifest` 无 `seams/order/sectionName` 字段；`buildSystemPrompt` 段顺序硬编码；审批/沙箱/超时仍在引擎与工具内部 |
| 构思报告 §七 | 安装时静态扫描，含原生二进制即拒绝 | **无任何二进制/头扫描**代码（`SkillManager.importSkillFile`、`syncBundledPlugins`、`ZipArchive` 只做 zip-slip 与 inflate 防护） |
| 构思报告 §二·2.5 步骤 3 / §七·3 | 校验 `minCoreVersion`、`dependsOn`、`conflictsWith` 仲裁 | `PluginManifest` 声明了这三个字段，但**全库零消费**（grep 仅命中定义文件）⇒ 依赖与冲突仲裁未落地 |
| 构思报告 §五 | 内置 2 技能 `skill-creator` / `code-reviewer` | 实际只有 `plugin-creator`（v1.6.0）；`code-reviewer` 不在 BundledPlugins |
| 开发指南 §3.3/§3.4 | 包内脚本不可达等限制 | 与 `plugin-creator/SKILL.md` 一致，属**当前有效**限制（非偏差），已写入 §3.6 |

### 6.3 代码级风险 / 待办（本次实读发现）

1. **技能启用态口径不一致（可能导致停用技能仍被注入 prompt）**：`SkillManager.enabledSkillMetadata()`(:269) 用 `enabled[fm.name] ?? true`，键取 `SKILL.md` 的 `name`；而 `loadSkills`(:68) 用 `enabled[manifest.name] ?? (内置 ? enabledByDefault : false)`。对「导入且用户从未手动开关」的技能，前者判为**启用**、后者判为**停用** ⇒ 该技能元数据仍会进入 system 稳定段（并可能以 `fm.name` 与列表名不一致的方式）。同时 `skillBody(named:)`(:330) 遍历 `skillDirectories()` 时**不校验启用态**，`skill_load` 可以加载已停用技能的正文。
2. **`skillBodyCache` 无失效路径**：`invalidateSkillsCache()`(:32) 只清 `skillsCache`；`skillBodyCache`(:280) 只在读/写处出现，全库无清除调用 ⇒ 插件原地升级（`updateSkill`/`importSkillFile` 覆盖目录）后，本进程内 `skill_load` 仍可能返回**旧正文**，直到 App 重启。
3. **索引对 embedding 模型更换无维度校验**：`.cache/embeddings/index.json` 只存 `mtimes/chunks/vectors`，无模型名/维度/版本字段；mtime 未变时不会重建，若用户改了 `embeddingModel`，旧 vectors 与新 query vector 维度不同 → `cosine` 的 `a.count == b.count` guard 直接返回 0 → 向量分全 0、`embeddingAvailable` 仍为 true，**静默退化为纯 FTS**（不会报错、不会重建）。
4. **第三方工具能力面窄**：只有 `shell` 后端（builtin 白名单硬编码在 `ToolPluginManager.builtinFactories` :178，文档明确「仅供内置包」）；加上「包内脚本不可达」，实际能做的只是「沙箱内一行流命令」，复杂工具必须依赖 `apk add` 或让 AI 先落盘脚本。
5. **依赖/冲突/最低版本未校验**（同 §6.2）：字段存在但无实现，第三方插件若声明了 `dependsOn` 会被静默忽略。
6. **MCP 工具注册无重名拒绝**：`AgentRunService.registerRemoteMCPTools`(:112) 直接 `tools.forEach(toolRouter.register)`，而 `ToolRouter.register`(:163) 是**覆盖**语义；插件工具路径有 `toolRouter.contains` 检查（:62）而 MCP 路径没有。名字带 `mcp__` 前缀使冲突面很小，但两路径口径不对称。
7. **发现缓存失效不完整**：`MCPToolDiscoveryCache.invalidate(serverId:)`(:98) 只清 `entries`，**不清 `failures`** ⇒ 一个刚失败过的 server 即使配置被改（upsert / 换 token / 重新启用），60s 内仍会被失败负缓存快速跳过，表现为「改了配置仍不生效」。
8. **`MemoryIndexer`/`MemoryConsolidator` 的模型调用无重试与可观测重试次数**：一致性可接受（失败即降级），但整理是长耗时后台任务，用户侧只能从日志（category "Memory"）与 `Report.rewriteRejected` 判断。
9. **`memory_write` 的确认语义名不副实**：`resumePolicy = .requiresUserConfirmation` 在 v1 不生效；实际拦截面是全局 `confirmBeforeToolCall`（默认关），而复盘分身以 `isSubagentEngine` 绕过。若产品期望「长期记忆写入必须用户确认」，当前实现不满足。
10. **i18n 硬编码（审计已记）**：`Models/MountPermissionModels.swift:43-46` 的 `PermissionState.rawValue` 为中文（`未授权/已授权/已拒绝/受限`，当前仅供持久化兼容，`label` 属性已走查表），审计 `audit-2026-09-07.md` §五把它列为用户可见硬编码之一。

### 6.4 从审计 / 清洗 / 上架计划提炼的结论

- **`MiniClaw/docs/audit-2026-09-07.md`（上架前漏洞审计）**：结论表 14 项 + 3 项证伪，**无 P0**；P1 三项为 `list_dir` 沙盒逃逸（`resolvePath` 宽松版放行任意绝对路径，契约声明只允许 `/var/MiniClaw/`）、设置-后台页死键、`NetService.resolve` 主路径恒失效。与本报告范围相关的仅：`MountPermissionModels.swift` 的权限 UI 硬编码中文（§五）；以及一条**全局方法论**——「源码分两棵：`MiniClaw/MiniClaw/`（App）与 `MiniClaw/MiniClawKit/`（渲染核心），任何全库扫描必须同时覆盖，否则整棵漏检」（§七 末）。
- **`MiniClaw/docs/cleanup-report-2026-09-13.md`（系统性清洗）**：两轮共删 696 行代码 + 876 KB 资源（KaTeX 死链、重复实现收敛、休眠渲染栈 3 文件 576 行）；结论与记忆/技能/插件/MCP 无直接交集。可复用的两条纪律：① **shell grep 不可信**（BSD grep 对 `\|`、`\b` 静默返回空，本轮又踩 3 次）——一律用 ripgrep/Grep 工具并加第二证据；② 子代理会「臆造文件并互相背书」，删除类结论必须由执行者亲自验证文件存在性。其 §7 留下的全局待办：`DEBUG` 编译条件从未定义（`SWIFT_ACTIVE_COMPILATION_CONDITIONS` 只有 `ISH_ENABLED`，43 处 `#if DEBUG`、约 547 行从未参与编译）；5 个「已实现但零入口」的设置/搜索页（疑产品 bug）；`第三方源码/` 53 MB 入库需确认 `.gitignore`。
- **`MiniClaw/docs/plans/scene-17-launch/plan.md`（上架计划）**：与本范围相关的风险项——R1「权限用途描述与实际功能相符」中 HealthKit 读/写链路（`Tools/HealthKitTools.swift` + `PermissionManager`）已闭环；R3「Required Reason API」中 `FileTimestamp`（`C617.1`）的合规依据正来自 `MemoryIndexer` 等 10+ 处 `.contentModificationDateKey` 使用；R4 后台模式真实性已闭环，而 `MemoryConsolidator` 的 `BGProcessingTask` 正是 `UIBackgroundModes: processing` 的能力支撑之一。

### 6.5 一句话状态判断

记忆与技能两条链路是**完整可用的生产实现**（写入门禁、降级重试、复盘限额、整理四阶段与备份纪律都到位，问题集中在启用态口径、缓存失效、embedding 换模型这三处工程细节）；插件化底座**只落地了「声明式内容分发 + 启停」**，架构报告里真正让它成为「可插拔体系」的部分（seam 注册、prompt 段契约、guard 插件、依赖仲裁、安装静态扫描、第三方原生/记忆后端扩展点）**全部尚未实现**；MCP 是本范围内完成度最高、工程细节最扎实的一块（HTTP/legacy SSE/stdio 三传输 + OAuth 2.1 全套 + 发现缓存与性能加固）；权限则是「iOS 系统权限、挂载写权限、工具确认、配置/健康写开关」四套并行机制，其中工具确认声明层（`ResumePolicy`）在 v1 只是元数据，真正生效的只有全局 `confirmBeforeToolCall`。
