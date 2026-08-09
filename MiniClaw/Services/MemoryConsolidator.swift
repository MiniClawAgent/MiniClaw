import Foundation

/// P2-2：跨会话记忆 consolidation（去重 / 归并 / 压缩）。
///
/// 要解决的问题：`SessionReviewService` 每结束一次会话就往 MEMORY.md 追加要点，
/// 长期运行后长期记忆里会堆出大量语义重复、彼此覆盖的条目，体积膨胀直接吃掉系统提示预算。
///
/// 三段式流水线，任一段失败都能安全降级，绝不凭空丢事实：
/// 1. **精确去重**：按归一化文本剔除完全重复的条目（纯本地、零成本、零风险）。
/// 2. **语义归并**：有 embedding 端点时把条目向量化，余弦相似度 ≥ 阈值的判为同一事实，
///    保留信息量更大（更长）的一条，位置沿用首次出现处。
/// 3. **主题重写**：用后台（副）模型把去重后的条目按主题重排成结构化 MEMORY.md；
///    输出要过体量校验（过短即视为模型截断 / 漏写），不通过就退回第 2 步的结果。
///
/// 另外会把超过 `retentionDays` 的每日日志蒸馏成一段归档摘要并入 MEMORY.md，再删除原文件；
/// 没有可用模型时**不做归档也不删文件**（宁可不整理，也不无损耗地丢日志）。
///
/// 每次改写前把原文备份到 `.cache/memory-backups/`，保留最近 10 份。
final class MemoryConsolidator: @unchecked Sendable {
    static let shared = MemoryConsolidator()

    private let fs = FileSystemManager.shared
    private let gate = RunGate()
    private static let lastRunKey = "memory.consolidation.lastRunAt"
    /// 自动触发的最小间隔，避免每次离开会话都跑一遍。
    private static let cooldown: TimeInterval = 6 * 3600
    /// 归档蒸馏时喂给模型的最大字符数。
    private static let maxArchiveInput = 40_000
    /// 保留的备份份数。
    private static let maxBackups = 10

    // MARK: - 报告

    struct Report: Sendable {
        var didRun = false
        var skippedReason: String?
        var charsBefore = 0
        var charsAfter = 0
        var itemsBefore = 0
        var itemsAfter = 0
        var exactDuplicatesRemoved = 0
        var semanticDuplicatesMerged = 0
        var dailyFilesArchived = 0
        var rewritten = false
        var rewriteRejected = false

        var text: String {
            if let skippedReason { return String(format: L10n.tr("已跳过：%@"), skippedReason) }
            var parts: [String] = []
            parts.append(String(format: L10n.tr("条目 %1$d → %2$d"), itemsBefore, itemsAfter))
            parts.append(String(format: L10n.tr("字符 %1$d → %2$d"), charsBefore, charsAfter))
            if exactDuplicatesRemoved > 0 {
                parts.append(String(format: L10n.tr("精确去重 %d"), exactDuplicatesRemoved))
            }
            if semanticDuplicatesMerged > 0 {
                parts.append(String(format: L10n.tr("语义归并 %d"), semanticDuplicatesMerged))
            }
            if dailyFilesArchived > 0 {
                parts.append(String(format: L10n.tr("归档日志 %d 份"), dailyFilesArchived))
            }
            if rewritten {
                parts.append(L10n.tr("已按主题重写"))
            } else if rewriteRejected {
                parts.append(L10n.tr("重写结果未通过校验，已回退"))
            }
            return parts.joined(separator: L10n.tr("；"))
        }
    }

    // MARK: - 触发入口

    /// 后台条件触发：满足开关 + 冷却 + 体量阈值才真跑。会话复盘结束后调用。
    func consolidateIfNeeded() {
        Task.detached(priority: .background) { [weak self] in
            _ = await self?.consolidate(force: false)
        }
    }

