import Foundation

// MARK: - 供应商适配器工厂(参考 LLMProviderFactory 设计)
//
// 职责:按 providerType 构造适配器并注入凭据(apiKey / Azure 模式 / 附加头 / UA)。
// 加新供应商 = 新建一个适配器文件 + 在本工厂注册一行。
// 全部 7 家已接入:openai/openRouter/custom/grok/qwen/xiaomi/zhipu → OpenAI 兼容族,
// anthropic → AnthropicProviderAdapter,google → GeminiProviderAdapter。

enum LLMProviderFactory {
    /// 构造适配器(全部已注册的供应商均返回非 nil)。
    static func adapter(
        providerType: ProviderType,
        endpointURL: String,
        apiKey: String,
        usesAzureAPIKey: Bool,
        format: APIFormat,
        customHeaders: [String: String]?,
        organizationId: String?,
        projectId: String?,
        clientRequestId: UUID?
    ) -> (any LLMProviderAdapter)? {
        // 2026-09-01：OpenAI 兼容族厂商行为（能力标志/思考映射/采样约束）由
        // model 插件包的 behavior 声明驱动（PluginModelCatalog 聚合），薄壳适配器已删除。
        // 未安装对应插件 = 无行为声明 = 基类默认行为（不兜底）。
        let behavior = PluginModelCatalog.behavior(providerType: providerType)
        switch providerType {
        case .openai, .openRouter, .custom, .grok, .deepSeek, .qwen, .xiaomi, .zhipu:
            return OpenAIProviderAdapter(
                name: "OpenAI(\(providerType.rawValue))",
                config: OpenAICompatConfig(
                    endpointURL: endpointURL,
                    apiKey: apiKey,
                    usesAzureAPIKey: usesAzureAPIKey,
                    format: format,
                    customHeaders: customHeaders,
                    organizationId: organizationId,
                    projectId: projectId,
                    clientRequestId: clientRequestId,
                    behavior: behavior,
                    providerType: providerType
                )
            )
        case .anthropic:
            return AnthropicProviderAdapter(
                config: AnthropicCompatConfig(
                    endpointURL: endpointURL,
                    apiKey: apiKey,
                    customHeaders: customHeaders
                )
            )
        case .google:
            return GeminiProviderAdapter(
                config: GeminiCompatConfig(
                    endpointURL: endpointURL,
                    apiKey: apiKey,
                    customHeaders: customHeaders
                )
            )
        }
    }

    /// 模型能力查询入口(2026-09-01 TopFlow拍板:模型数据完全由 model 插件包承载,
    /// 适配器不再内嵌 builtinModels,也不做启发式猜测兜底):
    /// 拉取到的模型 ID 在用户已安装插件的 providers.json 声明中精确匹配;
    /// 匹配不到返回 nil,调用方按默认值处理(contextWindow=0 / deepThinking=false)。
    static func modelCapabilities(providerType: ProviderType, modelID: String) -> BuiltinModelInfo? {
        PluginModelCatalog.modelCapabilities(providerType: providerType, modelID: modelID)
    }

}
