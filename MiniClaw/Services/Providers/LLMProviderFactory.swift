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
        switch providerType {
        case .openai, .openRouter, .custom:
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
                    providerType: providerType
                )
            )
        case .grok:
            return GrokProviderAdapter(
                config: OpenAICompatConfig(
                    endpointURL: endpointURL,
                    apiKey: apiKey,
                    usesAzureAPIKey: false,
                    format: format,
                    customHeaders: customHeaders,
                    organizationId: organizationId,
                    projectId: projectId,
                    clientRequestId: clientRequestId,
                    providerType: providerType
                )
            )
        case .deepSeek:
            return DeepSeekProviderAdapter(
                config: OpenAICompatConfig(
                    endpointURL: endpointURL,
                    apiKey: apiKey,
                    usesAzureAPIKey: false,
                    format: format,
                    customHeaders: customHeaders,
                    organizationId: organizationId,
                    projectId: projectId,
                    clientRequestId: clientRequestId,
                    providerType: providerType
                )
            )
        case .qwen:
            return QwenProviderAdapter(
                config: OpenAICompatConfig(
                    endpointURL: endpointURL,
                    apiKey: apiKey,
                    usesAzureAPIKey: false,
                    format: format,
                    customHeaders: customHeaders,
                    organizationId: organizationId,
                    projectId: projectId,
                    clientRequestId: clientRequestId,
                    providerType: providerType
                )
            )
        case .xiaomi:
            return XiaomiProviderAdapter(
                config: OpenAICompatConfig(
                    endpointURL: endpointURL,
                    apiKey: apiKey,
                    usesAzureAPIKey: false,
                    format: format,
                    customHeaders: customHeaders,
                    organizationId: organizationId,
                    projectId: projectId,
                    clientRequestId: clientRequestId,
                    providerType: providerType
                )
            )
        case .zhipu:
            return ZhipuProviderAdapter(
                config: OpenAICompatConfig(
                    endpointURL: endpointURL,
                    apiKey: apiKey,
                    usesAzureAPIKey: false,
                    format: format,
                    customHeaders: customHeaders,
                    organizationId: organizationId,
                    projectId: projectId,
                    clientRequestId: clientRequestId,
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

    /// 模型能力查询入口(模型维护并入厂商适配器文件后,拉取/路由统一走这里):
    /// 按 providerType 找到对应适配器的内置目录,精确匹配 → 名称启发式兜底。
    static func modelCapabilities(providerType: ProviderType, modelID: String) -> BuiltinModelInfo? {
        if let compat = openAICompat(providerType: providerType) {
            return compat.modelCapabilities(for: modelID)
        }
        switch providerType {
        case .anthropic: return AnthropicProviderAdapter.modelCapabilities(for: modelID)
        case .google: return GeminiProviderAdapter.modelCapabilities(for: modelID)
        default: return nil
        }
    }

    /// 全量内置目录(拉取失败时的回退模型列表用)。
    static func builtinModels(providerType: ProviderType) -> [String: BuiltinModelInfo] {
        switch providerType {
        case .openai, .openRouter, .custom: return OpenAIProviderAdapter.builtinModels
        case .grok: return GrokProviderAdapter.builtinModels
        case .deepSeek: return DeepSeekProviderAdapter.builtinModels
        case .qwen: return QwenProviderAdapter.builtinModels
        case .xiaomi: return XiaomiProviderAdapter.builtinModels
        case .zhipu: return ZhipuProviderAdapter.builtinModels
        case .anthropic: return AnthropicProviderAdapter.builtinModels
        case .google: return GeminiProviderAdapter.builtinModels
        }
    }

    /// OpenAI 兼容族适配器类型(用于解析静态模型能力)。
    private static func openAICompat(providerType: ProviderType) -> OpenAIProviderAdapter.Type? {
        switch providerType {
        case .openai, .openRouter, .custom: return OpenAIProviderAdapter.self
        case .grok: return GrokProviderAdapter.self
        case .deepSeek: return DeepSeekProviderAdapter.self
        case .qwen: return QwenProviderAdapter.self
        case .xiaomi: return XiaomiProviderAdapter.self
        case .zhipu: return ZhipuProviderAdapter.self
        default: return nil
        }
    }
}
