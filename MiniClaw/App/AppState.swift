import SwiftUI
import UIKit

final class AppState: ObservableObject {
    @MainActor static var shared: AppState!

    // MARK: - Agent 显示信息
    @Published var agentName: String = "MiniClaw"

    // MARK: - 智能体服务商（本地文件持久化，便于后续 iCloud 同步）
    /// 已添加的全部 智能体服务商（内存态，落盘见 ProviderStore）
    @Published var providers: [LLMProvider] = []
    /// 对话默认模型所在服务商
    @Published var selectedProviderId: UUID?
    /// 对话默认模型 ID
    @Published var selectedModelId: UUID?

    // MARK: - 初始化（从本地文件载入服务商与默认模型）

    init() {
        let container = ProviderFileStore.load()
        self.providers = container.providers
        self.selectedProviderId = container.selectedProviderId
        self.selectedModelId = container.selectedModelId
        // 从持久化设置载入外观初值（init 内赋值不触发 didSet，不会回写）。
        self.colorSchemePreference = ColorSchemePreference(rawValue: SettingsStore.shared.settings.appearance.colorSchemeRaw) ?? .system
        // 从持久化设置载入界面语言初值（init 内赋值不触发 didSet，需显式同步 L10n）。
        self.appLanguage = AppLanguage(rawValue: SettingsStore.shared.settings.appearance.appLanguageRaw) ?? .system
        L10n.shared.setLanguage(self.appLanguage)
    }

    // MARK: - OAuth 支持

    /// 是否启用了 OAuth 认证的服务商（避免每次发消息做无谓遍历）。
    var hasOAuthProviders: Bool {
        providers.contains { $0.credentialType == "oauth" }
    }

    /// 是否已配置任意服务商密钥（apiKey / OAuth / Keychain 任一有效）。
    /// 用于会话页「添加密钥」引导指示器的显隐判断（2026-08-11 用户需求）。
    var hasAnyConfiguredProvider: Bool {
        providers.contains { p in
            if p.credentialType == "oauth" { return true }
            if !p.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            return APIKeyStore.getKey(for: p.id) != nil
        }
    }

    /// 供应商 → OAuth 管理器映射。仅已适配 OAuth 的服务商返回非 nil。
    @MainActor
    static func oauthManager(for providerType: ProviderType) -> (any OAuthManager)? {
        switch providerType {
        case .anthropic: return AnthropicOAuthManager.shared
        case .openai: return OpenAIOAuthManager.shared
        default: return nil
        }
    }

    /// OAuth 服务商 令牌 刷新：过期自动续期并回填内存 apiKey（不落盘——
    /// 令牌 由 OAuthKeychainStorage 按 instanceId=provider.id 持久化）。
    /// 未认证 → apiKey 置空、hasApiKey=false（UI 提示重新登录）；
    /// 网络/服务器错误 → 保留原值（不误标未认证，请求时自然报错）。
    @MainActor
    func refreshOAuthTokensIfNeeded() async {
        guard hasOAuthProviders else { return }
        for i in providers.indices where providers[i].credentialType == "oauth" {
            let p = providers[i]
            guard let manager = Self.oauthManager(for: p.providerType) else { continue }
            do {
                let token = try await manager.validAccessToken(instanceId: p.id.uuidString)
                providers[i].apiKey = token
                providers[i].hasApiKey = true
            } catch OAuthError.notAuthenticated {
                providers[i].apiKey = ""
                providers[i].hasApiKey = false
            } catch {
                // 网络/刷新失败：保留原值。
            }
        }
    }

    /// 删除服务商：同时清理该实例的 OAuth 令牌（OAuthKeychainStorage）与 API key（APIKeyStore）。
    @MainActor
    func removeProvider(id: UUID) {
        APIKeyStore.deleteKey(for: id)
        if let p = providers.first(where: { $0.id == id }), p.credentialType == "oauth" {
            if let manager = Self.oauthManager(for: p.providerType) {
                Task { try? await manager.logout(instanceId: id.uuidString) }
            }
        }
        updateProviders { $0.removeAll { $0.id == id } }
    }

    /// 持久化当前服务商与默认模型选择到本地文件
    func persistProviders() {
        ProviderFileStore.save(ProvidersContainer(
            providers: providers,
            selectedProviderId: selectedProviderId,
            selectedModelId: selectedModelId
        ))
    }

    /// 统一修改 providers 并落盘
    func updateProviders(_ block: (inout [LLMProvider]) -> Void) {
        block(&providers)
        persistProviders()
    }

    /// 设置对话默认模型（用于聊天推理）
    func setActiveModel(providerId: UUID, modelId: UUID) {
        selectedProviderId = providerId
        selectedModelId = modelId
        persistProviders()
    }

    /// 首页等非执行态 UI 使用的当前模型来源名称。
    /// 主槽位为组时展示“分组名称·首个候选模型名称”；为单模型时展示模型名；未配置时回退全局默认。
    var currentModelDisplayName: String {
        let settings = SettingsStore.shared.settings
        switch settings.session.mainModel {
        case .group(let groupId):
            if let group = settings.groups.first(where: { $0.id == groupId }),
               let candidate = routeCandidates(for: group, applyLoadBalancing: false).first {
                let groupName = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return groupName.isEmpty
                    ? candidate.model.resolvedName
                    : "\(groupName)·\(candidate.model.resolvedName)"
            }
        case .model(let compositeKey):
            if let candidate = resolveModelCandidate(compositeKey: compositeKey) {
                return candidate.model.resolvedName
            }
        case .none:
            break
        }
        return resolveActiveEndpoint()?.model.resolvedName ?? L10n.l("no_model_configured")
    }

