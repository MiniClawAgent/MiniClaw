import Foundation

/// 下载进度全局追踪。同一时刻只可能有一个下载任务（Agent 循环串行）。
/// ToolCallCardView 通过 `claim(by:)` 绑定到特定卡片，进度只在该卡片显示。
@MainActor
@Observable
final class DownloadProgressTracker {
    static let shared = DownloadProgressTracker()

    /// 当前进度 0.0...1.0
    var progress: Double = 0
    /// 文件名标签
    var label: String = ""
    /// 是否正在下载
    var isActive: Bool = false
    /// 是否刚完成（下一次 start 时重置）
    var isDone: Bool = false

    func start(label: String) {
        progress = 0
        self.label = label
        isActive = true
        isDone = false
    }

    func update(downloaded: Int64, total: Int64) {
        progress = total > 0 ? Double(downloaded) / Double(total) : 0
    }

    func finish() {
        progress = 1.0
        isActive = false
        isDone = true
    }
}
