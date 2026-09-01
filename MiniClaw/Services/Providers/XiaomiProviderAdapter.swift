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

}
