import Foundation
import os

// MARK: - 会话文件系统路由表（Swift 侧真源）
//
// 严格对应会话隔离规格：
//   1. 每个 ChatSession 分配一个进程内递增的 `fs_context: UInt64`；
//      `0` 保留表示"无会话 / 系统进程"（init、未绑定会话的进程）。
//   2. 维护 `fs_context ↔ sessionUUID` 双向映射（fs_context 只是 Runtime 路由句柄，
//      无需持久化；App 重启后重新分配，符合规格）。
//   3. 被 iSH 内核的 path-translate hook 经 `@_cdecl miniclaw_session_resolve_host_path`
//      在每次文件访问时调用，把会话专属逻辑路径
//      `/var/MiniClaw/{workspace,attachments,browser,offloads}/...`
//      翻译为宿主物理路径 `Documents/MiniClaw-Sessions/<uuid>/<subdir>/...`。
//      注意：会话宿主根刻意放在 `Documents/MiniClaw-Sessions`（**不在**父 bind mount
//      树 `Documents/MiniClaw` 之内）——否则 realfs_getpath 反查时，静态挂载表
//      `/var/MiniClaw → Documents/MiniClaw` 会先命中该前缀，把会话文件反查成错误的
//      guest 路径（这正是此前"ls 列根目录"的根因之一）。
//
// 线程安全：hook 运行在 iSH 内核线程（热路径），全部访问经 `OSAllocatedUnfairLock`
// 保护；本类型不依赖任何 MainActor 状态，可在任意线程同步调用，非阻塞、可重入。

final class SessionFileRouter: Sendable {
    static let shared = SessionFileRouter()

    /// 会话专属逻辑子目录（对应 guest 内 /var/MiniClaw/<name>）。
    /// subagent：该会话的子代理数据（每会话独立 subagent_store.json）。
    static let sessionSubdirs = ["workspace", "attachments", "browser", "offloads", "subagent"]

    /// 宿主物理根：Documents/MiniClaw-Sessions
    /// 刻意放在父 bind mount 树（Documents/MiniClaw）**之外**，避免静态挂载表
    /// 在 realfs_getpath 反查时劫持会话文件路径（详见文件头注释）。
    static let sessionsHostBase: URL = {
        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("MiniClaw-Sessions", isDirectory: true)
    }()

    /// 扁平共享根：Documents/MiniClaw（启动期由 FileSystemManager 创建）。
    /// 供 fs_context == 0（首页终端 / init / 未绑定会话）回落使用，
    /// 保证系统进程访问 /var/MiniClaw/{workspace,attachments,browser,offloads}
    /// 时落到共享扁平区而非 ENOENT，同时仍看不到任何具体会话的 Sessions/<uuid> 内容。
    static let flatMiniClawBase: URL = {
        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("MiniClaw", isDirectory: true)
    }()

    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    private struct State {
        var contextToUUID: [UInt64: UUID] = [:]
        var uuidToContext: [UUID: UInt64] = [:]
        /// 进程内递增的 fs_context 分配计数器（Runtime 路由句柄，无需持久化）。
        var nextFsContext: UInt64 = 1
    }

    private init() {}

    /// 为指定会话分配（或复用）其 fs_context，并确保宿主目录树存在。
    /// 同一进程生命周期内对同一 UUID 返回稳定值；App 重启后重新分配。
    func fsContext(for sessionID: UUID) -> UInt64 {
        // 先查缓存（无锁快路径）
        if let cached = lock.withLock({ $0.uuidToContext[sessionID] }) {
            return cached
        }
        // 分配新值（加锁，二次校验避免并发重复分配；仅操作 inout state，不捕获 self）
        let ctx = lock.withLock { (state: inout State) -> UInt64 in
            if let existing = state.uuidToContext[sessionID] { return existing }
            let newCtx = state.nextFsContext
            state.nextFsContext += 1
            state.contextToUUID[newCtx] = sessionID
            state.uuidToContext[sessionID] = newCtx
            return newCtx
        }
        // 确保新目录存在。
        ensureHostDirs(for: sessionID)
        return ctx
    }

