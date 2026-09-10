import Foundation

/// Kit 模块日志设施（KitLog）：本模块为独立编译单元，不引用宿主实现。
/// 本模块为独立编译单元，不能引用宿主 App 的日志实现，故在此自带一份最小实现：
/// 与宿主日志写入同一目录文件（Documents/MiniClaw/logs/MiniClaw-YYYY-MM-DD.log），
/// 拉取时统一可见。宿主侧代码迁移进主工程后，同名类型由主工程实现接管，调用点无需改动。
struct KitLog {
    let category: String
    init(category: String) { self.category = category }

    /// 高频诊断类别降噪（2026-08-13 用户要求）：这些类别的 info/debug 日志
    /// 不再 print 也不落盘（每次消息渲染 / 滚动采样 / 键盘变化都刷屏）。
    /// WARN/ERROR 永远保留；排查需要时把对应类别移出此集合即可恢复。
    private static let quietCategories: Set<String> = [
        "SnapshotDiag", "ScrollDiag", "ScrollStall", "ScrollDecel", "PendingSnap",
        "Settle", "SettleJitter", "FGLayout", "KbdDiag", "CellSizing",
        "StreamDiag", "ThinkingCollapse", "AttachHotPath", "AttachBoundsHot",
        "MarkdownRenderer", "ThinkPerf", "WatchdogProbe"
    ]
    /// 按实际生效类别判断是否降噪（info/debug 的 category 参数可覆盖实例类别）。
    private func isQuiet(_ category: String?) -> Bool {
        Self.quietCategories.contains(category ?? self.category)
    }

    /// 写日志文件(与主工程 AppLogger 同目录:Documents/MiniClaw/logs/MiniClaw-YYYY-MM-DD.log)。
    /// 2026-08-11 之前桩只 print 不进文件,导致 MiniClawKit 全链路日志(StreamDiag/
    /// ScrollDiag/KbdDiag)从未落盘,排查只能靠猜;补写文件后与主工程日志统一拉取。
    private func persist(_ level: String,_ message: String,_ category: String?) {
        let cat = category ?? self.category
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory,in: .userDomainMask).first else { return }
        let dir = docs.appendingPathComponent("MiniClaw/logs",isDirectory: true)
        try? fm.createDirectory(at: dir,withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let file = dir.appendingPathComponent("MiniClaw-\(df.string(from: Date())).log")
        let ts = DateFormatter()
        ts.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(ts.string(from: Date()))] MiniClaw[\(ProcessInfo.processInfo.processIdentifier)] [MiniClaw][\(level)][\(cat)] \(message)\n"
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8) ?? Data())
            try? h.close()
        } else {
            try? line.data(using: .utf8)?.write(to: file)
        }
    }
    func debug(_ message: String,category: String? = nil,subsystem: String? = nil) {
        guard !isQuiet(category) else { return }
        print("[MiniClaw][DEBUG][\(category ?? self.category)] \(message)")
        persist("DEBUG",message,category)
    }
    func info(_ message: String,category: String? = nil,subsystem: String? = nil) {
        guard !isQuiet(category) else { return }
        print("[MiniClaw][\(category ?? self.category)] \(message)")
        persist("INFO",message,category)
    }
    func warning(_ message: String,category: String? = nil,subsystem: String? = nil) {
        print("[MiniClaw][WARN][\(category ?? self.category)] \(message)")
        persist("WARN",message,category)
    }
    func error(_ message: String,category: String? = nil,subsystem: String? = nil) {
        print("[MiniClaw][ERROR][\(category ?? self.category)] \(message)")
        persist("ERROR",message,category)
    }
}
