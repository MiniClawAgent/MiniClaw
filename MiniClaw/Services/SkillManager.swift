import Foundation
import zlib



// MARK: - Zip Deflate 解压（zlib，Foundation 已链接，无需额外依赖）

/// 用 zlib 的 `inflate` 解压 DEFLATE 数据流（zip 的标准压缩方法）。
private enum ZipInflate {
    /// 用 zlib 的 inflate 解压 DEFLATE 数据流（zip 的标准压缩方法）。
    static func inflateData(_ data: Data) throws -> Data {
        var out = Data()
        var strm = z_stream()
        let initResult = inflateInit2_(&strm, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else { throw SkillError.invalidName }

        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        var result: Int32 = Z_OK

        var input = [UInt8](data)
        var inputLeft = input.count
        while inputLeft > 0 {
            let consumed = input.count - inputLeft
            let total = input.count
            let inputCopy = input
            withExtendedLifetime(inputCopy) {
                input.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) in
                    let base = ptr.baseAddress?.assumingMemoryBound(to: Bytef.self)
                    strm.next_in = base?.advanced(by: consumed)
                    strm.avail_in = UInt32(min(inputLeft, Int(Int32.max)))
                    // 2026-08-12:输出缓冲指针与 inflate 调用必须在同一闭包内(避免悬垂指针)。
                    while strm.avail_in > 0 {
                        var produced = 0
                        buffer.withUnsafeMutableBytes { (outPtr: UnsafeMutableRawBufferPointer) in
                            strm.next_out = outPtr.bindMemory(to: Bytef.self).baseAddress
                            strm.avail_out = UInt32(chunk)
                            let r = inflate(&strm, Z_NO_FLUSH)
                            if r != Z_OK && r != Z_STREAM_END && r != Z_BUF_ERROR {
                                result = r
                            }
                            produced = chunk - Int(strm.avail_out)
                        }
                        // 闭包外 append:避免与 buffer 独占访问重叠。
                        if produced > 0 {
                            out.append(buffer, count: produced)
                        }
                        if result != Z_OK || strm.avail_in == 0 { break }
                    }
                }
            }
            inputLeft = total - Int(strm.avail_in)
            if result != Z_OK && result != Z_STREAM_END { break }
        }

        inflateEnd(&strm)
        guard result == Z_OK || result == Z_STREAM_END else { throw SkillError.invalidName }
        return out
    }
}



/// 技能总管：扫描沙盒 skills/ 目录、解析 SKILL.md、管理启用状态、为 system prompt 提供注入文本。
/// 兼容技能格式目录格式，可直接放入符合规范的技能目录。
@MainActor
final class SkillManager {

    static let shared = SkillManager()
    private init() {}

    private var fs: FileSystemManager { FileSystemManager.shared }

    // MARK: - 纯读盘（nonisolated，供后台线程调用；主线程低频 UI 调用亦可复用）

