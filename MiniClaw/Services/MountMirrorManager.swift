import Foundation
import Darwin

/// 双向镜像管理器（解决 iSH 无法裸 open「File Provider Storage」外部文件夹的问题）
///
/// # 设计要点（v2，修复「ls 间歇性无输出 / 不完整」）
/// 初版在「外部 ↔ 镜像」之间用 (mtime,size) 较新者覆盖，触发了**乒乓循环**：
/// 写镜像改了 mtime → 下一轮判外部较旧被回写 → 又改外部 mtime → 再判镜像较旧被拉回……
/// 每 20s 把全部文件 remove+重写一遍，iSH 的 ls 在重写窗口读到空/残目录。
///
/// v2 改为**带账本(ledger)的两遍顺序同步**，彻底切断反馈：
/// - 每文件记录「上次已协调的两侧状态」(extSize/extMtime/mirSize/mirMtime)。
/// - 外部→镜像：仅当「外部相对账本变化」且「镜像相对账本未变」才拉取；否则保留本地改动。
/// - 镜像→外部：仅当「镜像相对账本变化」才回写；回写后立即把外部新状态写进账本。
/// - 两遍在同一串行队列、同一 tick 内顺序执行，无交叉；账本使任一侧的「自身改动」不被误判为对方变化。
/// 结果：文件仅在任一侧真正变更时才复制一次，镜像目录内容稳定，ls 永远读到完整目录。
///
/// 另：文件写入用「原子替换」(write options:.atomic)，**绝不先 removeItem 再写**，
/// 保证目录项在重写期间始终存在，ls 不会因读到缺失项而残缺。
///
/// 落点：bind mount 已映射的 `Documents/MiniClaw/mounts/<name>/`（占位目录本身），
/// iSH 经 bind mount 解析父目录 fd 后能直接在目录内 openat 子文件（裸 open 沙盒目录必然成功）。
final class MountMirrorManager: @unchecked Sendable {
    static let shared = MountMirrorManager()

    private let queue = DispatchQueue(label: "com.miniclaw.mountmirror")
    /// 挂载变更通知的观察队列（独立后台队列）。notification 可能由主线程经
    /// DispatchQueue.main.async 发出，若用 queue:nil 会在主线程跑本观察者，
    /// 虽 syncEnabledNow 内部为 async 风险低，仍独立队列彻底隔离主线程。
    private let observerQueue = DispatchQueue(label: "com.miniclaw.mountmirror.observer")
    private let cacheRoot: URL

    /// 每个启用挂载：外部→镜像兜底轮询 timer（File Provider 变更事件不可靠，低频补全）。
    private var pollers: [String: DispatchSourceTimer] = [:]

    /// 每挂载每文件的「上次已协调状态」账本：[mountName: [relPath: SyncState]]。
    /// 仅进程内有效；重启后会重新对账一次并趋于稳定（不会乒乓，因为账本在首轮即建立）。
    private var ledger: [String: [String: SyncState]] = [:]

    private struct SyncState {
        var extSize: Int64 = -1
        var extMtime: TimeInterval = 0
        var mirSize: Int64 = -1
        var mirMtime: TimeInterval = 0
    }

    private init() {
        // 镜像落点：bind mount 已映射的 `Documents/MiniClaw/mounts`（占位目录所在）。
        self.cacheRoot = FileSystemManager.shared.mountsDir
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

        // 挂载表变化时（增删 / 启用停用）重建镜像与监听。
        let _ = NotificationCenter.default.addObserver(
            forName: .mountStoreDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            // 通知可能由主线程发出；观察者块本身只做轻量 async 派发，
            // 真正的同步工作落到独立的 observerQueue 后台队列，彻底隔离主线程。
            // iOS16 兼容:提前捕获 self 引用避免 Sendable 闭包内捕获警告。
            guard let self else { return }
            self.observerQueue.async { self.syncEnabledNow() }
        }
        // 初始对账（App 启动时可能已错过首次通知）。
        syncEnabledNow()
    }

    // MARK: - 路径

    /// 沙盒内、bind-mount 可见的镜像根目录：`mounts/<name>/`（即占位目录本身）。
    func mirrorURL(for name: String) -> URL {
        cacheRoot.appendingPathComponent(name, isDirectory: true)
    }

    // MARK: - 挂载对账（建立 / 清理监听与初始同步）