    /// 是否存在当前聊天用途真正可执行的模型路由。
    var hasConfiguredModel: Bool {
        let settings = SettingsStore.shared.settings
        switch settings.session.mainModel {
        case .group(let groupId):
            if let group = settings.groups.first(where: { $0.id == groupId }),
               !routeCandidates(for: group).isEmpty {
                return true
            }
        case .model(let compositeKey):
            if resolveModelCandidate(compositeKey: compositeKey) != nil {
                return true
            }
        case .none:
            break
        }
        return resolveActiveEndpoint() != nil
    }

    /// 解析当前用于推理的服务商与模型
    func resolveActiveEndpoint() -> (provider: LLMProvider, model: ModelConfig)? {
        // 1. 显式选择
        if let pid = selectedProviderId,
           let p = providers.first(where: { $0.id == pid }),
           p.isEnabled,
           p.keyAdded,
           let mid = selectedModelId,
           let m = p.models.first(where: { $0.id == mid && !$0.hidden }) {
            return (p, m)
        }
        // 2. 回退：第一个启用且含模型的服务商
        if let p = providers.first(where: { $0.isEnabled && $0.keyAdded && $0.models.contains(where: { !$0.hidden }) }),
           let m = p.models.first(where: { !$0.hidden }) {
            return (p, m)
        }
        return nil
    }

    /// 解析推理请求所需的完整端点信息（含 Azure / Responses API 路径处理）。
    /// 保留单端点接口供首页等旧调用使用；聊天应优先使用 resolveModelRoutingPlan。
    func resolveChatEndpoint() -> (url: String, apiKey: String, format: APIFormat, modelId: String, modelName: String)? {
        guard let (provider, model) = resolveActiveEndpoint(),
              let endpoint = makeRouteEndpoint(
                provider: provider,
                model: model,
                groupName: nil,
                fallbackStrategy: "limited",
                contextLimitTokens: 0,
                thinkingLevel: "off"
              ) else { return nil }
        return (endpoint.url, endpoint.apiKey, endpoint.format, endpoint.modelId, endpoint.modelName)
    }

    /// 解析 embeddings 端点（OpenAI 兼容 /v1/embeddings）。
    /// 记忆 Embedding 端点（后台任务）：统一复用「副模型」端点（铁律：后台调用一律走副模型）。
    /// 仅当副模型 provider 为 OpenAI 兼容（支持 /v1/embeddings：openai / custom / openRouter）时复用其
    /// 解析记忆嵌入端点（完整 endpoint URL + key + 模型名）。单一事实来源 = `ProviderType.embeddingSupport`
    /// 能力表（未登记的厂商按不支持处理）；无可用密钥时返回 nil（索引器自动回退全文/关键词）。
    /// 返回的 endpoint 为**完整请求 URL**（含 /embeddings 路径），EmbeddingClient 不再拼路径。
    func resolveEmbeddingEndpoint() -> (endpoint: String, apiKey: String, model: String)? {
        let mem = SettingsStore.shared.settings.memory
        let model = mem.embeddingModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "text-embedding-3-small"
            : mem.embeddingModel

        /// 由候选 provider 生成完整端点：用户自定义 baseURL 非空时视为 OpenAI 兼容根（拼 /embeddings）；
        /// 为空时用厂商默认 baseURL + 能力表相对路径（如 openai → api.openai.com/v1/embeddings）。
        func endpoint(for p: LLMProvider) -> String? {
            let custom = p.customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !custom.isEmpty {
                var base = custom
                if base.hasSuffix("/") { base = String(base.dropLast()) }
                return base + "/embeddings"
            }
            guard let support = p.providerType.embeddingSupport,
                  let path = support.openAICompatPath else { return nil }
            var base = p.providerType.defaultBaseURL
            if base.hasSuffix("/") { base = String(base.dropLast()) }
            return base + "/" + path
        }

        // 1. 副模型厂商：能力表登记了 OpenAI 兼容端点才参与（Anthropic/DeepSeek/小米/Google 自动排除）；
        //    端点统一经 endpoint(for:) 生成（尊重用户自定义 baseURL，否则默认 baseURL + 能力表路径）。
        if let bg = resolveBackgroundModelEndpoint(),
           bg.providerType.embeddingSupport?.openAICompatPath != nil,
           let key = APIKeyStore.getKey(for: bg.providerId), !key.isEmpty,
           let p = providers.first(where: { $0.id == bg.providerId }),
           let ep = endpoint(for: p) {
            return (ep, key, model)
        }

        // 2. 记忆设置指定的厂商（embeddingProviderType）→ 回退 OpenAI（均有 key 的 provider）。
        let candidate = providers.first(where: { $0.providerType == mem.embeddingProviderType && $0.keyAdded })
            ?? providers.first(where: { $0.providerType == .openai && $0.keyAdded })
        guard let p = candidate, let key = APIKeyStore.getKey(for: p.id), !key.isEmpty,
              let ep = endpoint(for: p) else { return nil }
        return (ep, key, model)
    }

