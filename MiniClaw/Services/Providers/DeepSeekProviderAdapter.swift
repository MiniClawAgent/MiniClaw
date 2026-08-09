import Foundation

// MARK: - DeepSeek 适配器
// 官方文档(核对日期 2026-08,官网更新至 2026-07-31):
// - 首页:https://api-docs.deepseek.com/zh-cn/
// - 模型与价格:https://api-docs.deepseek.com/zh-cn/quick_start/pricing
// - 思考模式:https://api-docs.deepseek.com/zh-cn/guides/thinking_mode
// - 上下文硬盘缓存:https://api-docs.deepseek.com/zh-cn/guides/kv_cache
// - Responses API:https://api-docs.deepseek.com/zh-cn/guides/responses_api
// - Tool Calls:https://api-docs.deepseek.com/zh-cn/guides/tool_calls
// - Chat Completions 参考:https://api-docs.deepseek.com/zh-cn/api/create-chat-completion
//
// OpenAI 兼容层:base_url `https://api.deepseek.com`(`/v1` 前缀等价,官方明示),
// 认证 `Authorization: Bearer`,SSE 标准 `data:` + `[DONE]`;Responses 端点**无 /v1 前缀**
// (`https://api.deepseek.com/responses`)。
// 官方规范要点(2026 现状):
// 1. 思考模式:默认开启(effort 默认 high);开关 `thinking: {"type": "enabled"/"disabled"}`
//    (OpenAI 格式),强度 `reasoning_effort`;Responses 格式开关/强度合一:`reasoning: {"effort":
//    "none/low/high/max"}`(none=关闭)。官方映射表(2026-08,thinking_mode 页):
//      请求 effort | v4-flash 实际 | v4-pro 实际
//      low        | low          | high
//      high       | high         | high
//      xhigh      | high         | max
//      max        | max          | max
//    → v4-flash 有效档 low/high/max;v4-pro 当前有效档 high/max(8 月初更新为三档);
//    思考内容经 `delta.reasoning_content` 返回;
// 2. **思考模式下不支持 temperature/top_p/presence_penalty/frequency_penalty**(设置不报错但不生效)
//    ——构造时显式置 nil,避免给用户"参数生效"的错觉;
// 3. **工具调用时 assistant 消息必须完整回传 reasoning_content**(官方硬性要求,否则 400)
//    ——preserveReasoningContent = true;
// 4. 上下文硬盘缓存**自动生效**、无需配置;命中字段 usage 顶层 `prompt_cache_hit_tokens` /
//    `prompt_cache_miss_tokens`(Responses 为 `input_tokens_details.cached_tokens`);
//    稳定内容放前缀、动态内容放末尾是命中最佳实践(缓存命中输入价远低于未命中);
// 5. 模型(2026-08 官网在售仅 2 个):`deepseek-v4-flash`(支持 chat/Responses/Anthropic/FIM;
//    context 1M、maxOutput 384K、纯文本)、`deepseek-v4-pro`(chat/Anthropic/FIM,**Responses 暂不支持**,
//    context 1M、maxOutput 384K、纯文本);**deepseek-chat / deepseek-reasoner 已于 2026-07-24 停止使用**,
//    调用会失败,不在适配范围内。

final class DeepSeekProviderAdapter: OpenAIProviderAdapter {
    /// 官方 Responses API 支持的模型(2026-08:仅 deepseek-v4-flash;v4-pro 官方称 8 月初加推)。
    /// 其他模型(deepseek-chat / deepseek-reasoner)选 Responses API 时自动回落 Chat Completions。
    static let responsesSupportedModels: Set<String> = ["deepseek-v4-flash"]

    init(config: OpenAICompatConfig) {
        super.init(name: "DeepSeek", config: config)
    }

    /// Responses API 回落:模型不在官方支持列表时降级 Chat Completions(URL 侧同步判断,
    /// 见 AppState.makeRouteEndpoint,两处共用 responsesSupportedModels)。
    override func effectiveFormat(for request: LLMStreamRequest) -> APIFormat {
        if config.format == .responsesAPI, !Self.responsesSupportedModels.contains(request.model) {
            return .chatCompletions
        }
        return config.format
    }

    override var capabilities: ProviderCapabilities {
        var caps = super.capabilities
        caps.supportsReasoning = true
        caps.supportsPromptCaching = true
        return caps
    }

    /// 工具调用必须回传 reasoning_content(官方硬性要求,否则 400)。
    override var preserveReasoningContent: Bool { true }

    /// 思考模式开关(官方参数,默认开启;off 时显式 disabled)。
    override func extraBodyFields(request: LLMStreamRequest) -> [String: Any]? {
        guard let level = request.thinkingLevel else { return nil }
        return ["thinking": ["type": level == "off" ? "disabled" : "enabled"]]
    }

    /// 思考模式下官方不支持 temperature/top_p/presence_penalty/frequency_penalty
    /// (设置不报错但不生效)——显式置 nil,避免无效参数带给用户的错觉。
    /// 注意:思考模式默认开启,仅显式 off 时不抑制。
    override func clampSampling(request: inout LLMStreamRequest) {
        if request.thinkingLevel != "off" {
            request.temperature = nil
            request.topP = nil
            request.frequencyPenalty = nil
            request.presencePenalty = nil
        }
    }

    // MARK: 内置模型目录(DeepSeek 官方模型)

    override class var builtinModels: [String: BuiltinModelInfo] {
        [

            "deepseek-v4-flash": BuiltinModelInfo(displayName: "DeepSeek V4 Flash", contextWindow: 1000000, maxOutputTokens: 393216, deepThinking: true, thinkingLevels: ["low", "high", "max"], input: ["text"], output: ["text"], apiFormats: ["chat/completions", "responses", "anthropic"], responsesSupported: true, specialConstraints: "思考模式禁 temperature/top_p/penalty(不报错但不生效);带 tools 请求必须回传 reasoning_content 否则 400;effort medium/xhigh 映射 high", pricing: "缓存命中 0.02 元/M、未命中 1 元/M、输出 2 元/M(人民币);峰谷定价即将实行"),
            "deepseek-v4-pro": BuiltinModelInfo(displayName: "DeepSeek V4 Pro", contextWindow: 1000000, maxOutputTokens: 393216, deepThinking: true, thinkingLevels: ["high", "max"], input: ["text"], output: ["text"], apiFormats: ["chat/completions", "anthropic"], responsesSupported: false, specialConstraints: "Responses 暂不支持(官方 8 月初加推);effort 目前仅 high/max 有效(low→high、xhigh→max);思考模式禁 temperature/top_p/penalty;带 tools 请求必须回传 reasoning_content 否则 400", pricing: "缓存命中 0.025 元/M、未命中 3 元/M、输出 6 元/M(人民币);峰谷定价即将实行"),
        ]
    }

    override class func modelCapabilities(for modelID: String) -> BuiltinModelInfo? {
        builtinModels[modelID] ?? heuristicCapabilities(for: modelID)
    }
}
