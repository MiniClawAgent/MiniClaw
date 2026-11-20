import Foundation





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

    /// 扫描统一插件布局下**所有类型**插件（plugins/<type>/<id>/），解析每个 plugin.json，
    /// 返回插件列表（按 name 排序）。列表页展示全类型；指令入口等 skill 专属消费方
    /// 经 enabledSkills() 的 type==skill 过滤兜住。
    /// SKILL.md 为 skill 类惯例（subagent 等类型可无），缺失时元数据全部取自清单。
    /// 启用状态由持久化的 `skillEnabledStates` 决定，缺省按来源分流（内置开/导入关）；
    /// 来源（内置/导入）依据 Bundle manifest 判断；安装时间首次记录后持久化。
    func loadSkills() -> [SkillPackage] {
        if let cache = skillsCache { return cache }
        let dirs = fs.allPluginDirectories()
        let settings = SettingsStore.shared.settings
        let enabled = settings.skillEnabledStates
        let bundled = bundledPluginIds()
        var installDates = settings.skillInstallDates
        var changed = false

        var result: [SkillPackage] = []
        for dir in dirs {
            // 强制 plugin.json：无清单的目录一律跳过，不兼容。
            let manifestURL = dir.appendingPathComponent("plugin.json")
            guard let manifestData = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(PluginManifest.self, from: manifestData) else {
                continue
            }
            // SKILL.md 可选：有则解析 frontmatter 供 displayName/描述回退，无则全取清单。
            let skillRaw = try? String(contentsOf: dir.appendingPathComponent("SKILL.md"), encoding: .utf8)
            let fm = skillRaw.map { Self.parseSkillMarkdown($0) } ?? SkillFrontmatter()
            let displayName = manifest.name.isEmpty ? fm.name : manifest.name
            guard !displayName.isEmpty else { continue }
            let isBuiltin = bundled.contains(dir.lastPathComponent)
            // 产品规则（2026-08-27 唐唐）：**用户导入的插件默认关闭**，内置插件沿用清单声明；
            // 用户手动开/关过的持久化状态始终优先于缺省值。
            let fallbackEnabled = isBuiltin ? manifest.enabledByDefault : false
            let isOn = enabled[displayName] ?? fallbackEnabled
            let installDate: Date
            if let d = installDates[displayName] {
                installDate = d
            } else {
                installDate = Date()
                installDates[displayName] = installDate
                changed = true
            }
            // 描述取值优先级：清单 description（规范来源）→ SKILL.md frontmatter（兼容第三方旧包）→ 无描述。
            let resolvedDesc = manifest.description.isEmpty
                ? (fm.description.isEmpty ? String(localized: "skill_no_description") : fm.description)
                : manifest.description
            result.append(SkillPackage(
                name: displayName,
                description: resolvedDesc,
                version: manifest.version.isEmpty ? (fm.version ?? "1.0.0") : manifest.version,
                isEnabled: isOn,
                directoryName: dir.lastPathComponent,
                source: isBuiltin ? "builtin" : "imported",
                installDate: installDate,
                icon: manifest.icon,
                category: manifest.category.isEmpty ? manifest.type : manifest.category,
                type: manifest.type
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

    /// 返回**仅当前已启用的 skill 类型**插件列表（指令入口/UI 注入等以此为准）。
    /// type 过滤兜底：subagent/rule 等其他类型不参与 /指令 命名空间。
    func enabledSkills() -> [SkillPackage] {
        loadSkills().filter { $0.isEnabled && $0.type == "skill" }
    }

    /// 读取某技能当前生效启用态（轻量版，供视图绑定逐帧拉取）：
    /// 用户手动开/关过的持久化状态优先；否则按来源缺省——内置开、导入关。
    /// 口径约束：内置包清单恒声明 enabledByDefault=true，与 loadSkills 的来源分流规则一致；
    /// 若未来出现声明为 false 的内置包，须把此方法改为回读该清单。
    func effectiveEnabled(name: String, source: String) -> Bool {
        if let v = SettingsStore.shared.settings.skillEnabledStates[name] { return v }
        return source == "builtin"
    }

    /// 设置插件启用状态并持久化。
    /// **soul 互斥语义（唐唐 2026-08-28 确认）**：soul 插件是排他单选——启用某个 soul
    /// 插件时，同类型其他 soul 插件立即停用，并应用该插件的人格（覆盖 memory/SOUL.md）。
    /// **来源切换与内置草稿**：内置生效时启用第三方 → 当前 SOUL.md 备份为内置草稿
    /// （SOUL.builtin.md）再应用第三方；启用内置 → 恢复草稿（无草稿用出厂模板）。
    /// subagent 开关切换后即时刷新角色注册表（停用插件的角色立即退出派发可用集）。
    func setEnabled(_ name: String, _ enabled: Bool) {
        var states = SettingsStore.shared.settings.skillEnabledStates
        states[name] = enabled
        var soulDir: URL?
        var soulIsBuiltin = false
        if enabled {
            let builtinIds = fs.bundledPluginIds()
            // 扫描 soul 类型插件：目标插件记录目录；其余 soul 一律停用（显式写 false，
            // 防止未手动设置过的内置包靠缺省值继续生效）。
            for dir in fs.allPluginDirectories() {
                guard let data = try? Data(contentsOf: dir.appendingPathComponent("plugin.json")),
                      let m = try? JSONDecoder().decode(PluginManifest.self, from: data),
                      m.type == "soul" else { continue }
                let key = m.name.isEmpty ? dir.lastPathComponent : m.name
                if key == name {
                    soulDir = dir
                    // 内置判定走 Bundle manifest（目录名=插件 id），不做 name 字符串耦合。
                    soulIsBuiltin = builtinIds.contains(dir.lastPathComponent)
                } else if !builtinIds.contains(dir.lastPathComponent) {
                    // 排他仅停用其他第三方 soul。内置人格是恒可用底座（唐唐 2026-09-02：
                    // 默认人格开关已移除），不写 false——旧逻辑写 false 会残留
                    // 「未装第三方却显示默认人格已停用」的假象（soul 实际生效由
                    // activePlugin + SOUL.md 文件决定，states 不参与）。
                    if states[key] ?? false { states[key] = false }
                }
            }
        }
        SettingsStore.shared.settings.skillEnabledStates = states
        invalidateSkillsCache()
        refreshSubagentProfiles()

        // soul 来源切换（主线程调用，UI 场景安全；activePlugin 持久化在 soul 域）。
        if enabled, let dir = soulDir {
            let current = SettingsStore.shared.settings.soul.activePlugin
            if soulIsBuiltin {
                // 启用内置：恢复内置草稿（用户改过的内容优先），无草稿用出厂模板。
                fs.restoreBuiltinSoul()
                SettingsStore.shared.settings.soul.activePlugin = nil
            } else {
                // 启用第三方：内置生效中则先备份当前 SOUL.md 为内置草稿（B→C 切换不覆盖草稿）。
                if current == nil { fs.backupBuiltinSoul() }
                fs.applySoulPackage(at: dir)
                SettingsStore.shared.settings.soul.activePlugin = name
            }
        } else if !enabled {
            // 停用当前生效的第三方 soul → 恢复内置灵魂。
            if SettingsStore.shared.settings.soul.activePlugin == name {
                fs.restoreBuiltinSoul()
                SettingsStore.shared.settings.soul.activePlugin = nil
                clearBuiltinSoulDisabledState()
            }
        }
        SettingsStore.shared.save()
    }

    /// 清除内置人格的显式停用记录（回落缺省启用）——旧排他逻辑会把内置写成 false，
    /// 残留「未装第三方人格却显示默认人格已停用」的假象（2026-09-02 唐唐报告）。
    private func clearBuiltinSoulDisabledState() {
        let builtinIds = fs.bundledPluginIds()
        var states = SettingsStore.shared.settings.skillEnabledStates
        var changed = false
        for dir in fs.allPluginDirectories() {
            guard builtinIds.contains(dir.lastPathComponent),
                  let data = try? Data(contentsOf: dir.appendingPathComponent("plugin.json")),
                  let m = try? JSONDecoder().decode(PluginManifest.self, from: data),
                  m.type == "soul" else { continue }
            let key = m.name.isEmpty ? dir.lastPathComponent : m.name
            if states[key] == false {
                states[key] = nil
                changed = true
            }
        }
        if changed {
            SettingsStore.shared.settings.skillEnabledStates = states
            SettingsStore.shared.save()
        }
    }

    /// 主线程快照启用状态与内置集合后，刷新子代理角色注册表
    /// （SettingsStore 后台裸读竞态防护，与启动路径同一约束）。
    private func refreshSubagentProfiles() {
        let states = SettingsStore.shared.settings.skillEnabledStates
        let builtinIds = fs.bundledPluginIds()
        SubAgentProfileStore.shared.reload(enabledStates: states, builtinIds: builtinIds)
    }

    /// 返回当前所有已启用技能的 name 集合（用于判断输入是否为「/技能名」指令）。
    /// 停用的技能不参与指令判定：输入框入口不会提供，命中也不解析。
    func skillNames() -> Set<String> {
        Set(enabledSkills().map { $0.name })
    }

    /// 返回 Bundle manifest 中记录的内置插件 id 集合。
    func bundledPluginIds() -> Set<String> {
        fs.bundledPluginIds()
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
        // 输入框指令入口只提供**已启用**的技能；停用的不出现在菜单。
        let skills = enabledSkills()
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
                    subtitle: skill.description,
                    kind: .skill(skill.name)
                )
            }
    }

    // MARK: - 注入（供 system prompt 使用）

    /// 返回所有「已启用」技能的 name + description（frontmatter 元数据）拼接文本。
    /// 仅用于触发判定，正文按需由 `skill-load` 工具懒加载，避免每轮全量注入全部技能正文撑爆上下文。
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
                result.append(String(format: String(localized: "skill_meta_section"), fm.name, fm.description))
            }
            return result
        }.value
        return sections.joined(separator: "\n\n")
    }

    /// 懒加载缓存：技能正文按 name 缓存（正文为不可变内容，跨会话复用安全），
    /// 由 `skill-load` 工具命中，避免重复读盘与每轮全量注入。
    private var skillBodyCache: [String: String] = [:]

    /// 懒加载指定技能的完整 SKILL.md 正文（含 frontmatter）。
    /// 命中缓存直接返回；未命中则后台读盘、回主线程写缓存。供 `skill-load` 工具按需注入。
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

    /// 每个会话已通过 `skill-load` 加载的技能名集合（内存态，App 生命周期内有效；重启后清空，模型可重新 skill-load）。
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
        // 按名字排序（2026-09-11）：`Set` 的迭代顺序受 Swift 每进程随机 hash 种子影响，
        // 跨 App 重启可能变序 → 同一组已加载技能在不同进程里产出不同文本，易变段字节漂移，
        // 重启后首次请求白付一次缓存 miss。排序后顺序由技能名唯一确定。
        let names = (loadedSkillNamesBySession[sid] ?? []).sorted()
        guard !names.isEmpty else { return "" }
        var sections: [String] = []
        for name in names {
            guard let body = await loadSkillBody(named: name),
                  !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            sections.append(String(format: String(localized: "skill_loaded_body_section"), name, body))
        }
        guard !sections.isEmpty else { return "" }
        return String(localized: "skill_loaded_prompt") + sections.joined(separator: "\n\n")
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
        // 新建技能一并写出 plugin.json（强制清单，type:skill），保证符合 .mpk 规范。
        let manifestURL = dir.appendingPathComponent("plugin.json")
        if !FileManager.default.fileExists(atPath: manifestURL.path) {
            let manifest = PluginManifest(
                id: clean,
                name: clean,
                version: "1.0.0",
                type: "skill",
                category: "skill",
                enabledByDefault: true
            )
            if let data = try? JSONEncoder().encode(manifest) {
                try? data.write(to: manifestURL, options: [.atomic])
            }
        }
        invalidateSkillsCache()
        return clean
    }

    /// 删除指定目录名的插件（跨类型定位；连同其内容文件）。
    /// mcp 插件：连带删除其导入的全部 server（来源追踪 sourcePlugin）。
    func deleteSkill(directoryName: String) throws {
        guard let dir = pluginDir(named: directoryName) else { throw SkillError.notFound }
        // 先读清单（目录删除后无法再读）：类型 + 完整清单（soul 善后需要 name）。
        let manifest = (try? Data(contentsOf: dir.appendingPathComponent("plugin.json")))
            .flatMap { try? JSONDecoder().decode(PluginManifest.self, from: $0) }
        let manifestType = manifest?.type
        try FileManager.default.removeItem(at: dir)
        invalidateSkillsCache()
        // 删除 subagent 插件后即时刷新角色注册表，其角色立即退出派发可用集。
        refreshSubagentProfiles()
        // mcp 插件：连带删除其导入的 server（含 Keychain 令牌）。
        if manifestType == "mcp" {
            MCPConfigStore.shared.removeServers(sourcePlugin: directoryName)
        }
        // model 插件：连带删除其导入的供应商（含密钥/OAuth 清理）。
        if manifestType == "model" {
            let ids = AppState.shared.providers
                .filter { $0.sourcePlugin == directoryName }.map(\.id)
            for id in ids {
                AppState.shared.removeProvider(id: id)
            }
        }
        // soul 插件：若删除的是当前生效的第三方 soul（activePlugin 悬挂）→
        // 恢复内置灵魂（草稿优先）并清空生效来源标记（2026-08-29 体检 P0-2）。
        if manifestType == "soul" {
            let soulKey = (manifest?.name.isEmpty == false) ? manifest!.name : directoryName
            if SettingsStore.shared.settings.soul.activePlugin == soulKey {
                fs.restoreBuiltinSoul()
                SettingsStore.shared.settings.soul.activePlugin = nil
                clearBuiltinSoulDisabledState()
                SettingsStore.shared.save()
            }
        }
        // theme 插件：若删除的正是当前选用的背景主题 → 清空选用（三页回退系统默认背景）。
        if manifestType == "theme", ThemeManager.shared.activeThemeID == directoryName {
            ThemeManager.shared.activeThemeID = nil
        }
    }

    /// 按 directoryName（=插件目录名/插件 id）在统一插件布局下跨类型定位插件目录。
    private func pluginDir(named directoryName: String) -> URL? {
        fs.allPluginDirectories().first { $0.lastPathComponent == directoryName }
    }

    /// 导出插件为 `.mpk`（zip，Store，含 `<id>/` 前缀，与内置包同布局）。
    /// 用户可把导入的插件、或让 AI 生成的插件打包分享给他人（他人导入即可用）。
    /// 返回临时目录中的文件 URL，调用方通过系统分享面板发出后自行清理。
    func exportPluginMPK(directoryName: String) throws -> URL {
        guard let dir = pluginDir(named: directoryName) else { throw SkillError.notFound }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(directoryName).mpk")
        try? FileManager.default.removeItem(at: out)
        try ZipArchive.create(at: out, from: dir, entryPrefix: directoryName)
        return out
    }

    /// 列出插件目录下的所有文件（相对路径），SKILL.md 始终排第一。
    func skillFiles(directoryName: String) -> [String] {
        guard let dir = pluginDir(named: directoryName) else { return [] }
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

    /// 插件内某个文件的真实 URL（相对路径）。
    ///
    /// **文件打开统一走 `FilePreviewView`**：详情页把 URL 交给统一预览组件即可，
    /// 不再自己读成 String 再自渲染（那套自造 sheet 在读取失败/相对路径失真时会渲染成空白页，
    /// 且是「所有文件打开走统一套机制」这条规矩的唯一例外）。
    func pluginFileURL(directoryName: String, relativePath: String) -> URL? {
        guard let dir = pluginDir(named: directoryName) else { return nil }
        let url = dir.appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 从文件更新指定技能：解压/取出后覆盖原目录。
    func updateSkill(directoryName: String, from url: URL) -> ImportResult {
        var result = ImportResult()
        let ext = url.pathExtension.lowercased()
        let staging: URL
        if ext == "zip" || ext == "mpk" {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("miniclaw_skill_upd_\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                try ZipArchive.extract(at: url, into: tmp)
                staging = tmp
            } catch {
                result.message = String(format: String(localized: "skill_unzip_failed"), error.localizedDescription)
                return result
            }
        } else {
            // 单文件 SKILL.md 已弃用，更新也只接受 .mpk/.zip 压缩包。
            result.message = String(format: String(localized: "skill_single_file_deprecated"), ext)
            return result
        }

        guard let src = findPluginDirectories(in: staging).first else {
            result.message = String(localized: "skill_no_plugin_dir")
            return result
        }
        // 强制 plugin.json：id 必须匹配目标避免覆盖错插件；type 必须 = skill（更新流只服务技能详情页）。
        guard let parsed = Self.pluginIDAndType(from: src.appendingPathComponent("plugin.json")),
              parsed.id == directoryName, parsed.type == "skill" else {
            result.message = String(localized: "skill_update_id_mismatch")
            return result
        }
        let dest = fs.skillsDir.appendingPathComponent(directoryName)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: src, to: dest)
            result.imported.append(directoryName)
            result.message = String(format: String(localized: "skill_updated"), directoryName)
        } catch {
            result.message = String(format: String(localized: "skill_update_failed"), error.localizedDescription)
        }
        return result
    }

    // MARK: - 导入（支持 .zip 技能包 或 单个 SKILL.md）

    /// 导入结果：成功导入的技能名、跳过的（已存在或非法）、失败原因。
    struct ImportResult {
        var imported: [String] = []
        /// 原地升级条目（展示串："dirName 旧版本 → 新版本"）。
        var updated: [String] = []
        var skipped: [String] = []
        var message: String = ""
    }

    /// 从用户选择的 `.mpk`/`.zip` 压缩包导入插件（全类型入口）。
    /// - 解压后扫描所有含 `plugin.json` 的子目录（强制清单），逐个以 `id` 为目录名、
    ///   按 `type` 分发拷入沙盒统一插件布局 `plugins/<type>/`（type 缺省按 skill）。
    /// - **单文件 `.md` 已弃用**：不再提供兼容导入，提示改用 `.mpk`。
    /// 导入失败不会中断其他插件；同名 id 已存在的插件会被跳过（不覆盖，避免误删内置/已编辑插件）。
    func importSkillFile(from url: URL) -> ImportResult {
        let fm = FileManager.default
        var result = ImportResult()
        let ext = url.pathExtension.lowercased()

        let staging: URL
        if ext == "zip" || ext == "mpk" {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("miniclaw_skill_import_\(UUID().uuidString)")
            do {
                try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                try ZipArchive.extract(at: url, into: tmp)
                staging = tmp
            } catch {
                result.message = String(format: String(localized: "skill_unzip_failed"), error.localizedDescription)
                return result
            }
        } else {
            // 单文件 SKILL.md 已弃用：不再提供兼容导入，提示改用 .mpk。
            result.message = String(format: String(localized: "skill_single_file_deprecated"), ext)
            return result
        }

        let pluginDirs = findPluginDirectories(in: staging)
        if pluginDirs.isEmpty {
            result.message = String(localized: "skill_no_plugin_in_file")
            return result
        }

        for src in pluginDirs {
            // 目录名取 plugin.json 的 id（清洗路径分隔符）；type 决定分发目的地（缺省 skill）
            guard let parsed = Self.pluginIDAndType(from: src.appendingPathComponent("plugin.json")) else {
                result.skipped.append(src.lastPathComponent)
                continue
            }
            let dirName = Self.sanitizePluginID(parsed.id)
            let typeDir = fs.pluginTypeDir(parsed.type)
            try? fm.createDirectory(at: typeDir, withIntermediateDirectories: true)
            let dest = typeDir.appendingPathComponent(dirName)
            if fm.fileExists(atPath: dest.path) {
                // 内置包由 Bundle 同步管理（syncBundledPlugins 同名先删后拷），用户导入不得覆盖。
                guard !fs.bundledPluginIds().contains(dirName) else {
                    result.skipped.append(dirName)
                    continue
                }
                // 同 id 升级（唐唐 2026-09-01）：新包版本高于已安装 → 原地替换（启用状态/
                // 供应商配置/密钥全保留——用户数据不在插件目录内）；版本相同 → 跳过；
                // 更低 → 拒绝（降级需先删除插件再手动导入）。
                let oldVer = Self.pluginVersion(from: dest.appendingPathComponent("plugin.json"))
                // 新包版本从 staging 中新包的 plugin.json 读取（pluginIDAndType 元组不含 version）。
                let newVer = Self.pluginVersion(from: src.appendingPathComponent("plugin.json"))
                switch Self.compareVersion(newVer, oldVer) {
                case 0:
                    result.skipped.append(dirName)
                    continue
                case -1:
                    result.message = String(format: String(localized: "plugin_update_downgrade_rejected"), newVer, oldVer)
                    continue
                default:
                    break
                }
                let backup = fm.temporaryDirectory
                    .appendingPathComponent("miniclaw_plugin_upgrade_\(UUID().uuidString)")
                do {
                    try fm.copyItem(at: dest, to: backup)
                    try fm.removeItem(at: dest)
                    try fm.copyItem(at: src, to: dest)
                    if parsed.type == "theme",
                       let violation = ThemeManager.validateThemeAssets(in: dest) {
                        // theme 超限回滚旧版本
                        try? fm.removeItem(at: dest)
                        try? fm.copyItem(at: backup, to: dest)
                        try? fm.removeItem(at: backup)
                        result.message = violation
                        continue
                    }
                    // mcp：升级后 servers.json 幂等重合并（保留用户启用状态）。
                    if parsed.type == "mcp",
                       let json = try? String(contentsOf: dest.appendingPathComponent("servers.json"), encoding: .utf8) {
                        _ = try? MCPConfigStore.shared.mergePluginServers(json, sourcePlugin: dirName)
                    }
                    try? fm.removeItem(at: backup)
                    result.updated.append("\(dirName) \(oldVer) → \(newVer)")
                    continue
                } catch {
                    // 升级失败回滚旧版本
                    try? fm.removeItem(at: dest)
                    try? fm.copyItem(at: backup, to: dest)
                    try? fm.removeItem(at: backup)
                    result.skipped.append(dirName)
                    continue
                }
            }
            do {
                try fm.copyItem(at: src, to: dest)
                // theme 类型：图片规格校验（单张 ≤2MB、长边 ≤3840）——超限回滚导入并报错。
                if parsed.type == "theme",
                   let violation = ThemeManager.validateThemeAssets(in: dest) {
                    try? fm.removeItem(at: dest)
                    result.message = violation
                    continue
                }
                result.imported.append(dirName)
                // soul 类型：导入即默认应用（唐唐 2026-09-02：装了第三方人格就默认用它）——
                // 走 setEnabled 排他停用其他 soul，内置 SOUL.md 自动备份为草稿；
                // 切回内置 = 灵魂设置页重置或删除该插件。
                if parsed.type == "soul" {
                    // 排他 key 用 manifest.name（与 setEnabled 扫描口径一致），缺省回落目录名。
                    let manifest = (try? Data(contentsOf: dest.appendingPathComponent("plugin.json")))
                        .flatMap { try? JSONDecoder().decode(PluginManifest.self, from: $0) }
                    let soulName = (manifest?.name.isEmpty == false) ? manifest!.name : dirName
                    setEnabled(soulName, true)
                }
                // model 类型：拷入存档后，解析包内 providers.json（服务商连接模板）
                // 并幂等合并进供应商列表（新增默认停用，密钥用户自填）。
                // mcp 类型：拷入存档后，解析包内 servers.json（业界通用 mcpServers 格式）
                // 并幂等合并进 MCP 配置（新增默认停用）。
                if parsed.type == "mcp" {
                    let serversURL = dest.appendingPathComponent("servers.json")
                    if let json = try? String(contentsOf: serversURL, encoding: .utf8) {
                        do {
                            let (added, updated) = try MCPConfigStore.shared.mergePluginServers(json, sourcePlugin: dirName)
                            result.message = String(format: String(localized: "mcp_plugin_merge_result"), added, updated)
                        } catch {
                            result.message = error.localizedDescription
                        }
                    } else {
                        result.message = String(localized: "mcp_plugin_no_servers")
                    }
                }
            } catch {
                result.skipped.append(dirName)
            }
        }

        if !result.imported.isEmpty || !result.updated.isEmpty {
            invalidateSkillsCache()
            // 导入/升级后即时刷新子代理角色注册表（subagent 类型插件无需重启即可派发）。
            refreshSubagentProfiles()
        }
        if result.imported.isEmpty && result.skipped.isEmpty {
            result.message = result.message.isEmpty ? String(localized: "import_none") : result.message
        } else {
            var parts: [String] = []
            if !result.imported.isEmpty { parts.append(String(format: String(localized: "import_done_list"), result.imported.joined(separator: "、"))) }
            if !result.updated.isEmpty { parts.append(String(format: String(localized: "import_updated_list"), result.updated.joined(separator: "、"))) }
            if !result.skipped.isEmpty { parts.append(String(format: String(localized: "import_skipped_list"), result.skipped.joined(separator: "、"))) }
            result.message = parts.joined(separator: "；")
        }
        return result
    }

    /// 递归查找所有含 `plugin.json` 的子目录（强制清单），扁平化为顶层插件目录（跳过被嵌套在其他插件内的目录）。
    private func findPluginDirectories(in root: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var candidates: [URL] = []
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == "plugin.json" {
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

    /// 从 plugin.json 宽松读取插件 id 与 type（JSONSerialization，与内置同步同口径）。
    /// id 强制非空；type 缺省 "skill"（宽容第三方清单漏写，与 loadSkills 解码默认一致）。
    private static func pluginIDAndType(from url: URL) -> (id: String, type: String)? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String, !id.isEmpty else { return nil }
        let type = (obj["type"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "skill"
        return (id, type)
    }

    /// 将插件 id 清洗为安全目录名——统一转调 PluginManifest.sanitizeID（唯一真相源）。
    private static func sanitizePluginID(_ id: String) -> String {
        PluginManifest.sanitizeID(id)
    }

    /// 读取插件 manifest 的 version（缺省 "0.0.0"）。
    private static func pluginVersion(from url: URL) -> String {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = obj["version"] as? String, !v.isEmpty else { return "0.0.0" }
        return v
    }

    /// 点分数字版本比较（semver 子集）：-1 = a<b，0 = 相等，1 = a>b。非数字段按 0 处理。
    static func compareVersion(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x < y { return -1 }
            if x > y { return 1 }
        }
        return 0
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

    /// 解析插件图标（统一 SF Symbols）：
    /// 用户 `plugin.json` 声明 `icon` 优先；否则按 `category` 取该分类默认图标；再失败回退 `puzzlepiece`。
    /// 对齐《MiniClaw 插件化架构方案》§二·2.4。
    nonisolated static func pluginIcon(category: String, declared: String) -> String {
        if !declared.isEmpty { return declared }
        switch category {
        case "model": return "cpu"
        case "skill": return "wrench.and.screwdriver"
        case "rule": return "checklist"
        case "subagent": return "person.2"
        case "soul": return "brain.head.profile"
        case "theme": return "paintpalette"
        case "agent-mode": return "speedometer"
        case "shell-tool": return "terminal"
        case "mcp": return "link"
        case "fragment": return "doc.plaintext"
        case "tool.whitelist": return "wrench"
        case "tool": return "hammer"
        default: return "puzzlepiece"
        }
    }
}

