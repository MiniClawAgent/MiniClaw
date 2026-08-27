import Foundation

// MARK: - Skill Frontmatter (技能格式 格式)

/// 解析 SKILL.md 得到的元数据 + 正文。
/// 格式对齐 https://github.com//技能格式：
/// 每个技能是一个目录（小写 kebab-case），内含 SKILL.md：
///   ---
///   name: skill-name
///   description: >            # 折叠标量，可多行
///     做什么、何时触发
///   compatibility: 可选依赖    # 可选
///   version: 1.0.0            # 可选（技能格式 无此字段，这里用于展示）
///   ---
///   <Markdown 指令正文，建议 < 500 行>
/// 可选子目录：scripts/（可执行脚本）、references/（按需加载文档）、assets/（模板/资源）、evals/（测试用例）
struct SkillFrontmatter {
    var name: String = ""
    var description: String = ""
    var compatibility: String?
    var version: String?
    var body: String = ""
}

/// 插件清单（`plugin.json`）—— `.mpk` 唯一真相源，缺失则整个插件拒绝加载。
/// 字段对齐《MiniClaw 插件化架构方案》§二；`id` 全局唯一，用作沙盒目录名。
///
/// **容错解码（治本修复 2026-08-27）**：Swift 合成的 Decodable 不使用属性默认值，
/// 非 Optional 键在 JSON 中缺失即整体解码失败。第三方手写的 plugin.json
/// （含内置包）通常省略 `dependsOn`/`conflictsWith` 等可选字段，会导致
/// loadSkills 静默跳过、插件"已导入却不显示"。因此显式实现 init(from:)，
/// 所有键均按"缺失即取声明默认值"处理；编码端保持合成实现。
struct PluginManifest: Codable {
    var id: String = ""
    var name: String = ""
    var version: String = "1.0.0"
    var type: String = "skill"
    var category: String = "skill"
    var minCoreVersion: String = "1.0.0"
    var enabledByDefault: Bool = true
    var dependsOn: [String] = []
    var conflictsWith: [String] = []
    var author: String = ""
    var license: String = ""
    var icon: String = ""

    private enum CodingKeys: String, CodingKey {
        case id, name, version, type, category, minCoreVersion
        case enabledByDefault, dependsOn, conflictsWith
        case author, license, icon
    }

    /// 声明默认值：所有键均可缺席。
    init(
        id: String = "",
        name: String = "",
        version: String = "1.0.0",
        type: String = "skill",
        category: String = "skill",
        minCoreVersion: String = "1.0.0",
        enabledByDefault: Bool = true,
        dependsOn: [String] = [],
        conflictsWith: [String] = [],
        author: String = "",
        license: String = "",
        icon: String = ""
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.type = type
        self.category = category
        self.minCoreVersion = minCoreVersion
        self.enabledByDefault = enabledByDefault
        self.dependsOn = dependsOn
        self.conflictsWith = conflictsWith
        self.author = author
        self.license = license
        self.icon = icon
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        // 自定义键名映射时取不到声明的属性默认值，先以 d 为基底再覆盖。
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? d.id
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? d.version
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? d.type
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? d.category
        minCoreVersion = try c.decodeIfPresent(String.self, forKey: .minCoreVersion) ?? d.minCoreVersion
        enabledByDefault = try c.decodeIfPresent(Bool.self, forKey: .enabledByDefault) ?? d.enabledByDefault
        dependsOn = try c.decodeIfPresent([String].self, forKey: .dependsOn) ?? d.dependsOn
        conflictsWith = try c.decodeIfPresent([String].self, forKey: .conflictsWith) ?? d.conflictsWith
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? d.author
        license = try c.decodeIfPresent(String.self, forKey: .license) ?? d.license
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? d.icon
    }
}

enum SkillError: Error {
    case invalidName
    case notFound
}