    /// 读取 SKILL.md 原文。nonisolated：不依赖任何实例状态，任意线程安全。
    nonisolated static func readSkillRaw(from url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - 加载

    /// 技能列表内存缓存（线程治理 2026-08-09）：技能集合在 App 生命周期内相对稳定，
    /// 主线程高频路径（斜杠命令判定/菜单）不再每次全量读盘；集合变化入口
    /// （创建/删除/导入/启用开关/同步合并）统一 invalidateSkillsCache() 失效。
    private var skillsCache: [SkillPackage]?

    /// 技能集合或启用状态变化时调用，使 loadSkills 缓存失效。
    func invalidateSkillsCache() {
        skillsCache = nil
    }

    /// 扫描 skills/ 下所有子目录，解析每个 SKILL.md，返回技能列表（按 name 排序）。
    /// 启用状态由持久化的 `skillEnabledStates` 决定，缺省为启用；
    /// 来源（内置/导入）依据 Bundle manifest 判断；安装时间首次记录后持久化。
    func loadSkills() -> [SkillPackage] {
        if let cache = skillsCache { return cache }
        let dirs = fs.skillDirectories()
        let settings = SettingsStore.shared.settings
        let enabled = settings.skillEnabledStates
        let bundled = bundledSkillNames()
        var installDates = settings.skillInstallDates
        var changed = false

        var result: [SkillPackage] = []
        for dir in dirs {
            let skillURL = dir.appendingPathComponent("SKILL.md")
            guard let raw = try? String(contentsOf: skillURL, encoding: .utf8) else { continue }
            let fm = Self.parseSkillMarkdown(raw)
            guard !fm.name.isEmpty else { continue }
            let isOn = enabled[fm.name] ?? true
            let isBuiltin = bundled.contains(dir.lastPathComponent)
            let installDate: Date
            if let d = installDates[fm.name] {
                installDate = d
            } else {
                installDate = Date()
                installDates[fm.name] = installDate
                changed = true
            }
            result.append(SkillPackage(
                name: fm.name,
                description: fm.description.isEmpty ? "(无描述)" : fm.description,
                version: fm.version ?? "1.0.0",
                isEnabled: isOn,
                directoryName: dir.lastPathComponent,
                source: isBuiltin ? "builtin" : "imported",
                installDate: installDate
            ))
        }
        if changed {
            SettingsStore.shared.settings.skillInstallDates = installDates
            SettingsStore.shared.save()
        }
        let sorted = result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        skillsCache = sorted
        return sorted
    }

    /// 返回 Bundle manifest 中记录的内置技能目录名集合。
    private func bundledSkillNames() -> Set<String> {
        let paths = fs.bundledSkillsManifest()
        return Set(paths.compactMap { $0.components(separatedBy: "/").first })
    }

    /// 设置技能启用状态并持久化。
    func setEnabled(_ name: String, _ enabled: Bool) {
        SettingsStore.shared.settings.skillEnabledStates[name] = enabled
        SettingsStore.shared.save()
        invalidateSkillsCache()
    }

    /// 返回当前所有已加载技能的 name 集合（用于判断输入是否为「/技能名」指令）。
    func skillNames() -> Set<String> {
        Set(loadSkills().map { $0.name })
    }

    /// 累加某技能的调用次数并持久化（斜杠命令触发时调用）。
    func incrementUseCount(_ name: String) {
        var counts = SettingsStore.shared.settings.skillUseCounts
        counts[name, default: 0] += 1
        SettingsStore.shared.settings.skillUseCounts = counts
        SettingsStore.shared.save()
    }

    /// 为斜杠命令菜单生成「技能命令」列表：每个技能一条 `/技能名`，按调用次数降序。
    /// 调用次数相同则按 name 升序，保证顺序稳定。
    func skillSlashCommands() -> [SlashCommandItem] {
        let skills = loadSkills()
        let counts = SettingsStore.shared.settings.skillUseCounts
        return skills
            .sorted {
                let c0 = counts[$0.name, default: 0]
                let c1 = counts[$1.name, default: 0]
                if c0 != c1 { return c0 > c1 }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            .map { skill in
                SlashCommandItem(
                    id: "skill:\(skill.name)",
                    icon: "sparkles",
                    title: "/\(skill.name)",
                    subtitle: skill.description.isEmpty ? "(无描述)" : skill.description,
                    kind: .skill(skill.name)
                )
            }
    }

    // MARK: - 注入（供 system prompt 使用）

    /// 返回所有「已启用」技能的 name + description（frontmatter 元数据）拼接文本。
    /// 仅用于触发判定，正文按需由 `skill_load` 工具懒加载，避免每轮全量注入全部技能正文撑爆上下文。
    /// 线程治理（2026-08-09）：每轮 prompt 构建的主线程读盘移后台（detached 纯读盘，
    /// 不捕获 self；enabled 状态主线程快照为值拷贝传入）。
    func enabledSkillMetadata() async -> String {
        let dirs = fs.skillDirectories()
        let enabled = SettingsStore.shared.settings.skillEnabledStates
        let sections = await Task.detached(priority: .userInitiated) { () -> [String] in
            var result: [String] = []
            for dir in dirs {
                let skillURL = dir.appendingPathComponent("SKILL.md")
                guard let raw = Self.readSkillRaw(from: skillURL) else { continue }
                let fm = Self.parseSkillMarkdown(raw)
                guard !fm.name.isEmpty else { continue }
                let isOn = enabled[fm.name] ?? true
                guard isOn, !fm.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                result.append("### 技能：\(fm.name)\n\(fm.description)")
            }
            return result
        }.value
        return sections.joined(separator: "\n\n")
    }

    /// 懒加载缓存：技能正文按 name 缓存（正文为不可变内容，跨会话复用安全），
    /// 由 `skill_load` 工具命中，避免重复读盘与每轮全量注入。
    private var skillBodyCache: [String: String] = [:]

    /// 懒加载指定技能的完整 SKILL.md 正文（含 frontmatter）。
    /// 命中缓存直接返回；未命中则后台读盘、回主线程写缓存。供 `skill_load` 工具按需注入。
    /// 线程治理（2026-08-09）：未命中路径不再主线程同步读盘。
    func loadSkillBody(named name: String) async -> String? {
        if let cached = skillBodyCache[name] {
            return cached
        }
        guard let raw = await skillBody(named: name) else { return nil }
        skillBodyCache[name] = raw
        return raw
    }

    // MARK: - 渐进式加载：本会话已加载技能（强注入-cache-safe 变体）

    /// 每个会话已通过 `skill_load` 加载的技能名集合（内存态，App 生命周期内有效；重启后清空，模型可重新 skill_load）。
    /// 由 `SkillLoadTool` 写入，由 `AgentLoopEngine` 在拼 system 易变段时读取，
    /// 把已加载技能正文注入「缓存断点之后」的易变段——不污染缓存前缀，命中率零影响。
    private var loadedSkillNamesBySession: [UUID: Set<String>] = [:]

    /// 记录某会话加载了某技能（供引擎拼易变段 + 工具返回确认）。
    func markSkillLoaded(_ name: String, sessionID: UUID) {
        var set = loadedSkillNamesBySession[sessionID] ?? []
        set.insert(name)
        loadedSkillNamesBySession[sessionID] = set
    }

    /// 拼接某会话已加载技能的完整正文，格式化为一段易变段文本（不含任何缓存前缀内容）。
    /// 若未加载任何技能或 sessionID 为 nil，返回空字符串。
    /// 线程治理（2026-08-09）：正文读盘经 loadSkillBody（后台读盘），不再主线程同步 IO。
    func loadedSkillBodies(for sessionID: UUID?) async -> String {
        guard let sid = sessionID else { return "" }
        let names = loadedSkillNamesBySession[sid] ?? []
        guard !names.isEmpty else { return "" }
        var sections: [String] = []
        for name in names {
            guard let body = await loadSkillBody(named: name),
                  !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            sections.append("### 已加载技能正文：\(name)\n\(body)")
        }
        guard !sections.isEmpty else { return "" }
        return L10n.l("skill_loaded_prompt") + sections.joined(separator: "\n\n")
    }

    /// 读取指定 name 的技能正文。线程治理（2026-08-09）：后台读盘，不阻塞主线程。
    /// 注意：不写 skillBodyCache（供「本轮强制技能」一次性注入，写缓存会泄漏到后续轮次）。
    func skillBody(named name: String) async -> String? {
        let dirs = fs.skillDirectories()
        return await Task.detached(priority: .userInitiated) { () -> String? in
            for dir in dirs {
                let skillURL = dir.appendingPathComponent("SKILL.md")
                guard let raw = Self.readSkillRaw(from: skillURL) else { continue }
                let fm = Self.parseSkillMarkdown(raw)
                if fm.name == name {
                    return raw.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return nil
        }.value
    }

    // MARK: - 创建 / 删除

    /// 新建一个技能目录并写入 SKILL.md 模板（name 自动转 kebab-case）。
    @discardableResult
    func createSkillDirectory(name: String) throws -> String {
        let clean = name.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        guard !clean.isEmpty, clean.rangeOfCharacter(from: CharacterSet(charactersIn: "/")) == nil else {
            throw SkillError.invalidName
        }
        let dir = fs.skillsDir.appendingPathComponent(clean)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let skillURL = dir.appendingPathComponent("SKILL.md")
        if !FileManager.default.fileExists(atPath: skillURL.path) {
            let template = """
            ---
            name: \(clean)
            description: >
              在此描述该技能做什么，以及何时应当被触发（包含用户可能说的具体短语、上下文与关键词）。
            ---

            # \(clean)

            在此编写技能的指令、工作流与输出格式。需要时引用同目录下的
            `references/`（参考文档）、`scripts/`（可执行脚本）、`assets/`（模板/资源）、`evals/`（测试用例）。
            """
            try template.write(to: skillURL, atomically: true, encoding: .utf8)
        }
        invalidateSkillsCache()
        return clean
    }

    /// 删除指定目录名的技能（连同其 scripts/references/assets 等）。
    func deleteSkill(directoryName: String) throws {
        let dir = fs.skillsDir.appendingPathComponent(directoryName)
        guard FileManager.default.fileExists(atPath: dir.path) else { throw SkillError.notFound }
        try FileManager.default.removeItem(at: dir)
        invalidateSkillsCache()
    }

    // MARK: - 详情视图辅助

    /// 返回技能正文（第一个 `#` 标题到第一个 `##` 标题之间的介绍内容）。
    /// 详情页低频 UI 操作，保持同步（读盘量极小）；skillBody 已 async 化故内联读盘。
    func introSection(named name: String) -> String {
        for dir in fs.skillDirectories() {
            let skillURL = dir.appendingPathComponent("SKILL.md")
            guard let raw = Self.readSkillRaw(from: skillURL) else { continue }
            let fm = Self.parseSkillMarkdown(raw)
            if fm.name == name { return Self.extractIntro(raw) }
        }
        return ""
    }

    /// 列出技能目录下的所有文件（相对路径），SKILL.md 始终排第一。
    func skillFiles(directoryName: String) -> [String] {
        let dir = fs.skillsDir.appendingPathComponent(directoryName)
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [String] = []
        for case let url as URL in enumerator {
            guard !url.hasDirectoryPath else { continue }
            let rel = url.path.replacingOccurrences(of: dir.path + "/", with: "")
            files.append(rel)
        }
        return files.sorted {
            if $0 == "SKILL.md" { return true }
            if $1 == "SKILL.md" { return false }
            return $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    /// 读取技能内某个文件的正文（相对路径）。
    func fileContent(directoryName: String, relativePath: String) -> String? {
        let url = fs.skillsDir.appendingPathComponent(directoryName)
            .appendingPathComponent(relativePath)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// 从文件更新指定技能：解压/取出后覆盖原目录。
    func updateSkill(directoryName: String, from url: URL) -> ImportResult {
        var result = ImportResult()
        let ext = url.pathExtension.lowercased()
        let staging: URL
        if ext == "zip" {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("miniclaw_skill_upd_\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                try extractZip(at: url, into: tmp)
                staging = tmp
            } catch {
                result.message = String(format: L10n.l("skill_unzip_failed"), error.localizedDescription)
                return result
            }
        } else if ext == "md" {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("miniclaw_skill_upd_\(UUID().uuidString)")
                .appendingPathComponent(directoryName)
            do {
                try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: tmp.appendingPathComponent("SKILL.md"))
                staging = tmp
            } catch {
                result.message = String(format: L10n.l("skill_read_failed"), error.localizedDescription)
                return result
            }
        } else {
            result.message = String(format: L10n.l("skill_unsupported_type"), ext)
            return result
        }

        guard let src = findSkillDirectories(in: staging).first else {
            result.message = L10n.l("skill_no_skillmd_dir")
            return result
        }
        let dest = fs.skillsDir.appendingPathComponent(directoryName)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: src, to: dest)
            result.imported.append(directoryName)
            result.message = String(format: L10n.l("skill_updated"), directoryName)
        } catch {
            result.message = String(format: L10n.l("skill_update_failed"), error.localizedDescription)
        }
        return result
    }

    /// 提取 SKILL.md 中第一个 `#` 标题到第一个 `##` 标题之间的介绍正文。
    nonisolated static func extractIntro(_ raw: String) -> String {
        let lines = raw.components(separatedBy: "\n")
        guard let firstHash = lines.firstIndex(where: { $0.hasPrefix("# ") || $0 == "#" }) else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let end = lines[firstHash...].firstIndex(where: { $0.hasPrefix("## ") }) {
            return lines[(firstHash + 1)..<end]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return lines[(firstHash + 1)...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 导入（支持 .zip 技能包 或 单个 SKILL.md）

    /// 导入结果：成功导入的技能名、跳过的（已存在或非法）、失败原因。
    struct ImportResult {
        var imported: [String] = []
        var skipped: [String] = []
        var message: String = ""
    }

    /// 将任意技能名清洗为合法的目录名（小写 kebab-case，去除路径分隔符）。
    private static func sanitizeDirName(_ name: String) -> String {
        let clean = name.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        // 去掉可能混入的路径分隔符与非法字符
        let legal = clean.components(separatedBy: CharacterSet(charactersIn: "/\\"))
            .joined(separator: "-")
        return legal.isEmpty ? "imported-skill" : legal
    }

    /// 从用户选择的文件导入技能。
    /// - 若是 `.zip`：解压后扫描所有含 SKILL.md 的子目录，逐个拷入沙盒 skills/。
    /// - 若是 `.md`（单个 SKILL.md）：以其文件名（去扩展名）作为技能目录名导入。
    /// 导入失败不会中断其他技能；同名已存在的技能会被跳过（不覆盖，避免误删内置/已编辑技能）。
    func importSkillFile(from url: URL) -> ImportResult {
        let fm = FileManager.default
        var result = ImportResult()
        let ext = url.pathExtension.lowercased()

        let staging: URL
        if ext == "zip" {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("miniclaw_skill_import_\(UUID().uuidString)")
            do {
                try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                try extractZip(at: url, into: tmp)
                staging = tmp
            } catch {
                result.message = String(format: L10n.l("skill_unzip_failed"), error.localizedDescription)
                return result
            }
        } else if ext == "md" {
            // 单文件 SKILL.md：暂存为 <name>/SKILL.md
            let name = url.deletingPathExtension().lastPathComponent
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .replacingOccurrences(of: "_", with: "-")
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("miniclaw_skill_import_\(UUID().uuidString)")
                .appendingPathComponent(name.isEmpty ? "imported-skill" : name)
            do {
                try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                try fm.copyItem(at: url, to: tmp.appendingPathComponent("SKILL.md"))
                staging = tmp
            } catch {
                result.message = String(format: L10n.l("skill_import_failed"), error.localizedDescription)
                return result
            }
        } else {
            result.message = String(format: L10n.l("skill_unsupported_type_hint"), ext)
            return result
        }

        let skillDirs = findSkillDirectories(in: staging)
        if skillDirs.isEmpty {
            result.message = L10n.l("skill_no_skillmd_in_file")
            return result
        }

        // 确保沙盒 skills/ 存在
        try? fm.createDirectory(at: fs.skillsDir, withIntermediateDirectories: true)

        for src in skillDirs {
            // 目录名优先取 SKILL.md frontmatter 的 name（清洗成 kebab-case），
            // 回退到压缩包内的文件夹名，避免出现 uuid 临时名。
            let skillURL = src.appendingPathComponent("SKILL.md")
            let baseName: String
            if let raw = try? String(contentsOf: skillURL, encoding: .utf8) {
                let fm2 = Self.parseSkillMarkdown(raw)
                baseName = fm2.name.isEmpty ? src.lastPathComponent : fm2.name
            } else {
                baseName = src.lastPathComponent
            }
            let dirName = Self.sanitizeDirName(baseName)
            let dest = fs.skillsDir.appendingPathComponent(dirName)
            if fm.fileExists(atPath: dest.path) {
                result.skipped.append(dirName)
                continue
            }
            do {
                try fm.copyItem(at: src, to: dest)
                result.imported.append(dirName)
            } catch {
                result.skipped.append(dirName)
            }
        }

        if !result.imported.isEmpty {
            invalidateSkillsCache()
        }
        if result.imported.isEmpty && result.skipped.isEmpty {
            result.message = result.message.isEmpty ? "未导入任何技能。" : result.message
        } else {
            var parts: [String] = []
            if !result.imported.isEmpty { parts.append("已导入：\(result.imported.joined(separator: "、"))") }
            if !result.skipped.isEmpty { parts.append("已跳过（同名已存在）：\(result.skipped.joined(separator: "、"))") }
            result.message = parts.joined(separator: "；")
        }
        return result
    }

    /// 递归查找所有含 SKILL.md 的子目录，并扁平化为顶层技能目录（跳过被嵌套在其他技能内的目录）。
    private func findSkillDirectories(in root: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var candidates: [URL] = []
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == "SKILL.md" {
                candidates.append(fileURL.deletingLastPathComponent())
            }
        }
        // 去除被嵌套在其他候选目录内的目录
        return candidates.filter { dir in
            !candidates.contains { other in
                other != dir && dir.path.hasPrefix(other.path + "/")
            }
        }
    }

    /// 纯 Swift 解压 zip（iOS 无 Archive/Process，用 zlib 的 inflate 自行解压）。
    /// 仅支持 Store(0) 与 Deflate(8) 两种常见压缩方法，覆盖绝大多数 .zip 技能包。
    private func extractZip(at zipURL: URL, into destination: URL) throws {
        let data = try Data(contentsOf: zipURL)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let entries = try parseZipEntries(data)
        for entry in entries {
            // 防路径穿越：仅取相对成分
            let comps = entry.name.split(separator: "/").map(String.init)
                .filter { !$0.isEmpty && $0 != ".." }
            guard !comps.isEmpty else { continue }
            let outURL = destination.appendingPathComponent(comps.joined(separator: "/"))
            try FileManager.default.createDirectory(
                at: outURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            switch entry.method {
            case 0: // store
                try entry.data.write(to: outURL)
            case 8: // deflate
                let inflated = try ZipInflate.inflateData(entry.data)
                try inflated.write(to: outURL)
            default:
                throw SkillError.invalidName
            }
        }
    }

    /// 解析 zip 中央目录，返回各条目（名称、压缩方法、解压后数据）。
    /// 注意：压缩大小必须读自**中央目录记录**（offset+20），而非本地文件头——本地头的
    /// 压缩大小在流式打包（data descriptor）时为 0，从那里读会解压出 0 字节的空文件。
    private func parseZipEntries(_ data: Data) throws -> [(name: String, method: Int, data: Data)] {
        let cdSig = UInt32(littleEndian: 0x02014b50)
        guard data.count >= 4 else { throw SkillError.invalidName }
        var offset = 0
        // 定位 End Of Central Directory（从尾部回溯）
        var eocd = -1
        let minEOCD = 22
        for i in stride(from: data.count - minEOCD, through: 0, by: -1) {
            let sig = data.withUnsafeBytes { $0.load(fromByteOffset: i, as: UInt32.self) }.littleEndian
            if sig == 0x06054b50 {
                eocd = i
                break
            }
        }
        guard eocd >= 0 else { throw SkillError.invalidName }
        // 读中央目录偏移
        let cdOffset = data.withUnsafeBytes { $0.load(fromByteOffset: eocd + 16, as: UInt32.self) }.littleEndian
        offset = Int(cdOffset)

        var result: [(name: String, method: Int, data: Data)] = []
        while offset + 4 <= data.count {
            let sig = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }.littleEndian
            guard sig == cdSig else { break }
            let method = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 10, as: UInt16.self) }.littleEndian
            let nameLen = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 28, as: UInt16.self) }.littleEndian
            let extraLen = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 30, as: UInt16.self) }.littleEndian
            let commentLen = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 32, as: UInt16.self) }.littleEndian
            // 中央目录记录的压缩大小（offset+20）与本地头偏移（offset+42）才是可靠值
            let compSize = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 20, as: UInt32.self) }.littleEndian
            let localHeaderOffset = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 42, as: UInt32.self) }.littleEndian
            let nameStart = offset + 46
            guard nameStart + Int(nameLen) <= data.count else { break }
            let nameData = data.subdata(in: nameStart..<nameStart + Int(nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? ""
            // 定位本地头部以确定压缩数据的起始位置（仍来自本地头）
            let lhNameLen = data.withUnsafeBytes { $0.load(fromByteOffset: Int(localHeaderOffset) + 26, as: UInt16.self) }.littleEndian
            let lhExtraLen = data.withUnsafeBytes { $0.load(fromByteOffset: Int(localHeaderOffset) + 28, as: UInt16.self) }.littleEndian
            let dataStart = Int(localHeaderOffset) + 30 + Int(lhNameLen) + Int(lhExtraLen)
            guard dataStart + Int(compSize) <= data.count else { break }
            let compData = data.subdata(in: dataStart..<dataStart + Int(compSize))
            result.append((name: name, method: Int(method), data: compData))
            offset = nameStart + Int(nameLen) + Int(extraLen) + Int(commentLen)
        }
        return result
    }

    // MARK: - Frontmatter 解析（最小实现，无第三方依赖）

    /// 解析 SKILL.md：提取 `--- ... ---` 之间的 YAML frontmatter 与正文。
    /// 支持 `key: value`、`key: "quoted"`、以及 `key: >` 折叠标量（多行累积）。
    /// nonisolated：纯函数，供后台线程读盘解析（线程治理 2026-08-09）。
    nonisolated static func parseSkillMarkdown(_ raw: String) -> SkillFrontmatter {
        var result = SkillFrontmatter()

        guard let start = raw.range(of: "---\n"),
              let end = raw[start.upperBound...].range(of: "\n---") else {
            // 无 frontmatter：整段视为正文
            result.body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return result
        }

        let fmText = String(raw[start.upperBound..<end.lowerBound])
        let bodyStart = raw.index(after: end.upperBound)
        result.body = String(raw[bodyStart...]).trimmingCharacters(in: .whitespacesAndNewlines)

        var currentKey: String?
        var folding = false

        for line in fmText.components(separatedBy: "\n") {
            if folding {
                if line.hasPrefix(" ") || line.hasPrefix("\t") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { appendFolded(&result, key: currentKey, value: trimmed) }
                    continue
                } else {
                    folding = false
                }
            }

            guard let colon = line.range(of: ":"),
                  !line.hasPrefix(" "), !line.hasPrefix("\t"),
                  line.first != "#" else { continue }

            let key = String(line[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
            var value = String(line[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }

            if ["-", "|", "|-", ">"].contains(value) {
                folding = true
                currentKey = key
                if key == "description" { result.description = "" }
                else if key == "compatibility" { result.compatibility = "" }
                else if key == "version" { result.version = "" }
            } else {
                currentKey = key
                assignScalar(&result, key: key, value: value)
            }
        }

        return result
    }

    /// nonisolated：frontmatter 解析纯函数，供后台线程调用（线程治理 2026-08-09）。
    nonisolated private static func assignScalar(_ fm: inout SkillFrontmatter, key: String, value: String) {
        switch key {
        case "name": fm.name = value
        case "description": fm.description = value
        case "compatibility": fm.compatibility = value
        case "version": fm.version = value
        default: break
        }
    }

    /// nonisolated：frontmatter 解析纯函数，供后台线程调用（线程治理 2026-08-09）。
    nonisolated private static func appendFolded(_ fm: inout SkillFrontmatter, key: String?, value: String) {
        guard let key else { return }
        switch key {
        case "description": fm.description = (fm.description.isEmpty ? "" : fm.description + " ") + value
        case "compatibility": fm.compatibility = (fm.compatibility ?? "").isEmpty ? value : (fm.compatibility! + " " + value)
        case "version": fm.version = (fm.version ?? "").isEmpty ? value : (fm.version! + " " + value)
        default: break
        }
    }
}

