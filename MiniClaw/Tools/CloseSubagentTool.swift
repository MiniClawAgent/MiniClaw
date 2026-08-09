import Foundation

/// `close_subagent` 工具声明：关闭一个不再需要的子代理（释放其会话、头像与上下文）。
/// 与 `dispatch_subagent` 同为引擎保留工具（不在 ToolRouter 注册表）——
/// 由 `AgentLoopEngine.executeTool` 拦截执行（引擎持有 `activeSubagents` 才能取消运行中的子代理）。
/// 按用户纪律与其它 智能体工具同放 `Tools/` 文件夹，仅在此声明 schema 与参数解析。
enum CloseSubagentTool {
    static let name = "close_subagent"

    /// 引擎 buildToolSchemas 注入用（与 dispatch_subagent 并列）。
    static let schema: JSONSchema = JSONSchema(
        type: "object",
        properties: [
            "subagent_id": JSONSchema.JSONProperty(
                type: "string",
                description: "必填：要关闭的子代理 id（来自 dispatch_subagent 返回结果或「当前会话的子代理」清单）。关闭后其会话与头像移除、上下文释放，不可再复用。"
            )
        ],
        required: ["subagent_id"]
    )

    /// 解析参数 → 子代理 id；缺参/非法返回 nil（调用方给模型明确报错）。
    static func parseSubagentID(_ args: [String: Any]) -> UUID? {
        guard let s = args["subagent_id"] as? String,
              let uuid = UUID(uuidString: s) else { return nil }
        return uuid
    }
}
