import Foundation
import os

// MARK: - File System Manager

enum FileWriteActor {
    case agent
    case memory
    case shellAutomatic
    case browserAutomatic
}


final class FileSystemManager: @unchecked Sendable {
    static let shared = FileSystemManager()

    private let fileManager = FileManager.default

    // MARK: - Bundle 资源同步(2026-08-09 线程治理:后台执行)

    /// bundled rules/skills/subagent-profiles「先删后拷」同步队列(后台,串行)。
    /// 冷启动时这批全量磁盘 IO 曾阻塞主线程(启动卡顿 P0),现移后台;
    /// 依赖方(角色加载/prompt 构建读规则)经 waitForBundledSync() 等待完成信号。
    private let bundleSyncQueue = DispatchQueue(label: "com.neartop.miniclaw.bundlesync", qos: .userInitiated)
    private let bundleSyncLock = NSLock()
    private var _bundledSyncDone = false
    private var bundledSyncWaiters: [CheckedContinuation<Void, Never>] = []

    /// bundle 资源是否已同步完成(锁内读,任意线程)
    var isBundledSyncDone: Bool {
        bundleSyncLock.lock(); defer { bundleSyncLock.unlock() }
        return _bundledSyncDone
    }

    /// 启动时调用:后台串行执行同步(rules 散文件 + BundledPlugins 各类型 mpk),完成后置标记并唤醒等待者。
    /// 不阻塞主线程;同步期间读取方短暂读到旧版/空目录,由 waitForBundledSync 兜底。
    /// 注:subagent 内置角色已并入 BundledPlugins 的 .mpk 体系(syncBundledPlugins 统一分发)。
    func syncBundledResourcesInBackground() {
        bundleSyncQueue.async { [self] in
            syncBundledRules()
            syncBundledPlugins()
            bundleSyncLock.lock()
            _bundledSyncDone = true
            let waiters = bundledSyncWaiters
            bundledSyncWaiters.removeAll()
            bundleSyncLock.unlock()
            for w in waiters { w.resume() }
            AppLogger.shared.info("[FS] bundled resources synced (background)", category: "FS")
        }
    }

    /// 等待 bundle 资源同步完成(异步,不阻塞主线程;已完成则立即返回)。
    func waitForBundledSync() async {
        if isBundledSyncDone { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            bundleSyncLock.lock()
            if _bundledSyncDone {
                bundleSyncLock.unlock()
                cont.resume()
                return
            }
            bundledSyncWaiters.append(cont)
            bundleSyncLock.unlock()
        }
    }

    // MARK: - Frontmatter 解析（SOUL.md 等带元信息的 markdown）

