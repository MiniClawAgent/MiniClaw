import Foundation

/// 维护 `Documents/MiniClaw/mounts/<name>` 下的空占位目录，
/// 使 iSH 内 `ls /var/MiniClaw/mounts` 能列出当前启用的挂载名。
///
/// 设计背景（方案 B：fakefs path-translate hook）：
/// - iSH 的 `fakefs_set_path_translate_hook` 只在「访问某个具体路径」时被调用，
///   不会参与「目录枚举（readdir）」；父目录 `/var/MiniClaw/mounts` 走主 bind mount，
///   列的是真实 `Documents/MiniClaw/mounts/` 下的实际条目。
/// - 因此需要在真实 `mounts/` 下为每个启用挂载保留一个**同名空目录**，
///   `ls` 才能列出名字；深入子路径时再由 hook 翻译到外部真实文件。
/// - 占位目录**永远为空、只装名字**；真实文件内容在外部文件夹，本类绝不触碰。
///
/// 同步时机：
/// - App 启动 / iSH boot 时：全量对账一次（在 `do_boot` 末尾经 `@_cdecl` 触发）。
/// - 运行时挂载表变化：`MountStore` 发出 `mountStoreDidChange` 后实时对账。
final class MountPlaceholderSyncer: @unchecked Sendable {
    static let shared = MountPlaceholderSyncer()

    private let queue = DispatchQueue(label: "com.miniclaw.mountplaceholder")
    private let mountsRoot: URL

    private init() {
        self.mountsRoot = FileSystemManager.shared.mountsDir
        let _ = NotificationCenter.default.addObserver(
            forName: .mountStoreDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.reconcile()
        }
    }

    /// 全量对账（可安全重复调用）。
    func reconcile() {
        queue.async { [weak self] in
            self?._reconcileLocked()
        }
    }

    // MARK: - 内部

    /// 以 MountStore 当前启用的挂载名为准，校准真实 `mounts/` 下的占位目录：
    /// - 多出（已删除/停用的挂载残留）→ 删
    /// - 缺失（新挂载）→ 建空目录
    /// 仅操作 `mountsRoot` 内的空占位，绝不触碰任何外部文件夹内容。
    private func _reconcileLocked() {
        let fm = FileManager.default

        // 确保 mounts 根目录存在（FileSystemManager 通常已建，这里双保险）。
        try? fm.createDirectory(at: mountsRoot, withIntermediateDirectories: true)

        let enabled = MountStore.shared.list().filter { $0.isMounted }
        let enabledNames = Set(enabled.map { $0.name })
        NSLog("[MountPlaceholder] reconcile 开始 mountsRoot=%@ 启用挂载名=%@", mountsRoot.path, enabledNames.joined(separator: ","))

        // 1) 清理多余 / 失效的占位目录。
        // 安全约束：仅删除「非已知挂载名」且「为空」的目录，避免误删仍被镜像管理器
        // 使用、含已同步文件 / iSH 写回内容的 `mounts/<name>/`（重启时 MountStore
        // 可能尚未加载导致 knownNames 暂为空，若直接删会丢数据）。
        let knownNames = Set(MountStore.shared.list().map { $0.name })
        // 防御：若 knownNames 为空（MountStore 尚未加载的竞态窗口），本次不做任何删除，
        // 避免把正在被镜像填充的 mounts/<name> 空目录误删，造成 ls 间歇性看不到挂载名。
        if !knownNames.isEmpty {
            if let entries = try? fm.contentsOfDirectory(
                at: mountsRoot,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) {
                for entry in entries {
                    let name = entry.lastPathComponent
                    guard !name.hasPrefix(".") else { continue }
                    // 只处理目录；普通文件（如 MOUNTS_STATUS.txt 状态说明）跳过，避免误删。
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else {
                        continue
                    }
                    // 已知挂载名（含已禁用）：交给镜像管理器处理，此处不碰，避免删镜像内容。
                    if knownNames.contains(name) { continue }
                    if enabledNames.contains(name) { continue }
                    // 非空目录保留（疑似镜像内容），只清真正空的孤儿目录。
                    let hasContent = (try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil).isEmpty) == false
                    if hasContent {
                        NSLog("[MountPlaceholder] 保留非空残留 dir=%@ (疑似镜像内容，跳过删除)", name)
                        continue
                    }
                    try? fm.removeItem(at: entry)
                    NSLog("[MountPlaceholder] 清理失效占位 dir=%@", name)
                }
            }
        }

        // 自解释状态文件：保证 `ls /var/MiniClaw/mounts` 永不静默为空。
        // 列出当前已挂载/已知挂载名，并说明无输出时的排查方向（重装后无挂载也能一眼看出）。
        let statusText = """
        MiniClaw 外部挂载状态（由 App 自动维护，勿手动修改）
        已启用挂载 (\(enabledNames.count) 个)：\(enabledNames.isEmpty ? "（无）" : enabledNames.joined(separator: "、"))
        已知挂载 (\(knownNames.count) 个)：\(knownNames.isEmpty ? "（无）" : knownNames.joined(separator: "、"))

        使用说明：
        - iSH 内访问外部文件夹：/var/MiniClaw/mounts/<挂载名>/
        - 若某路径 ls 无输出：说明该挂载未添加、已停用或书签失效。
        - 请在 MiniClaw App「设置 → 挂载」中添加外部文件夹（重装 App 后需重新添加）。
        """
        let statusURL = mountsRoot.appendingPathComponent("MOUNTS_STATUS.txt")
        try? statusText.write(to: statusURL, atomically: true, encoding: .utf8)

        // 2) 补齐缺失的占位目录。
        for m in enabled {
            let dir = mountsRoot.appendingPathComponent(m.name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
                continue
            }
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            NSLog("[MountPlaceholder] 创建占位 dir=%@", m.name)
        }

        // 诊断：对账后 mountsRoot 实际内容（确认 ls /var/MiniClaw/mounts 是否能列名）。
        if let final = try? fm.contentsOfDirectory(at: mountsRoot, includingPropertiesForKeys: nil) {
            NSLog("[MountPlaceholder] reconcile 结束 mountsRoot 内容=[%@]", final.map { $0.lastPathComponent }.joined(separator: ","))
        }
    }
}
