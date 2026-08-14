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

enum SkillError: Error {
    case invalidName
    case notFound
}

