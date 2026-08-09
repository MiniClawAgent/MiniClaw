import Foundation

/// skill_load（P0-1 渐进式技能加载 — 强注入 cache-safe 变体）
///
/// system 稳定段只常驻各启用技能的 name + description 元数据（见 `SkillManager.enabledSkillMetadata()`）。
/// 模型据此判断某技能与当前任务相关时，主动调用本工具把该技能标记为「本会话已加载」。
///
/// 关键设计（cache-safe）：
/// - 完整 SKILL.md 正文**不**作为工具结果留在历史里（历史不进缓存但会被 ContextBudget 压缩吞掉），
///   也不进 system 稳定段（会污染缓存前缀、致命打击命中率）。
/// - 正文由 `AgentLoopEngine` 在每个请求拼 system 时，注入到**缓存断点之后的易变段**，
///   因此对 KV 缓存命中率零影响，且模型遵循强度更高（在 system 内）、不怕上下文压缩。
/// - 本工具只返回一句短确认；真正的正文由引擎从 `SkillManager.loadedSkillBodies(for:)` 读入易变段。
struct SkillLoadTool: AgentTool {
    let name = "skill_load"
    let currentSessionID: UUID?

    init(currentSessionID: UUID? = nil) {
        self.currentSessionID = currentSessionID
    }

    let schema: ToolSchema = {
        ToolSchema(
            type: "function",
            function: ToolSchema.FunctionDef(
                name: "skill_load",
                description: "按需加载某个已启用技能的完整 SKILL.md 正文。system 提示已列出全部启用技能的 name 与 description 供你判断；当某条技能与当前任务相关、你需要遵循其指令时，调用本工具加载其正文。加载后请在后续对话中严格遵循该技能的工作流与输出格式。name 必须是 system 中「已启用技能」列出的技能名之一。",
                parameters: JSONSchema(
                    type: "object",
                    properties: [
                        "name": JSONSchema.JSONProperty(
                            type: "string",
                            description: "要加载的技能名（与 system 中「已启用技能」列出的 name 完全一致，例如 git-workflow）"
                        )
                    ],
                    required: ["name"]
                )
            )
        )
    }()

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let name = (parameters["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return ToolResult(success: false, text: "skill_load 需要 name 参数（要加载的技能名）。")
        }

        guard let body = await SkillManager.shared.loadSkillBody(named: name) else {
            return ToolResult(
                success: false,
                text: "未找到名为「\(name)」的已启用技能。请确认 name 与 system 中「已启用技能」列出的名称完全一致。"
            )
        }

        // 记录到本会话已加载集合，由引擎在 system 易变段注入完整正文（不进缓存前缀，命中率不受影响）。
        if let sid = currentSessionID {
            await SkillManager.shared.markSkillLoaded(name, sessionID: sid)
            return ToolResult(
                success: true,
                text: "已加载技能「\(name)」。其完整指令正文已注入本会话 system 提示的易变段，后续对话请严格遵循其工作流与输出格式。"
            )
        }

        // 兜底：无会话上下文（理论上不会发生）时退回工具结果返回正文，保证模型至少本轮可见。
        return ToolResult(
            success: true,
            text: "## 已加载技能：\(name)\n以下是该技能的完整指令正文，请在后续对话中严格遵循其工作流与输出格式：\n\n\(body)"
        )
    }
}
