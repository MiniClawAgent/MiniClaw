import Foundation

/// 后台下载器：基于 `URLSession.background` 的下载会话（系统接管传输）。
///
/// 为什么需要它：普通 URLSession 在 App 退后台被挂起时连接立即断开，大文件下载中断。
/// background session 由系统继续传输：App 挂起/被杀后下载不中断，完成后系统唤醒 App，
/// 经 `application(_:handleEventsForBackgroundURLSession:)` 回调收尾。
///
/// 关键约束（Apple 文档，违反会崩溃/丢任务）：
/// 1. 同一 identifier 的 background session 一个进程只能有一个实例——这里为进程级单例，绝不重建；
/// 2. background session **不能** invalidate（否则系统无法继续任务）；
/// 3. 必须实现 AppDelegate 的 `handleEventsForBackgroundURLSession` 并把 completionHandler
///    保存下来，在 `urlSessionDidFinishEvents` 回调后调用，否则系统认为任务未处理完；
/// 4. 仅适用于下载/上传——LLM 流式对话（SSE）不支持 background session，仍走普通会话。
/// `@unchecked Sendable`：全部可变状态经 NSLock 保护（项目单例惯例，见 RunGate）。
final class BackgroundDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = BackgroundDownloader()

    /// 后台会话标识（App 级唯一；与 AppDelegate.handleEventsForBackgroundURLSession 对应）。
    static let sessionIdentifier = "com.neartop.miniclaw.background-download"

    /// 单个下载任务的回调句柄（taskIdentifier → handle；resume 后从字典移除，天然防双回调）。
    private struct Handle {
        let onProgress: (Int64, Int64) -> Void
        let onComplete: (Result<Data, Error>) -> Void
    }

    private let lock = NSLock()
    private var session: URLSession?
    private var handles: [Int: Handle] = [:]
    /// AppDelegate 存入的系统后台完成处理器（urlSessionDidFinishEvents 后调用）。
    private var backgroundCompletion: (() -> Void)?

    private override init() {}

    /// 幂等创建/复用后台会话。冷启动被系统唤醒时（handleEventsForBackgroundURLSession）
    /// 必须调用本方法，否则收不到系统转交的下载任务。
    func ensureSession() {
        lock.lock(); defer { lock.unlock() }
        if session == nil {
            let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
            config.isDiscretionary = false         // 用户正在等下载，不做延迟调度
            config.sessionSendsLaunchEvents = true // 完成后唤醒 App
            session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            AppLogger.shared.info("BackgroundDownloader 会话已创建", category: "BG", subsystem: "Download")
        }
    }

    /// AppDelegate 保存系统完成处理器（handleEventsForBackgroundURLSession 时注入）。
    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        backgroundCompletion = handler
    }

    /// 下载 URL 为 Data（完成后由调用方落盘）。后台挂起/被杀期间由系统继续传输。
    func download(from url: URL) async throws -> Data {
        ensureSession()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let handle = Handle(
                onProgress: { downloaded, total in
                    Task { @MainActor in
                        DownloadProgressTracker.shared.update(downloaded: downloaded, total: total)
                    }
                },
                onComplete: { result in
                    switch result {
                    case .success(let data): cont.resume(returning: data)
                    case .failure(let error): cont.resume(throwing: error)
                    }
                }
            )
            lock.lock()
            guard let session = session else {
                lock.unlock()
                cont.resume(throwing: URLError(.badServerResponse))
                return
            }
            let task = session.downloadTask(with: url)
            handles[task.taskIdentifier] = handle
            lock.unlock()
            task.resume()
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        lock.lock(); let handle = handles[downloadTask.taskIdentifier]; lock.unlock()
        handle?.onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // 成功路径：系统保证在此方法返回前临时文件有效，必须立即处理。
        lock.lock()
        let h = handles.removeValue(forKey: downloadTask.taskIdentifier)
        lock.unlock()
        if let h {
            do {
                let data = try Data(contentsOf: location)
                try? FileManager.default.removeItem(at: location)
                h.onComplete(.success(data))
            } catch {
                try? FileManager.default.removeItem(at: location)
                h.onComplete(.failure(error))
            }
        } else {
            // 冷启动唤醒（下载期间 App 被杀，新进程无调用方 continuation）：
            // 无法交付给原调用方，但绝不能让数据凭空消失——持久保存到 offloads/ 并记日志。
            Self.persistOrphanDownload(location, filename: downloadTask.response?.suggestedFilename)
        }
    }

    /// 进程重启后完成的后台下载：把文件持久保存到 offloads/（智能体可从文件系统访问）。
    private static func persistOrphanDownload(_ location: URL, filename: String?) {
        let offloads = FileSystemManager.shared.offloadsDir
        // 服务器返回的 suggestedFilename 不可信（可能含 / 或 ..）：只取最后路径组件并拒绝穿越。
        let raw = filename ?? location.lastPathComponent
        let clean = raw.split(separator: "/").last.map(String.init) ?? "download"
        let name = (clean.isEmpty || clean == "." || clean == "..") ? "download" : clean
        let dest = offloads.appendingPathComponent("bgdownload-\(Int(Date().timeIntervalSince1970))-\(name)")
        do {
            try FileManager.default.createDirectory(at: offloads, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: dest)
            AppLogger.shared.info("后台下载在进程重启后完成，已持久保存: \(dest.lastPathComponent)", category: "BG", subsystem: "Download")
        } catch {
            try? FileManager.default.removeItem(at: location)
            AppLogger.shared.error("后台下载结果持久化失败: \(error.localizedDescription)", category: "BG", subsystem: "Download")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // 成功路径已由 didFinishDownloadingTo 处理（handle 已移除）；此处只处理失败/取消。
        if let error {
            lock.lock(); let handle = handles.removeValue(forKey: task.taskIdentifier); lock.unlock()
            handle?.onComplete(.failure(error))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // 系统要求：在主线程调用保存的 completionHandler，告知后台传输已处理完毕。
        lock.lock(); let handler = backgroundCompletion; backgroundCompletion = nil; lock.unlock()
        if let handler {
            Task { @MainActor in handler() }
        }
    }
}
