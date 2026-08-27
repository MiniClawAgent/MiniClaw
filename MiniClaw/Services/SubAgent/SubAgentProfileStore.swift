import Foundation

/// 子代理角色注册表：扫描 `plugins/subagent/<id>/` 加载全部 profile。
/// 每个角色 = 一个插件目录（强制 `plugin.json[type=subagent]` 清单 + SKILL.md），
/// 随 BundledPlugins 内置 .mpk 同步或用户从插件页导入；旧散 .md 布局已由启动迁移器转换。
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
            // 强制 plugin.json 且 type=subagent：无清单/类型不符的目录一律跳过。
            guard let manifestData = try? Data(contentsOf: sub.appendingPathComponent("plugin.json")),
                  let manifest = try? JSONDecoder().decode(PluginManifest.self, from: manifestData),
                  manifest.type == "subagent",
                  !manifest.name.isEmpty,
                  let raw = try? String(contentsOf: sub.appendingPathComponent("SKILL.md"), encoding: .utf8) else { continue }
            // dispatch 主键 = manifest.name（内置 general/planner/research/writer 短名，迁移包=原文件名）；
            // displayName/summary 仍由 SKILL.md frontmatter 承载，与旧格式无缝。
            guard let p = SubAgentProfile.parse(fileName: manifest.name, content: raw) else { continue }
            loaded[p.name] = p
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
