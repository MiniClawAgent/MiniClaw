import Foundation

final class MemoryManager: @unchecked Sendable {
    static let shared = MemoryManager()
    private let fs = FileSystemManager.shared

    /// 记忆文件写入串行队列：所有记忆写操作（daily/longTerm/edit）统一经此排队，
    /// 消除并发 append 双 FileHandle 交错写、replace 与 append 竞态（L7），
    /// 并顺带串行化 dateFormatter 的访问（非线程安全，L6）。
    private let writeQueue = DispatchQueue(label: "miniclaw-memory-write")

    /// 在串行队列内执行写入（同步等待结果；临界区为文件 IO 短操作，可接受）。
    private func syncWrite<T>(_ body: () throws -> T) throws -> T {
        try writeQueue.sync(execute: body)
    }

    private var dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    @discardableResult
    func writeDailyMemory(_ content: String, settings: AppSettings, date: Date = Date()) throws -> String {
        let filename = dateFormatter.string(from: date) + ".md"
        let virtualPath = "/var/MiniClaw/memory/\(filename)"
        try syncWrite {
            let entry = "\n\n## \(Date().formatted(date: .omitted, time: .shortened))\n\n\(sanitizeMemory(content, settings: settings))"

            if fs.fileExists(at: virtualPath) {
                try fs.writeFile(at: virtualPath, content: entry, append: true, actor: .memory)
            } else {
                let header = "# 每日记忆 - \(dateFormatter.string(from: date))\n"
                try fs.writeFile(at: virtualPath, content: header + entry, actor: .memory)
            }
        }
        return virtualPath
    }

    @discardableResult
    func writeLongTermMemory(_ content: String, mode: LongTermMemoryWriteMode, settings: AppSettings) throws -> String {
        try syncWrite {
            let sanitized = sanitizeMemory(content, settings: settings).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sanitized.isEmpty else {
                throw FileError.writeFailed("MEMORY.md 内容不能为空")
            }

            let virtualPath = "/var/MiniClaw/memory/MEMORY.md"
            switch mode {
            case .append:
                let separator = fs.fileExists(at: virtualPath) ? "\n\n" : ""
                try fs.writeFile(at: virtualPath, content: separator + sanitized + "\n", append: true, actor: .memory)
            case .replace:
                try fs.writeFile(at: virtualPath, content: sanitized + "\n", actor: .memory)
            }
        }
        return "/var/MiniClaw/memory/MEMORY.md"
    }

    /// 定点替换记忆文件中的文本（走 .memory actor，写前仍做敏感信息净化）。
    /// 用于修改已存在的一行记忆，例如追加一条并列事实。
    @discardableResult
    func editMemory(target: MemoryEditTarget, oldString: String, newString: String, settings: AppSettings) throws -> String {
        try syncWrite {
            guard !oldString.isEmpty else {
                throw FileError.writeFailed("old_string 不能为空")
            }

            let virtualPath: String
            switch target {
            case .longTerm:
                virtualPath = "/var/MiniClaw/memory/MEMORY.md"
            case .daily:
                virtualPath = "/var/MiniClaw/memory/" + dateFormatter.string(from: Date()) + ".md"
            }

            guard fs.fileExists(at: virtualPath) else {
                throw FileError.notFound(virtualPath)
            }

            // 必须经 resolveAgentPath 把虚拟路径映射到真实沙盒文件再读取，
            // 不能直接用虚拟路径 String(contentsOf:)，否则因 /var/MiniClaw 不是真实目录而读不到。
            var content = try fs.readFile(at: virtualPath)
            guard content.contains(oldString) else {
                throw FileError.stringNotFound(oldString)
            }

            content = content.replacingOccurrences(of: oldString, with: newString)
            let sanitized = sanitizeMemory(content, settings: settings)
            try fs.writeFile(at: virtualPath, content: sanitized, actor: .memory)
        }
        let targetPath: String
        switch target {
        case .longTerm: targetPath = "/var/MiniClaw/memory/MEMORY.md"
        case .daily: targetPath = "/var/MiniClaw/memory/" + dateFormatter.string(from: Date()) + ".md"
        }
        return targetPath
    }

    /// 记忆写入前的敏感信息净化（spec 9.5）：
    /// 1. 敏感信息不记忆：过滤密码 / API Key / Token 等模式
    /// 2. 隐私模式：开启 envvars.privacyMode 时，shell 输出中的变量值被掩码
    /// 2026-08-13 改传主线程快照：不再后台线程裸读 SettingsStore（竞争修复）。
    private func sanitizeMemory(_ content: String, settings: AppSettings) -> String {
        var text = content

        // 隐私模式：屏蔽环境变量值
        if settings.envvarsPrivacyMode {
            for v in settings.envvars where !v.value.isEmpty {
                text = text.replacingOccurrences(of: v.value, with: "***")
            }
        }

        // 通用密钥 / 令牌模式过滤
        let patterns = [
            #"(?i)\b(sk|pk|rk)-[A-Za-z0-9_\-]{20,}"#,
            #"(?i)Bearer\s+[A-Za-z0-9._\-]+"#,
            #"(?i)(password|passwd|api[_-]?key|token|secret|access[_-]?token|client[_-]?secret)\s*[:=]\s*\S+"#
        ]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p) {
                let range = NSRange(text.startIndex..., in: text)
                text = re.stringByReplacingMatches(in: text, range: range, withTemplate: "***REDACTED***")
            }
        }
        return text
    }

    func searchMemory(keyword: String, scope: MemorySearchScope = .all) -> [String] {
        var results: [String] = []

        let files: [URL]
        switch scope {
        case .daily:
            let today = dateFormatter.string(from: Date()) + ".md"
            files = [fs.memoryDir.appendingPathComponent(today)]
        case .longTerm:
            files = [fs.memoryDir.appendingPathComponent("MEMORY.md")]
        case .all:
            let dailyFiles = ((try? FileManager.default.contentsOfDirectory(
                at: fs.memoryDir,
                includingPropertiesForKeys: nil
            )) ?? []).filter {
                $0.lastPathComponent.range(
                    of: #"^\d{4}-\d{2}-\d{2}\.md$"#,
                    options: .regularExpression
                ) != nil
            }
            files = [fs.memoryDir.appendingPathComponent("MEMORY.md")] + dailyFiles
        }

        for file in files where file.pathExtension == "md" {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = content.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.localizedCaseInsensitiveContains(keyword) {
                let start = max(0, i - 2)
                let end = min(lines.count, i + 3)
                let context = lines[start..<end].joined(separator: "\n")
                results.append("\(file.lastPathComponent):\(i + 1)\n\(context)")
            }
        }

        return results
    }

    func getRecentMemory(days: Int = 2) -> String {
        var allContent = ""
        let calendar = Calendar.current

        for dayOffset in 0..<days {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: Date()) else { continue }
            let filename = dateFormatter.string(from: date) + ".md"
            let path = fs.memoryDir.appendingPathComponent(filename)

            if let content = try? String(contentsOf: path, encoding: .utf8) {
                allContent += "\n---\n\(content)\n"
            }
        }

        return allContent
    }
}

enum LongTermMemoryWriteMode {
    case append
    case replace
}

enum MemoryEditTarget {
    case longTerm
    case daily
}

enum MemorySearchScope {
    case daily
    case longTerm
    case all
}

