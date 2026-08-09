import Foundation
import CryptoKit

/// Markdown 解析结果持久化缓存（2026-08-07）。
///
/// **Why**：进入会话页首帧的「同步 Markdown 解析」是点击长会话不跟手的根因——
/// VStack 全量构建所有消息时每条消息首帧解析一次，耗时随消息数线性增长。
/// 历史消息内容不变，解析结果按内容 hash 落盘：冷启动/被系统杀进程后
/// 首次进入长会话也直接命中磁盘缓存，无需重新解析。
///
/// **存储**：`MiniClawRoot/markdown-cache/<sha256前40hex>.json`（统一保存、内容去重——
/// 同文本跨会话只存一份；不跟随会话，删会话不影响其它会话命中）。
/// 上限 800 条，按修改时间淘汰最旧（内存 NSCache 上限 400 条，App 内二级加速）。
///
/// **写入时机**：每条消息解析完成即写（后台队列原子写）；流式中间态不写
/// （内容在变会产生垃圾条目），流式结束后的最终解析自然落盘。
final class MarkdownCacheStore: @unchecked Sendable {
    static let shared = MarkdownCacheStore()

    private final class CacheBox {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }

    private let memory: NSCache<NSString, CacheBox>
    private let ioQueue = DispatchQueue(label: "miniclaw-markdown-cache-io")
    private let maxDiskEntries = 800

    /// 缓存目录（与 FileSystemManager.miniClawRoot 同源，但直接计算避免跨 actor 访问）。
    private var cacheDir: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents
            .appendingPathComponent("MiniClaw", isDirectory: true)
            .appendingPathComponent("markdown-cache", isDirectory: true)
    }

    private init() {
        memory = NSCache<NSString, CacheBox>()
        memory.countLimit = 400
        pruneIfNeeded()
    }

    /// 内容 → 稳定 key（SHA256 前 40 hex；跨进程稳定，不做 App 内 hashValue）。
    static func key(for content: String) -> String {
        let digest = SHA256.hash(data: Data(content.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(40))
    }

    /// 三级查询（内存 → 磁盘）；未命中返回 nil 由调用方解析。
    func blocks(for content: String) -> [MarkdownBlock]? {
        let key = Self.key(for: content)
        let nsKey = key as NSString
        if let box = memory.object(forKey: nsKey) { return box.blocks }
        let url = cacheDir.appendingPathComponent(key + ".json")
        guard let data = try? Data(contentsOf: url),
              let blocks = try? JSONDecoder().decode([MarkdownBlock].self, from: data) else {
            return nil
        }
        memory.setObject(CacheBox(blocks), forKey: nsKey)
        return blocks
    }

    /// 写入（内存立即 + 后台原子落盘 + 超限淘汰）。
    func store(_ blocks: [MarkdownBlock], for content: String) {
        let key = Self.key(for: content)
        memory.setObject(CacheBox(blocks), forKey: key as NSString)
        let url = cacheDir.appendingPathComponent(key + ".json")
        ioQueue.async { [weak self] in
            guard let data = try? JSONEncoder().encode(blocks) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            self?.pruneIfNeeded()
        }
    }

    /// 条目数超限时按修改时间删最旧（启动/写入后调用）。
    private func pruneIfNeeded() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        guard files.count > maxDiskEntries else { return }
        let sorted = files.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
        for f in sorted.prefix(files.count - maxDiskEntries) {
            try? fm.removeItem(at: f)
        }
    }
}
