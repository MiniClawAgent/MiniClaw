import Foundation

/// 子代理角色注册表：扫描 `plugins/subagent/<id>/` 加载全部 profile。
/// 插件形态：**一个 subagent 插件 = 一份 plugin.json[type=subagent] 清单 + 若干 .md 角色文件**（任意层级）。
/// 角色的 dispatch 主键 = 文件名 stem（如 general/planner/research/writer）；
/// 显示名/适用场景由各角色 md 的 frontmatter（name/description）承载。
/// 随 BundledPlugins 内置 .mpk 同步或用户从插件页导入。
/// （未上架不做旧兼容：历史散 .md 布局由启动清退直接删除。）
/// `general` 恒存在（内置回退常量，防数据目录被清空导致派发失败）。
/// 线程安全：NSLock 保护字典（reload 在启动后台任务；引擎在任意线程读取）。
final class SubAgentProfileStore: @unchecked Sendable {
    static let shared = SubAgentProfileStore()

    private let lock = NSLock()
    private var profiles: [String: SubAgentProfile] = [:]

    private init() {}

    /// 全量重载（启动时调用；用户新增/导入插件后也可再调）。
    func reload() {
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
        // 保证 general 恒存在（内置回退）。
        if loaded["general"] == nil {
            loaded["general"] = SubAgentProfile(
                name: "general",
                displayName: "通用助手",
                summary: "默认角色：适合可独立完成、需要聚焦上下文的通用子任务",
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
                ?? SubAgentProfile(name: "general", displayName: "通用助手", summary: "",
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

    /// general 兜底提示词（内置常量；数据目录无任何文件时保证子代理仍可用）。
    static let fallbackGeneralPrompt = """
    你是一个专注的子代理（subagent），由父代理把一个明确的子任务交给你独立完成。
    规则：
    - 只使用你手上的工具完成任务。
    - 直接、简洁地完成任务，最后用一段中文总结你的关键发现或结果，不要多余寒暄与自我介绍。
    - 你的最终回答会作为父代理的一个工具结果，请保证信息自包含、可被父代理直接引用。
    """
}