    /// 解析用途对应的模型路由计划。槽位可指向模型组或单个模型：
    /// - 主用途：主槽位候选耗尽后串接副槽位候选（同端点去重）；主槽位未配置/不可用时回退全局默认。
    /// - 其它用途：仅该槽位候选；未配置时回退全局默认。
    func resolveModelRoutingPlan(for purpose: ModelGroupPurpose = .main) -> ModelRoutingPlan? {
        let settings = SettingsStore.shared.settings
        let primarySelection = selection(for: purpose, session: settings.session)

        var endpoints: [ModelRouteEndpoint] = []
        var seenModelConfigs = Set<String>()
        var usesExplicitSelection = false

        func appendEndpoints(for selection: ModelSelection) {
            switch selection {
            case .none:
                break
            case .group(let groupId):
                guard let group = settings.groups.first(where: { $0.id == groupId }) else { return }
                let candidates = routeCandidates(for: group)
                guard !candidates.isEmpty else { return }
                usesExplicitSelection = true
                for candidate in candidates
                where seenModelConfigs.insert("\(candidate.provider.id.uuidString):\(candidate.model.id.uuidString)").inserted {
                    if let endpoint = makeRouteEndpoint(
                        provider: candidate.provider,
                        model: candidate.model,
                        groupName: group.name,
                        fallbackStrategy: group.fallbackStrategy,
                        contextLimitTokens: group.contextLimitTokens,
                        thinkingLevel: group.defaultThinkingLevel
                    ) {
                        endpoints.append(endpoint)
                    }
                }
            case .model(let compositeKey):
                guard let candidate = resolveModelCandidate(compositeKey: compositeKey) else { return }
                usesExplicitSelection = true
                if seenModelConfigs.insert("\(candidate.provider.id.uuidString):\(candidate.model.id.uuidString)").inserted,
                   let endpoint = makeRouteEndpoint(
                    provider: candidate.provider,
                    model: candidate.model,
                    groupName: nil,
                    fallbackStrategy: "limited",
                    contextLimitTokens: 0,
                    thinkingLevel: "off"
                   ) {
                    endpoints.append(endpoint)
                }
            }
        }

        appendEndpoints(for: primarySelection)

        // 主槽位无可用端点时回退全局默认模型（保持旧行为兼容）。
        if endpoints.isEmpty,
           let (provider, model) = resolveActiveEndpoint(),
           let endpoint = makeRouteEndpoint(
            provider: provider,
            model: model,
            groupName: nil,
            fallbackStrategy: "limited",
            contextLimitTokens: 0,
            thinkingLevel: "off"
           ) {
            endpoints.append(endpoint)
            seenModelConfigs.insert("\(provider.id.uuidString):\(model.id.uuidString)")
        }

        // 主用途：把副槽位候选串接在后面作为容灾（与主槽位不同才追加）。
        if purpose == .main, settings.session.secondaryModel != primarySelection {
            appendEndpoints(for: settings.session.secondaryModel)
        }

        guard !endpoints.isEmpty else { return nil }
        return ModelRoutingPlan(endpoints: endpoints, usesModelGroups: usesExplicitSelection)
    }

    /// 后台任务专用端点（记忆复盘、会话标题/图标生成等）：
    /// 优先副槽位（组则取首个候选；单模型直取），未配置或不可用时回退主计划首端点。
    /// 目的：把后台并发从主模型上剥离，减少对主会话的限流影响。
    func resolveBackgroundModelEndpoint() -> ModelRouteEndpoint? {
        let settings = SettingsStore.shared.settings
        if !settings.session.secondaryModel.isNone,
           let plan = resolveModelRoutingPlan(for: .secondary),
           let first = plan.endpoints.first {
            return first
        }
        return resolveModelRoutingPlan(for: .main)?.endpoints.first
    }

    /// 复盘（后台）模型展示名：优先副模型选择，未填写则回退主模型选择；
    /// 单模型显示模型名，模型组显示分组名；两者皆空则显示全局默认模型或「未配置模型」。
    /// 用于「设置-记忆-复盘模型」只读展示，用户需到「模型分组」自行调整副/主模型。
    var backgroundModelDisplayName: String {
        let settings = SettingsStore.shared.settings
        if let name = selectionDisplayName(settings.session.secondaryModel) {
            return name
        }
        if let name = selectionDisplayName(settings.session.mainModel) {
            return name
        }
        return resolveActiveEndpoint()?.model.resolvedName ?? L10n.l("no_model_configured")
    }

    private func selectionDisplayName(_ selection: ModelSelection) -> String? {
        let settings = SettingsStore.shared.settings
        switch selection {
        case .none:
            return nil
        case .group(let groupId):
            guard let group = settings.groups.first(where: { $0.id == groupId }) else { return nil }
            let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? L10n.l("unnamed_group") : name
        case .model(let compositeKey):
            guard let candidate = resolveModelCandidate(compositeKey: compositeKey) else { return nil }
            return candidate.model.resolvedName
        }
    }

    private func selection(for purpose: ModelGroupPurpose, session: SessionSettings) -> ModelSelection {
        switch purpose {
        case .main: return session.mainModel
        case .secondary: return session.secondaryModel
        case .speechInput: return session.speechInputModel
        case .speechOutput: return session.speechOutputModel
        case .subagent: return session.secondaryModel
        }
    }

    /// 子代理路由计划（后台派生任务）：统一走「副模型」槽位（铁律：后台调用一律走副模型）。
    /// 副模型未配置时返回 nil —— 调用方（AgentLoopEngine）据此沿用父引擎路由（即主模型）。
    func resolveSubagentRoutingPlan() -> ModelRoutingPlan? {
        resolveModelRoutingPlan(for: .secondary)
    }