    /// 确保该会话的宿主目录树存在。
    ///
    /// **幂等 + 非破坏式**：只补建缺失的子目录，绝不删除已存在内容。
    /// `createDirectory(withIntermediateDirectories: true)` 对已存在目录不报错，
    /// 并会把父级 `Sessions/<uuid>` 作为中间目录一并创建。
    ///
    /// 注意：这里**刻意不用**"staging 临时目录 + 原子重命名"方案——那会在
    /// `base` 已存在时先 `removeItem(base)` 再搬入空目录，导致 App 重启后
    /// （fs_context 缓存清空 → 首次 shell 触发本函数）把该会话上次遗留的
    /// workspace 文件整体清空（跨重启数据丢失）。会话目录是长期累积文件的，
    /// 初始创建的"原子性"远不如"不丢已有数据"重要。
    func ensureHostDirs(for sessionID: UUID) {
        let base = Self.sessionsHostBase.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        let fm = FileManager.default
        for sub in Self.sessionSubdirs {
            do {
                try fm.createDirectory(at: base.appendingPathComponent(sub, isDirectory: true),
                                       withIntermediateDirectories: true)
            } catch {
                AppLogger.shared.error("会话宿主子目录创建失败 \(sessionID)/\(sub): \(error.localizedDescription)",
                                       category: "Session", subsystem: "FS")
            }
        }
    }

