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

final class QwenProviderAdapter: OpenAIProviderAdapter, @unchecked Sendable {
    init(config: OpenAICompatConfig) {
        super.init(name: L10n.l("provider_qwen"), config: config)
    }

    override var capabilities: ProviderCapabilities {
        var caps = super.capabilities
        caps.supportsReasoning = true
        return caps
    }

    // MARK: 内置模型目录(阿里云百炼官方模型,OpenAI 兼容模式 ID)

    /// 思考开关:官方参数 `enable_thinking`(仅混合思考模型可开关)。
    override func extraBodyFields(request: LLMStreamRequest) -> [String: Any]? {
        guard let level = request.thinkingLevel, level != "off" else { return nil }
        return ["enable_thinking": true]
    }
}