    /// 依据当前启用挂载，建立 / 清理镜像与监听，并对启用挂载触发一次完整对账。
    /// 供 boot 末尾与 mountStoreDidChange 调用。
    func syncEnabledNow() {
        queue.async { [weak self] in
            guard let self else { return }
            let enabled = MountStore.shared.list().filter { $0.isMounted }
            let enabledNames = Set(enabled.map { $0.name })

            // 清理已停用 / 删除挂载的轮询（镜像目录保留，避免误删用户可见内容）。
            for (name, t) in self.pollers where !enabledNames.contains(name) {
                t.cancel()
                self.pollers.removeValue(forKey: name)
            }

            // 为启用挂载建立镜像、兜底轮询，并触发一次初始对账（外部→镜像 + 镜像→外部）。
            for m in enabled {
                self.ensureMirrorAndSync(name: m.name)
            }
        }
    }

    /// 确保镜像根目录存在，建立兜底轮询，并立即触发一次完整对账（先拉后推）。
    private func ensureMirrorAndSync(name: String) {
        let mirror = mirrorURL(for: name)
        try? FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)

        // 立即做一次完整对账，尽快让镜像可用。
        syncCycle(name: name)

        // 外部 → 镜像兜底轮询（File Provider 变更事件不可靠，低频补全）。
        if pollers[name] == nil {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 20, repeating: 20)
            t.setEventHandler { [weak self] in
                self?.syncCycle(name: name)
            }
            t.resume()
            pollers[name] = t
        }
    }

    // MARK: - 同步循环（两遍：先拉后推，顺序执行，无交叉）

    /// 一个 tick 内的完整对账：先外部→镜像（下载），再镜像→外部（回写）。
    /// 两遍顺序执行，账本使任一侧的「自身改动」不会被误判为对方变化 → 无乒乓。
    private func syncCycle(name: String) {
        pullExternalToMirror(name: name)
        pushMirrorToExternal(name: name)
    }

    /// 外部 → 镜像（下载）：仅复制「外部较账本变化且镜像相对账本未变」的文件；
    /// 镜像的本地改动（iSH 写入）保留，等下一遍回写。
    private func pullExternalToMirror(name: String) {
        guard let external = MountStore.shared.resolveExternalURL(mountName: name, subPath: "") else {
            NSLog("[MountMirror] ⚠️ pull 跳过 name=%@ 外部解析失败(书签失效/未授权) → 镜像保持现状，iSH 内 ls 读到的是上次已同步内容", name)
            return
        }
        let mirror = mirrorURL(for: name)
        try? FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        pullDir(from: external, to: mirror, rel: "", name: name)
    }

    /// 镜像 → 外部（上传）：仅回写「镜像相对账本变化」的文件；只读挂载不回写。
    private func pushMirrorToExternal(name: String) {
        let mirror = mirrorURL(for: name)
        guard FileManager.default.fileExists(atPath: mirror.path) else { return }

        // 只读挂载：不回写外部。
        let mounts = MountStore.shared.list()
        guard let mount = mounts.first(where: { $0.name == name }),
              mount.isMounted, mount.isWritable else { return }
        guard let external = MountStore.shared.resolveExternalURL(mountName: name, subPath: "") else { return }
        pushDir(from: mirror, to: external, rel: "", name: name)
    }

    // MARK: - 递归同步原语（带账本）

    private func pullDir(from extDir: URL, to mirDir: URL, rel: String, name: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: mirDir, withIntermediateDirectories: true)
        let coordinator = NSFileCoordinator()
        var coordErr: NSError?
        var items: [URL] = []
        coordinator.coordinate(readingItemAt: extDir, options: [], error: &coordErr) { url in
            items = (try? fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey]
            )) ?? []
        }
        for item in items {
            let base = item.lastPathComponent
            let childRel = rel.isEmpty ? base : rel + "/" + base
            let dst = mirDir.appendingPathComponent(base)
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                pullDir(from: item, to: dst, rel: childRel, name: name)
            } else {
                pullFile(from: item, to: dst, rel: childRel, name: name)
            }
        }
    }

    private func pullFile(from ext: URL, to mir: URL, rel: String, name: String) {
        let extState = readState(ext)
        let mirState = readState(mir)
        var book = ledger[name] ?? [:]
        let prev = book[rel]

        if mirState.size < 0 {
            // 镜像缺失 → 拉取
            copyExtToMir(from: ext, to: mir)
            let newMir = readState(mir)
            book[rel] = SyncState(extSize: extState.size, extMtime: extState.mtime,
                                  mirSize: newMir.size, mirMtime: newMir.mtime)
            ledger[name] = book
        } else if prev == nil || prev!.extSize != extState.size || prev!.extMtime != extState.mtime {
            // 外部相对账本变化 → 拉取（v1：外部优先，覆盖本地改动）；
            // 回写后账本已记录镜像现状，故不会触发下一遍误回写。
            copyExtToMir(from: ext, to: mir)
            let newMir = readState(mir)
            book[rel] = SyncState(extSize: extState.size, extMtime: extState.mtime,
                                  mirSize: newMir.size, mirMtime: newMir.mtime)
            ledger[name] = book
        }
        // 否则（外部未变）：保留镜像现状（含 iSH 本地改动），等 push 回写
    }

    private func pushDir(from mirDir: URL, to extDir: URL, rel: String, name: String) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: mirDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        for item in items {
            let base = item.lastPathComponent
            // 跳过状态文件与占位元数据（避免把内部文件同步到外部）。
            if base == "MOUNTS_STATUS.txt" { continue }
            let childRel = rel.isEmpty ? base : rel + "/" + base
            let dst = extDir.appendingPathComponent(base)
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
                pushDir(from: item, to: dst, rel: childRel, name: name)
            } else {
                pushFile(from: item, to: dst, rel: childRel, name: name)
            }
        }
    }

    private func pushFile(from mir: URL, to ext: URL, rel: String, name: String) {
        let mirState = readState(mir)
        var book = ledger[name] ?? [:]
        let prev = book[rel]
        guard mirState.size >= 0 else { return }   // 镜像无此文件，无内容可推
        if prev == nil || prev!.mirSize != mirState.size || prev!.mirMtime != mirState.mtime {
            // 镜像相对账本变化 → 回写外部；回写后把外部新状态写进账本，切断乒乓。
            copyMirToExt(from: mir, to: ext)
            let newExt = readState(ext)   // 回写后重读外部状态（File Provider 可能改写 mtime）
            book[rel] = SyncState(extSize: newExt.size, extMtime: newExt.mtime,
                                  mirSize: mirState.size, mirMtime: mirState.mtime)
            ledger[name] = book
        }
        // 否则镜像未变 → 不回写
    }

    // MARK: - 复制原语

    /// 读 (size, mtime)；文件不存在返回 (-1, 0)。
    private func readState(_ url: URL) -> (size: Int64, mtime: TimeInterval) {
        let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return (Int64(vals?.fileSize ?? -1),
                vals?.contentModificationDate?.timeIntervalSince1970 ?? 0)
    }

    /// 外部 → 镜像：用 NSFileCoordinator(.forUploading) 物化 File Provider 文件，
    /// 写入镜像用 **原子替换**（options:.atomic，不先 removeItem），保证目录项始终存在。
    private func copyExtToMir(from src: URL, to dst: URL) {
        let coordinator = NSFileCoordinator()
        var readErr: NSError?
        var data: Data?
        coordinator.coordinate(readingItemAt: src, options: .forUploading, error: &readErr) { url in
            data = try? Data(contentsOf: url)
        }
        guard let data else {
            NSLog("[MountMirror] 读取失败 src=%@ err=%@", src.path, readErr?.localizedDescription ?? "unknown")
            return
        }
        var writeErr: NSError?
        coordinator.coordinate(writingItemAt: dst, options: [], error: &writeErr) { url in
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("[MountMirror] 写入失败(镜像) dst=%@ err=%@", url.path, "\(error)")
            }
        }
    }

    /// 镜像 → 外部：读取镜像 Data，经 NSFileCoordinator 写入外部（File Provider）。
    /// 外部侧不是 iSH 的 ls 目标，存在则先移除再原子写入。
    private func copyMirToExt(from src: URL, to dst: URL) {
        guard let data = try? Data(contentsOf: src) else { return }
        let coordinator = NSFileCoordinator()
        var writeErr: NSError?
        coordinator.coordinate(writingItemAt: dst, options: [], error: &writeErr) { url in
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("[MountMirror] 写入失败(外部) dst=%@ err=%@", url.path, "\(error)")
            }
        }
    }
}
