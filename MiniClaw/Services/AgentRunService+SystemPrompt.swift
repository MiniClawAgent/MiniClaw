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

        // 0. 共享前缀（L0）：必须与所有子代理**逐字节一致**且位于最前，
        // 否则主代理与子代理、子代理彼此之间的 KV 缓存前缀无法复用
        // （真机实测：3 个并行子代理各自冷写 12099 tok、命中 0%）。
        // 内容见 AgentPromptCore —— 只允许放对所有 agent 恒定的段。
        stableParts.append(AgentPromptCore.sharedPrefix)

        // 1. 人格定义（SOUL.md 全部内容，保证在灵魂里修改后能完全生效）；异步读，不阻塞主线程。
        if let raw = await readText(fs.memoryDir.appendingPathComponent("SOUL.md")),
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stableParts.append(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // 2. 项目规则（rule 插件：启用过滤 + 按当前语言取用）；逐文件异步读取，避免主线程同步 IO。
        // 启用状态主线程快照（SettingsStore 后台裸读竞态防护，2026-08-14 崩溃修复同款约束）。
        let ruleEnabledStates = await MainActor.run { SettingsStore.shared.settings.skillEnabledStates }
        // 2026-09-05 主线程治理：bundle 清单读取与规则目录枚举是同步 IO，
        // 移出主线程执行（此前是 PROMPT BUILD 数秒级主线程卡顿的组成部分）。
        let ruleBuiltinIds = await Task.detached(priority: .userInitiated) {
            FileSystemManager.shared.bundledPluginIds()
        }.value
        let ruleURLs = await Task.detached(priority: .userInitiated) {
            fs.ruleMarkdownFiles(enabledStates: ruleEnabledStates, builtinIds: ruleBuiltinIds)
        }.value
        var ruleSections: [String] = []
        for fileURL in ruleURLs {
            guard let raw = await readText(fileURL),
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let relativePath = fileURL.path.replacingOccurrences(
                of: fs.rulesDir.path + "/",
                with: ""
            )
            ruleSections.append(String(format: String(localized: "agent_rules_file_inject"), relativePath, raw.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        if !ruleSections.isEmpty {
            stableParts.append(String(localized: "project_rules_header") + ruleSections.joined(separator: "\n\n"))
        }

        // 2.5 已启用技能（渐进式加载：仅常驻 name + description 元数据；正文由 skill_load 工具按需加载）
        let skillMeta = await SkillManager.shared.enabledSkillMetadata()
        if !skillMeta.isEmpty {
            stableParts.append(String(localized: "enabled_skills_header") + skillMeta + String(localized: "skills_hint_load"))
        }

        // 2.6 本次一次性强制使用的技能（/技能名 触发）：无论该技能是否启用，都临时注入其正文，
        // 让 智能体在本轮直接按该技能执行。
        // [2026-09-15 OpenAI 官方合规·指令不得逐轮变] 原先插在 stableParts **中段**，导致
        // `/技能` 轮与相邻两轮的 stable 从插入点起全部不同（官方 §5 把「Changes to instructions
        // or system prompts」列为低命中原因）。现改为**延迟到 volatile 段尾部注入**（官方 §4.2：
        // 「Move volatile content … to the end」）——stable 从此与 extraSkillName 无关，
        // 可以正常读写会话级缓存；强制技能正文作为「本轮新增的尾巴」出现，不影响任何已有前缀。
        var forcedSkillSection: String? = nil
        if let name = extraSkillName, let body = await SkillManager.shared.skillBody(named: name),
           !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            forcedSkillSection = """
            ## 本轮强制使用的技能：\(name)
            下面是用户通过「/\(name)」指令要求本轮必须使用的技能正文。请严格遵循其指令完成本次任务，\
            并在需要时引用同目录下的 references/、scripts/、assets/ 等。
            \(body)
            """
        }

        // 3./4./5. 文件系统、miniclaw:// 链接、文件搜索、联网搜索策略已迁入
        // AgentPromptCore.sharedPrefix（置于 stable 最前，供主代理与子代理共享缓存前缀）。

        // 5. 可用工具列表 —— 已移至下方 volatile 段:会话中 MCP 服务器可能增减工具,
        // 留在稳定前缀会导致工具变化时整段缓存失效;移到 volatile 后工具清单每轮更新
        // 但不触碰前缀(工具 schema 本身经 tools: 参数权威下发)。

        // 6. 环境变量 —— 已移至下方 volatile 段:设置页修改 envVars/隐私模式不破坏前缀。

        // 7. 内存系统（i18n：整段经 String(localized:) 查 String Catalog）
        stableParts.append(String(localized: "memory_system_section"))

        // 8. 子代理使用指南（stable：角色列表与角色文件同频，属稳定内容，进缓存前缀）
        stableParts.append(SubAgentGuide.guideWithProfiles())
        // 记忆内容会随会话复盘被 memory_write 改写，属于「易变内容」，若留在稳定前缀会导致
        // 每次记忆更新后整段缓存失效、命中率归零，故必须放在断点之后。

        // === 易变段开始：以下内容置于 system prompt 末尾，避免污染 KV 缓存前缀 ===
        //
        // 段内排序判据（2026-09-11）：**变化频率升序**——volatile 整段都位于缓存边界
        // 之后（OpenAI 追加为末尾独立 user 消息 / Anthropic 并入最后一条 user，均在
        // cache_control 断点之后），故内部排序不影响稳定前缀的命中；它只决定「首个
        // 变化点右侧还有多少内容一起 miss」。因此越易变的段必须越靠后：
        //   工具清单(MCP 注册后冻结) → 环境变量/挂载(改设置才变) → 跨会话摘要 →
        //   近期记忆 → 长期记忆 → 环境快照(每小时) → 子代理段(每次派发/关闭都变，收尾)

        // 3.5 可用工具列表(会话中 MCP 工具可增减,每轮更新;schema 权威在 tools: 参数)
        // 追加引擎保留工具 dispatch_subagent/close_subagent：它们由引擎拦截执行，必须出现在
        // 白名单里，否则「列表外禁止调用」铁律会让模型判定该工具不可用（子代理从不触发的根因）。
        // [2026-09-15 去重] 这两个工具现已由 `AgentLoopEngine.init` 幂等注册进 `ToolRouter`
        // ⇒ `allToolNames()` 里**已经包含**它们，原先无条件 append 会让清单出现重复项
        //（真机 reqdump 实证：`close_subagent`/`dispatch_subagent` 各出现两次）。
        // 改为「缺失才补」，两种注册状态都正确。
        var toolNames = toolRouter.allToolNames()
        for engineReserved in ["dispatch_subagent", "close_subagent"] where !toolNames.contains(engineReserved) {
            toolNames.append(engineReserved)
        }
        toolNames.sort()
        volatileParts.append("""
        ## 可用工具 (\(toolNames.count) 个) — 完整列表如下，仅可调用此处列出的工具名
        \(toolNames.map { "- `\($0)`" }.joined(separator: "\n"))

        **再次强调：** 上方列表是你唯一可用的工具，不得编造列表中不存在的工具名。需要联网检索时用 `web_search`（仅当它出现在上方列表）；需要打开/操作具体网页用 `browser`；执行命令用 `shell_execute`；其他需求请用文字回答。
        """)

        // 3.5.1 环境变量(设置页可改,不进前缀)
        let privacyMode = SettingsStore.shared.settings.envvarsPrivacyMode
        let envVars = SettingsStore.shared.settings.envvars
        var envSection = String(localized: "env_vars_header")
        if envVars.isEmpty {
            envSection += String(localized: "no_env_vars_header")
        } else {
            envSection += String(localized: "env_vars_available")
            for v in envVars where !v.key.isEmpty {
                envSection += "- `\(v.key)`\n"
            }
        }
        envSection += String(format: String(localized: "prompt_privacy_mode_label"), privacyMode ? String(localized: "enable_mask_label") : String(localized: "close"))
        volatileParts.append(envSection)

        // 3.6 已挂载的外部文件夹（动态注入，让 智能体知道具体可访问的挂载名与路径）
        let mounted = MountStore.shared.list().filter { $0.isMounted }
        if !mounted.isEmpty {
            let mountLines = mounted.map { "  - `\($0.path)/`（\($0.isWritable ? String(localized: "prompt_mount_writable") : String(localized: "prompt_mount_readonly"))）" }.joined(separator: "\n")
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

        // 8. 近期记忆 + 9. 长期记忆（受「记忆开关」守卫；关闭时不注入）。
        // 记忆内容会随会话复盘被 memory_write 改写，属于「易变内容」，必须放在 volatile 段
        // （缓存断点之后），否则每次记忆更新都会让稳定前缀失效、缓存命中率归零。
        // 段内顺序：**长期记忆靠后**——向量检索开启时其检索 query 取「当前会话最新一条
        // 用户消息」，命中片段每轮都变，且它是 volatile 里体量最大的一段；放在前面会连带
        // 打掉其后的全部段。近期记忆（今日+昨日）变化频率低于它，故置于其前。
        if SettingsStore.shared.settings.memory.isEnabled {
            // 9. 近期记忆（今日 + 昨日）；getRecentMemory 内部同步读 2 个文件，卸载到后台执行避免主线程阻塞。
            let recentMemory = await Task.detached(priority: .userInitiated) { MemoryManager.shared.getRecentMemory(days: 2) }.value
            if !recentMemory.isEmpty {
                volatileParts.append(String(format: String(localized: "agent_recent_memory_inject"), recentMemory))
            }

            if let longTermSection = await longTermMemorySection(fs: fs, sessionID: sessionID) {
                volatileParts.append(longTermSection)
            }
        }

        // 每条新用户消息生成一次；不自动注入设备名称、标识、电量等非必要信息。
        // 时间已改为小时级粒度（见 currentEnvironmentPromptSection），比子代理清单稳定，
        // 故置于子代理段之前（次末位）——不再自称「最末尾」，以免与下方事实不符。
        volatileParts.append(currentEnvironmentPromptSection())

        // 2.6 的强制技能正文：按「变化频率升序」放在易变段靠后位置（紧邻子代理段之前），
        // 既有最强的末尾权重，又不破坏「子代理段恒定收尾 / 铁律作切分点」这条既有不变量。
        if let forcedSkillSection {
            volatileParts.append(forcedSkillSection)
        }

        // 3.4.5 子代理操作铁律 + 当前会话的子代理清单（**成对收尾**：短码就近可读）。
        // 铁律**无条件**注入——它防的是「回复文本里声称已派发/已关闭」的假执行，与是否
        // 有存活子代理无关，故不能跟着清单一起被条件带上。清单来自 SubagentRuntimeRegistry
        // （跨轮次/跨重启存活），无子代理时只注入铁律。
        // 这一段是 volatile 里变化最频繁的（每次 dispatch_subagent / close_subagent 都变），
        // 放最末使变化只损失自身，不打掉前面的记忆/环境段。
        // 铁律文案取自 SubAgentGuide.ironRule —— 它同时是引擎 skill_load 后重排易变段时的
        // 切分点，两侧共用同一常量（此处不得内联复制字面量，否则重排会失步）。
        let liveSubagentRecords = SubagentRuntimeRegistry.shared.allRecords(for: sessionID)
        var subagentTail = SubAgentGuide.ironRule
        if let liveSection = SubAgentGuide.liveSubagentsSection(records: liveSubagentRecords) {
            subagentTail += "\n\n" + liveSection
        }
        volatileParts.append(subagentTail)

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
                    return String(localized: "long_term_memory_fragments")
                        + fragments.joined(separator: "\n\n")
                        + String(localized: "agent_memory_get_hint")
                }
            }
            // 检索无命中 → 回落全文兜底
        }
        // 全文注入（默认路径 / 兜底路径）
        if let memory = await readText(fs.memoryDir.appendingPathComponent("MEMORY.md")),
           !memory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           memory.trimmingCharacters(in: .whitespacesAndNewlines) != FileSystemManager.defaultMemoryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines) {
            return String(format: String(localized: "agent_long_term_memory_inject"), memory.trimmingCharacters(in: .whitespacesAndNewlines))
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
        return String(localized: "other_sessions_recent_points") + others.map { "- \($0.0)" }.joined(separator: "\n")
    }

