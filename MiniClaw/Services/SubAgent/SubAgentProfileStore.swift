import Foundation

/// 子代理角色注册表：扫描 `plugins/subagent/<id>/` 加载全部 profile。
/// 插件形态：**一个 subagent 插件 = 一份 plugin.json[type=subagent] 清单 + 若干 .md 角色文件**（任意层级）。
/// 角色的 dispatch 主键 = 文件名 stem（如 general/planner/research/writer）；
/// 显示名/适用场景由各角色 md 的 frontmatter（name/description）承载。
/// 随 BundledPlugins 内置 .mpk 同步或用户从插件页导入。
/// **启用语义**：插件列表的开关（键 = manifest.name）对本插件全部角色生效；
/// 停用的插件其角色不参与派发。`general` 为引擎保底角色：数据目录无任何插件时兜底。
/// （未上架不做旧兼容：历史散 .md 布局由启动清退直接删除。）
/// 线程安全：NSLock 保护字典（reload 在启动后台任务；引擎在任意线程读取）。
final class SubAgentProfileStore: @unchecked Sendable {
    static let shared = SubAgentProfileStore()

    private let lock = NSLock()
    private var profiles: [String: SubAgentProfile] = [:]

    private init() {}

    /// 全量重载。导入/删除/开关切换后也需调用，使角色可见性即时生效。
    /// - Parameters:
    ///   - enabledStates: 插件启用状态（调用方在**主线程**快照 `skillEnabledStates`，
    ///     避免 SettingsStore 后台裸读竞态，2026-08-14 崩溃修复同款约束）。
    ///   - builtinIds: 内置插件 id 集合（决定缺省启用分流：内置=清单声明，导入=关）。
    func reload(enabledStates: [String: Bool], builtinIds: Set<String>) {
        var loaded: [String: SubAgentProfile] = [:]
        let dir = FileSystemManager.shared.subagentProfilesDir
        let fm = FileManager.default
        let subs = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for sub in subs where sub.hasDirectoryPath {
            // 强制 plugin.json 且 type=subagent：无清单/类型不符的插件目录一律跳过。
            guard let manifestData = try? Data(contentsOf: sub.appendingPathComponent("plugin.json")),
                  let manifest = try? JSONDecoder().decode(PluginManifest.self, from: manifestData),
                  manifest.type == "subagent",
                  let en = fm.enumerator(at: sub, includingPropertiesForKeys: nil,
                                         options: [.skipsHiddenFiles]) else { continue }
            // 停用语义：插件列表开关（键 = manifest.name，与 loadSkills 的 displayName 同源）
            // 停用 → 本插件全部角色不加载。缺省值按来源分流（内置=清单声明，导入=关）。
            let stateKey = manifest.name.isEmpty ? sub.lastPathComponent : manifest.name
            let fallbackEnabled = builtinIds.contains(sub.lastPathComponent) ? manifest.enabledByDefault : false
            guard enabledStates[stateKey] ?? fallbackEnabled else { continue }
            // 递归收本插件目录下所有 .md 角色文件（plugin.json 之外的角色定义）。
            for case let url as URL in en {
                guard url.pathExtension.lowercased() == "md",
                      let raw = try? String(contentsOf: url, encoding: .utf8),
                      let p = SubAgentProfile.parse(fileName: url.deletingPathExtension().lastPathComponent,
                                                    content: raw) else { continue }
                if loaded[p.name] == nil {
                    loaded[p.name] = p
                } else {
                    AppLogger.shared.info("[SubAgent] 角色主键冲突，保留先加载者: \(p.name)",
                                          category: "SubAgent", subsystem: "SubAgent")
                }
            }
        }
        // general 保底：仅当数据目录完全没有任何 subagent 插件（空目录/清空态）时兜底，
        // 有插件但被用户停用时不强行兜底（尊重停用语义，角色列表如实反映）。
        if loaded["general"] == nil && subs.isEmpty {
            loaded["general"] = SubAgentProfile(
                name: "general",
                displayName: String(localized: "subagent_general_display"),
                summary: String(localized: "subagent_general_summary"),
                systemPrompt: Self.fallbackGeneralPrompt
            )
        }
        lock.lock()
        profiles = loaded
        lock.unlock()
    }

    /// 按名取 profile；nil/空/未找到一律回退 general（不阻塞派发）。
    func profile(named name: String?) -> SubAgentProfile {
        lock.lock()
        defer { lock.unlock() }
        guard let name, !name.isEmpty, let p = profiles[name] else {
            return profiles["general"]
                ?? SubAgentProfile(name: "general", displayName: String(localized: "subagent_general_display"), summary: "",
                                   systemPrompt: Self.fallbackGeneralPrompt)
        }
        return p
    }

    /// 全部 profile 摘要（name + 显示名 + 适用场景），供工具 schema 与引导段动态展示。
    func allSummaries() -> [(name: String, displayName: String, summary: String)] {
        lock.lock()
        defer { lock.unlock() }
        return profiles.values.sorted { $0.name < $1.name }
            .map { ($0.name, $0.displayName, $0.summary) }
    }

    /// general 兜底提示词（跟随界面语言；数据目录无任何文件时保证子代理仍可用）。
    /// 2026-08-29 修正：原先硬编码中文违反"提示词跟界面语言"决策，改走 String Catalog 查表。
    static var fallbackGeneralPrompt: String { String(localized: "subagent_fallback_prompt") }
}
