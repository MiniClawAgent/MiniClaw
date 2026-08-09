import Foundation

// MARK: - 智谱 GLM 适配器
// 官方:https://open.bigmodel.cn/dev/api(中文站)与 https://docs.z.ai(国际站,同源完整文档)
//
// OpenAI v4 兼容端点:`POST https://open.bigmodel.cn/api/paas/v4/chat/completions`
// (国际站 https://api.z.ai/api/paas/v4/),认证 `Authorization: Bearer`,SSE 标准 + `[DONE]`。
// 与 OpenAI 的差异(官方文档明示):
// 1. `temperature` 范围 [0,1](OpenAI 为 [0,2]),超出报错 → 钳制;
// 2. 思考模式非标准对象 `thinking: {"type":"enabled"|"disabled"}`(可加 clear_thinking 保留思考);
//    GLM-5.2 另有 `reasoning_effort`(max/xhigh/high/medium/low/minimal/none,基类已透传);
// 3. 思考内容经 `delta.reasoning_content` 返回(基类解析已支持);
// 4. 上下文缓存全自动,命中经 `usage.prompt_tokens_details.cached_tokens` 上报(基类 usage 解析已支持)。

final class ZhipuProviderAdapter: OpenAIProviderAdapter {
    init(config: OpenAICompatConfig) {
        super.init(name: "Zhipu 智谱", config: config)
    }

    /// 官方采样范围钳制:temperature ∈ [0,1]。
    override func clampSampling(request: inout LLMStreamRequest) {
        if let t = request.temperature, t > 1.0 {
            request.temperature = 1.0
        }
        if let t = request.temperature, t < 0.0 {
            request.temperature = 0.0
        }
    }

    // MARK: 内置模型目录(智谱 GLM 官方模型)

    override class var builtinModels: [String: BuiltinModelInfo] {
        [

            "glm-4.5": BuiltinModelInfo(displayName: "GLM-4.5", contextWindow: 128000, maxOutputTokens: 98304, deepThinking: true, input: ["text"], output: ["text"]),
            "glm-4.5-air": BuiltinModelInfo(displayName: "GLM-4.5 Air", contextWindow: 128000, maxOutputTokens: 16384, deepThinking: false, input: ["text"], output: ["text"]),
            "glm-4.6": BuiltinModelInfo(displayName: "GLM-4.6", contextWindow: 200000, maxOutputTokens: 128000, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh", "max"], input: ["text"], output: ["text"]),
            "glm-4.7": BuiltinModelInfo(displayName: "GLM-4.7", contextWindow: 200000, maxOutputTokens: 32768, deepThinking: true, input: ["text"], output: ["text"]),
            "glm-5": BuiltinModelInfo(displayName: "GLM-5", contextWindow: 198000, maxOutputTokens: 64000, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh", "max"], input: ["text"], output: ["text"]),
            "glm-5.1": BuiltinModelInfo(displayName: "GLM-5.1", contextWindow: 198000, maxOutputTokens: 128000, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh", "max"], input: ["text"], output: ["text"]),
            "glm-5.2": BuiltinModelInfo(displayName: "GLM-5.2", contextWindow: 1000000, maxOutputTokens: 128000, deepThinking: true, input: ["text"], output: ["text"]),
        ]
    }

    override class func modelCapabilities(for modelID: String) -> BuiltinModelInfo? {
        builtinModels[modelID] ?? heuristicCapabilities(for: modelID)
    }

    /// 思考开关:官方非标准对象 `thinking`。GLM-4.6+ 默认思考开启,
    /// 显式「off」必须发 `{"type":"disabled"}` 才能真正关闭(省略=默认开启,关闭无效)。
    override func extraBodyFields(request: LLMStreamRequest) -> [String: Any]? {
        guard let level = request.thinkingLevel else { return nil }
        return ["thinking": ["type": level == "off" ? "disabled" : "enabled"]]
    }
}