    /// 执行整理。`force = true` 时忽略开关 / 冷却 / 体量阈值（供设置页手动触发）。
    @discardableResult
    func consolidate(force: Bool = false) async -> Report {
        var report = Report()

        let mem = SettingsStore.shared.settings.memory
        guard mem.isEnabled else {
            report.skippedReason = L10n.tr("记忆功能未启用")
            return report
        }
        if !force {
            guard mem.consolidationEnabled else {
                report.skippedReason = L10n.tr("自动整理已关闭")
                return report
            }
            if let last = UserDefaults.standard.object(forKey: Self.lastRunKey) as? Double,
               Date().timeIntervalSince1970 - last < Self.cooldown {
                report.skippedReason = L10n.tr("处于冷却期")
                return report
            }
        }

        guard gate.begin() else {
            report.skippedReason = L10n.tr("已有整理任务在运行")
            return report
        }
        defer { gate.end() }

        let memoryURL = fs.memoryDir.appendingPathComponent("MEMORY.md")
        let original = (try? String(contentsOf: memoryURL, encoding: .utf8)) ?? ""
        report.charsBefore = original.count

        if !force, original.count < mem.consolidationMinChars {
            report.skippedReason = String(
                format: L10n.tr("长期记忆 %1$d 字符，未达阈值 %2$d"),
                original.count, mem.consolidationMinChars
            )
            return report
        }
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            report.skippedReason = L10n.tr("长期记忆为空")
            return report
        }

        // 后台（副）模型端点，供归档蒸馏与主题重写使用；没有就只做本地去重。
        let endpoint = await MainActor.run { AppState.shared.resolveBackgroundModelEndpoint() }

        // ── 阶段 0：过期每日日志蒸馏归档 ──────────────────────────────
        var working = original
        if let endpoint {
            let (digest, archivedCount) = await archiveExpiredDailyLogs(
                retentionDays: mem.retentionDays,
                endpoint: endpoint
            )
            if let digest, !digest.isEmpty {
                working += "\n\n## \(L10n.tr("历史归档"))\n\n" + digest + "\n"
            }
            report.dailyFilesArchived = archivedCount
        }

        // ── 阶段 1：解析 + 精确去重 ─────────────────────────────────
        var blocks = Self.parse(working)
        report.itemsBefore = blocks.filter { $0.isDedupable }.count
        let exactRemoved = Self.removeExactDuplicates(&blocks)
        report.exactDuplicatesRemoved = exactRemoved

        // ── 阶段 2：语义归并 ───────────────────────────────────────
        if mem.embeddingEnabled {
            let merged = await mergeSemanticDuplicates(&blocks, threshold: Float(mem.consolidationSimilarity))
            report.semanticDuplicatesMerged = merged
        }
        report.itemsAfter = blocks.filter { $0.isDedupable }.count

        var result = Self.render(blocks)

        // ── 阶段 3：主题重写 ───────────────────────────────────────
        if let endpoint, result.count >= 200 {
            if let rewritten = await rewriteByTopic(result, endpoint: endpoint) {
                result = rewritten
                report.rewritten = true
            } else {
                report.rewriteRejected = true
            }
        }

        result = result.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        report.charsAfter = result.count

