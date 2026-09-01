import Foundation
import SwiftUI

/// AgentRunService 的 system prompt 构建职责（2026-08 拆分：按职责分文件，语义不变）。
extension AgentRunService {

    func buildSystemPrompt(with toolRouter: ToolRouter, extraSkillName: String? = nil, sessionID: UUID) async -> (stable: String, volatile: String) {
        // 危机标记而非普通 info：本函数曾是主线程同步 IO 的重灾区，
        // 一旦再次卡死，看门狗报告首屏能直接指出「最后执行点：PROMPT BUILD ENTER」。
        AppLogger.shared.crisisMark("PROMPT BUILD ENTER")
        defer { AppLogger.shared.crisisMark("PROMPT BUILD DONE") }
        let fs = FileSystemManager.shared
        // bundle 规则/技能/角色样例同步已移后台(线程治理 P0)：
        // 首轮 prompt 构建前等同步完成，避免读到空/旧版规则目录。
        await fs.waitForBundledSync()
        var stableParts: [String] = []      // 稳定段：置于前缀，进入 KV 缓存
        var volatileParts: [String] = []    // 易变段：置于末尾，不参与前缀匹配

        // 1. 人格定义（SOUL.md 全部内容，保证在灵魂里修改后能完全生效）；异步读，不阻塞主线程。
        if let raw = await readText(fs.memoryDir.appendingPathComponent("SOUL.md")),
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stableParts.append(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // 2. 项目规则（rule 插件：启用过滤 + 按当前语言取用）；逐文件异步读取，避免主线程同步 IO。
        // 启用状态主线程快照（SettingsStore 后台裸读竞态防护，2026-08-14 崩溃修复同款约束）。
        let ruleEnabledStates = await MainActor.run { SettingsStore.shared.settings.skillEnabledStates }
        let ruleBuiltinIds = FileSystemManager.shared.bundledPluginIds()
        let ruleURLs = fs.ruleMarkdownFiles(enabledStates: ruleEnabledStates, builtinIds: ruleBuiltinIds)
        var ruleSections: [String] = []
        for fileURL in ruleURLs {
            guard let raw = await readText(fileURL),
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let relativePath = fileURL.path.replacingOccurrences(
                of: fs.rulesDir.path + "/",
                with: ""
            )
            ruleSections.append(String(format: L10n.l("agent_rules_file_inject"), relativePath, raw.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        if !ruleSections.isEmpty {
            stableParts.append(L10n.l("project_rules_header") + ruleSections.joined(separator: "\n\n"))
        }

        // 2.5 已启用技能（渐进式加载：仅常驻 name + description 元数据；正文由 skill_load 工具按需加载）
        let skillMeta = await SkillManager.shared.enabledSkillMetadata()
        if !skillMeta.isEmpty {
            stableParts.append(L10n.l("enabled_skills_header") + skillMeta + L10n.l("skills_hint_load"))
        }

        // 2.6 本次一次性强制使用的技能（/技能名 触发）：无论该技能是否启用，都临时注入其正文，
        // 让 智能体在本轮直接按该技能执行。注意：放在「已启用技能」之后，优先级更高。
        if let name = extraSkillName, let body = await SkillManager.shared.skillBody(named: name),
           !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stableParts.append("""
            ## 本轮强制使用的技能：\(name)
            下面是用户通过「/\(name)」指令要求本轮必须使用的技能正文。请严格遵循其指令完成本次任务，\
            并在需要时引用同目录下的 references/、scripts/、assets/ 等。
            \(body)
            """)
        }

        // 3. 工具能力描述
        stableParts.append("""
        ## 工具系统
        你有完整的工具系统，包括文件读写、浏览器、Apple 原生框架（日历/提醒/剪贴板/设备信息/语音/NLP等）、配置管理、会话管理等。每个工具都有明确的 name 和 parameters schema，在需要时直接调用。

        ⚠️ **工具调用铁律（必须遵守）：**
        - 你**只能**调用「可用工具」列表中明确列出的工具名（见下方 ## 可用工具），绝对禁止编造、猜测或使用列表中不存在的任何工具名。
        - 如果需要的功能不在已有工具范围内，用文字回答用户并说明限制，不要尝试调用不存在的工具。
        - 每次调用前必须核对工具名是否在列表中。常见错误示例：不要调用 `查询今日科技新闻` / `web_search` / `联网搜索` 等不存在的工具——这些都不在你的工具列表中。

        执行约束：
        - 所有文件路径必须是 `/var/MiniClaw/...` 绝对路径；拒绝目录穿越和二进制文本读取
        - 创建/覆写文件用 `file_write`；修改已有文件用 `file_edit`
        - 也可用 shell 命令（echo / heredoc / printf 重定向）写文件；含转义字符或多行内容建议优先用 `file_write` 以避免 BusyBox ash 转义差异
        - Agent 可写 attachments/workspace/shared/skills；offloads 仅 shell 自动写，browser 仅浏览器自动写
        - rules（含 rules/GLOBAL.md）为 App 托管的只读规则目录；memory/MEMORY.md 与每日记忆可由 memory_write 读写；SOUL.md 仅 Settings 可写；mounts 对 Agent 只读
        - 工具调用超时 120 秒
        - 最多 50 轮工具循环，防止无限循环
        """)

        // 4. 文件系统布局
        stableParts.append("""
        ## 文件系统（/var/MiniClaw/）
        ```
        /var/MiniClaw/
        ├── attachments/    图片/音频/视频附件 (png/jpg/gif/webp/mp3/m4a/wav/mp4/mov/m4v)
        ├── workspace/      临时工作区
        ├── shared/         共享数据
        ├── offloads/       大文件转存 (shell_execute 输出超阈值时)
        ├── browser/        浏览器截图 (screenshot_<ts>.jpg)
        ├── memory/         记忆系统
        │   ├── SOUL.md     人设定义
        │   ├── MEMORY.md   长期记忆（用户与 AI 可读写）
        │   └── YYYY-MM-DD.md  每日记忆
        ├── rules/          自动注入的项目规则 (Markdown，App 托管只读)
        │   └── GLOBAL.md   全局规则
        ├── skills/         技能（技能格式 格式：每个技能一个子目录，含 SKILL.md）
        │   └── <skill-name>/
        │       ├── SKILL.md       必需：frontmatter(name/description) + 指令正文
        │       ├── scripts/       可选：可执行脚本
        │       ├── references/    可选：按需加载的参考文档
        │       ├── assets/        可选：模板/资源
        │       └── evals/         可选：evals/evals.json 测试用例
        └── mounts/         外部挂载（默认只读，可在「设置 → 挂载」开启允许写入）
        ```

        目录写入策略：
        - attachments/、workspace/、offloads/、browser/ 为**当前会话独享**（每个会话独立命名空间，互不可见）；Agent 的 file_write/file_edit/file_read/list_dir/apple-image 与 Shell 命令均落在本会话目录下
        - shared/：Agent file_write、Shell 可写；跨会话共享、持久
        - offloads/：仅 Shell 自动写；可清理
        - browser/：仅浏览器截图/下载自动写；可清理
        - memory/SOUL.md：仅 Settings 可写；永久
        - memory/MEMORY.md：长期记忆；用户可编辑，AI 仅通过 memory_write 读写；永久
        - memory/YYYY-MM-DD.md：每日记忆；仅 memory_write 追加；永久
        - rules/（含 GLOBAL.md）：App 启动时从 Bundle 同步；自动注入；Agent 只读
        - skills/：每个子目录是一个技能（技能格式 格式），含 SKILL.md（frontmatter name/description）；Agent file_write、Shell 可写；启用后正文自动注入 prompt；永久
        - mounts/：Agent 只读（除非在「设置 → 挂载」中开启该文件夹的「允许写入」）；跟随系统挂载；写入经软件自带文件管理系统落盘到外部真实文件夹
        """)

        stableParts.append("""
        ## miniclaw:// 内部链接
        - `miniclaw://attachments/...`、`workspace/...`、`shared/...`、`browser/...`、`offloads/...`、`memory/...`、`rules/...` 映射到对应本地文件
        - `miniclaw://settings/<path>` 跳转设置；`miniclaw://open_terminal?init_command=...` 打开终端
        - 非 ASCII 路径必须百分号编码；路径含空格时也必须百分号编码（空格→%20）
        - `miniclaw://` 不可传入 browser 工具
        - **向用户展示文件/媒体**：必须使用「独占一行」的图片语法（以 `!` 开头），前端会自动内联渲染并支持点击预览；普通链接 `[文件名](miniclaw://...)` 不会被内联渲染，仅作可点击链接：
          - 图片：`![](miniclaw://browser/截图.png)`
          - 视频：`![](miniclaw://browser/视频.mp4)`
          - 音频：`![](miniclaw://browser/语音.m4a)`
          - 文档（pdf/word/excel/ppt/代码等）：`![](miniclaw://shared/报告.pdf)`
        - 仅当希望用户点击后跳转到文档查看器时才用普通链接 `[文件名](miniclaw://...)`；不要把媒体/文件写成普通链接，否则用户看不到内容。
        """)

        stableParts.append("""
        ## 文件搜索策略
        按以下顺序搜索用户文件：
        1. `/var/MiniClaw/attachments/` 与 `/var/MiniClaw/workspace/`
        2. `/var/MiniClaw/shared/`
        3. `/var/MiniClaw/mounts/*/`
        4. 不扫描 iSH 的 `/etc`、`/usr` 等系统目录
        通过 `shell_execute` 递归搜索使用 `find /var/MiniClaw/... -name '*.ext'`，不要使用 BusyBox ash 不支持的 globstar `**`。
        """)

        // 5. 可用工具列表 —— 已移至下方 volatile 段:会话中 MCP 服务器可能增减工具,
        // 留在稳定前缀会导致工具变化时整段缓存失效;移到 volatile 后工具清单每轮更新
        // 但不触碰前缀(工具 schema 本身经 tools: 参数权威下发)。

        // 6. 环境变量 —— 已移至下方 volatile 段:设置页修改 envVars/隐私模式不破坏前缀。

        // 7. 内存系统（i18n：整段走 L10n）
        stableParts.append(L10n.l("memory_system_section"))

        // 8. 子代理使用指南（stable：角色列表与角色文件同频，属稳定内容，进缓存前缀）
        stableParts.append(SubAgentGuide.guideWithProfiles())
        // 记忆内容会随会话复盘被 memory_write 改写，属于「易变内容」，若留在稳定前缀会导致
        // 每次记忆更新后整段缓存失效、命中率归零，故必须放在断点之后。

        // === 易变段开始：以下内容置于 system prompt 末尾，避免污染 KV 缓存前缀 ===

        // 3.5 可用工具列表(会话中 MCP 工具可增减,每轮更新;schema 权威在 tools: 参数)
        // 追加引擎保留工具 dispatch_subagent：它由引擎拦截执行（不在 toolRouter 注册表），
        // 但必须出现在白名单里，否则「列表外禁止调用」铁律会让模型判定该工具不可用（子代理从不触发的根因）。
        var toolNames = toolRouter.allToolNames()
        toolNames.append("dispatch_subagent")
        toolNames.append("close_subagent")
        toolNames.sort()
        // 3.4.5 当前会话的子代理清单（A 方案：让 智能体每轮「看见」可复用/可关闭的子代理）。
        // 数据来自 SubagentRuntimeRegistry（跨轮次/跨重启存活）；无子代理时不注入。
        // 属易变内容（随子代理增删变化），放缓存断点之后，不进前缀。
        let liveSubagentRecords = SubagentRuntimeRegistry.shared.allRecords(for: sessionID)
        if let liveSection = SubAgentGuide.liveSubagentsSection(records: liveSubagentRecords) {
            volatileParts.append(liveSection)
        }
        volatileParts.append("""
        ## 可用工具 (\(toolNames.count) 个) — 完整列表如下，仅可调用此处列出的工具名
        \(toolNames.map { "- `\($0)`" }.joined(separator: "\n"))

        **再次强调：** 上方列表是你唯一可用的工具。没有「搜索」「新闻」「联网」「查询」等通用工具。如需浏览网页请用 `browser` 工具；如需执行命令请用 `shell_execute`；其他需求请用文字回答。
        """)

        // 3.5.1 环境变量(设置页可改,不进前缀)
        let privacyMode = SettingsStore.shared.settings.envvarsPrivacyMode
        let envVars = SettingsStore.shared.settings.envvars
        var envSection = L10n.l("env_vars_header")
        if envVars.isEmpty {
            envSection += L10n.l("no_env_vars_header")
        } else {
            envSection += L10n.l("env_vars_available")
            for v in envVars where !v.key.isEmpty {
                envSection += "- `\(v.key)`\n"
            }
        }
        envSection += String(format: L10n.l("prompt_privacy_mode_label"), privacyMode ? L10n.l("enable_mask_label") : L10n.l("close"))
        volatileParts.append(envSection)

        // 3.6 已挂载的外部文件夹（动态注入，让 智能体知道具体可访问的挂载名与路径）
        let mounted = MountStore.shared.list().filter { $0.isMounted }
        if !mounted.isEmpty {
            let mountLines = mounted.map { "  - `\($0.path)/`（\($0.isWritable ? L10n.l("prompt_mount_writable") : L10n.l("prompt_mount_readonly"))）" }.joined(separator: "\n")
            let firstPath = mounted.first!.path
            volatileParts.append("""
            ## 已挂载的外部文件夹
            以下文件夹是用户在「设置 → 挂载」中挂载的外部目录，可通过文件系统工具（`list_dir` / `file_read` / `file_write` / `file_edit`）或 `shell_execute` 两种方式访问：
            \(mountLines)

            读取挂载内容的方式：
            1. 若想知道当前挂载了哪些外部文件夹，先 `list_dir` 路径 `/var/MiniClaw/mounts/`，会返回挂载名列表；
            2. 再用 `list_dir`，path 设为某个挂载目录，例如 `\(firstPath)/`，查看里面有哪些文件；
            3. 读取具体文件用 `file_read`，path 设为 `/var/MiniClaw/mounts/<name>/<子路径>`。

            写入挂载内容：
            - 标注「可写」的挂载可用 `file_write` / `file_edit` 把内容写到外部真实文件夹（真实落盘，不是拷贝）；
            - 标注「只读」的挂载写入会被拒绝并提示「该挂载为只读」；如需写入请在「设置 → 挂载」开启该文件夹的「允许写入」开关。
            """)
        }

        // 9.5 其它会话最近要点（跨对话近况摘要）：受「记忆开关」守卫，置于 volatile 段以免污染 KV 缓存前缀
        if let crossSection = crossSessionSummarySection(excluding: sessionID) {
            volatileParts.append(crossSection)
        }

        // 8. 长期记忆 + 9. 近期记忆（受「记忆开关」守卫；关闭时不注入）。
        // 记忆内容会随会话复盘被 memory_write 改写，属于「易变内容」，必须放在 volatile 段
        // （缓存断点之后），否则每次记忆更新都会让稳定前缀失效、缓存命中率归零。
        if SettingsStore.shared.settings.memory.isEnabled {
            if let longTermSection = await longTermMemorySection(fs: fs, sessionID: sessionID) {
                volatileParts.append(longTermSection)
            }

            // 9. 近期记忆（今日 + 昨日）；getRecentMemory 内部同步读 2 个文件，卸载到后台执行避免主线程阻塞。
            let recentMemory = await Task.detached(priority: .userInitiated) { MemoryManager.shared.getRecentMemory(days: 2) }.value
            if !recentMemory.isEmpty {
                volatileParts.append(String(format: L10n.l("agent_recent_memory_inject"), recentMemory))
            }
        }

        // 每条新用户消息生成一次；不自动注入设备名称、标识、电量等非必要信息。
        // 时间戳最易变，必须放在 system prompt 最末尾（volatile 段），让前面的稳定段能够命中缓存。
        volatileParts.append(currentEnvironmentPromptSection())

        return (
            stable: stableParts.joined(separator: "\n\n"),
            volatile: volatileParts.joined(separator: "\n\n")
        )
    }

    /// 长期记忆注入段：向量检索可用时注入相关片段（省 词元），否则全文兜底（现状行为）。
    /// - 检索 query 用「当前会话最新一条用户消息」：它最贴近用户此刻意图，比多句拼接更稳定
    ///   （拼接会引入历史噪音，embedding 对长 query 的召回精度反而下降），成本也最低。
    /// - 注入片段时附「完整记忆可用 memory_get 查询」，缓解「模型看不到未召回全文」的副作用。
    /// - 检索无命中时回落全文：不注入会让模型完全失去长期记忆，属功能退化。
    private func longTermMemorySection(fs: FileSystemManager, sessionID: UUID) async -> String? {
        // 向量检索可用（用户开了向量开关 + embedding 端点探测成功）→ 片段注入
        if SettingsStore.shared.settings.memory.embeddingEnabled,
           await MemoryIndexer.shared.isEmbeddingAvailable() {
            let query = latestUserMessageText(sessionID: sessionID) ?? ""
            if !query.isEmpty {
                let fragments = await MemoryIndexer.shared.search(keyword: query, scope: .longTerm, topK: 8)
                if !fragments.isEmpty {
                    return L10n.l("long_term_memory_fragments")
                        + fragments.joined(separator: "\n\n")
                        + L10n.l("agent_memory_get_hint")
                }
            }
            // 检索无命中 → 回落全文兜底
        }
        // 全文注入（默认路径 / 兜底路径）
        if let memory = await readText(fs.memoryDir.appendingPathComponent("MEMORY.md")),
           !memory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           memory.trimmingCharacters(in: .whitespacesAndNewlines) != FileSystemManager.defaultMemoryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines) {
            return String(format: L10n.l("agent_long_term_memory_inject"), memory.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    /// 当前会话最新一条用户消息文本（检索 query 用）；无用户消息时返回 nil。
    private func latestUserMessageText(sessionID: UUID) -> String? {
        guard let session = SessionManager.shared.session(id: sessionID) else { return nil }
        guard let text = session.messages.last(where: { $0.role == .user })?.content else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 其它会话最近要点（跨对话近况摘要）：受「启用记忆」总开关守卫，置于 volatile 段。
    func crossSessionSummarySection(excluding sessionID: UUID) -> String? {
        guard SettingsStore.shared.settings.memory.isEnabled else { return nil }
        let others = SessionManager.shared.allSessions()
            .filter { $0.id != sessionID }
            .compactMap { s -> (String, Date)? in
                guard let sum = s.summary, !sum.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return (sum, s.updatedAt)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
        guard !others.isEmpty else { return nil }
        return L10n.l("other_sessions_recent_points") + others.map { "- \($0.0)" }.joined(separator: "\n")
    }

// MARK: - 环境快照（Step C：自 ChatView 迁入）

    /// 为本轮对话生成一次隐私最小化的本机环境快照。

// MARK: - 环境快照（Step C：自 ChatView 迁入）

    func currentEnvironmentPromptSection(now: Date = Date()) -> String {
        let timeZone = TimeZone.autoupdatingCurrent
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = timeZone
        let locale = Locale.autoupdatingCurrent

        let localFormatter = DateFormatter()
        localFormatter.calendar = calendar
        localFormatter.locale = locale
        localFormatter.timeZone = timeZone
        localFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let weekdayFormatter = DateFormatter()
        weekdayFormatter.calendar = calendar
        weekdayFormatter.locale = locale
        weekdayFormatter.timeZone = timeZone
        weekdayFormatter.dateFormat = "EEEE"

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.timeZone = timeZone
        isoFormatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]

        let offsetSeconds = timeZone.secondsFromGMT(for: now)
        let offsetSign = offsetSeconds >= 0 ? "+" : "-"
        let absoluteOffset = abs(offsetSeconds)
        let offsetHours = absoluteOffset / 3_600
        let offsetMinutes = (absoluteOffset % 3_600) / 60
        let utcOffset = String(format: "%@%02d:%02d", offsetSign, offsetHours, offsetMinutes)

        let languageCode = locale.language.languageCode?.identifier ?? L10n.l("unknown")
        let regionCode = locale.region?.identifier ?? L10n.l("unknown")
        let calendarIdentifier = String(describing: calendar.identifier)

        return """
        ## 当前运行环境
        - 当前本地时间：\(localFormatter.string(from: now))
        - ISO 8601 时间：\(isoFormatter.string(from: now))
        - 当前时区：\(timeZone.identifier)（UTC\(utcOffset)）
        - 当前星期：\(weekdayFormatter.string(from: now))
        - 系统语言与地区：\(languageCode)-\(regionCode)
        - 日历系统：\(calendarIdentifier)

        涉及“今天、明天、昨天、现在、稍后”等相对日期或时间时，必须以上述本地时间和时区为准。该信息是本轮开始时的设备环境快照；如需在长时间工具执行后确认精确到秒的最新时间，应重新获取可靠时间信息。
        """
    }

    // MARK: - 启动一轮回复（服务层派发核心：ChatView.startAgentResponse 后半段迁入）

    /// 从会话设置构造采样配置：新建回复与恢复路径共用，保证采样参数同源。
    func samplingConfig() -> SamplingConfig {
        let sessionSettings = SettingsStore.shared.settings.session
        return SamplingConfig(
            topP: sessionSettings.topP,
            frequencyPenalty: sessionSettings.frequencyPenalty,
            presencePenalty: sessionSettings.presencePenalty,
            seed: sessionSettings.seed,
            parallelToolCalls: sessionSettings.parallelToolCalls,
            responseFormat: sessionSettings.responseFormat == "text" ? nil : ResponseFormat(type: sessionSettings.responseFormat)
        )
    }
}