    /// 按 compositeKey 精确解析单模型候选（要求服务商启用且已配密钥、模型未隐藏）。
    /// compositeKey 格式: "{providerInstanceId}/{modelId}"，与 ModelEntry.compositeKey 一致。
    private func resolveModelCandidate(compositeKey: String) -> (provider: LLMProvider, model: ModelConfig)? {
        let parts = compositeKey.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let providerInstanceId = UUID(uuidString: String(parts[0])) else { return nil }
        let modelId = String(parts[1])
        guard let provider = providers.first(where: { $0.id == providerInstanceId && $0.isEnabled && $0.keyAdded }),
              let model = provider.models.first(where: { $0.modelId == modelId && !$0.hidden }) else {
            return nil
        }
        return (provider, model)
    }

    private func routeCandidates(
        for group: ModelGroup,
        applyLoadBalancing: Bool = true
    ) -> [(provider: LLMProvider, model: ModelConfig)] {
        var candidates: [(provider: LLMProvider, model: ModelConfig)] = []
        var seenModelConfigs = Set<String>()

        if !group.entries.isEmpty {
            for entry in group.entries {
                guard let candidate = resolveModelCandidate(compositeKey: entry.compositeKey) else { continue }
                let key = "\(candidate.provider.id.uuidString):\(candidate.model.id.uuidString)"
                if seenModelConfigs.insert(key).inserted {
                    candidates.append((candidate.provider, candidate.model))
                }
            }
        } else {
            // 旧版 modelIds 无法表达服务商身份。迁移时为每个 ID 选设置顺序中的首个可用模型，
            // 避免旧数据一次选中多个同名服务商端点。
            for modelId in group.modelIds {
                guard let provider = providers.first(where: {
                    $0.isEnabled && $0.keyAdded && $0.models.contains(where: { $0.modelId == modelId && !$0.hidden })
                }), let model = provider.models.first(where: { $0.modelId == modelId && !$0.hidden }) else {
                    continue
                }
                let key = "\(provider.id.uuidString):\(model.id.uuidString)"
                if seenModelConfigs.insert(key).inserted {
                    candidates.append((provider, model))
                }
            }
        }

        guard applyLoadBalancing, group.strategy == "loadBalance", candidates.count > 1 else {
            return candidates
        }
        let offset = Int.random(in: 0..<candidates.count)
        return Array(candidates[offset...]) + Array(candidates[..<offset])
    }

    private func makeRouteEndpoint(
        provider: LLMProvider,
        model: ModelConfig,
        groupName: String?,
        fallbackStrategy: String,
        contextLimitTokens: Int,
        thinkingLevel: String
    ) -> ModelRouteEndpoint? {
        guard provider.isEnabled, provider.keyAdded, !model.hidden else { return nil }

        let base = provider.customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? provider.providerType.defaultBaseURL
            : provider.customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }

        let url: String
        if provider.azureEnabled {
            url = base
        } else {
            var normalized = base
            if normalized.hasSuffix("/v1/") {
                normalized = String(normalized.dropLast("/v1/".count))
            } else if normalized.hasSuffix("/v1") {
                normalized = String(normalized.dropLast("/v1".count))
            }
            if !normalized.hasSuffix("/") { normalized += "/" }
            if provider.providerType == .anthropic {
                normalized += "v1/messages"
            } else if provider.providerType == .google {
                // Gemini 端点：v1beta/models/{modelId}:streamGenerateContent
                // 密钥通过 `?key=` 查询参数拼接（由 LLMClient 在请求时处理），此处仅拼路径。
                let escapedModel = model.modelId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model.modelId
                normalized += "v1beta/models/\(escapedModel):streamGenerateContent"
            } else {
                // Responses 端点按厂商能力表(ProviderType.responsesPath):DeepSeek 无 /v1 前缀、
                // 智谱不支持(自动回落 chat/completions);DeepSeek 模型级限制(仅 v4-flash 支持
                // Responses)同步回落——两处与适配器 effectiveFormat 共用同一能力来源。
                if provider.apiFormat == .responsesAPI,
                   let responsesPath = provider.providerType.responsesPath {
                    if provider.providerType == .deepSeek,
                       !DeepSeekProviderAdapter.responsesSupportedModels.contains(model.modelId) {
                        normalized += "v1/chat/completions"
                    } else {
                        normalized += responsesPath
                    }
                } else {
                    normalized += "v1/chat/completions"
                }
            }
            url = normalized
        }

        // 有效上下文窗口：用户设置（model.contextLimit）> 厂商适配器内置目录默认 > 模型组窗口。
        // 用户未设置时回退厂商默认，保证「用户设置优先、否则厂商默认」。
        let catalogContext = LLMProviderFactory.modelCapabilities(providerType: provider.providerType, modelID: model.modelId)?.contextWindow ?? 0
        let effectiveContext = model.contextLimit > 0
            ? model.contextLimit
            : (catalogContext > 0 ? catalogContext : contextLimitTokens)
        // 有效最大输出 词元：用户设置 > 适配器目录默认（nil 表示交服务端默认）。
        let effectiveMax = model.maxOutputTokens
            ?? LLMProviderFactory.modelCapabilities(providerType: provider.providerType, modelID: model.modelId)?.maxOutputTokens

