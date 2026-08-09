import Foundation

/// 子代理角色注册表：扫描 `MiniClawRoot/subagent-profiles/*.md` 加载全部 profile。
/// 内置样例在启动同步（BundledSubAgentProfiles → 数据目录）之后调用 `reload()`。
/// `general` 恒存在（内置回退常量，防数据目录被清空导致派发失败）。
/// 线程安全：NSLock 保护字典（reload 在启动主线程；引擎在任意线程读取）。
final class SubAgentProfileStore: @unchecked Sendable {
    static let shared = SubAgentProfileStore()

    private let lock = NSLock()
    private var profiles: [String: SubAgentProfile] = [:]

    private init() {}

    /// 全量重载（启动时调用；用户新增/修改文件后也可再调）。
    func reload() {
        var loaded: [String: SubAgentProfile] = [:]
        let dir = FileSystemManager.shared.subagentProfilesDir
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "md" {
            let base = url.deletingPathExtension().lastPathComponent
            guard let data = try? String(contentsOf: url, encoding: .utf8),
                  let p = SubAgentProfile.parse(fileName: base, content: data) else { continue }
            loaded[base] = p
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
