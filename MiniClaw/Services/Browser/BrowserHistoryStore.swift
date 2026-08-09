import Foundation

/// 持久化浏览历史（跨启动保存）。
/// 原实现读 WKWebView.backForwardList——那是「当前 webView 会话内」的后退/前进列表，
/// App 重启或浏览器重新进入后即为空，表现为「每次打开浏览器都看不到浏览记录」。
/// 本存储改为落盘 JSON（MiniClawRoot/browser/history.json），导航完成时记录，
/// 按访问时间倒序展示，支持清空。
@MainActor
final class BrowserHistoryStore {
    static let shared = BrowserHistoryStore()

    /// 单条历史。
    struct Entry: Codable, Identifiable {
        let url: String
        var title: String
        var visitedAt: Date
        var id: String { url }
    }

    private var entries: [Entry] = []
    /// 上限：防无限增长（文件极小，100 条足够日常回溯）。
    private let maxEntries = 100

    private var fileURL: URL {
        FileSystemManager.shared.browserDir.appendingPathComponent("history.json")
    }

    private init() {
        load()
    }

    /// 记录一次访问：同 URL 更新标题与时间（移到最前），否则插入头部；超上限裁剪。
    func record(url: String, title: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("data:") else {
            return
        }
        let now = Date()
        if let idx = entries.firstIndex(where: { $0.url == trimmed }) {
            entries[idx].title = title
            entries[idx].visitedAt = now
            let e = entries.remove(at: idx)
            entries.insert(e, at: 0)
        } else {
            entries.insert(Entry(url: trimmed, title: title, visitedAt: now), at: 0)
        }
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save()
    }

    /// 全部历史（已按访问时间倒序）。
    func all() -> [Entry] { entries }

    /// 清空全部历史。
    func clear() {
        entries = []
        save()
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else {
            entries = []
            return
        }
        entries = decoded
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // 历史记录落盘失败不阻塞浏览，静默忽略（下次导航再试）。
        }
    }
}