// MARK: - 环境快照（Step C：自 ChatView 迁入）

    /// 为本轮对话生成一次隐私最小化的本机环境快照。
    ///
    /// [2026-09-11 改为小时级粒度] 时间取整到整点（分钟/秒清零），
    /// 使该段文本在**一小时内逐字节稳定** → KV 缓存前缀照常命中，不再因分钟跳动而断裂。
    /// 代价是时间仅精确到整点——文案中已明确标注，并保留「需要精确时间请另行获取」的指引。
    /// DateFormatter 为静态复用（创建成本高，且 iOS 7+ 线程安全）。

    private static let hourlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:00"
        return f
    }()

    private static let hourlyISOFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return f
    }()

    func currentEnvironmentPromptSection(now: Date = Date()) -> String {
        let timeZone = TimeZone.autoupdatingCurrent
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = timeZone
        let locale = Locale.autoupdatingCurrent

        // [2026-09-11] 取整到整点：分钟/秒清零 → 一小时内该段文本逐字节相同，
        // system prompt 前缀缓存不受时间流逝影响（每轮请求重拼也不破坏命中）。
        let hourlyNow = calendar.dateInterval(of: .hour, for: now)?.start ?? now

        let localFormatter = Self.hourlyFormatter
        localFormatter.timeZone = timeZone
        let isoFormatter = Self.hourlyISOFormatter
        isoFormatter.timeZone = timeZone

        let weekdayFormatter = DateFormatter()
        weekdayFormatter.calendar = calendar
        weekdayFormatter.locale = locale
        weekdayFormatter.timeZone = timeZone
        weekdayFormatter.dateFormat = "EEEE"

        let offsetSeconds = timeZone.secondsFromGMT(for: hourlyNow)
        let offsetSign = offsetSeconds >= 0 ? "+" : "-"
        let absoluteOffset = abs(offsetSeconds)
        let offsetHours = absoluteOffset / 3_600
        let offsetMinutes = (absoluteOffset % 3_600) / 60
        let utcOffset = String(format: "%@%02d:%02d", offsetSign, offsetHours, offsetMinutes)

        let languageCode = locale.language.languageCode?.identifier ?? String(localized: "unknown")
        let regionCode = locale.region?.identifier ?? String(localized: "unknown")
        let calendarIdentifier = String(describing: calendar.identifier)

        // [2026-09-14] 曾按唐唐要求在此加过「工具选择决策优先级」规则（观察模型遵守度），
        // 实测后**已撤回**：规则属"概率性引导"，与可达性探测（1a）无关。细节见
        // `研究报告-搜索引擎选源方案` §4.7。
        return """
        ## 当前运行环境
        - 当前本地时间（小时级近似）：\(localFormatter.string(from: hourlyNow))
        - ISO 8601 时间：\(isoFormatter.string(from: hourlyNow))
        - 当前时区：\(timeZone.identifier)（UTC\(utcOffset)）
        - 当前星期：\(weekdayFormatter.string(from: hourlyNow))
        - 系统语言与地区：\(languageCode)-\(regionCode)
        - 日历系统：\(calendarIdentifier)

        涉及“今天、明天、昨天、现在、稍后”等相对日期或时间时，必须以上述本地时间和时区为准（时间精度为整点）。如需精确到秒的最新时间（如计时、限流窗口判断），必须通过工具或系统接口重新获取，不得沿用本快照时间。
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
