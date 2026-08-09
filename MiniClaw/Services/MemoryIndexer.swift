import Foundation

/// 记忆向量索引 + FTS 混合检索。
///
/// - 索引落盘在 `Documents/MiniClaw/.cache/embeddings/index.json`，刻意避开 `memory/` 写入门禁。
/// - 向量经 OpenAI 兼容 `/embeddings` 接口生成（Anthropic 无 embeddings API，故走 OpenAI 格式最通用；
///   OpenAI / OpenRouter（部分）/ OpenAI-Compatible 自建均可）。
/// - 检索融合：FTS 关键词命中 + 向量余弦相似度，加权排序取 topK。
/// - 当 embeddings 未启用、或无可用的 embedding 密钥时，自动回退到纯 FTS 关键词检索。
final class MemoryIndexer: @unchecked Sendable {
    static let shared = MemoryIndexer()

    private let fs = FileSystemManager.shared

    // 索引状态锁：chunks/vectors/lastMtimes/builtAt/embeddingAvailable/rebuildInFlight 全部经它保护。
    // search 可被主引擎、复盘引擎、多个并行子代理同时触发，无锁并发读写是数据竞争（Swift 6 严格并发）。
    private let lock = NSLock()
    private var builtAt: Date?
    private var lastMtimes: [String: TimeInterval] = [:]
    private var chunks: [MemoryChunk] = []
    private var vectors: [[Float]] = []
    /// 标记当前是否有可用的 embedding 端点（无则纯 FTS）。
    private var embeddingAvailable: Bool = false
    /// 重建单飞标志：同一时刻只允许一个重建任务（避免并发重复 embedding 请求）。
    private var rebuildInFlight = false

    /// 锁保护的同步状态访问（NSLock 不能在 async 上下文直接加解锁，封装为同步方法）。
    private func withStateLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    struct MemoryChunk: Codable {
        let file: String   // 源文件名，如 MEMORY.md / 2026-07-30.md
        let text: String
    }

    private struct IndexFile: Codable {
        var mtimes: [String: TimeInterval]
        var chunks: [MemoryChunk]
        var vectors: [[Float]]
    }

    // MARK: - 公共检索

    /// 检索记忆，返回与 `MemoryManager.searchMemory` 同构的结果数组（每个元素为「文件名:行号 + 上下文」或「文件名 + 文本」）。
    /// - Parameters:
    ///   - keyword: 查询关键字
    ///   - scope: 检索范围
    ///   - topK: 最多返回条数
    func search(keyword: String, scope: MemorySearchScope = .all, topK: Int = 8) async -> [String] {
        // 记忆总开关关闭时直接走纯关键词检索（无向量、无 embedding 调用）。
        guard SettingsStore.shared.settings.memory.isEnabled else {
            return keywordSearch(keyword: keyword, scope: scope)
        }
        let enabled = SettingsStore.shared.settings.memory.embeddingEnabled
        if !enabled {
            return keywordSearch(keyword: keyword, scope: scope)
        }
        await ensureIndex()
        // 在锁内取状态快照（值类型数组，COW 安全），后续检索不再触碰共享状态
        let snapshot = withStateLock {
            (chunks: self.chunks, vectors: self.vectors, embeddingAvailable: self.embeddingAvailable)
        }
        // 纯 FTS 回退（无可用 embedding 端点）
        if !snapshot.embeddingAvailable {
            return keywordSearch(keyword: keyword, scope: scope, chunks: snapshot.chunks)
        }
        // 融合检索
        guard let queryVec = await embed([keyword])?.first, !queryVec.isEmpty else {
            return keywordSearch(keyword: keyword, scope: scope, chunks: snapshot.chunks)
        }
        let scored = hybridScore(query: queryVec, keyword: keyword, chunks: snapshot.chunks, vectors: snapshot.vectors)
        let top = scored.prefix(topK)
        return top.map { "[\($0.chunk.file)]\n\($0.chunk.text)" }
    }

    // MARK: - 索引构建

    /// 向量检索当前是否可用（embedding 端点探测成功）。供 system prompt 记忆注入等外部调用：
    /// 先确保索引就绪（内部会做 embedding 端点真实探测），再返回状态；开关未开/不可用时返回 false。
    func isEmbeddingAvailable() async -> Bool {
        guard SettingsStore.shared.settings.memory.isEnabled,
              SettingsStore.shared.settings.memory.embeddingEnabled else { return false }
        await ensureIndex()
        return withStateLock { embeddingAvailable }
    }