        return ModelRouteEndpoint(
            providerId: provider.id,
            modelConfigId: model.id,
            url: url,
            // OAuth 服务商：内存 apiKey 为空时从 Keychain 同步兜底（避免启动刷新未完成导致首请求缺凭证）；
            // 过期续期由 refreshOAuthTokensIfNeeded（启动 / 发消息前 / 回前台）负责。
            apiKey: provider.apiKey.isEmpty && provider.credentialType == "oauth"
                ? (OAuthKeychainStorage.loadTokenSync(instanceId: provider.id.uuidString)?.accessToken ?? "")
                : provider.apiKey,
            format: provider.apiFormat,
            usesAzureAPIKey: provider.azureEnabled,
            modelId: model.modelId,
            modelName: model.resolvedName,
            groupName: groupName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? groupName : nil,
            fallbackStrategy: fallbackStrategy,
            contextLimitTokens: effectiveContext,
            thinkingLevel: thinkingLevel,
            supportsDeepThinking: model.deepThinking,
            maxOutputTokens: effectiveMax,
            supportsImageInput: model.inputImage,
            supportsAudioInput: model.inputAudio,
            supportsVideoInput: model.inputVideo,
            organizationId: provider.organizationId,
            projectId: provider.projectId,
            providerType: provider.providerType,
            customHeaders: provider.customHeaders
        )
    }

    // MARK: - 会话
    @Published var sessions: [ChatSession] = []
    @Published var selectedSession: ChatSession?

    /// 会话级进行中运行时（key = session.id）。仅在某会话有活跃 智能体回复时存在，
    /// 回复完成 / 出错 / 用户停止后移除。使 ChatView 被销毁重建（返回首页再回来）后，
    /// 能重新接管同一引擎——恢复「响应中」状态、继续实时刷新、并保留「停止生成」控制。
    @Published var chatRuntimes: [UUID: ChatSessionRuntime] = [:]

    /// 会话级上下文压缩冷却（key = session.id，跨引擎存活）：
    /// 引擎实例每轮重建，冷却若放引擎内会随重建失效，长会话几乎每轮触发压缩（2026-08-13 修复）。
    /// sessionCompressionTurn 每轮 run 递增；压缩成功后将当前轮次写入 sessionLastCompressionTurn。
    var sessionCompressionTurn: [UUID: Int] = [:]
    var sessionLastCompressionTurn: [UUID: Int] = [:]

    /// 排队中的用户消息（key = session.id）。智能体回复进行中用户继续发送的消息进入此队列，
    /// 在会话页以虚线气泡持续展示（带删除按钮）；当前回复完成后按 FIFO 逐条落盘并触发新回复。
    @Published var pendingUserMessages: [UUID: [PendingUserMessage]] = [:]

    /// 搜索结果点击后，要求 ChatView 打开时滚动到的消息 ID（一次性，消费后清空）。
    /// 仅由首页搜索结果点击设置；普通进入会话时为 nil。
    @Published var scrollToMessageID: UUID?

    // MARK: - UI 状态
    @Published var showSettings: Bool = false
    @Published var showSearch: Bool = false
    @Published var showNewSession: Bool = false
    @Published var isAgentRunning: Bool = false

    /// 设置页内部的深链目标，例如 "models" 表示跳转到「智能体服务商」
    @Published var settingsDeepLink: String? = nil

    /// 设置页深链路由（单一事实来源；App 级 handleDeepLink 与会话内链接点击共用）：
    /// 命中 `miniclaw://settings/...`（或含 envvars/providers/models/permissions）→ 打开设置页并跳对应子页。
    /// - Returns: 是否已消费（true = 设置深链,调用方不要再当浏览器/资源链接处理）。
    @MainActor
    func routeSettingsDeepLink(_ url: URL) -> Bool {
        let lower = url.absoluteString.lowercased()
        guard lower.contains("settings") || lower.contains("envvars") else { return false }
        showSettings = true
        if lower.contains("environments") || lower.contains("envvars") {
            settingsDeepLink = "environments"
        } else if lower.contains("providers") || lower.contains("provider") {
            settingsDeepLink = "providers"
        } else if lower.contains("models") || lower.contains("model") {
            settingsDeepLink = "models"
        } else if lower.contains("permissions") {
            settingsDeepLink = "permissions"
        } else {
            settingsDeepLink = nil
        }
        return true
    }

    /// 待在浏览器中打开的本地资源 URL（来自 miniclaw:// 资源深链）
    @Published var pendingBrowserResourceURL: URL? = nil

    /// 待在浏览器中打开的 web URL（来自 apple-open 等工具，替代 Safari 跳转）
    @Published var pendingBrowserURL: URL? = nil

    /// 终端深链请求（miniclaw://open_terminal?init_command=...），终端功能后续版本接入
    @Published var pendingTerminalCommand: String? = nil

    /// 闹钟页深链（miniclaw://views/alarm）
    @Published var showAlarmView: Bool = false

    // MARK: - 深链派任务（P1-4）
    /// 一次已解析的深链派发任务，等待目标会话的 ChatView 消费。
    /// 由 `handleDeepLinkTask(url:)` 生成；ChatView 在对应会话出现（或任务 ID 变化）时复用既有发送管线执行，
    /// 不触碰 AgentLoopEngine 与 system prompt 缓存前缀（对缓存命中零影响）。
    /// 快捷指令「继续会话」随消息携带的附件（内存态：AppIntent 侧写盘后由 ChatView 落会话目录）。
    struct DeepLinkAttachment {
        let fileName: String
        let data: Data
    }

    struct PendingDeepLinkTask: Identifiable {
        let id = UUID()
        let prompt: String
        let targetSessionID: UUID
        let xSuccess: URL?
        let xError: URL?
        var attachments: [DeepLinkAttachment] = []
    }

    @Published var pendingDeepLinkTask: PendingDeepLinkTask? = nil
    /// 已消费的任务 ID，防止 ChatView 重建 / 多次 onChange 导致重复派发。
    @Published var consumedDeepLinkIDs: Set<UUID> = []
    /// 冷启动竞态兜底：若 onOpenURL 早于 SessionManager 配置（尚无法建会话），
    /// 先存原始 URL，待 HomeView 出现后由 `retryPendingDeepLink()` 重试。
    @Published var pendingRawDeepLinkURL: URL? = nil

    /// 解析并登记一次「深链派任务 / x-callback-url」请求。
    /// - Returns: true 表示已处理（成功登记、或参数缺失已回跳 x-error）；false 表示因 SessionManager 未就绪而推迟。
    @MainActor
    func handleDeepLinkTask(url: URL) -> Bool {
        guard url.scheme?.lowercased() == "miniclaw" else { return false }
        let host = url.host?.lowercased() ?? ""
        guard host == "task" || host == "run" || host == "x-callback-url" else { return false }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            fireDeepLinkError(url: url)
            return true
        }
        let items = components.queryItems ?? []
        let queryValue: (String) -> String? = { name in
            items.first(where: { $0.name.lowercased() == name.lowercased() })?
                .value?.removingPercentEncoding
        }

        guard let prompt = queryValue("prompt"),
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // prompt 缺失：若带 x-error 则回跳，否则静默忽略。
            fireDeepLinkError(url: url)
            return true
        }

        let xSuccess = queryValue("x-success").flatMap { URL(string: $0) }
        let xError = queryValue("x-error").flatMap { URL(string: $0) }

        // 解析目标会话：优先 session=<uuid>，否则新建（source 标 deeplink 便于排查）。
        var target: ChatSession?
        if let sidRaw = queryValue("session"), let sid = UUID(uuidString: sidRaw) {
            target = SessionManager.shared.session(id: sid)
        }
        if target == nil {
            let agent = queryValue("agent") ?? L10n.l("deep_link_task")
            target = SessionManager.shared.createSession(title: agent, source: "deeplink")
        }
        guard let session = target else {
            // SessionManager 尚未配置（冷启动竞态）：推迟重试。
            pendingRawDeepLinkURL = url
            return false
        }

        self.selectedSession = session
        self.pendingDeepLinkTask = PendingDeepLinkTask(
            prompt: prompt,
            targetSessionID: session.id,
            xSuccess: xSuccess,
            xError: xError
        )
        return true
    }

    /// 无 UI 派发消费者（headless：快捷指令 intent 冷启动/后台执行时使用）。
    /// 等价于 ChatView.consumePendingDeepLinkTask 的服务层路径——路由解析、附件落盘、
    /// 消息入库、引擎启动全部不依赖界面；失败确定性回跳 x-error。
    /// 与 UI 路径共享 consumedDeepLinkIDs 去重，双路径不会重复派发。
    @MainActor
    func consumeIntentTaskIfNeeded() {
        guard let task = pendingDeepLinkTask,
              !consumedDeepLinkIDs.contains(task.id) else { return }
        consumedDeepLinkIDs.insert(task.id)

        let prompt = task.prompt
        guard let session = SessionManager.shared.session(id: task.targetSessionID) else {
            pendingDeepLinkTask = nil
            fireDeepLinkError(task.xError)
            return
        }

        // 回复进行中 / 已暂停 → 并入排队队列（与人工发送一致，FIFO 续跑）。
        if let runtime = chatRuntimes[task.targetSessionID], runtime.isResponding || runtime.isPaused {
            pendingUserMessages[task.targetSessionID, default: []].append(
                PendingUserMessage(text: prompt, dlXSuccess: task.xSuccess, dlXError: task.xError)
            )
            // 2026-08-12 修复:深链入队也落盘,否则排队后被杀后台消息永久丢失。
            persistPending(task.targetSessionID)
            pendingDeepLinkTask = nil
            return
        }

        // 未配置模型：确定性失败，回跳 x-error。
        guard hasConfiguredModel else {
            pendingDeepLinkTask = nil
            fireDeepLinkError(task.xError)
            return
        }

        // 路由解析失败：确定性失败。
        guard let routingPlan = resolveModelRoutingPlan(for: .main),
              let firstEndpoint = routingPlan.endpoints.first else {
            pendingDeepLinkTask = nil
            fireDeepLinkError(task.xError)
            return
        }

        // 注：SessionManager 已配置的会话必有 modelContext；startRun 内部 guard 兜底，
        // 失败由下方 started 分支确定性回跳 x-error（headless 无 UI 时无法 insert 兜底）。

        let started = dispatchTaskToSession(
            session: session,
            prompt: prompt,
            deepLinkAttachments: task.attachments,
            firstEndpoint: firstEndpoint,
            routingPlan: routingPlan,
            xSuccess: task.xSuccess,
            xError: task.xError
        )
        if !started {
            // startRun 失败（会话无法持久化等）：确定性回跳，避免 waitForResult 挂满超时。
            fireDeepLinkError(task.xError)
        } else {
            // 首条消息触发 智能体标题生成（必须在 dispatchTaskToSession 之后：那时用户消息才入库，
            // generateAITitleIfNeeded 按「用户消息数 == 1」判定，提前调用会被跳过，
            // 深链任务会话会永远叫「深链任务」）。
            AgentRunService.shared.generateAITitleIfNeeded(session: session, firstUserText: prompt)
        }
        pendingDeepLinkTask = nil
    }

    /// 排队队列 drain（服务层）：会话终态回调后调用，headless 下 ChatView 不存在，
    /// 排队消息由这里续跑（与 UI 路径经 chatRuntimes 存在性互斥，不会重复派发）。
    @MainActor
    func drainPendingQueueIfNeeded(sessionID: UUID) {
        guard chatRuntimes[sessionID] == nil else { return }
        guard var queue = pendingUserMessages[sessionID], !queue.isEmpty else { return }
        // 2026-08-12 修复:先校验(会话/模型/路由)再出队——失败时消息保留在队列,
        // 只回跳 x-error,不再静默丢弃(此前先出队后校验失败即丢失)。
        guard let session = SessionManager.shared.session(id: sessionID) else {
            if let first = queue.first { fireDeepLinkError(first.dlXError) }
            return
        }
        guard hasConfiguredModel,
              let routingPlan = resolveModelRoutingPlan(for: .main),
              let firstEndpoint = routingPlan.endpoints.first else {
            if let first = queue.first { fireDeepLinkError(first.dlXError) }
            return
        }
        let item = queue.removeFirst()
        pendingUserMessages[sessionID] = queue
        persistPending(sessionID)
        _ = dispatchTaskToSession(
            session: session,
            prompt: item.text,
            deepLinkAttachments: [],
            firstEndpoint: firstEndpoint,
            routingPlan: routingPlan,
            xSuccess: item.dlXSuccess,
            xError: item.dlXError
        )
    }

    /// 排队队列落盘(与 ChatView.persistQueue 同一存储)。
    @MainActor
    private func persistPending(_ sessionID: UUID) {
        PendingMessageStore.shared.save(pendingUserMessages[sessionID] ?? [], for: sessionID)
    }

    /// 派发核心（consumeIntentTaskIfNeeded / drainPendingQueueIfNeeded 共用）：
    /// 附件落盘 → 模态过滤与 hints 注入 → 消息入库 → AgentRunService.startRun。
    /// - Returns: true = 引擎已启动；false = startRun 失败（调用方负责回跳 x-error）。
    @MainActor
    private func dispatchTaskToSession(
        session: ChatSession,
        prompt: String,
        deepLinkAttachments: [DeepLinkAttachment],
        firstEndpoint: ModelRouteEndpoint,
        routingPlan: ModelRoutingPlan,
        xSuccess: URL?,
        xError: URL?
    ) -> Bool {

        // 附件落盘（命名约定 <UUID前缀>_<原名>，与 UI 路径一致）。
        var attachmentPaths: [String] = []
        if !deepLinkAttachments.isEmpty {
            let sessionAttachDir = SessionFileRouter.shared.sessionHostDirectory(for: session.id)
                .appendingPathComponent("attachments", isDirectory: true)
            try? FileManager.default.createDirectory(at: sessionAttachDir, withIntermediateDirectories: true)
            for att in deepLinkAttachments {
                let safeName = att.fileName.replacingOccurrences(of: "/", with: "_")
                let name = "\(UUID().uuidString.prefix(8))_\(safeName)"
                let dest = sessionAttachDir.appendingPathComponent(name)
                do {
                    try att.data.write(to: dest)
                    attachmentPaths.append("attachments/\(name)")
                } catch {
                    NSLog("[AppState] 深链附件落盘失败: \(error.localizedDescription)")
                }
            }
        }

        let (allowedAttachments, _, droppedPaths) = AgentRunService.filterAttachments(attachmentPaths, endpoint: firstEndpoint)
        // 被拒收附件注入路径提示（同 UI 路径语义）。
        var enrichedInput = prompt
        if !droppedPaths.isEmpty {
            let guestBase = "/var/MiniClaw/"
            let imagePaths = droppedPaths.filter { AttachmentKind.from(ext: ($0 as NSString).pathExtension) == .image }
                .map { guestBase + $0 }
            let filePaths = droppedPaths.filter { AttachmentKind.from(ext: ($0 as NSString).pathExtension) != .image }
                .map { guestBase + $0 }
            var hints: [String] = []
            if !imagePaths.isEmpty {
                let fileList = imagePaths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
                let pathList = imagePaths.joined(separator: "\", \"")
                hints.append("[图片] 用户附件了 \(imagePaths.count) 张图片 (\(fileList))，但当前模型不支持原生视觉输入。请使用 vision_analyze 工具分析这些图片来理解用户意图。图片路径：\"\(pathList)\"")
            }
            if !filePaths.isEmpty {
                let fileList = filePaths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
                let pathList = filePaths.joined(separator: "\", \"")
                hints.append("[文件] 用户附件了 \(filePaths.count) 个文件 (\(fileList))，但当前模型不支持直接读取。请使用 read_document 工具读取这些文件的内容来理解用户意图。文件路径：\"\(pathList)\"")
            }
            if !hints.isEmpty {
                enrichedInput.append("\n\n[系统提示] " + hints.joined(separator: "\n"))
            }
        }

        let userMessage = ChatMessage(role: .user, content: prompt)
        userMessage.session = session
        userMessage.attachments = attachmentPaths // 与 UI 路径一致：消息气泡展示附件
        session.messages.append(userMessage)
        session.updatedAt = Date()
        // 用户消息即落盘(2026-08-12 回归修复,与 UI 路径一致):防止 headless 下会话行缺失。
        SessionManager.shared.persist(session)

        return AgentRunService.shared.startRun(
            session: session,
            enrichedInput: enrichedInput,
            userMessageID: userMessage.id,
            routingPlan: routingPlan,
            allowedAttachments: allowedAttachments,
            injectedSkill: nil,
            thinkingLevel: session.thinkingLevel,
            deepLinkCallback: (xSuccess, xError),
            uiHooks: nil
        ) != nil
    }

    /// 冷启动兜底：HomeView 配置完 SessionManager 后调用，重试被推迟的深链。
    @MainActor
    func retryPendingDeepLink() {
        guard let url = pendingRawDeepLinkURL else { return }
        pendingRawDeepLinkURL = nil
        _ = handleDeepLinkTask(url: url)
    }

    /// 快捷指令「继续会话」等待结果的续体：整轮完成时 resume 回复文本，失败/中断时 resume 错误。
    /// 由 AppIntent.perform 挂起；无等待方时保持 nil（深链 x-callback-url 路径不受影响）。
    var deepLinkResultContinuation: CheckedContinuation<String, any Error>?
    /// 续体代际号：每次登记续体 +1。超时 Task 捕获自己的代际号，
    /// 醒来时若代际已变（旧续体已被新意图替换）则不再 resume，防止陈旧超时误杀新意图。
    private(set) var deepLinkGeneration = 0

    /// 引擎已启动信号（headless 派发用）：startRun 的 preparationTask 在 engine.run 前置位，
    /// intent.perform 等待该信号后返回——保证返回时引擎已在跑（请求在途、agentDidStart 保活已续）。
    @Published var intentEngineStartedSessions: Set<UUID> = []

    /// 引擎整轮完成信号（iOS 27+ LongRunningIntent 官方路径用）：sessionID → 结果。
    /// 由 AgentRunService 终态回调（onComplete/onError/onInterrupted）写入；
    /// performBackgroundTask 轮询消费后移除。成功=整轮回复文本，失败=具体错误。
    private(set) var intentEngineFinishedSessions: [UUID: Result<String, any Error>] = [:]

    /// 记录一次整轮完成/失败结果（headless 官方路径的「完成上报」数据源）。
    @MainActor
    func markIntentEngineFinished(sessionID: UUID, result: Result<String, any Error>) {
        intentEngineFinishedSessions[sessionID] = result
    }

    /// 消费一次完成信号（取走并移除，幂等：无信号返回 nil）。
    /// 官方路径 performBackgroundTask 轮询调用；失败时抛出具体错误。
    @MainActor
    func consumeIntentEngineFinished(sessionID: UUID) throws -> String? {
        guard let r = intentEngineFinishedSessions.removeValue(forKey: sessionID) else { return nil }
        switch r {
        case .success(let text): return text
        case .failure(let error): throw error
        }
    }

    /// 整轮 Agent 跑完（成功）后回跳 x-success（x-callback-url 的「已完成」语义，对应 `PendingDeepLinkTask.xSuccess`），
    /// 并把整轮回复文本交给等待中的快捷指令（AppIntent 返回值）。
    @MainActor
    func fireDeepLinkSuccess(_ url: URL?, replyText: String? = nil) {
        if let url { UIApplication.shared.open(url) }
        deepLinkResultContinuation?.resume(returning: replyText ?? "")
        deepLinkResultContinuation = nil
        deepLinkGeneration += 1
    }

    /// 整轮 Agent 出错 / 中断后回跳 x-error（x-callback-url 的「执行失败」语义，对应 `PendingDeepLinkTask.xError`）。
    @MainActor
    func fireDeepLinkError(_ url: URL?) {
        if let url { UIApplication.shared.open(url) }
        deepLinkResultContinuation?.resume(throwing: DeepLinkAgentError.failed)
        deepLinkResultContinuation = nil
        deepLinkGeneration += 1
    }

    /// 「继续会话」快捷指令等待结果失败时的错误。
    enum DeepLinkAgentError: LocalizedError {
        case failed
        var errorDescription: String? {
            switch self {
            case .failed: return L10n.l("the_agent_failed_or_was_interrupted")
            }
        }
    }

    /// 解析阶段就失败（URL 非法 / prompt 缺失）时，从原始 URL 解析并回跳 x-error。
    @MainActor
    func fireDeepLinkError(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name.lowercased() == "x-error" })?
                .value?.removingPercentEncoding,
              let errURL = URL(string: raw) else { return }
        UIApplication.shared.open(errURL)
    }

    // Navigation
    @Published var navigationPath: [String] = []

    // MARK: - 外观（迁移自 UserDefaults，现统一由 SettingsStore 持久化）
    /// 外观模式偏好。必须是**可观察的存储属性**——修改即触发 SwiftUI 重新求值立即换肤，`didSet` 负责落盘持久化。
    @Published var colorSchemePreference: ColorSchemePreference = .system {
        didSet {
            guard oldValue != colorSchemePreference else { return }
            SettingsStore.shared.settings.appearance.colorSchemeRaw = colorSchemePreference.rawValue
            SettingsStore.shared.save()
        }
    }

    // MARK: - 界面语言（持久化于 appearance.appLanguageRaw，切换即刷新 L10n）
    /// 界面显示语言。存储属性：修改即触发 SwiftUI 重新求值刷新全部 L10n.tr，
    /// `didSet` 负责落盘持久化并通知 L10n 单例切换当前语言。
    @Published var appLanguage: AppLanguage = .system {
        didSet {
            guard oldValue != appLanguage else { return }
            SettingsStore.shared.settings.appearance.appLanguageRaw = appLanguage.rawValue
            SettingsStore.shared.save()
            L10n.shared.setLanguage(appLanguage)
        }
    }
}

