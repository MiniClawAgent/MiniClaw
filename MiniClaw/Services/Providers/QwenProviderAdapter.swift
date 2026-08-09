import Foundation

// MARK: - 千问(Qwen / 阿里云百炼 DashScope)适配器
// 官方:https://help.aliyun.com/zh/model-studio/developer-reference/compatibility-of-openai-with-dashscope
//
// 官方推荐 OpenAI 兼容模式:base_url `https://dashscope.aliyuncs.com/compatible-mode/v1`
// (业务空间/地域变体),认证 `Authorization: Bearer sk-*`,SSE 标准 `data:` + `[DONE]`。
// 与 OpenAI 的差异(官方文档明示):
// 1. 思考开关 `enable_thinking`(顶层布尔,非 OpenAI 标准);
// 2. `system` 角色仅允许出现在 messages[0](我方消息构造满足,无需处理);
// 3. usage 需 `stream_options.include_usage` 才返回(基类已支持)。

final class QwenProviderAdapter: OpenAIProviderAdapter {
    init(config: OpenAICompatConfig) {
        super.init(name: "Qwen 千问", config: config)
    }

    override var capabilities: ProviderCapabilities {
        var caps = super.capabilities
        caps.supportsReasoning = true
        return caps
    }

    // MARK: 内置模型目录(阿里云百炼官方模型,OpenAI 兼容模式 ID)

    override class var builtinModels: [String: BuiltinModelInfo] {
        [

            "qwen-max": BuiltinModelInfo(displayName: "Qwen Max", contextWindow: 32768, maxOutputTokens: 8192, deepThinking: false, input: ["text"], output: ["text"]),
            "qwen-plus": BuiltinModelInfo(displayName: "Qwen Plus", contextWindow: 1000000, maxOutputTokens: 32768, deepThinking: true, input: ["text"], output: ["text"]),
            "qwen-turbo": BuiltinModelInfo(displayName: "Qwen Turbo", contextWindow: 131072, maxOutputTokens: 16384, deepThinking: true, input: ["text"], output: ["text"]),
            "qwen-vl-max": BuiltinModelInfo(displayName: "Qwen VL Max", contextWindow: 32768, maxOutputTokens: 8192, deepThinking: false, input: ["text", "image"], output: ["text"]),
            "qwen-vl-plus": BuiltinModelInfo(displayName: "Qwen VL Plus", contextWindow: 32768, maxOutputTokens: 4096, deepThinking: false, input: ["text"], output: ["text"]),
            "qwen3-235b-a22b": BuiltinModelInfo(displayName: "Qwen3-235B-A22B", contextWindow: 128000, maxOutputTokens: 16384, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh", "max"], input: ["text"], output: ["text"]),
            "qwen3-32b": BuiltinModelInfo(displayName: "Qwen3 32B", contextWindow: 131072, maxOutputTokens: 8192, deepThinking: true, input: ["text"], output: ["text"]),
            "qwen3-coder": BuiltinModelInfo(displayName: "Qwen3 Coder", contextWindow: 262144, deepThinking: false, input: ["text"], output: ["text"]),
            "qwen3-coder-plus": BuiltinModelInfo(displayName: "Qwen3 Coder Plus", contextWindow: 1000000, maxOutputTokens: 65536, deepThinking: true, input: ["text"], output: ["text"]),
            "qwen3-max": BuiltinModelInfo(displayName: "Qwen3 Max", contextWindow: 262144, maxOutputTokens: 65536, deepThinking: true, input: ["text"], output: ["text"]),
        ]
    }

    override class func modelCapabilities(for modelID: String) -> BuiltinModelInfo? {
        builtinModels[modelID] ?? heuristicCapabilities(for: modelID)
    }

    /// 思考开关:官方参数 `enable_thinking`(仅混合思考模型可开关)。
    override func extraBodyFields(request: LLMStreamRequest) -> [String: Any]? {
        guard let level = request.thinkingLevel, level != "off" else { return nil }
        return ["enable_thinking": true]
    }
}