    /// 注销会话（对应规格「删除会话时清理 fsContext」）：
    /// 1. 先移除 fs_context ↔ UUID 双向映射——此后该会话的任何 shell/hook 解析都
    ///    查不到映射（resolve 返回 false → 交由 bind mount/rootfs 落空），
    ///    天然阻止新的文件访问落入已删除会话；
    /// 2. 再在后台队列删除宿主 `Sessions/<uuid>/` 目录树（避免阻塞主线程）。
    /// 可重复调用（幂等）；未注册过 fs_context 的会话也会清理目录。
    func unregister(sessionID: UUID) {
        lock.withLock { (state: inout State) in
            if let ctx = state.uuidToContext.removeValue(forKey: sessionID) {
                state.contextToUUID.removeValue(forKey: ctx)
            }
        }
        let dir = Self.sessionsHostBase.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// 会话宿主根目录（Swift 侧工具直接读写用，如 attachments / 产物下载）。
    /// 首次访问时若目录缺失会自动补齐。
    func sessionHostDirectory(for sessionID: UUID) -> URL {
        let base = Self.sessionsHostBase.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        if !FileManager.default.fileExists(atPath: base.path) {
            ensureHostDirs(for: sessionID)
        }
        return base
    }

    // MARK: - C 可调用解析（被 iSH hook 调用）

    /// 把 guest 会话专属路径翻译为宿主物理路径，写入 outHostPath（NUL 结尾）。
    /// - 返回 true：已翻译并写入 outHostPath；
    /// - 返回 false：非会话专属路径（交由静态 bind mount / rootfs）。
    ///
    /// `fs_context == 0`（init / 系统进程 / 未绑定会话 / 首页终端）访问会话专属路径时，
    /// 回落到扁平共享目录 `Documents/MiniClaw/<sub>`（启动期已创建），避免 ENOENT；
    /// 系统进程只能见到共享扁平区，看不到任何具体会话的 `Sessions/<uuid>` 内容，隔离语义不变。
    /// `fs_context != 0` 时按映射路由到 `Documents/MiniClaw-Sessions/<uuid>/<sub>`，实现会话间隔离。
    /// 查询 fs_context 对应的会话 UUID（热路径只读，供 cdecl 把 fs_context
    /// 还原为 guest 会话根路径 /var/MiniClaw/sessions/<uuid>）。
    func contextToUUID(_ fsContext: UInt64) -> UUID? {
        lock.withLock { $0.contextToUUID[fsContext] }
    }

    func resolve(fsContext: UInt64,
                 guestPath: String,
                 outHostPath: UnsafeMutablePointer<CChar>,
                 outSize: Int) -> Bool {
        // 热路径：禁止任何日志 / 阻塞。

        // ---- 会话专属根目录：/var/MiniClaw/sessions/<uuid>/<rest> ----
        // 路径内自带 uuid，按"路径 uuid 必须匹配当前 fs_context 所属会话"做隔离校验，
        // 防止跨会话越权（A 会话 shell 拼 B 的 uuid 也无法路由）。
        // fs_context == 0（系统进程 / 首页终端）无映射 → 返回 false（Sessions 是纯会话概念，
        // 系统进程本就不应见到任何具体会话目录）。
        let sessionsPrefix = "/var/MiniClaw/sessions"
        if guestPath == sessionsPrefix || guestPath.hasPrefix(sessionsPrefix + "/") {
            let remainder: String
            if guestPath == sessionsPrefix {
                remainder = ""
            } else {
                remainder = String(guestPath.dropFirst(sessionsPrefix.count + 1)) // "<uuid>/<rest>"
            }
            // 取路径中的 uuid 做隔离校验
            let firstSlash = remainder.firstIndex(of: "/")
            let pathUUID = String(remainder[..<(firstSlash ?? remainder.endIndex)])
            guard let expected = lock.withLock({ $0.contextToUUID[fsContext] }),
                  expected.uuidString == pathUUID else { return false }
            var hostURL = Self.sessionsHostBase
            if !remainder.isEmpty {
                hostURL.appendPathComponent(remainder)
            }
            let pathStr = hostURL.path
            let bytes = Array(pathStr.utf8)
            guard bytes.count + 1 <= outSize else { return false }
            for i in 0..<bytes.count { outHostPath[i] = CChar(bitPattern: bytes[i]) }
            outHostPath[bytes.count] = 0
            return true
        }

        // ---- 会话逻辑子目录：/var/MiniClaw/{workspace,attachments,browser,offloads} ----
        // 这类路径不带 uuid，完全由 fs_context 路由到当前会话；其余路径
        // （skills/memory/mounts/系统目录）交由静态 bind mount / rootfs 处理。
        let matched = Self.sessionSubdirs.first { sub in
            let prefix = "/var/MiniClaw/\(sub)"
            return guestPath == prefix || guestPath.hasPrefix(prefix + "/")
        }
        guard let sub = matched else { return false }

        let prefix = "/var/MiniClaw/\(sub)"
        let remainder: String
        if guestPath == prefix {
            remainder = ""
        } else {
            remainder = String(guestPath.dropFirst(prefix.count + 1)) // 去掉 "/var/MiniClaw/<sub>/"
        }

        var host: URL
        if fsContext == 0 {
            // fs_context == 0：无会话 / 系统进程（首页终端、init、未绑定会话）。
            // 回落到扁平共享目录 Documents/MiniClaw/<sub>（由 FileSystemManager 启动期创建），
            // 既避免访问会话专属路径时 ENOENT，也保留隔离语义：系统进程只能见到共享扁平区，
            // 看不到任何具体会话的 Sessions/<uuid> 内容。
            host = Self.flatMiniClawBase.appendingPathComponent(sub, isDirectory: true)
        } else {
            guard let uuid = lock.withLock({ $0.contextToUUID[fsContext] }) else { return false }
            host = Self.sessionsHostBase
                .appendingPathComponent(uuid.uuidString, isDirectory: true)
                .appendingPathComponent(sub, isDirectory: true)
        }
        if !remainder.isEmpty {
            host.appendPathComponent(remainder)
        }

        let pathStr = host.path
        let bytes = Array(pathStr.utf8)
        guard bytes.count + 1 <= outSize else { return false }
        for i in 0..<bytes.count { outHostPath[i] = CChar(bitPattern: bytes[i]) }
        outHostPath[bytes.count] = 0
        return true
    }

    // MARK: - 反向解析（host → guest，供 realfs_getpath 反查）

    /// 把宿主绝对路径翻译回 guest 路径，供 iSH `realfs_getpath()` 在 F_GETPATH
    /// 反查时调用（ls / getcwd / 路径显示都依赖它）。例如：
    ///   /var/mobile/.../Documents/MiniClaw-Sessions/<uuid>/<sub>/<tail>
    ///   /private/var/mobile/.../Documents/MiniClaw-Sessions/<uuid>/<sub>/<tail>
    /// → /var/MiniClaw/sessions/<uuid>/<sub>/<tail>
    ///
    /// 只要 host 路径含会话隔离标记 `MiniClaw-Sessions/` 且后续首个组件形如
    /// `<uuid>` 即命中，统一反查为 `/var/MiniClaw/sessions/<uuid>/<rest>` 形态
    /// （与 forward hook 的 Sessions 形态一致），使会话内 `pwd` / `ls` / 路径显示
    /// 始终落在会话专属根目录内。其余路径一律返回 nil，交由静态 bind mount 表
    /// （/var/MiniClaw → Documents/MiniClaw）或 realfs 根兜底处理，避免误伤其它路径。
    ///
    /// 用子串定位而非前缀匹配，天然兼容 F_GETPATH 在 iOS 上返回 `/private/var`
    /// 与 `/var` 两种形式，也兼容 Documents 实际所处的任意容器路径。
    ///
    /// 热路径：禁止任何日志 / 阻塞。
    func reverseResolve(hostPath: String) -> String? {
        let marker = "MiniClaw-Sessions/"
        guard let range = hostPath.range(of: marker) else { return nil }
        let remainder = hostPath[range.upperBound...] // "<uuid>/<sub>/<tail>"
        let parts = remainder.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 1 else { return nil }
        let uuid = String(parts[0])
        guard UUID(uuidString: uuid) != nil else { return nil }
        if parts.count == 1 {
            return "/var/MiniClaw/sessions/\(uuid)"
        }
        let tail = parts.dropFirst().joined(separator: "/")
        return "/var/MiniClaw/sessions/\(uuid)/\(tail)"
    }
}

/// 由 iSH 内核 path-translate hook（C）调用的桥接函数。
/// 运行在 iSH 内核线程，必须非阻塞、可重入，不触碰任何 MainActor 状态。
@_cdecl("miniclaw_session_resolve_host_path")
public func miniclaw_session_resolve_host_path(
    _ fsContext: UInt64,
    _ guestPath: UnsafePointer<CChar>,
    _ outHostPath: UnsafeMutablePointer<CChar>,
    _ outSize: Int
) -> Bool {
    SessionFileRouter.shared.resolve(
        fsContext: fsContext,
        guestPath: String(cString: guestPath),
        outHostPath: outHostPath,
        outSize: outSize
    )
}

/// 由 iSH 内核 realfs_getpath() 经 `fakefs_set_path_reverse_hook` 注册的 C 回调调用。
/// 把宿主绝对路径（F_GETPATH 结果）反查为 guest 路径写入 outGuestPath。
/// 运行在 iSH 内核线程，必须非阻塞、可重入，不触碰任何 MainActor 状态。
@_cdecl("miniclaw_session_reverse_host_path")
public func miniclaw_session_reverse_host_path(
    _ hostPath: UnsafePointer<CChar>,
    _ outGuestPath: UnsafeMutablePointer<CChar>,
    _ outSize: Int
) -> Bool {
    guard let guest = SessionFileRouter.shared.reverseResolve(hostPath: String(cString: hostPath)) else {
        return false
    }
    let bytes = Array(guest.utf8)
    guard bytes.count + 1 <= outSize else { return false }
    for i in 0..<bytes.count { outGuestPath[i] = CChar(bitPattern: bytes[i]) }
    outGuestPath[bytes.count] = 0
    return true
}

/// 由 C 侧（会话 shell 启动前，ISHShellExecutor 在 do_execve 前）调用，
/// 把 fs_context 还原为 guest 会话根路径 `/var/MiniClaw/sessions/<uuid>`，
/// 供会话 shell 启动即 chdir 进本会话专属文件夹。fs_context 无映射（==0）时返回 false。
/// 运行在 iSH 内核线程，必须非阻塞、可重入，不触碰任何 MainActor 状态。
@_cdecl("miniclaw_session_guest_root")
public func miniclaw_session_guest_root(
    _ fsContext: UInt64,
    _ outGuestPath: UnsafeMutablePointer<CChar>,
    _ outSize: Int
) -> Bool {
    guard let uuid = SessionFileRouter.shared.contextToUUID(fsContext) else { return false }
    let guest = "/var/MiniClaw/sessions/\(uuid.uuidString)"
    let bytes = Array(guest.utf8)
    guard bytes.count + 1 <= outSize else { return false }
    for i in 0..<bytes.count { outGuestPath[i] = CChar(bitPattern: bytes[i]) }
    outGuestPath[bytes.count] = 0
    return true
}