    /// 解析形如 `---- key: value ----` 的 frontmatter，返回元数据与正文。
    /// 无 frontmatter 时返回空元数据且 body 为原文（向后兼容旧 SOUL.md）。
    static func parseFrontmatter(_ raw: String) -> (meta: [String: String], body: String) {
        var meta: [String: String] = [:]
        let lines = raw.components(separatedBy: "\n")
        guard lines.count > 1, isDelimiter(lines[0]) else { return (meta, raw) }
        var end = -1
        for i in 1..<lines.count {
            if isDelimiter(lines[i]) { end = i; break }
        }
        guard end > 0 else { return (meta, raw) }
        for fl in lines[1..<end] {
            guard let colon = fl.firstIndex(of: ":") else { continue }
            let key = fl[..<colon].trimmingCharacters(in: .whitespaces)
            var value = String(fl[fl.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty else { continue }
            meta[key] = value
        }
        let body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (meta, body)
    }

    private static func isDelimiter(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t.allSatisfy { $0 == "-" } && t.count >= 3
    }

    /// 默认 SOUL.md 内容（首次安装 / 重置时写入）。单一真源，FileSystemManager 与设置重置共用。
    static let defaultSoulMarkdown = """
    ---
    name: "MiniClaw"
    style: "可爱、务实"
    lang: "auto"
    ---

    """

    /// 长期记忆文件的默认内容。GLOBAL.md 已改为规则文件，不再存放记忆。
    static let defaultMemoryMarkdown = """
    # 长期记忆

    在此记录需要跨会话长期保留的记忆。
    """

    var miniClawRoot: URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent("MiniClaw", isDirectory: true)
    }

    // Subdirectories
    var attachmentsDir: URL { miniClawRoot.appendingPathComponent("attachments") }
    var workspaceDir: URL { miniClawRoot.appendingPathComponent("workspace") }
    var sharedDir: URL { miniClawRoot.appendingPathComponent("shared") }
    var offloadsDir: URL { miniClawRoot.appendingPathComponent("offloads") }
    var browserDir: URL { miniClawRoot.appendingPathComponent("browser") }
    var modelsDir: URL { miniClawRoot.appendingPathComponent("models") }
    /// Models.dev 模型能力缓存（首次联网抓取后落盘，避免每次请求外网）
    var modelsDevCacheURL: URL { modelsDir.appendingPathComponent("models_dev_cache.json") }
    var memoryDir: URL { miniClawRoot.appendingPathComponent("memory") }
    // MARK: - 统一插件沙盒布局（2026-08-27 Stage-2）

    /// 统一插件沙盒根：`plugins/<type>/<插件目录>/`。
    /// plugin.json 的 `type` 字段决定分发目的地；各类型消费方沿用各自 dir 计算属性，零感知。
    /// 存量旧布局由 `migrateLegacyLayoutIfNeeded()` 一次性迁移（skills/、subagent-profiles/、rules/）。
    var pluginsRoot: URL { miniClawRoot.appendingPathComponent("plugins") }
    func pluginTypeDir(_ type: String) -> URL { pluginsRoot.appendingPathComponent(type) }

    var rulesDir: URL { pluginTypeDir("rule") }
    var skillsDir: URL { pluginTypeDir("skill") }
    /// 子代理角色插件目录 = plugins/subagent/<id>/（强制 plugin.json[type=subagent] + SKILL.md）。
    var subagentProfilesDir: URL { pluginTypeDir("subagent") }
    /// 配置目录：providers.json / settings.json / settings_audit.json
    var configDir: URL { miniClawRoot.appendingPathComponent("config") }
    /// 内部缓存目录（向量索引 / embeddings 等），刻意避开 memory/ 写入门禁。
    var cacheDir: URL { miniClawRoot.appendingPathComponent(".cache") }
    /// 记忆向量索引缓存目录。
    var embeddingsCacheDir: URL { cacheDir.appendingPathComponent("embeddings") }

    /// 读取内置插件同步 manifest：**id → type** 映射（记录由 App 内置管理、每次启动被同名内置包覆盖的插件）。
    /// 用于区分「内置/导入」与清理已移除的内置包（type 决定其在 plugins/<type>/ 下的位置）。
    /// 未上架不做旧格式兼容：仅认 v2 格式 = pluginsRoot/.bundled-manifest.json（JSON object）。
    func bundledPluginEntries() -> [String: String] {
        let url = pluginsRoot.appendingPathComponent(".bundled-manifest.json")
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let obj = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return obj
    }

    func saveBundledPluginEntries(_ entries: [String: String]) {
        let url = pluginsRoot.appendingPathComponent(".bundled-manifest.json")
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    /// 内置插件 id 集合（不区分类型的调用方使用）。
    func bundledPluginIds() -> Set<String> {
        Set(bundledPluginEntries().keys)
    }
    var mountsDir: URL { miniClawRoot.appendingPathComponent("mounts") }

    // MARK: - 受支持附件类型（spec 2.3.2）

    /// 附件目录支持的媒体扩展名：图片/音频/视频
    static let attachmentExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp",
        "mp3", "m4a", "wav",
        "mp4", "mov", "m4v"
    ]

    /// 判断给定路径是否为受支持的附件类型
    func isSupportedAttachment(_ path: String) -> Bool {
        Self.attachmentExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private init() {
        createDirectoryStructure()
    }

    private func createDirectoryStructure() {
        let dirs = [
            miniClawRoot,
            attachmentsDir,
            workspaceDir,
            sharedDir,
            offloadsDir,
            browserDir,
            configDir,
            modelsDir,
            memoryDir,
            rulesDir,
            skillsDir,
            subagentProfilesDir,
            mountsDir
        ]

        for dir in dirs {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // 旧沙盒布局清退（未上架不做兼容：检测到旧根目录即整树删除；先于一切同步/加载执行）。
        purgeLegacyLayoutDirectories()

        // Create initial SOUL.md if not exists（frontmatter 对齐 SoulConfig）
        let soulPath = memoryDir.appendingPathComponent("SOUL.md")
        if !fileManager.fileExists(atPath: soulPath.path) {
            try? FileSystemManager.defaultSoulMarkdown.write(to: soulPath, atomically: true, encoding: .utf8)
        }

        // Create MEMORY.md as the sole long-term memory file.
        let memoryPath = memoryDir.appendingPathComponent("MEMORY.md")
        if !fileManager.fileExists(atPath: memoryPath.path) {
            try? Self.defaultMemoryMarkdown.write(to: memoryPath, atomically: true, encoding: .utf8)
        }

        // bundled 资源删+拷已移后台(syncBundledResourcesInBackground),
        // 依赖方经 waitForBundledSync() 等待完成(2026-08-09 线程治理)。
    }

    // MARK: - Bundled Rules

    /// 将 App Bundle 中的项目托管规则同步到 Documents/MiniClaw/rules。
    /// Bundle 内同名文件始终覆盖，以便 App 升级时发布规则更新；用户自行新增的其他文件会保留。
    /// 上一版本由 Bundle 托管、但新版本已经移除的规则会依据 manifest 清理。
    private func syncBundledRules() {
        // 2026-08-12 治本:优先同步当前语言子目录 BundledRules/<lang>/ 的规则文件
        // (存在则用,否则回退根目录中文版)。en/ja/ko 版本可分别提供。
        let resourceURL = Bundle.main.resourceURL
        let langCode = L10n.shared.current.tableCode
        let langDir = resourceURL?
            .appendingPathComponent("BundledRules", isDirectory: true)
            .appendingPathComponent(langCode, isDirectory: true)
        var bundledRulesDir: URL?
        if let langDir, fileManager.fileExists(atPath: langDir.path) {
            bundledRulesDir = langDir
        } else if let base = resourceURL?.appendingPathComponent("BundledRules", isDirectory: true),
                  fileManager.fileExists(atPath: base.path) {
            bundledRulesDir = base
        }
        guard let bundledRulesDir else { return }
        let manifestURL = rulesDir.appendingPathComponent(".bundled-rules-manifest.json")
        let previousManagedFiles = loadBundledRulesManifest(at: manifestURL)
        let bundledFiles = recursiveFiles(in: bundledRulesDir)
        var currentManagedFiles = Set<String>()

        for sourceURL in bundledFiles {
            guard let relativePath = relativePath(of: sourceURL, under: bundledRulesDir),
                  !relativePath.isEmpty else { continue }

            currentManagedFiles.insert(relativePath)
            let destinationURL = rulesDir.appendingPathComponent(relativePath)

            do {
                try fileManager.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            } catch {
                continue
            }
        }

        for removedPath in previousManagedFiles.subtracting(currentManagedFiles) {
            let staleURL = rulesDir.appendingPathComponent(removedPath).standardizedFileURL
            guard contains(staleURL, in: rulesDir),
                  fileManager.fileExists(atPath: staleURL.path) else { continue }
            try? fileManager.removeItem(at: staleURL)
        }

        saveBundledRulesManifest(currentManagedFiles, to: manifestURL)
    }

    // MARK: - Bundled Plugins（.mpk 压缩包）

    /// 将 App Bundle 中的内置插件（`.mpk`）解包同步到 `plugins/<type>/<plugin-id>/`。
    /// 每个 `.mpk` 是标准 zip，内部固定含 `<plugin-id>/plugin.json`（强制清单）+ 内容文件；
    /// `type` 决定分发目的地（skill→plugins/skill、subagent→plugins/subagent…）。
    /// 与 rules 同理：Bundle 同名覆盖升级；用户自建插件目录保留；已移除的内置插件按 manifest 清理。
    /// **强制 plugin.json**：缺失 plugin.json 或读不到 id/type 时整体拒绝解包（不兼容旧单文件 SKILL.md）。
    private func syncBundledPlugins() {
        guard let bundledPluginsDir = Bundle.main.resourceURL?
            .appendingPathComponent("BundledPlugins", isDirectory: true),
              fileManager.fileExists(atPath: bundledPluginsDir.path) else {
            return
        }
        let previousEntries = bundledPluginEntries()
        var currentEntries: [String: String] = [:]

        // 列举内置 .mpk 包
        let mpkURLs: [URL]
        do {
            mpkURLs = try fileManager.contentsOfDirectory(at: bundledPluginsDir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "mpk" }
        } catch {
            mpkURLs = []
        }

        for mpkURL in mpkURLs {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("miniclaw_bundled_plugin_\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                try ZipArchive.extract(at: mpkURL, into: tmp)
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                continue
            }
            guard let pluginDir = findPluginDirectory(in: tmp) else {
                try? FileManager.default.removeItem(at: tmp)
                continue
            }
            let pluginURL = URL(fileURLWithPath: pluginDir.path).appendingPathComponent("plugin.json")
            guard let (id, type) = Self.pluginIDAndType(from: pluginURL) else {
                // 强制 plugin.json：缺失或读不到 id/type → 拒绝该内置包
                try? FileManager.default.removeItem(at: tmp)
                continue
            }
            currentEntries[id] = type
            let dest = pluginTypeDir(type).appendingPathComponent(id)
            // 同名覆盖升级（先删后拷，避免半包残留）
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.copyItem(at: URL(fileURLWithPath: pluginDir.path), to: dest)
            } catch {
                try? FileManager.default.removeItem(at: dest)
                currentEntries.removeValue(forKey: id)
            }
            try? FileManager.default.removeItem(at: tmp)
        }

        // 清理已移除的内置插件目录（manifest 中记录但当前不再内置的 id）
        for (oldID, oldType) in previousEntries where currentEntries[oldID] == nil {
            let typeDir = pluginTypeDir(oldType)
            let staleURL = typeDir.appendingPathComponent(oldID).standardizedFileURL
            guard contains(staleURL, in: typeDir),
                  fileManager.fileExists(atPath: staleURL.path) else { continue }
            try? fileManager.removeItem(at: staleURL)
        }

        saveBundledPluginEntries(currentEntries)
    }

    /// 从 plugin.json 宽松读取插件 id 与 type（JSONSerialization，与导入链路同口径；二者均强制非空）。
    private static func pluginIDAndType(from url: URL) -> (id: String, type: String)? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String, !id.isEmpty,
              let type = obj["type"] as? String, !type.isEmpty else { return nil }
        return (id, type)
    }

    /// 递归查找含 `plugin.json` 的目录，返回路径最浅的一个（避免嵌套）。
    private func findPluginDirectory(in root: URL) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var candidates: [URL] = []
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == "plugin.json" {
                candidates.append(fileURL.deletingLastPathComponent())
            }
        }
        return candidates.sorted { $0.path.count < $1.path.count }.first
    }

    // MARK: - 旧布局清退（2026-08-27 唐唐决策：App 未上架，历史沙盒数据一律不做兼容）

    /// 统一 `plugins/<type>/` 布局引入前，旧根下曾存在 skills / subagent-profiles / rules 物理目录。
    /// 未上架 = 不做任何旧数据迁移与读取兼容：检测到即**整树删除**（含全部旧格式内容），
    /// 新布局全部由 Bundle 同步重建；用户自建的旧内容随清退一并丢弃。
    /// 位于 createDirectoryStructure 内同步调用，先于一切 Bundle 同步与加载；
    /// 删除后 exists 恒为假，重复启动零开销、无需标志位。
    private func purgeLegacyLayoutDirectories() {
        let legacyDirs = [
            miniClawRoot.appendingPathComponent("skills"),
            miniClawRoot.appendingPathComponent("subagent-profiles"),
            miniClawRoot.appendingPathComponent("rules"),
        ]
        for url in legacyDirs where fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
            AppLogger.shared.info("[FS] purged legacy dir: \(url.lastPathComponent)", category: "FS", subsystem: "Migration")
        }
    }

    /// 返回 skills/ 下所有技能子目录，按目录名稳定排序。
    func skillDirectories() -> [URL] {
        guard let subs = try? fileManager.contentsOfDirectory(at: skillsDir, includingPropertiesForKeys: nil) else { return [] }
        return subs
            .filter { $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// 返回 rules/ 下所有可注入 Markdown，递归扫描并按相对路径稳定排序。
    func ruleMarkdownFiles() -> [URL] {
        recursiveFiles(in: rulesDir)
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted {
                let lhs = relativePath(of: $0, under: rulesDir) ?? $0.lastPathComponent
                let rhs = relativePath(of: $1, under: rulesDir) ?? $1.lastPathComponent
                let comparison = lhs.localizedCaseInsensitiveCompare(rhs)
                return comparison == .orderedSame ? lhs < rhs : comparison == .orderedAscending
            }
    }

    private func recursiveFiles(in directory: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files.append(url)
            }
        }
        return files
    }

    private func relativePath(of fileURL: URL, under directoryURL: URL) -> String? {
        let rootPath = directoryURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return nil }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    private func loadBundledRulesManifest(at url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let paths = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(paths)
    }

    private func saveBundledRulesManifest(_ paths: Set<String>, to url: URL) {
        guard let data = try? JSONEncoder().encode(paths.sorted()) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - File Operations

    func readFile(at path: String, offset: Int? = nil, limit: Int? = nil, tail: Int? = nil, sessionID: UUID? = nil) throws -> String {
        let url = try resolveAgentPath(path, sessionID: sessionID)

        guard fileManager.fileExists(atPath: url.path) else {
            throw FileError.notFound(path)
        }
        guard !isBinaryFile(url) else {
            throw FileError.binaryFileNotSupported(path)
        }

        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: "\n")
        if let tail {
            guard tail >= 0 else { throw FileError.invalidRange("tail 必须大于等于 0") }
            return lines.suffix(tail).joined(separator: "\n")
        }

        let start = offset ?? 0
        guard start >= 0 else { throw FileError.invalidRange("offset 必须大于等于 0") }
        if let limit, limit < 0 { throw FileError.invalidRange("limit 必须大于等于 0") }
        guard start < lines.count else { return "" }
        let end = limit.map { min(start + $0, lines.count) } ?? lines.count
        return lines[start..<end].joined(separator: "\n")
    }

    func writeFile(
        at path: String,
        content: String,
        append: Bool = false,
        createDirs: Bool = true,
        actor: FileWriteActor = .agent,
        sessionID: UUID? = nil
    ) throws {
        let url = try resolveAgentPath(path, sessionID: sessionID)
        try validateWrite(url, actor: actor, mustExist: false)
        if path.hasPrefix("/var/MiniClaw/mounts/") {
            NSLog("[FileSystemManager] writeFile path=%@ → resolved=%@", path, url.path)
        }

        if createDirs {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        if append && fileManager.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = content.data(using: .utf8) { try handle.write(contentsOf: data) }
        } else {
            // 2026-08-13 崩溃修复:改用 Data 原子写,去掉 NSString 桥接
            // (content.write(to:atomically:encoding:) 的 objc_msgSend 是
            // offloadIfLarge 崩溃的落点)。
            try Data(content.utf8).write(to: url, options: .atomic)
        }
    }

    func editFile(at path: String, oldString: String, newString: String, sessionID: UUID? = nil) throws {
        let url = try resolveAgentPath(path, sessionID: sessionID)
        try validateWrite(url, actor: .agent, mustExist: true)
        guard fileManager.fileExists(atPath: url.path) else { throw FileError.notFound(path) }
        guard !isBinaryFile(url) else { throw FileError.binaryFileNotSupported(path) }
        var content = try String(contentsOf: url, encoding: .utf8)

        guard let range = content.range(of: oldString) else {
            throw FileError.stringNotFound(oldString)
        }
        content.replaceSubrange(range, with: newString)
        // 2026-08-13 崩溃修复:同 writeFile,改用 Data 原子写。
        try Data(content.utf8).write(to: url, options: .atomic)
    }

    func imageURL(at path: String, sessionID: UUID? = nil) throws -> URL {
        let url = try resolveAgentPath(path, sessionID: sessionID)
        let supported: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
        guard supported.contains(url.pathExtension.lowercased()) else {
            throw FileError.unsupportedImage(path)
        }
        guard fileManager.fileExists(atPath: url.path) else { throw FileError.notFound(path) }
        return url
    }

    func writeAutomaticData(at path: String, data: Data, actor: FileWriteActor, sessionID: UUID? = nil) throws {
        let url = try resolveAgentPath(path, sessionID: sessionID)
        try validateWrite(url, actor: actor, mustExist: false)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func fileExists(at path: String, sessionID: UUID? = nil) -> Bool {
        fileManager.fileExists(atPath: resolvePath(path, sessionID: sessionID).path)
    }

    func listDirectory(at path: String, sessionID: UUID? = nil) throws -> [String] {
        // 挂载根目录：外部文件夹物理上并不真实存在于沙盒，需从 MountStore 返回虚拟挂载名，
        // 让 Agent 能「发现」有哪些挂载，再钻取 /var/MiniClaw/mounts/<name>/...
        let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalized == "/var/MiniClaw/mounts" {
            return MountStore.shared.list().filter { $0.isMounted }.map { $0.name }.sorted()
        }
        let url = resolvePath(path, sessionID: sessionID)
        if path.hasPrefix("/var/MiniClaw/mounts/") {
            NSLog("[FileSystemManager] listDirectory path=%@ → resolved=%@ exists=%d", path, url.path, fileManager.fileExists(atPath: url.path))
        }
        return try fileManager.contentsOfDirectory(atPath: url.path)
    }

    func deleteFile(at path: String, sessionID: UUID? = nil) throws {
        // 删除是高危操作：走严格的 throwing 解析（含 .. 拒绝与会话/共享边界校验），
        // 不经过 lenient 路径（lenient 越界时只回退，无法区分"不存在"与"被拒"）。
        let url = try resolveAgentPath(path, sessionID: sessionID)
        try fileManager.removeItem(at: url)
    }

    /// 浏览某个挂载内的目录内容，返回每个条目的真实外部 URL（供分享 / 钻取）。
    /// 仅列出名称与目录判定，不读取文件内容。
    func browse(mountName: String, subPath: String) -> [MountFileEntry] {
        let virtual = "/var/MiniClaw/mounts/\(mountName)/\(subPath)".trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let names = (try? listDirectory(at: virtual)) ?? []
        return names.compactMap { name in
            let itemVirtual = virtual.isEmpty
                ? "/var/MiniClaw/mounts/\(mountName)/\(name)"
                : "\(virtual)/\(name)"
            guard let url = try? resolveAgentPath(itemVirtual) else { return nil }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let rel = subPath.isEmpty ? name : "\(subPath)/\(name)"
            return MountFileEntry(name: name, url: url, isDirectory: isDir, relativePath: rel)
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func directorySize(at path: String, sessionID: UUID? = nil) -> Int64 {
        let url = resolvePath(path, sessionID: sessionID)
        return sizeOfDirectory(url)
    }

    /// 计算任意目录树的总字节数（含子目录）。目录不存在时返回 0。
    /// 供设置 → 存储页实时统计工作区 / 附件 / 缓存 / 各会话占用。
    func sizeOfDirectory(_ url: URL) -> Int64 {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        guard let enumerator = fileManager.enumerator(at: url,
                                                     includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalSize += Int64(size)
            }
        }
        return totalSize
    }

    /// 共享（无会话 / fs_context==0）工作区目录名，由设置 `files.defaultWorkspace` 决定。
    /// 默认 "workspace"，用户可在 设置 → 存储 → 文件 中修改。
    var defaultWorkspaceDir: URL {
        miniClawRoot.appendingPathComponent(SettingsStore.shared.settings.files.defaultWorkspace)
    }

    /// 确保共享工作区目录（按 defaultWorkspace 设置命名）存在。幂等、非破坏式。
    func ensureDefaultWorkspace() {
        try? fileManager.createDirectory(at: defaultWorkspaceDir,
                                         withIntermediateDirectories: true)
    }

    // MARK: - 大输出转存（spec 2.3.2 offloads/）

    /// 将可能超长的 shell 输出转存到 offloads/，返回可在聊天中打开的 miniclaw:// URL。
    /// 未超过阈值则原样返回文本，便于直接展示。
    /// - 文件名格式：shell_execute_<ts>_call_<n>.txt
    func offloadIfLarge(_ output: String, thresholdBytes: Int = 8_000, sessionID: UUID? = nil) -> String {
        guard output.utf8.count > thresholdBytes else { return output }
        let n = FileSystemManager.offloadCounter.withLock { c in
            c += 1
            return c
        }
        let ts = Int(Date().timeIntervalSince1970)
        let filename = "shell_execute_\(ts)_call_\(n).txt"
        do {
            try writeFile(
                at: "/var/MiniClaw/offloads/\(filename)",
                content: output,
                actor: .shellAutomatic,
                sessionID: sessionID
            )
            return String(format: L10n.l("fs_offload_notice"), output.utf8.count, filename)
        } catch {
            return output
        }
    }

    private static let offloadCounter = OSAllocatedUnfairLock(initialState: 0)

    // MARK: - Path Resolution / Directory Policy

    /// 会话独享目录（与 iSH hook 的 kSessionPrefixes 保持一致）。
    private static let sessionExclusiveSubdirs: Set<String> = Set(SessionFileRouter.sessionSubdirs)

    /// 严格解析 `/var/MiniClaw/<relative>` → 真实沙盒路径（抛错版，供 Agent 工具入口使用）。
    /// - 会话独享目录（workspace/attachments/browser/offloads）带 `sessionID` 时落到
    ///   `Documents/MiniClaw-Sessions/<uuid>/<relative>`；**不带 sessionID 时抛出 `.sessionRequired`**
    ///   （与 iSH 内核 `fs_context == 0` 拒绝访问会话专属路径的语义一致）。
    /// - 共享目录（shared/skills/memory/mounts/...）始终落到扁平 `miniClawRoot`。
    private func resolveVarMiniClawThrowing(_ relative: String, sessionID: UUID?) throws -> URL {
        // 外部挂载优先（mounts/<name>/... 经 bookmark 解析到外部真实 URL）。
        if let mounted = resolveMountedURL(relative: relative) { return mounted }
        let comps = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        // 统一拒绝目录穿越组件：任何 `..` 都是逃逸企图（standardizedFileURL 会把它解析到
        // 沙盒外的真实路径，绝不能依赖它"自行变安全"），在所有解析分支前拦截。
        if comps.contains("..") {
            throw FileError.pathEscapesRoot("/var/MiniClaw/" + relative)
        }
        let top = comps.first ?? ""
        if Self.sessionExclusiveSubdirs.contains(top) {
            guard let sessionID else {
                throw FileError.sessionRequired("/var/MiniClaw/" + relative)
            }
            let base = SessionFileRouter.shared.sessionHostDirectory(for: sessionID)
            let resolved = base.appendingPathComponent(relative).standardizedFileURL
            // 会话分支边界校验：resolved 必须仍位于本会话根内（与共享分支同级别防护）
            guard isPathSafe(resolved, within: base) else { throw FileError.pathEscapesRoot("/var/MiniClaw/" + relative) }
            return resolved
        }
        let resolved = miniClawRoot.appendingPathComponent(relative).standardizedFileURL
        guard isPathSafe(resolved, within: miniClawRoot, expectedFirst: top) else { throw FileError.pathEscapesRoot("/var/MiniClaw/" + relative) }
        return resolved
    }

    /// 路径边界校验（所有解析分支的唯一校验入口）：
    /// - 必须位于 `within` 根目录内（standardizedFileURL 已解析 `..`，此处做最终防线）；
    /// - 若指定 `expectedFirst`（请求的顶层子目录），标准化后路径的首个组件必须等于它，
    ///   拦截 `shared/../config/...` 这类跨子目录逃逸（未逃出 miniClawRoot 但越过了请求目录语义）。
    private func isPathSafe(_ url: URL, within root: URL, expectedFirst: String? = nil) -> Bool {
        guard contains(url, in: root) else { return false }
        if let expectedFirst, !expectedFirst.isEmpty {
            let rootPath = root.path
            let tail = url.path.hasPrefix(rootPath + "/") ? String(url.path.dropFirst(rootPath.count + 1)) : url.path
            guard let first = tail.split(separator: "/").first else { return false }
            return String(first) == expectedFirst
        }
        return true
    }

    /// 宽松解析（不抛错版，供内部 list/exists/delete/size 等使用）。
    /// 会话独享目录无 sessionID 时回落到扁平 `miniClawRoot`（兼容系统级 / 旧调用）。
    private func resolveVarMiniClawLenient(_ relative: String, sessionID: UUID?) -> URL {
        if let mounted = resolveMountedURL(relative: relative) { return mounted }
        // 统一拒绝目录穿越组件（与 throwing 版本同源，防止 list/exists/delete 越界）
        let comps = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if comps.contains("..") { return miniClawRoot }
        let top = comps.first ?? ""
        if Self.sessionExclusiveSubdirs.contains(top) {
            if let sessionID {
                let base = SessionFileRouter.shared.sessionHostDirectory(for: sessionID)
                let resolved = base.appendingPathComponent(relative).standardizedFileURL
                guard isPathSafe(resolved, within: base) else { return miniClawRoot }
                return resolved
            }
            // 无会话：共享区。`workspace` 可由设置 `files.defaultWorkspace` 重命名。
            if comps.first == "workspace" {
                let name = SettingsStore.shared.settings.files.defaultWorkspace
                let rest = comps.count > 1 ? comps[1...].joined(separator: "/") : ""
                let resolved = miniClawRoot
                    .appendingPathComponent(name)
                    .appendingPathComponent(rest)
                    .standardizedFileURL
                guard isPathSafe(resolved, within: miniClawRoot) else { return miniClawRoot }
                return resolved
            }
            // 其它会话专属子目录（attachments/browser/offloads）无会话时回落扁平（保持原名）
        }
        let resolved = miniClawRoot.appendingPathComponent(relative).standardizedFileURL
        guard isPathSafe(resolved, within: miniClawRoot, expectedFirst: top) else { return miniClawRoot }
        return resolved
    }

    /// 将浏览器工具（screenshot/fetch）返回的 `miniclaw://browser/xxx` 内部链接
    /// 归一化为 `/var/MiniClaw/...` 绝对路径，使其能被 read_image / vision_analyze /
    /// read_document 等文件工具直接消费（二者协议不互通是此前的 bug 来源）。
    /// 非 miniclaw:// 路径原样返回。
    static func normalizeMiniClawURL(_ path: String) -> String {
        guard path.hasPrefix("miniclaw://") else { return path }
        return "/var/MiniClaw/" + String(path.dropFirst("miniclaw://".count))
    }

    /// Agent 文件工具只接受 `/var/MiniClaw/...` 绝对路径，并拒绝目录穿越。
    /// - Parameter sessionID: 绑定会话时传入，用于将会话独享目录隔离到该会话；为 nil 时访问独享目录抛 `.sessionRequired`。
    func resolveAgentPath(_ path: String, sessionID: UUID? = nil) throws -> URL {
        let normalized = Self.normalizeMiniClawURL(path)
        guard normalized.hasPrefix("/var/MiniClaw/") else {
            throw FileError.absolutePathRequired(path)
        }
        let relative = String(normalized.dropFirst("/var/MiniClaw/".count))
        return try resolveVarMiniClawThrowing(relative, sessionID: sessionID)
    }

    /// 若相对路径形如 `mounts/<name>` 或 `mounts/<name>/<sub>`，解析为外部挂载的真实 URL；
    /// 非挂载路径、未启用、bookmark 失效或目录穿越时返回 nil（调用方回退到本地空 mounts 目录）。
    private func resolveMountedURL(relative: String) -> URL? {
        let comps = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard comps.count >= 2, comps[0] == "mounts" else { return nil }
        let name = comps[1]
        let sub = comps.dropFirst(2).joined(separator: "/")
        return MountStore.shared.resolveExternalURL(mountName: name, subPath: sub)
    }

    /// 将 `miniclaw://<目录>/<路径>` 安全映射到沙盒文件。导航型 URL 返回 nil。
    /// - Parameter sessionID: 会话独享目录（attachments/workspace/browser/offloads）优先按会话解析；
    ///   命中即返回，否则回落到扁平目录（兼容隔离前旧文件 / 无会话上下文的点击）。
    func resolveMiniClawResourceURL(_ raw: String, sessionID: UUID? = nil) -> URL? {
        guard let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "miniclaw",
              let host = components.host?.lowercased(),
              ["attachments", "workspace", "shared", "offloads", "browser", "memory", "rules", "skills", "mounts"].contains(host) else {
            return nil
        }
        let decodedPath = components.percentEncodedPath.removingPercentEncoding ?? components.path
        let relative = decodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let isSessionExclusive = ["attachments", "workspace", "browser", "offloads"].contains(host)

        // 会话独享目录：优先按会话解析（隔离后新写入的文件），命中直接返回。
        //
        // ⚠️ 铁律：`URLComponents` 会把 `miniclaw://browser/a.png` 的 `browser` 解析进 `host`，
        // `relative` 里只剩 `a.png`。而写入侧 `resolveVarMiniClawThrowing` 收到的是完整的
        // `browser/a.png`，落盘在 `Sessions/<uuid>/browser/a.png`。因此这里**必须把 host 拼回去**，
        // 否则算出 `Sessions/<uuid>/a.png` 永远 miss（曾导致所有浏览器下载的图片无法显示）。
        if isSessionExclusive, let sessionID {
            let sessionBase = SessionFileRouter.shared.sessionHostDirectory(for: sessionID)
                .appendingPathComponent(host, isDirectory: true)
            let sessionURL = sessionBase.appendingPathComponent(relative).standardizedFileURL
            guard contains(sessionURL, in: sessionBase) else { return nil }
            if fileManager.fileExists(atPath: sessionURL.path) { return sessionURL }
        }

        let base: URL
        switch host {
        case "attachments": base = attachmentsDir
        case "workspace": base = workspaceDir
        case "shared": base = sharedDir
        case "offloads": base = offloadsDir
        case "browser": base = browserDir
        case "memory": base = memoryDir
        case "rules": base = rulesDir
        case "skills": base = skillsDir
        case "mounts":
            // 外部挂载：relative 形如 "<name>/<sub>"，先走 bookmark 解析到外部真实 URL。
            let comps = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if let first = comps.first {
                let sub = comps.dropFirst().joined(separator: "/")
                if let ext = MountStore.shared.resolveExternalURL(mountName: first, subPath: sub) {
                    return ext
                }
            }
            base = mountsDir
        default: return nil
        }
        let resolved = base.appendingPathComponent(relative).standardizedFileURL

        guard contains(resolved, in: base) else { return nil }

        // 会话独享目录回落到扁平区（fs_context=0 / 隔离前的旧文件）：
        // 仅当文件确实存在才返回，避免返回不存在路径导致 UIImage(contentsOfFile:)
        // 静默失败、UI 显示灰框。
        if isSessionExclusive {
            return fileManager.fileExists(atPath: resolved.path) ? resolved : nil
        }
        return resolved
    }

    /// 判断 url 是否落在某个会话的独享子目录下
    /// （MiniClaw-Sessions/<uuid>/<subdir>/...）。
    /// 注意：会话宿主根已移至 `Documents/MiniClaw-Sessions`（与父 bind mount 树
    /// `Documents/MiniClaw` 平级，避免 static bind mount 表在 realfs_getpath 反查时劫持）。
    private func isSessionExclusiveDir(_ url: URL, subdirs: Set<String>) -> Bool {
        let p = url.standardizedFileURL.path
        let root = SessionFileRouter.sessionsHostBase.path + "/"
        guard p.hasPrefix(root) else { return false }
        let rest = String(p.dropFirst(root.count)) // "<uuid>/<subdir>/..."
        let comps = rest.split(separator: "/")
        return comps.count >= 2 && subdirs.contains(String(comps[1]))
    }

    private func validateWrite(_ url: URL, actor: FileWriteActor, mustExist: Bool) throws {
        if mustExist && !fileManager.fileExists(atPath: url.path) { throw FileError.notFound(url.path) }

        let soul = memoryDir.appendingPathComponent("SOUL.md").standardizedFileURL
        let longTermMemory = memoryDir.appendingPathComponent("MEMORY.md").standardizedFileURL
        let isDailyMemory = contains(url, in: memoryDir)
            && url.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}\.md$"#, options: .regularExpression) != nil
        let isWritableMemory = isDailyMemory || url == longTermMemory

        switch actor {
        case .agent:
            // 外部挂载：已启用且「允许写入」的挂载放行；只读挂载给出明确报错。
            if let mount = MountStore.shared.mountInfoForURL(url) {
                guard mount.isWritable else {
                    throw FileError.mountReadOnly(mount.name)
                }
                return
            }
            let allowed = contains(url, in: sharedDir)
                || contains(url, in: skillsDir)
                || isSessionExclusiveDir(url, subdirs: ["workspace", "attachments"])
                || contains(url, in: workspaceDir)    // 扁平回落（兼容旧调用）
                || contains(url, in: attachmentsDir)  // 扁平回落（兼容旧调用）
            guard allowed else { throw FileError.writeNotAllowed(url.path) }
        case .memory:
            guard isWritableMemory, url != soul else { throw FileError.writeNotAllowed(url.path) }
        case .shellAutomatic:
            guard isSessionExclusiveDir(url, subdirs: ["offloads"]) || contains(url, in: offloadsDir) else {
                throw FileError.writeNotAllowed(url.path)
            }
        case .browserAutomatic:
            guard isSessionExclusiveDir(url, subdirs: ["browser"]) || contains(url, in: browserDir) else {
                throw FileError.writeNotAllowed(url.path)
            }
        }
    }

    private func contains(_ candidate: URL, in directory: URL) -> Bool {
        let root = directory.standardizedFileURL.path
        let path = candidate.standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }

    /// 内部服务使用；相对路径仍默认 workspace，外部 Agent 工具不得调用。
    /// - Parameter sessionID: 会话独享目录按会话隔离；为 nil 时回落扁平（宽松，不抛错）。
    private func resolvePath(_ path: String, sessionID: UUID? = nil) -> URL {
        if path.hasPrefix("/var/MiniClaw/") {
            let relative = String(path.dropFirst("/var/MiniClaw/".count))
            return resolveVarMiniClawLenient(relative, sessionID: sessionID)
        }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return workspaceDir.appendingPathComponent(path).standardizedFileURL
    }

    // MARK: - Binary Detection

    private func isBinaryFile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        let data = handle.readData(ofLength: 8192)
        handle.closeFile()
        return data.contains(0)
    }
}

/// 挂载目录浏览条目（名称、真实外部 URL、是否目录、挂载内相对路径）。
/// 顶层类型（位于 FileSystemManager 类之外），供设置页文件浏览器跨文件使用。