    private func ensureIndex() async {
        // 读取当前 memory 文件 mtime（局部变量，无共享状态）
        let files = memoryFiles(scope: .all)
        var currentMtimes: [String: TimeInterval] = [:]
        for f in files {
            let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
            currentMtimes[f.lastPathComponent] = mtime
        }
        let needRebuild = withStateLock {
            builtAt == nil
                || currentMtimes != lastMtimes
                || chunks.isEmpty
        }
        if !needRebuild { return }

        // 单飞：已有重建任务在跑则本次跳过（下次 search 由新 mtime/空状态再次触发），
        // 避免 N 个并发 search 各自发起一轮 embedding 请求。
        let acquired = withStateLock { () -> Bool in
            if rebuildInFlight { return false }
            rebuildInFlight = true
            return true
        }
        guard acquired else { return }
        defer { withStateLock { rebuildInFlight = false } }

        // 切块
        var newChunks: [MemoryChunk] = []
        for f in files {
            guard let content = try? String(contentsOf: f, encoding: .utf8) else { continue }
            let fileChunks = chunkText(content).map { MemoryChunk(file: f.lastPathComponent, text: $0) }
            newChunks.append(contentsOf: fileChunks)
        }

        // 尝试生成向量
        var newVectors: [[Float]] = []
        var embeddingOK = false
        if let ep = await MainActor.run(body: { AppState.shared.resolveEmbeddingEndpoint() }),
           !newChunks.isEmpty {
            if let vs = await EmbeddingClient.embed(texts: newChunks.map(\.text), endpoint: ep.endpoint, apiKey: ep.apiKey, model: ep.model) {
                newVectors = vs
                embeddingOK = (vs.count == newChunks.count)
            }
        }

        // 落盘（锁内更新共享状态）
        withStateLock {
            self.chunks = newChunks
            if embeddingOK {
                self.vectors = newVectors
                self.embeddingAvailable = true
                // 仅 embedding 成功才推进 mtime/时间戳：失败时下次 search 会重试，
                // 避免一次临时网络故障导致向量检索永久降级为纯 FTS。
                self.lastMtimes = currentMtimes
                self.builtAt = Date()
            } else {
                self.vectors = []
                self.embeddingAvailable = false
                // chunks 已更新（供 FTS 回退使用），但 lastMtimes 不推进 → 下次重试 embedding
            }
        }
        saveIndex()
    }

    private func saveIndex() {
        // 锁内读状态构造快照后再编码落盘
        let index = withStateLock {
            IndexFile(mtimes: lastMtimes, chunks: chunks, vectors: vectors)
        }
        guard let data = try? JSONEncoder().encode(index) else { return }
        do {
            try FileManager.default.createDirectory(at: fs.embeddingsCacheDir, withIntermediateDirectories: true)
            try data.write(to: indexURL, options: [.atomic])
        } catch {
            AppLogger.shared.error("记忆索引写入失败: \(error.localizedDescription)", category: "Memory")
        }
    }

    private var indexURL: URL {
        fs.embeddingsCacheDir.appendingPathComponent("index.json")
    }

    // MARK: - 检索算法

    /// 纯关键词检索（FTS 回退）。当传入 chunks 时使用给定块，否则从文件实时扫。
    private func keywordSearch(keyword: String, scope: MemorySearchScope, chunks: [MemoryChunk]? = nil) -> [String] {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return [] }
        let tokens = kw.split(separator: " ").map(String.init)
        let scopeFiles = Set(memoryFiles(scope: scope).map(\.lastPathComponent))

        if let chunks {
            let filtered = chunks.filter { scopeFiles.isEmpty || scopeFiles.contains($0.file) }
            let scored = filtered.map { chunk -> (chunk: MemoryChunk, score: Int) in
                let lower = chunk.text.lowercased()
                let score = tokens.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
                return (chunk, score)
            }.filter { $0.score > 0 }
                .sorted { $0.score > $1.score }
            return scored.prefix(8).map { "[\($0.chunk.file)]\n\($0.chunk.text)" }
        }

