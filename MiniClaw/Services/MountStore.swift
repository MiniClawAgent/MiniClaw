import Foundation

/// 外部文件夹挂载管理器。
///
/// iOS 沙盒无法真正把外部文件夹 mount 到沙盒路径，本 Store 采用
/// **app-scoped bookmark（iOS fileImporter 选中文件夹用 `options:[]` 创建）+ 逻辑映射**：
/// - 用户经文件选择器（`.fileImporter(allowedContentTypes: [.folder])`）选中外部文件夹后，
///   调用 `add(url:)` 保存其 bookmark 到 `config/mounts.json`；
/// - Agent 访问 `/var/MiniClaw/mounts/<name>/...` 时，`FileSystemManager` 调用
///   `resolveExternalURL(mountName:subPath:)` 解析 bookmark 得到外部真实 URL 再读取；
/// - 挂载默认**只读**（由 `MountPoint.isWritable = false`）；用户可在「设置 → 挂载」中为每个挂载
///   显式开启「允许写入」，开启后 Agent 可通过 `file-write` / `file-edit` 把内容写到外部真实文件夹
///   （写入经 `FileSystemManager.validateWrite` 校验该挂载 `isWritable` 且在授权范围内）。
final class MountStore: @unchecked Sendable {
    static let shared = MountStore()

    private let queue = DispatchQueue(label: "com.miniclaw.mountstore")
    private var mounts: [MountPoint] = []
    /// 已成功 startAccessing 的外部 URL（进程生命周期内保持访问，退出自动释放）。
    /// 以 mount id 为键，避免对同一 bookmark 重复 start。
    private var activeAccess: [UUID: URL] = [:]
    private var loaded = false

    private var fileURL: URL {
        FileSystemManager.shared.configDir.appendingPathComponent("mounts.json")
    }

    private init() {}

    // MARK: - 持久化