        // 没有任何实质变化就不落盘（避免无谓改写 mtime 触发索引重建）
        guard result != original.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" else {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastRunKey)
            report.didRun = true
            report.skippedReason = nil
            AppLogger.shared.info("记忆整理：无变化", category: "Memory")
            return report
        }

        // 写回前检查期间是否有新的记忆写入（consolidate 的模型调用可能耗时数分钟，
        // 期间主引擎/复盘可能 append 了 MEMORY.md）：用快照 `original` 做基线，
        // 期间发生追加则合并保留；被整体改写则放弃本次写回，保护新数据不被旧快照产物覆盖。
        let current = (try? String(contentsOf: memoryURL, encoding: .utf8)) ?? ""
        if current != original {
            if current.hasPrefix(original) {
                let appended = String(current.dropFirst(original.count))
                result += "\n" + appended
                AppLogger.shared.info("整理期间检测到新增记忆，已合并保留（+\(appended.count) 字符）", category: "Memory")
            } else {
                AppLogger.shared.warn("整理期间 MEMORY.md 被改写，放弃本次写回以保护新数据", category: "Memory")
                report.skippedReason = "整理期间记忆被改写，已放弃写回"
                return report
            }
        }

        backup(original, label: "MEMORY")
        do {
            try MemoryManager.shared.writeLongTermMemory(result, mode: .replace)
            report.didRun = true
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastRunKey)
            AppLogger.shared.info("记忆整理完成：\(report.text)", category: "Memory")
        } catch {
            report.skippedReason = error.localizedDescription
            AppLogger.shared.error("记忆整理写回失败：\(error.localizedDescription)", category: "Memory")
        }
        return report
    }

    // MARK: - 阶段 0：过期日志归档

    /// 把早于 `retentionDays` 的每日日志蒸馏成一段摘要，成功后备份并删除原文件。
    /// 返回（摘要, 归档文件数）；蒸馏失败时返回 (nil, 0) 且不删任何文件。
    private func archiveExpiredDailyLogs(
        retentionDays: Int,
        endpoint: ModelRouteEndpoint
    ) async -> (String?, Int) {
        guard retentionDays > 0 else { return (nil, 0) }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) else {
            return (nil, 0)
        }

        let dir = fs.memoryDir
        let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let expired = all
            .filter { $0.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}\.md$"#, options: .regularExpression) != nil }
            .compactMap { url -> (URL, Date)? in
                let name = String(url.lastPathComponent.dropLast(3))
                guard let d = df.date(from: name), d < cutoff else { return nil }
                return (url, d)
            }
            .sorted { $0.1 < $1.1 }

        guard !expired.isEmpty else { return (nil, 0) }

        var corpus = ""
        // 实际进入蒸馏语料的文件集合：删除只能针对这些文件，
        // 未进语料（corpus 超限 break 截断）的过期日志必须保留，否则未蒸馏内容被永久删除。
        var distilled: [URL] = []
        for (url, _) in expired {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            corpus += "\n\n===== \(url.lastPathComponent) =====\n" + content
            distilled.append(url)
            if corpus.count > Self.maxArchiveInput { break }
        }
        guard !corpus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (nil, 0) }

        let prompt = """
        下面是一批过期的每日工作日志，即将被删除。请把其中有长期价值的内容蒸馏成一份精炼归档：

        规则：
        1. 只保留跨天仍然成立的事实：决策与理由、约定与规范、踩过的坑与解法、未完成事项。
        2. 丢弃一次性过程信息：临时路径、命令回显、当时的报错原文、当天才有意义的进度播报。
        3. 按主题用三级标题（###）分组，条目用「- 」列出，同一事实只出现一次。
        4. 数字、路径、命令、专有名词原样保留，不要改写、不要推断、不要新增事实。
        5. 直接输出 Markdown 正文，不要代码围栏，不要任何解释或前后缀。

        日志内容：
        \(String(corpus.prefix(Self.maxArchiveInput)))
        """

        guard let digest = await runBackgroundModel(prompt: prompt, endpoint: endpoint),
              digest.count >= 40 else {
            AppLogger.shared.info("过期日志蒸馏失败，保留原文件不删除", category: "Memory")
            return (nil, 0)
        }

        // 蒸馏成功：备份成功才删除（备份失败保留原文件，绝不无备份删数据）
        var archived = 0
        for url in distilled {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard backup(content, label: url.deletingPathExtension().lastPathComponent) else {
                AppLogger.shared.warn("归档日志备份失败，保留原文件不删除：\(url.lastPathComponent)", category: "Memory")
                continue
            }
            if (try? FileManager.default.removeItem(at: url)) != nil { archived += 1 }
        }
        return (digest, archived)
    }

    // MARK: - 阶段 2：语义归并

    /// 对可去重块做向量聚类归并，返回被合并掉的条目数。
    private func mergeSemanticDuplicates(_ blocks: inout [Block], threshold: Float) async -> Int {
        let indices = blocks.indices.filter { blocks[$0].isDedupable }
        guard indices.count >= 2 else { return 0 }

        let texts = indices.map { blocks[$0].text }
        guard let ep = await MainActor.run(body: { AppState.shared.resolveEmbeddingEndpoint() }),
              let vectors = await EmbeddingClient.embed(
                  texts: texts, endpoint: ep.endpoint, apiKey: ep.apiKey, model: ep.model
              ),
              vectors.count == texts.count
        else { return 0 }

        let normed = vectors.map(Self.normalize)
        var keptSlots: [(vec: [Float], blockIndex: Int)] = []
        var dropped = Set<Int>()
        var mergedCount = 0

        for (i, blockIndex) in indices.enumerated() {
            let v = normed[i]
            var hit: Int?
            for slot in keptSlots where Self.cosine(slot.vec, v) >= threshold {
                hit = slot.blockIndex
                break
            }
            if let hit {
                // 同一事实：保留信息量更大的表述，位置沿用首次出现处
                if blocks[blockIndex].text.count > blocks[hit].text.count {
                    blocks[hit].text = blocks[blockIndex].text
                }
                dropped.insert(blockIndex)
                mergedCount += 1
            } else {
                keptSlots.append((v, blockIndex))
            }
        }

        guard !dropped.isEmpty else { return 0 }
        blocks = blocks.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
        return mergedCount
    }

    // MARK: - 阶段 3：主题重写

    /// 让副模型按主题重排，输出需通过体量校验；不通过返回 nil（调用方回退去重结果）。
    private func rewriteByTopic(_ content: String, endpoint: ModelRouteEndpoint) async -> String? {
        let prompt = """
        下面是一个 AI 助手的长期记忆文件（Markdown）。请在【不新增、不推断、不删除任何事实】的前提下重新组织：

        1. 按主题归类，用二级标题（##）分节，同类事实收拢到同一节。
        2. 同一事实的多次表述合并为一条，保留信息量最大的版本与全部关键细节。
        3. 若两条结论互相冲突，保留更晚出现的那条，并在其后用「（此前记录为：…）」标注被取代的说法。
        4. 数字、路径、命令、代码、专有名词、日期一律原样保留，不得改写。
        5. 直接输出 Markdown 正文，不要代码围栏，不要任何解释或前后缀。

        记忆内容：
        \(content)
        """

        guard var out = await runBackgroundModel(prompt: prompt, endpoint: endpoint) else { return nil }
        out = Self.stripCodeFence(out)

        // 体量校验：模型截断 / 大幅漏写时拒收
        let ratio = Double(out.count) / Double(max(content.count, 1))
        guard out.count >= 200, ratio >= 0.45 else {
            AppLogger.shared.info(
                "记忆重写被拒（\(content.count) → \(out.count) 字符，比例 \(String(format: "%.2f", ratio))）",
                category: "Memory"
            )
            return nil
        }
        return out
    }

    // MARK: - 模型调用

    /// 跑一次无工具的后台模型调用，返回纯文本输出。
    private func runBackgroundModel(prompt: String, endpoint: ModelRouteEndpoint) async -> String? {
        let engine = AgentLoopEngine(toolRouter: ToolRouter())   // 空工具表 → 纯文本补全
        engine.configure(routingPlan: ModelRoutingPlan(endpoints: [endpoint], usesModelGroups: false))
        engine.configure(sessionID: UUID(), streamingMessageID: nil)
        engine.isSubagentEngine = true
        engine.setSystemPrompt(
            stable: "你是记忆整理器。严格按用户给出的规则处理文本，只输出结果本身，不输出任何解释。",
            volatile: ""
        )

        let collector = TextCollector()
        engine.onToken = { collector.append($0) }
        engine.onTokenUsage = { _ in }   // 整理开销不计入用户统计

        await engine.run(userMessage: prompt, history: [])

        let text = collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - 备份

    /// 备份原文到 .cache/memory-backups/，只留最近 N 份。
    /// 返回是否成功——调用方必须确认备份成功后才允许删除原文件（纪律：无备份不删数据）。
    @discardableResult
    private func backup(_ content: String, label: String) -> Bool {
        let dir = fs.cacheDir.appendingPathComponent("memory-backups")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let ts = Int(Date().timeIntervalSince1970)
            let url = dir.appendingPathComponent("\(label)-\(ts).md")
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            AppLogger.shared.error("记忆备份失败 \(label)：\(error.localizedDescription)", category: "Memory")
            return false
        }

        // 只留最近 N 份
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []).sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a > b
        }
        for old in files.dropFirst(Self.maxBackups) {
            try? FileManager.default.removeItem(at: old)
        }
        return true
    }

    // MARK: - Markdown 块解析

    struct Block {
        enum Kind { case heading, item, paragraph }
        var kind: Kind
        var text: String
        /// 只有条目与段落参与去重，标题结构原样保留。
        var isDedupable: Bool { kind != .heading }
        var normalized: String { MemoryConsolidator.normalizeKey(text) }
    }

    /// 把 Markdown 拆成「标题 / 列表条目（含缩进续行）/ 普通段落」三类块。
    static func parse(_ content: String) -> [Block] {
        var blocks: [Block] = []
        var pending: Block?

        func flush() {
            if var p = pending {
                p.text = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !p.text.isEmpty { blocks.append(p) }
                pending = nil
            }
        }

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
                continue
            }
            if trimmed.hasPrefix("#") {
                flush()
                blocks.append(Block(kind: .heading, text: trimmed))
                continue
            }
            if isListMarker(trimmed) {
                flush()
                pending = Block(kind: .item, text: line)
                continue
            }
            // 缩进续行 → 归入当前条目
            if pending?.kind == .item, line.hasPrefix(" ") || line.hasPrefix("\t") {
                pending?.text += "\n" + line
                continue
            }
            if pending?.kind == .paragraph {
                pending?.text += "\n" + line
            } else {
                flush()
                pending = Block(kind: .paragraph, text: line)
            }
        }
        flush()
        return blocks
    }

    static func render(_ blocks: [Block]) -> String {
        var out = ""
        var prevKind: Block.Kind?
        for b in blocks {
            switch b.kind {
            case .heading:
                out += (out.isEmpty ? "" : "\n") + b.text + "\n\n"
            case .item:
                out += b.text + "\n"
            case .paragraph:
                if prevKind != nil { out += "\n" }
                out += b.text + "\n"
            }
            prevKind = b.kind
        }
        return out
    }

    /// 精确去重：归一化后完全相同的块只保留第一次出现。返回移除条数。
    static func removeExactDuplicates(_ blocks: inout [Block]) -> Int {
        var seen = Set<String>()
        var removed = 0
        blocks = blocks.filter { b in
            guard b.isDedupable else { return true }
            let key = b.normalized
            guard !key.isEmpty else { return true }
            if seen.contains(key) { removed += 1; return false }
            seen.insert(key)
            return true
        }
        return removed
    }

    private static func isListMarker(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") { return true }
        return trimmed.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil
    }

    /// 去重键：剥列表标记 / 加粗符号，折叠空白，转小写。
    static func normalizeKey(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"^[-*+]\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^\d+[.)]\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.lowercased()
    }

    private static func stripCodeFence(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("```") else { return s }
        if let firstNewline = s.firstIndex(of: "\n") {
            s = String(s[s.index(after: firstNewline)...])
        }
        if s.hasSuffix("```") {
            s = String(s.dropLast(3))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 向量工具

    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i] }
        return dot   // 传入的已是单位向量
    }

    private static func normalize(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }
}

// MARK: - 并发辅助

/// 单实例运行闸门（Swift 6 下 NSLock 不能在 async 函数体里直接加解锁，故封装成同步方法）。
private final class RunGate: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if running { return false }
        running = true
        return true
    }
    func end() {
        lock.lock(); running = false; lock.unlock()
    }
}

/// 流式 词元 累加器（onToken 回调可能在非主线程触发）。
private final class TextCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    func append(_ s: String) { lock.lock(); buffer += s; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return buffer }
}