        // 退化路径：直接扫文件（与旧 searchMemory 行为一致）
        var results: [String] = []
        for file in memoryFiles(scope: scope) where file.pathExtension == "md" {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = content.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.localizedCaseInsensitiveContains(keyword) {
                let start = max(0, i - 2)
                let end = min(lines.count, i + 3)
                let ctx = lines[start..<end].joined(separator: "\n")
                results.append("\(file.lastPathComponent):\(i + 1)\n\(ctx)")
            }
        }
        return results
    }

    /// 融合打分：向量余弦（0..1）+ FTS 命中数，归一化后加权。
    private func hybridScore(query: [Float], keyword: String, chunks: [MemoryChunk], vectors: [[Float]]) -> [(chunk: MemoryChunk, score: Double)] {
        let kw = keyword.lowercased()
        let kwTokens = kw.split(separator: " ").map(String.init)
        let normQ = normalize(query)
        var vecScores: [Double] = []
        for v in vectors {
            let cos = cosine(normalize(v), normQ)
            vecScores.append(max(0.0, Double(cos)))
        }
        let maxVec = vecScores.max() ?? 1
        let maxVecSafe = maxVec > 0 ? maxVec : 1

        var ftsScores: [Double] = []
        for c in chunks {
            let lower = c.text.lowercased()
            let hit = kwTokens.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
            ftsScores.append(Double(hit))
        }
        let maxFts = ftsScores.max() ?? 1
        let maxFtsSafe = maxFts > 0 ? maxFts : 1

        var out: [(chunk: MemoryChunk, score: Double)] = []
        for i in chunks.indices {
            let vN = vecScores[i] / maxVecSafe
            let fN = ftsScores[i] / maxFtsSafe
            let score = 0.6 * vN + 0.4 * fN
            out.append((chunk: chunks[i], score: score))
        }
        return out.sorted { $0.score > $1.score }
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (sqrt(na) * sqrt(nb))
    }

    private func normalize(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    // MARK: - 切块

    private func chunkText(_ text: String, maxChunkSize: Int = 600) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var chunks: [String] = []
        var current = ""
        for p in paragraphs {
            if current.count + p.count > maxChunkSize, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n\n") + p
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.isEmpty ? [text] : chunks
    }

    // MARK: - 文件枚举

    private func memoryFiles(scope: MemorySearchScope) -> [URL] {
        let dir = fs.memoryDir
        let allDaily = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}\.md$"#, options: .regularExpression) != nil }
        switch scope {
        case .daily:
            // DateFormatter 非线程安全：局部创建（调用频率低，开销可忽略）
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            let today = f.string(from: Date()) + ".md"
            return [dir.appendingPathComponent(today)]
        case .longTerm:
            return [dir.appendingPathComponent("MEMORY.md")]
        case .all:
            return [dir.appendingPathComponent("MEMORY.md")] + allDaily
        }
    }

    private func embed(_ texts: [String]) async -> [[Float]]? {
        guard let ep = await MainActor.run(body: { AppState.shared.resolveEmbeddingEndpoint() }) else { return nil }
        return await EmbeddingClient.embed(texts: texts, endpoint: ep.endpoint, apiKey: ep.apiKey, model: ep.model)
    }
}

/// OpenAI 兼容的 Embeddings 客户端（endpoint 为完整 URL，含 /embeddings 路径）。
struct EmbeddingClient {
    /// 调用 embeddings 接口，返回与输入顺序一致的向量数组。失败返回 nil。
    static func embed(texts: [String], endpoint: String, apiKey: String, model: String) async -> [[Float]]? {
        guard !texts.isEmpty else { return [] }
        guard let url = URL(string: endpoint) else { return nil }

        let body: [String: Any] = ["model": model, "input": texts]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 60

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                AppLogger.shared.error("Embeddings 请求失败 HTTP \(http.statusCode)", category: "Memory")
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataArr = json["data"] as? [[String: Any]] else { return nil }
            // 按 index 排序，保证与输入顺序一致
            let sorted = dataArr.sorted {
                (($0["index"] as? Int) ?? 0) < (($1["index"] as? Int) ?? 0)
            }
            let vectors = sorted.compactMap { item -> [Float]? in
                guard let emb = item["embedding"] as? [NSNumber] else { return nil }
                return emb.map { $0.floatValue }
            }
            return vectors.count == texts.count ? vectors : nil
        } catch {
            AppLogger.shared.error("Embeddings 请求异常: \(error.localizedDescription)", category: "Memory")
            return nil
        }
    }
}