    private func loadLocked() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([MountPoint].self, from: data) else {
            mounts = []
            NSLog("[MountStore] loadLocked: mounts=0 (无配置文件)")
            return
        }
        mounts = decoded
        let withBookmark = decoded.filter { $0.bookmark != nil }.count
        let mounted = decoded.filter { $0.isMounted }.count
        NSLog("[MountStore] loadLocked: 共%ld个挂载 已启用=%ld 含书签=%ld", decoded.count, mounted, withBookmark)
    }

    private func persistLocked() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(mounts) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    // MARK: - 查询

    /// 当前所有挂载点（含未启用）。
    func list() -> [MountPoint] {
        queue.sync {
            loadLocked()
            return mounts
        }
    }

    /// 挂载是否「存在且已启用」的轻量查询（仅查内存中的挂载表，**不触碰 bookmark / 不访问外部**）。
    /// 供 iSH fakefs path-translate hook 在热路径上判定路径是否归属某挂载：
    /// 读镜像目录不应依赖外部（File Provider）是否当前可用——即便外部暂时不可达，
    /// 已同步进沙盒镜像的内容也必须能被 iSH 正常读取，否则表现为「ls 间歇性无输出」。
    func existsEnabled(_ name: String) -> Bool {
        queue.sync {
            loadLocked()
            return mounts.contains { $0.name == name && $0.isMounted }
        }
    }

    // MARK: - 增删改

    /// 从用户选中的外部文件夹 URL 创建挂载点。
    /// 会创建 security-scoped bookmark 并落盘。返回创建的挂载点；失败抛错。
    @discardableResult
    func add(url: URL) throws -> MountPoint {
        // 访问用户选中的资源以创建 bookmark（iOS 需在 startAccessing 期间创建）。
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        let bookmark: Data
        do {
            // iOS 经 fileImporter(.folder) 选中的 URL 本身是 security-scoped 的，
            // 其 app-scoped bookmark 用 options:[] 创建即可（.withSecurityScope 在 iOS 不可用）。
            // 若书签后续解析失败，一切会回退到本地 mounts/<name> 目录，
            // 由 mountInfoForURL 的本地兜底匹配保证写入仍可正确归属该挂载。
            bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            throw MountError.bookmarkFailed(error.localizedDescription)
        }

        return queue.sync {
            loadLocked()
                // 诊断：刚创建的书签能否立即解析？能→说明书签本身 OK（后续失败多为 JSON 存取 / 进程生命周期问题）；
            // 不能→说明创建环节就有问题（iOS 安全范围 / fileImporter URL 处置）。
            do {
                var s = false
                if let t = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &s) {
                    NSLog("[MountStore] ✅ 书签创建+即时解析成功 name=%@ → %@ stale=%d", url.lastPathComponent, t.path, s)
                } else {
                    NSLog("[MountStore] ⚠️ 书签创建后无法即时解析 name=%@ bookmarkBytes=%ld", url.lastPathComponent, bookmark.count)
                }
            }
            let rawBase = url.lastPathComponent.isEmpty ? "folder" : url.lastPathComponent
            let name = uniqueNameLocked(base: Self.normalizedName(rawBase))
            let point = MountPoint(
                name: name,
                path: "/var/MiniClaw/mounts/\(name)",
                externalPath: url.path,
                bookmark: bookmark,
                isWritable: true,
                isMounted: true
            )
            mounts.append(point)
            persistLocked()
            notifyChangedLocked()
            NSLog("[MountStore] 新增挂载 name=%@ path=%@ externalPath=%@ bookmarkBytes=%ld", name, point.path, url.path, bookmark.count)
            return point
        }
    }

    /// 删除挂载点（同时释放其 security-scoped 访问）。
    func remove(id: UUID) {
        queue.sync {
            loadLocked()
            if let active = activeAccess.removeValue(forKey: id) {
                active.stopAccessingSecurityScopedResource()
            }
            mounts.removeAll { $0.id == id }
            persistLocked()
            notifyChangedLocked()
        }
    }

    /// 启用 / 停用挂载点。停用后 Agent 无法通过虚拟路径访问其内容。
    func setEnabled(id: UUID, _ enabled: Bool) {
        queue.sync {
            loadLocked()
            guard let idx = mounts.firstIndex(where: { $0.id == id }) else { return }
            mounts[idx].isMounted = enabled
            if !enabled, let active = activeAccess.removeValue(forKey: id) {
                active.stopAccessingSecurityScopedResource()
            }
            persistLocked()
            notifyChangedLocked()
        }
    }

    /// 允许 / 禁止 Agent 写入该挂载（默认禁止）。开启后 Agent 可经 file-write / file-edit 写入外部真实文件夹。
    func setWritable(id: UUID, _ writable: Bool) {
        queue.sync {
            loadLocked()
            guard let idx = mounts.firstIndex(where: { $0.id == id }) else { return }
            mounts[idx].isWritable = writable
            persistLocked()
            notifyChangedLocked()
        }
    }

    /// 若 `url` 落在某个**已启用**挂载的授权范围内，返回其 (name, isWritable)；否则 nil。
    /// 供 `FileSystemManager.validateWrite` 判定外部写入是否放行 / 是否为只读挂载。
    /// 匹配两类根：① 经 bookmark 解析出的外部真实 URL；② 解析失败时的本地兜底目录
    /// `Documents/MiniClaw/mounts/<name>`（旧书签损坏时一切会回退到这里，必须也能识别，
    /// 否则写入落到通用 writeNotAllowed 分支，报出令人困惑的「不允许写入该目录」）。
    /// 注意：本方法在锁外逐个调用 `resolveExternalURL`（其内部才加锁），避免同队列 sync 嵌套死锁。
    func mountInfoForURL(_ url: URL) -> (name: String, isWritable: Bool)? {
        let candidates = queue.sync {
            loadLocked()
            return mounts.filter { $0.isMounted }.map { (name: $0.name, writable: $0.isWritable) }
        }
        let target = url.resolvingSymlinksInPath()
        let targetPath = normalizePathForContainment(target.path)
        // ① 外部真实 URL
        for c in candidates {
            guard let root = resolveExternalURL(mountName: c.name, subPath: "") else { continue }
            let rootPath = normalizePathForContainment(root.resolvingSymlinksInPath().path)
            if targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") {
                return (c.name, c.writable)
            }
        }
        // ② 本地兜底目录 Documents/MiniClaw/mounts/<name>（书签解析失败的降级路径）
        let mountsRoot = normalizePathForContainment(FileSystemManager.shared.mountsDir.standardizedFileURL.path)
        for c in candidates {
            let localRoot = normalizePathForContainment((mountsRoot as NSString).appendingPathComponent(c.name))
            if targetPath == localRoot || targetPath.hasPrefix(localRoot + "/") {
                return (c.name, c.writable)
            }
        }
        return nil
    }

    // MARK: - 解析（供 FileSystemManager 调用）

    /// 把 `mounts/<name>/<subPath>` 解析为外部真实文件 URL。
    /// - 未找到挂载点 / 未启用 / bookmark 解析失败 / 目录穿越 → 返回 nil（调用方回退到本地空目录）。
    /// - 成功时对外部根目录 startAccessing（进程内保持），并返回带子路径的最终 URL。
    func resolveExternalURL(mountName: String, subPath: String) -> URL? {
        queue.sync {
            loadLocked()
            guard let idx = mounts.firstIndex(where: { $0.name == mountName }),
                  mounts[idx].isMounted,
                  let bookmark = mounts[idx].bookmark else { return nil }

            // 解析外部根目录 URL（若已激活则复用，避免重复 start）。
            let base: URL
            if let cached = activeAccess[mounts[idx].id] {
                base = cached
            } else {
                var stale = false
                // iOS app-scoped bookmark 用 options:[] 解析即可。解析失败（返回 nil）时调用方会
                // 回退到本地 mounts/<name> 目录，由 mountInfoForURL 的本地兜底匹配保证写入仍可归属该挂载。
                var resolved: URL?
                var resolveErr: Error?
                do {
                    resolved = try URL(
                        resolvingBookmarkData: bookmark,
                        options: [],
                        relativeTo: nil,
                        bookmarkDataIsStale: &stale
                    )
                } catch {
                    resolveErr = error
                }
                guard let resolved else {
                    NSLog("[MountStore] ❌ 书签解析失败 mount=%@ stale=%d bookmarkBytes=%ld error=%@", mounts[idx].name, stale, bookmark.count, resolveErr?.localizedDescription ?? "resolvingBookmarkData 返回 nil")
                    return nil
                }
                // 解析出的 security-scoped URL 必须在访问期间 startAccessing；返回 false 时
                // （极少数 app-scoped 情形）仍可访问，仅不缓存，绝不因 false 放弃解析。
                let didStart = resolved.startAccessingSecurityScopedResource()
                if didStart {
                    activeAccess[mounts[idx].id] = resolved
                }
                // bookmark 过期则刷新并落盘（保持长期可用）。
                if stale, let fresh = try? resolved.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    mounts[idx].bookmark = fresh
                    mounts[idx].externalPath = resolved.path
                    persistLocked()
                }
                base = resolved
            }

            let trimmed = subPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            // 【关键修正】返回 base 派生的「原始 URL」(security scope 已对该 URL 激活)，
            // 不再对返回值做 standardizedFileURL / resolvingSymlinksInPath。
            // 原因：File Provider Storage 是虚拟化/symlink 路径，标准化后 URL 字符串变化，
            // 会脱离 bookmark 授予的 security scope，导致 App 侧枚举/复制该路径文件时
            // 抛「权限不足」→ 镜像目录建好却永远为空（iSH cat / 写回全 256）。
            // 目录穿越校验改用「本地标准化副本」比较，不影响返回值。
            let target: URL = trimmed.isEmpty
                ? base
                : base.appendingPathComponent(trimmed)
            let rootStd = normalizePathForContainment(base.resolvingSymlinksInPath().path)
            let targetStd = normalizePathForContainment(target.resolvingSymlinksInPath().path)
            guard targetStd == rootStd || targetStd.hasPrefix(rootStd + "/") else {
                NSLog("[MountStore] ❌ 目录穿越拦截 mount=%@ sub=%@ root=%@ target=%@", mountName, subPath.isEmpty ? "(root)" : subPath, rootStd, targetStd)
                return nil
            }
            return target
        }
    }

    /// 把完整 guest 路径 `/var/MiniClaw/mounts/<name>/<sub>` 解析为宿主真实路径字符串。
    /// 供 iSH fakefs path-translate hook 调用（C 热路径，要求非阻塞、可重入）。
    ///
    /// **关键修正（方案 B + 双向镜像）**：iSH 内核是裸 `open()`，iOS 沙盒禁止它对
    /// 「File Provider Storage」(iCloud / 云盘类文件夹) 路径做裸 open，即使文件已下载到本地
    /// 仍被拒（表现为 `cat` 退出码 256）。因此这里**不再返回外部真实路径**，而是返回
    /// App 沙盒内、且已被 iSH 主 bind mount 映射的镜像路径 `mounts/<name>/<sub>`——
    /// 即占位目录本身，iSH 用父目录 fd + 子文件名 openat 时文件就在该目录内，裸 open 必然成功。
    /// 镜像内容由 `MountMirrorManager` 与外部文件夹双向同步。
    ///
    /// - 仍先 `resolveExternalURL(mountName:name, subPath:"")` 校验挂载有效并激活 bookmark
    ///   （确保后续镜像→外部回写时外部可达），仅取其 name 判定，不直接返回其 path。
    /// - 返回 nil 表示不覆盖，fakefs 回退到 bind_mount 表（即真实 `mounts/<name>` 占位目录）。
    func resolveMountGuestPath(_ guestPath: String) -> String? {
        let prefix = "/var/MiniClaw/mounts/"
        guard guestPath.hasPrefix(prefix) else { return nil }
        let rest = String(guestPath.dropFirst(prefix.count))
        guard !rest.isEmpty else { return nil }
        let parts = rest.split(separator: "/", maxSplits: 1)
        let name = Self.normalizedName(String(parts[0]))
        let sub = parts.count > 1 ? String(parts[1]) : ""
        // 仅校验「挂载存在且已启用」即可映射到镜像路径——不要求外部当前可达：
        // 外部不可达时镜像里已有的内容仍必须能被 iSH 读取，否则会静默无输出。
        // （外部可用性只影响镜像能否继续同步，由 MountMirrorManager 在同步时优雅跳过。）
        guard existsEnabled(name) else {
            NSLog("[resolveMountGuestPath] ✗ 未命中 guest=%@ name=%@ sub=%@", guestPath, name, sub)
            return nil
        }
        // 返回沙盒内镜像路径（iSH 裸 open 必定成功）。
        let mirror = MountMirrorManager.shared.mirrorURL(for: name)
        let target = sub.isEmpty ? mirror : mirror.appendingPathComponent(sub)
        return target.path
    }

    // MARK: - 工具

    /// iOS 上 /var 是 /private/var 的 firmlink（非普通 symlink），URL API 解不开，
    /// 导致同一文件的路径可能以 /var 或 /private/var 开头。归一化后再做前缀比较。
    private func normalizePathForContainment(_ p: String) -> String {
        if p.hasPrefix("/private/var/") { return String(p.dropFirst(8)) }    // "/private".count = 8
        if p == "/private/var" { return "/var" }
        return p
    }

    /// 在锁内生成唯一挂载名（重名追加 -2/-3…）。
    private func uniqueNameLocked(base: String) -> String {
        let existing = Set(mounts.map { $0.name })
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// 挂载名统一归一化为 NFC（precomposed），避免 iOS 文件选择器（常返回 NFD）
    /// 与 iSH 终端输入（常返回 NFC）的 Unicode 规范化差异导致占位目录名与
    /// 访问路径字节不匹配、ls/cat 静默失败。存储与查询两侧都走此归一化，确保一致。
    private static func normalizedName(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
    }
}

enum MountError: LocalizedError {
    case bookmarkFailed(String)

    var errorDescription: String? {
        switch self {
        case .bookmarkFailed(let msg): return String(format: String(localized: "mount_bookmark_failed"), msg)
        }
    }
}

extension Notification.Name {
    /// 挂载表发生变化（增删 / 启用停用 / 改只读），供占位目录同步器实时对账。
    static let mountStoreDidChange = Notification.Name("mountStoreDidChange")
}

extension MountStore {
    /// 在锁内（queue.sync）持久化后调用，切到主线程广播挂载变更通知。
    /// 占位目录同步器监听后做实时对账；此处不直接做 I/O，保持热路径轻量。
    private func notifyChangedLocked() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .mountStoreDidChange, object: nil)
        }
    }
}
