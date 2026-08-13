import Foundation

// MARK: - 小米 MiMo 适配器
// 官方:https://platform.xiaomimimo.com/ 与 https://mimo.mi.com/docs(文档站 SPA,正文以官方 GitHub 集成指南佐证)
//
// 官方声明「提供 OpenAI 与 Anthropic 协议兼容 API」:
// - OpenAI 兼容端点 `POST https://api.xiaomimimo.com/v1/chat/completions`(按量)/ 词元-plan-{region}.xiaomimimo.com(订阅);
// - 认证 `Authorization: Bearer sk-*`(按量)或 `tp-*`(词元 Plan);
// - 推理模型思考可开关(官方模型目录以 reasoning_level/effort 体系描述);
// - 注意:官方模型目录标注 MiMo 仅顺序工具调用(supports_parallel_tool_calls: false),
//   因此覆写能力声明,由引擎侧退化为单工具循环。
// 官方文档站未逐字段公开 SSE 细节,按 OpenAI 标准协议实现,联调时验证。

final class XiaomiProviderAdapter: OpenAIProviderAdapter, @unchecked Sendable {
    init(config: OpenAICompatConfig) {
        super.init(name: "Xiaomi MiMo", config: config)
    }

    override var capabilities: ProviderCapabilities {
        var caps = super.capabilities
        caps.supportsParallelToolCalls = false
        caps.supportsSeed = false
        return caps
    }

    // MARK: 内置模型目录(小米 MiMo 官方模型)

    override class var builtinModels: [String: BuiltinModelInfo] {
        [

            "mimo-v2.5": BuiltinModelInfo(displayName: "MiMo-V2.5", contextWindow: 1000000, maxOutputTokens: 128000, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh", "max"], input: ["text", "image", "audio", "video"], output: ["text"]),
            "mimo-v2.5-asr": BuiltinModelInfo(displayName: "MiMo-V2.5-ASR", contextWindow: 8192, maxOutputTokens: 2048, deepThinking: false, input: ["audio"], output: ["text"]),
            "mimo-v2.5-pro": BuiltinModelInfo(displayName: "MiMo-V2.5-Pro", contextWindow: 1000000, maxOutputTokens: 128000, deepThinking: true, thinkingLevels: ["low", "medium", "high", "xhigh", "max"], input: ["text"], output: ["text"]),
            "mimo-v2.5-pro[1m]": BuiltinModelInfo(displayName: "MiMo v2.5 Pro 1M", contextWindow: 1048576, maxOutputTokens: 16384, deepThinking: true, input: ["text"], output: ["text"]),
            "mimo-v2.5-tts": BuiltinModelInfo(displayName: "MiMo-V2.5-TTS", contextWindow: 8192, maxOutputTokens: 8192, deepThinking: false, input: ["text"], output: ["audio"]),
            "mimo-v2.5-tts-voiceclone": BuiltinModelInfo(displayName: "MiMo-V2.5-TTS VoiceClone", contextWindow: 8000, maxOutputTokens: 8000, deepThinking: false, input: ["text", "audio"], output: ["audio"]),
            "mimo-v2.5-tts-voicedesign": BuiltinModelInfo(displayName: "MiMo-V2.5-TTS VoiceDesign", contextWindow: 8000, maxOutputTokens: 8000, deepThinking: false, input: ["text"], output: ["audio"]),
            "mimo-v2.5[1m]": BuiltinModelInfo(displayName: "MiMo v2.5 1M", contextWindow: 1048576, maxOutputTokens: 16384, deepThinking: true, input: ["text"], output: ["text"]),
        ]
    }

    override class func modelCapabilities(for modelID: String) -> BuiltinModelInfo? {
        builtinModels[modelID] ?? heuristicCapabilities(for: modelID)
    }
}
