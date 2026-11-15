import Foundation

/// OpenRouter 公开模型目录（**无需 API Key**）。
///
/// 用途：供应商自己的 `/v1/models` 往往只给 `id`，拿不到上下文窗口、最大输出、模态、
/// 是否支持工具。OpenRouter 的公开目录覆盖率极高（实测 470 个模型：context_length 100%、
/// pricing 100%、architecture 100%、supported_parameters 99%），且**匿名可拉**，
/// 因此用它给"已拉到的模型列表"补空缺。
///
/// 三条设计约束：
/// 1. **只补空缺，绝不覆盖**：供应商自己给的值才是权威。OpenRouter 的 `context_length`
///    可能是它自身路由层的可用上限，直接覆盖会造出"看着对、请求却超限"的配置。
/// 2. **匹配有歧义就放弃**：OpenRouter 的 id 是 `vendor/model[:variant]`，按去掉前缀的
///    叶名匹配；若同一叶名对应多个条目（不同 vendor 或不同变体），宁可不补也不猜。
/// 3. **失败静默降级**：拉不到目录不影响"保存 key / 显示模型列表"主流程。
actor OpenRouterCatalog {
    static let shared = OpenRouterCatalog()

    /// 目录 URL（公开，无需鉴权）。
    private let endpoint = URL(string: "https://openrouter.ai/api/v1/models")!
    /// 缓存有效期：24 小时。响应约 830KB，不能每次进设置页都拉。
    private let maxAge: TimeInterval = 24 * 60 * 60

    /// 一条目录项（只保留我们需要补的字段）。
    struct Entry: Codable, Sendable {
        let contextLength: Int?
        let maxCompletionTokens: Int?
        let inputModalities: [String]
        let outputModalities: [String]
        let supportsTools: Bool
        let supportsReasoning: Bool
    }

    private var index: [String: Entry]?
    private var lastLoadedAt: Date?

    // MARK: - 对外

    /// 给已拉到的模型补空缺。任何失败都原样返回入参。
    func enrich(_ models: [ModelConfig], providerType: ProviderType) async -> [ModelConfig] {
        guard let index = await loadIndex(), !index.isEmpty else { return models }

        return models.map { model in
            guard let entry = index[Self.leafKey(model.modelId)] else { return model }
            var enriched = model

            // 上下文：只有供应商没给时才补
            if enriched.contextLimit <= 0, let ctx = entry.contextLength, ctx > 0 {
                enriched.contextLimit = ctx
            }
            // 最大输出：同上
            if enriched.maxOutputTokens == nil, let maxOut = entry.maxCompletionTokens, maxOut > 0 {
                enriched.maxOutputTokens = maxOut
            }
            // 模态：只"补真"，不把供应商说支持的改回不支持
            if entry.inputModalities.contains("image") { enriched.inputImage = true }
            if entry.inputModalities.contains("audio") { enriched.inputAudio = true }
            if entry.outputModalities.contains("image") { enriched.outputImage = true }
            if entry.outputModalities.contains("audio") { enriched.outputAudio = true }
            // 思考能力：目录确认支持时打开；不支持则不动（供应商可能已声明支持）
            if entry.supportsReasoning { enriched.deepThinking = true }

            return enriched
        }
    }

    // MARK: - 目录加载（带磁盘缓存）

    private func loadIndex() async -> [String: Entry]? {
        if let index, let at = lastLoadedAt, Date().timeIntervalSince(at) < maxAge {
            return index
        }
        if let cached = readCache() {
            index = cached.0
            lastLoadedAt = cached.1
            if Date().timeIntervalSince(cached.1) < maxAge { return cached.0 }
        }
        // 缓存过期或不存在：拉一次；失败则继续用旧缓存（宁可旧也别空）
        do {
            let fetched = try await fetchIndex()
            index = fetched
            lastLoadedAt = Date()
            writeCache(fetched)
            return fetched
        } catch {
            AppLogger.shared.debug("[OpenRouterCatalog] fetch failed: \(error.localizedDescription)", category: "Provider")
            return index
        }
    }

    private func fetchIndex() async throws -> [String: Entry] {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // OpenRouter 建议带上来源标识；匿名请求也可用。
        request.setValue("MiniClaw", forHTTPHeaderField: "X-Title")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return Self.parse(data)
    }

    // MARK: - 解析

    /// 把 OpenRouter 的响应解析成「叶名 → 条目」。
    ///
    /// 两条判定规则（基于实测 470 条数据校准）：
    /// - **跨厂商同叶名 ⇒ 丢弃**：实测当前 0 组，但规则要留着，别赌它永远不冲突；
    /// - **同厂商多条目 ⇒ 择优，不丢弃**：实测 91 组来自 `:free` / `:batch` / `:nitro` 变体，
    ///   它们指向同一个模型。优先取无变体后缀的那条；都有后缀时取上下文更大的一条，
    ///   再按 id 字典序兜底（保证同一份数据每次结果一致）。
    static func parse(_ data: Data) -> [String: Entry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else { return [:] }

        struct Candidate {
            let id: String
            let vendor: String
            let hasVariantSuffix: Bool
            let entry: Entry
        }

        var buckets: [String: [Candidate]] = [:]
        for item in list {
            guard let id = item["id"] as? String, !id.isEmpty else { continue }
            let architecture = item["architecture"] as? [String: Any] ?? [:]
            let topProvider = item["top_provider"] as? [String: Any] ?? [:]
            let params = item["supported_parameters"] as? [String] ?? []

            let entry = Entry(
                contextLength: intValue(item["context_length"]),
                maxCompletionTokens: intValue(topProvider["max_completion_tokens"]),
                inputModalities: architecture["input_modalities"] as? [String] ?? [],
                outputModalities: architecture["output_modalities"] as? [String] ?? [],
                supportsTools: params.contains("tools"),
                supportsReasoning: params.contains("reasoning") || item["reasoning"] != nil
            )
            let vendor = id.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            let leafPart = id.split(separator: "/", maxSplits: 1).last.map(String.init) ?? id
            buckets[leafKey(id), default: []].append(Candidate(
                id: id,
                vendor: vendor,
                hasVariantSuffix: leafPart.contains(":"),
                entry: entry
            ))
        }

        var result: [String: Entry] = [:]
        for (key, candidates) in buckets {
            // 跨厂商同名 ⇒ 含义不确定，放弃
            guard Set(candidates.map(\.vendor)).count == 1 else { continue }
            let chosen = candidates.sorted { lhs, rhs in
                if lhs.hasVariantSuffix != rhs.hasVariantSuffix { return !lhs.hasVariantSuffix }
                let lc = lhs.entry.contextLength ?? 0
                let rc = rhs.entry.contextLength ?? 0
                if lc != rc { return lc > rc }
                return lhs.id < rhs.id
            }.first
            if let chosen { result[key] = chosen.entry }
        }
        return result
    }

    /// `vendor/model:variant` → `model`（去掉厂商前缀与变体后缀）。
    static func leafKey(_ id: String) -> String {
        var leaf = id
        if let slash = leaf.firstIndex(of: "/") {
            leaf = String(leaf[leaf.index(after: slash)...])
        }
        if let colon = leaf.firstIndex(of: ":") {
            leaf = String(leaf[..<colon])
        }
        return leaf.lowercased()
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let v = any as? Int { return v }
        if let v = any as? NSNumber { return v.intValue }
        if let v = any as? String { return Int(v) }
        return nil
    }

    // MARK: - 磁盘缓存

    private var cacheURL: URL {
        FileSystemManager.shared.cacheDir.appendingPathComponent("openrouter-models.json")
    }

    private func readCache() -> ([String: Entry], Date)? {
        let url = cacheURL
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(CachePayload.self, from: data) else { return nil }
        return (payload.index, payload.savedAt)
    }

    private func writeCache(_ index: [String: Entry]) {
        let url = cacheURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let payload = CachePayload(savedAt: Date(), index: index)
            let data = try JSONEncoder().encode(payload)
            try data.write(to: url, options: .atomic)
        } catch {
            AppLogger.shared.debug("[OpenRouterCatalog] cache write failed: \(error.localizedDescription)", category: "Provider")
        }
    }

    private struct CachePayload: Codable {
        let savedAt: Date
        let index: [String: Entry]
    }
}
