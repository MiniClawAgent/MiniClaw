import Foundation

// MARK: - 子代理编排工具（dispatch_subagent / close_subagent）
//
// 2026-09-09 工具派发统一：二者此前由 AgentLoopEngine 手工注入 schema + executeTool
// 拦截执行，游离在 ToolRouter 之外——schema 缺 activity 参数注入、执行绕过
// TOOL ENTER/TOOL DONE 危机日志、工具调用确认门、暂停/取消快速检查。
// 现在注册进 ToolRouter，与其余工具同一条注册/执行/生命周期管线；
// 编排逻辑仍在引擎（子引擎创建/取消必须持有 activeSubagents），
// 工具体经 ToolEngineScope（TaskLocal）解析**当前执行引擎**回呼——
// 同一 router 实例被父子引擎共享，固定 weak 引用会解析到错误引擎。

/// `dispatch_subagent`：派发子代理（单任务 / tasks 并行 / 复用已有子代理续接）。
final class DispatchSubagentTool: AgentTool {
    static let toolName = "dispatch_subagent"
    var name: String { Self.toolName }

    /// 并行上限快照（注册时由引擎注入，schema 文案与执行限制同源）。
    private let maxParallel: Int

    init(maxParallel: Int) {
        self.maxParallel = maxParallel
    }

    /// 子代理整轮回复可达分钟级，不受 120s 工具超时约束（与旧拦截路径行为一致）。
    var executionTimeout: TimeInterval? { nil }
    /// 长时编排：绝不自动重试（v1 元数据；恢复场景从检查点重放整轮）。
    var resumePolicy: ResumePolicy { .neverRetry }

    /// profile 参数的角色列表由 SubAgentProfileStore 动态生成（用户可自建角色）。
    var schema: ToolSchema {
        let profileList = SubAgentProfileStore.shared.allSummaries()
            .map { "- `\($0.name)`：\($0.displayName)（\($0.summary)）" }
            .joined(separator: "\n")
        let profileDescription = profileList.isEmpty
            ? String(localized: "param_subagent_role_default")
            : String(format: String(localized: "loop_subagent_roles"), profileList)
        return ToolSchema(
            type: "function",
            function: ToolSchema.FunctionDef(
                name: Self.toolName,
                description: String(localized: "dispatch_subagent_tool_desc"),
                parameters: JSONSchema(
                    type: "object",
                    properties: [
                        "task": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_subtask_desc_independent")),
                        "focus": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_subagent_focus_label")),
                        "profile": JSONSchema.JSONProperty(type: "string", description: profileDescription),
                        "subagent_id": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_subagent_id_reuse")),
                        "tasks": JSONSchema.JSONProperty(
                            type: "array",
                            description: String(format: String(localized: "loop_parallel_tasks_desc"), maxParallel),
                            items: JSONSchema(
                                type: "object",
                                properties: [
                                    "task": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_subtask_desc")),
                                    "focus": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_focus_label")),
                                    "profile": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_subagent_role_inherit")),
                                    "subagent_id": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_reuse_subagent_id"))
                                ],
                                required: ["task"]
                            )
                        )
                    ],
                    required: []
                )
            )
        )
    }

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let engine = ToolEngineScope.engine else {
            return ToolResult(success: false, text: String(localized: "err_engine_released"))
        }
        return await engine.dispatchSubagent(args: parameters)
    }
}

/// `close_subagent` 工具：关闭不再需要的子代理（释放其会话、头像与上下文）。
/// 支持**批量**：`subagent_ids` 数组一次关闭多个（与并行派发对称，2026-09-06）；
/// 单个关闭仍走 `subagent_id`。二者可混用，执行层按顺序逐个关闭并汇总结果。
final class CloseSubagentTool: AgentTool {
    static let toolName = "close_subagent"
    var name: String { Self.toolName }

    var schema: ToolSchema {
        ToolSchema(
            type: "function",
            function: ToolSchema.FunctionDef(
                name: Self.toolName,
                description: String(localized: "close_subagent_tool_desc"),
                parameters: Self.parameters
            )
        )
    }

    /// 二选一（或混用）：`subagent_id` 单个；`subagent_ids` 批量。
    /// required 为空——「一个都没给」由执行层给出带存活清单的明确报错。
    static let parameters: JSONSchema = JSONSchema(
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

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let engine = ToolEngineScope.engine else {
            return ToolResult(success: false, text: String(localized: "err_engine_released"))
        }
        return await engine.closeSubagents(args: parameters)
    }

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
