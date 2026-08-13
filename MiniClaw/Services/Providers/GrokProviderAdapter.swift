import Foundation

// MARK: - xAI Grok 适配器(官方:https://docs.x.ai)
//
// 官方 OpenAI 兼容层:base_url `https://api.x.ai/v1`(`POST /v1/chat/completions` 与 `/v1/responses` 均支持),
// 认证 `Authorization: Bearer <XAI_API_KEY>`(console.x.ai 创建),SSE 标准 `data:` + `[DONE]`。
// 官方规范要点:
// 1. **服务端默认存储对话 30 天**(Responses API 无状态交互),作为客户端 App 必须显式 `store: false` 关闭,
//    避免用户对话被保存在 xAI 服务器;
// 2. 思考内容在流式 delta 的 `reasoning` 字段(OpenAI 新协议字段名,基类解析已兼容);
// 3. 推理深度 `reasoning_effort`(基类已透传);工具调用与并行工具调用同 OpenAI 协议(基类已支持)。
// 因此继承基类,仅注入 `store: false`。

final class GrokProviderAdapter: OpenAIProviderAdapter, @unchecked Sendable {
    init(config: OpenAICompatConfig) {
        super.init(name: "xAI Grok", config: config)
    }

    // MARK: 内置模型目录(xAI 官方模型)

    override class var builtinModels: [String: BuiltinModelInfo] {
        [

            "grok-4.20": BuiltinModelInfo(displayName: "Grok 4.20", contextWindow: 1000000, deepThinking: true, input: ["text", "image"], output: ["text"]),
            "grok-4.3": BuiltinModelInfo(displayName: "Grok 4.3", contextWindow: 1000000, deepThinking: true, input: ["text", "image"], output: ["text"]),
            "grok-4.5": BuiltinModelInfo(displayName: "Grok 4.5", contextWindow: 500000, deepThinking: true, input: ["text", "image"], output: ["text"]),
        ]
    }

    override class func modelCapabilities(for modelID: String) -> BuiltinModelInfo? {
        builtinModels[modelID] ?? heuristicCapabilities(for: modelID)
    }

    /// 官方默认在服务端存储对话 30 天;作为客户端必须显式关闭存储(隐私)。
    override func extraBodyFields(request: LLMStreamRequest) -> [String: Any]? {
        ["store": false]
    }
}
