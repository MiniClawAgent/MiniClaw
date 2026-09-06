import Foundation

/// `close_subagent` 工具声明：关闭不再需要的子代理（释放其会话、头像与上下文）。
/// 支持**批量**：`subagent_ids` 数组一次关闭多个（与并行派发对称，2026-09-06）；
/// 单个关闭仍走 `subagent_id`。二者可混用，执行层按顺序逐个关闭并汇总结果。
/// 与 `dispatch_subagent` 同为引擎保留工具（不在 ToolRouter 注册表）——
/// 由 `AgentLoopEngine.executeTool` 拦截执行（引擎持有 `activeSubagents` 才能取消运行中的子代理）。
enum CloseSubagentTool {
    static let name = "close_subagent"

    /// 引擎 buildToolSchemas 注入用（与 dispatch_subagent 并列）。
    /// 二选一（或混用）：`subagent_id` 单个；`subagent_ids` 批量。
    /// required 为空——「一个都没给」由执行层给出带存活清单的明确报错。
    static let schema: JSONSchema = JSONSchema(
        type: "object",
        properties: [
            "subagent_id": JSONSchema.JSONProperty(
                type: "string",
                description: String(localized: "param_close_subagent_id_required")
            ),
            "subagent_ids": JSONSchema.JSONProperty(
                type: "array",
                description: String(localized: "param_close_subagent_ids"),
                items: JSONSchema(type: "string")
            ),
        ]
    )

    /// 收集待关闭目标（保留传入顺序、去重）：`subagent_id` 单个 + `subagent_ids` 数组。
    /// 元素支持完整 UUID 或 8 位短码（执行层解析）。
    static func parseSubagentTokens(_ args: [String: Any]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func push(_ raw: Any?) {
            guard let s = raw as? String else { return }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !seen.contains(t) else { return }
            seen.insert(t)
            out.append(t)
        }
        push(args["subagent_id"])
        if let list = args["subagent_ids"] as? [Any] {
            for v in list { push(v) }
        } else if let list = args["subagent_ids"] as? [String] {
            for v in list { push(v) }
        }
        return out
    }
}
