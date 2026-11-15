import Foundation

/// 服务商与模型条目的本地文件持久化容器。
/// 存放在 Documents/MiniClaw/config/providers.json。
/// API Key 明文不落盘：运行时密钥存于 iOS Keychain（APIKeyStore），文件仅保留 hasApiKey 标记。
/// [ModelEntry 重构] 模型不再内嵌在 LLMProvider.models 里，而是独立的 ModelEntry 数组，
/// 通过 compositeKey("{providerId}/{modelId}") 与 provider 关联。对齐 ProviderConfig。
struct ProvidersContainer: Codable, Equatable {
    var providers: [LLMProvider]
    /// 独立的模型条目列表。每个条目通过 providerInstanceId 关联到 LLMProvider。
    var modelEntries: [ModelEntry]
    var selectedProviderId: UUID?
    var selectedModelId: UUID?

    init(
        providers: [LLMProvider] = [],
        modelEntries: [ModelEntry] = [],
        selectedProviderId: UUID? = nil,
        selectedModelId: UUID? = nil
    ) {
        self.providers = providers
        self.modelEntries = modelEntries
        self.selectedProviderId = selectedProviderId
        self.selectedModelId = selectedModelId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providers = try c.decodeIfPresent([LLMProvider].self, forKey: .providers) ?? []
        modelEntries = try c.decodeIfPresent([ModelEntry].self, forKey: .modelEntries) ?? []
        selectedProviderId = try c.decodeIfPresent(UUID.self, forKey: .selectedProviderId)
        selectedModelId = try c.decodeIfPresent(UUID.self, forKey: .selectedModelId)
    }

    private enum CodingKeys: String, CodingKey {
        case providers, modelEntries, selectedProviderId, selectedModelId
    }

    /// 查找某供应商下的所有模型条目（未隐藏的）。
    func visibleEntries(for providerId: UUID) -> [ModelEntry] {
        modelEntries.filter { $0.providerInstanceId == providerId && !$0.isHidden }
    }

    /// 查找某供应商下的所有模型条目（含隐藏的）。
    func allEntries(for providerId: UUID) -> [ModelEntry] {
        modelEntries.filter { $0.providerInstanceId == providerId }
    }

    /// 按 compositeKey 查找模型条目。
    func entry(compositeKey: String) -> ModelEntry? {
        modelEntries.first { $0.compositeKey == compositeKey }
    }
}

/// 负责把「智能体服务商 + 模型」数据读写到本地文件，并与 Keychain 同步 API Key。
enum ProviderFileStore {
    static let fileName = "providers.json"

    /// 当前文件完整路径（Documents/MiniClaw/config/providers.json）。
    static var fileURL: URL {
        FileSystemManager.shared.configDir
            .appendingPathComponent(fileName)
    }

    /// 读取数据：从 config 路径解码；缺失时用种子初始化。
    /// 明文 apiKey 在加载时写入 Keychain，内存态回填供运行时使用。
    static func load() -> ProvidersContainer {
        let container: ProvidersContainer
        if let c = decode(from: fileURL) {
            container = migrateContainer(c)
        } else {
            container = ProvidersContainer(
                providers: seedProviders(),
                modelEntries: [],
                selectedProviderId: nil,
                selectedModelId: nil
            )
            save(container)
        }

        // 清理历史遗留的演示服务商：用户要求移除「无服务商时自动注入的演示项」。
        // 仅移除「未配置密钥、且与种子定义完全一致」的演示项，不会误删用户自建服务商。
        let cleaned = stripDemoProviders(container)
        if cleaned.providers.count != container.providers.count
            || cleaned.selectedProviderId != container.selectedProviderId {
            save(cleaned)
        }
        // 加载即按能力目录 / 名称启发式校正模型模态，修复「错误落盘旧模态」：
        // 模型模态在首次拉取时写入 providers.json，而 ModelConfig 默认 inputText/outputText=true，
        // 对于不在能力目录、且名称未被启发式识别的纯语音模型，会一直以对话模型身份持久化；
        // 加载路径此前从不回查目录，导致错误模态永久留存、副模型也可能被填成语音模型。
        // 此兜底每次加载都执行，使历史数据持续自愈，且与拉取/刷新时的校正逻辑保持一致。
        let reconciled = reconcileModelModalities(cleaned)
        if reconciled != cleaned {
            save(reconciled)
        }
        // [ModelEntry] 加载后把 modelEntries 回填到 provider.models（运行时属性）。
        let populated = populateProviderModels(reconciled)
        return populated
    }

    /// 把 modelEntries 回填到对应 provider 的 models 数组（运行时属性，不落盘）。
    private static func populateProviderModels(_ container: ProvidersContainer) -> ProvidersContainer {
        var c = container
        for i in c.providers.indices {
            let pid = c.providers[i].id
            c.providers[i].models = c.modelEntries
                .filter { $0.providerInstanceId == pid }
                .sorted { $0.baseModel.modelId < $1.baseModel.modelId }
                .map { entry in
                    var m = entry.model // 合并 baseModel + overrides
                    // 标记存在条目上（baseModel 可能来自旧版本、没有该字段）⇒ 回填时以条目为准
                    if entry.isCustom { m.isCustom = true }
                    return m
                }
        }
        return c
    }

    /// 按 model 插件声明的模型能力目录(唯一事实来源)重新校正每个模型的模态开关;
    /// [ModelEntry] 直接校正 modelEntries 里的 baseModel（API 报告值）。
    private static func reconcileModelModalities(_ container: ProvidersContainer) -> ProvidersContainer {
        var c = container
        for ei in c.modelEntries.indices {
            var entry = c.modelEntries[ei]
            // [P1-8] 用户手动调过模态的模型不再被厂商目录拍平（否则重启即还原）。
            if entry.baseModel.edited { continue }
            var m = entry.baseModel
            // 找不到所属 provider 时跳过校正(避免误用默认厂商目录)。
            guard let pt = c.providers.first(where: { $0.id == entry.providerInstanceId })?.providerType else { continue }
            let info = LLMProviderFactory.modelCapabilities(providerType: pt, modelID: m.modelId)
            BuiltinModelInfo.reconcile(info, modelId: m.modelId, config: &m)
            entry.baseModel = m
            c.modelEntries[ei] = entry
        }
        return c
    }

    /// 原子写入当前数据。写入前把内存态 apiKey 同步进 Keychain，落盘不含明文。
    /// [ModelEntry] 保存时把 provider.models 同步到 modelEntries（合并已有 overrides）。
    static func save(_ container: ProvidersContainer) {
        var toSave = container
        // 同步 provider.models → modelEntries
        toSave.modelEntries = syncModelEntries(from: toSave)
        for i in toSave.providers.indices {
            var p = toSave.providers[i]
            let key = p.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            // OAuth 服务商的凭证只存 OAuthKeychainStorage（instanceId = provider.id），
            // 绝不写 APIKeyStore——避免与 API key 共用键空间、重启回填旧 令牌。
            if p.credentialType != "oauth", !key.isEmpty {
                do {
                    try APIKeyStore.saveKey(key, for: p.id)
                    p.hasApiKey = true
                } catch {
                    // 写入失败绝不谎报已保存，否则用户看到「已保存」却在请求时报认证失败。
                    p.hasApiKey = false
                    AppLogger.shared.error("ProviderStore: API Key 写入 Keychain 失败 provider=\(p.id.uuidString) err=\(error.localizedDescription)",
                                           category: "ProviderStore")
                }
            }
            p.apiKey = "" // 落盘前清空明文
            toSave.providers[i] = p
        }
        // [P1-11] 落盘失败不能静默：否则用户在设置里改的一切"看起来保存成功"，重启全回滚。
        if !persist(toSave, to: fileURL) {
            AppLogger.shared.error("[ProviderStore] persist failed path=\(fileURL.lastPathComponent)", category: "Provider")
        }
    }

    /// 把 provider.models 同步到 modelEntries：已有条目更新 baseModel，新模型新增条目。
    /// 用户 overrides 被保留（不覆盖），只更新 API 报告的 baseModel 字段。
    private static func syncModelEntries(from container: ProvidersContainer) -> [ModelEntry] {
        var entries = container.modelEntries
        for provider in container.providers {
            for model in provider.models {
                let compositeKey = "\(provider.id)/\(model.modelId)"
                if let idx = entries.firstIndex(where: { $0.compositeKey == compositeKey }) {
                    // 更新 baseModel（API 报告值），保留 overrides
                    entries[idx].baseModel = model
                    // 自定义是「来源属性」，一旦成立就不再退化（接口后来也返回同名模型时保持）
                    entries[idx].isCustom = entries[idx].isCustom || model.custom
                } else {
                    // 新模型：创建条目（无 overrides）
                    entries.append(ModelEntry(
                        providerInstanceId: provider.id,
                        model: model,
                        // 标记必须随模型带来：此前恒写 false，导致下方「自定义模型不删除」
                        // 的保护形同虚设（刷新即被删除）。
                        isCustom: model.custom,
                        isHidden: model.isHidden ?? false
                    ))
                }
            }
            // 删除不在 provider.models 里的条目。
            //
            // 注意：这里的判据**不能**是「API 没返回」——provider.models 是权威列表，
            // 它已经在上游（applyFetchedModels）把接口未返回的既有模型并进来了。
            // 曾经这里写 `!entry.isCustom`，本意是保护自定义模型，实际造成两个问题：
            //   ① 标记恒为 false（从未写 true）⇒ 保护不生效，刷新即删（用户报的 bug）
            //   ② 标记真的生效后 ⇒ 用户主动删除的自定义模型会被"保护"复活
            // 现在删除只看「是否还在权威列表里」，两种情况都正确。
            // [P0-1 兜底] 运行时列表为空 = "没加载/没回填"，不是"用户删光了"。
            // 前者若走删除分支会清空该服务商的全部模型（config 工具曾造成这种事故）。
            // 代价：用户把最后一个模型删光后，重启会因条目仍在而"复活"——用数据安全换这点不便。
            guard !provider.models.isEmpty else {
                AppLogger.shared.warning(
                    "[ProviderStore] skip entry prune: provider \(provider.id.uuidString.prefix(8)) models empty (treated as unloaded)",
                    category: "Provider")
                continue
            }
            let currentModelIds = Set(provider.models.map { $0.modelId })
            entries.removeAll { entry in
                entry.providerInstanceId == provider.id &&
                !currentModelIds.contains(entry.baseModel.modelId)
            }
        }
        return entries
    }

    /// 把容器内明文 apiKey 迁入 Keychain，并回填内存态 key（供运行时使用）。
    /// 旧版文件不含 hasApiKey 时，按明文 apiKey 是否存在推断。
    private static func migrateContainer(_ container: ProvidersContainer) -> ProvidersContainer {
        var container = container
        for i in container.providers.indices {
            var p = container.providers[i]
            // OAuth 服务商：凭证在 OAuthKeychainStorage（instanceId = provider.id），
            // 不走 APIKeyStore 迁移/回填；hasApiKey 按 OAuth 令牌 存在性判定。
            if p.credentialType == "oauth" {
                p.apiKey = "" // 运行时由 refreshOAuthTokensIfNeeded / 端点解析兜底回填
                p.hasApiKey = OAuthKeychainStorage.loadTokenSync(instanceId: p.id.uuidString) != nil
                container.providers[i] = p
                continue
            }
            let legacyKey = p.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !legacyKey.isEmpty {
                do {
                    try APIKeyStore.saveKey(legacyKey, for: p.id)
                    p.hasApiKey = true
                    p.apiKey = "" // 暂清，稍后从 Keychain 回填
                } catch {
                    p.hasApiKey = false
                    AppLogger.shared.error("ProviderStore: 迁移 API Key 写入 Keychain 失败 provider=\(p.id.uuidString) err=\(error.localizedDescription)",
                                           category: "ProviderStore")
                }
            }
            if let stored = APIKeyStore.getKey(for: p.id), !stored.isEmpty {
                p.apiKey = stored
                p.hasApiKey = true
            } else {
                p.apiKey = ""
                p.hasApiKey = false
            }
            container.providers[i] = p
        }
        return container
    }

    private static func decode(from url: URL) -> ProvidersContainer? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProvidersContainer.self, from: data)
    }

    @discardableResult
    private static func persist(_ container: ProvidersContainer, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(container)
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    /// 首次启动不再自动注入演示服务商（按用户要求移除）。
    /// 无服务商时由用户在设置中自行添加；此函数保留为空实现以维持调用点稳定。
    static func seedProviders() -> [LLMProvider] {
        []
    }

    /// 移除历史遗留的演示服务商（无密钥、且与种子定义一致的 DeepSeek / OpenAI 演示项）。
    /// 若选中的服务商被移除，则一并清空选中态，避免悬空引用。
    private static func stripDemoProviders(_ container: ProvidersContainer) -> ProvidersContainer {
        var c = container
        let before = c.providers.count
        let removedProviderIds = Set(c.providers.filter { isDemoProvider($0, in: c) }.map { $0.id })
        c.providers.removeAll { removedProviderIds.contains($0.id) }
        if c.providers.count != before {
            // 清理被移除供应商的 modelEntries
            c.modelEntries.removeAll { removedProviderIds.contains($0.providerInstanceId) }
            if let sel = c.selectedProviderId,
               !c.providers.contains(where: { $0.id == sel }) {
                c.selectedProviderId = nil
                c.selectedModelId = nil
            }
        }
        return c
    }

    /// 判断是否为「未配置密钥的演示服务商」：标签与种子一致、baseURL/类型/模型一致，
    /// 且 apiKey 为空、Keychain 也无密钥。用于精准移除演示项而不误删用户自建服务商。
    /// [ModelEntry] 通过 container.modelEntries 查找模型（provider.models 在此时尚未填充）。
    private static func isDemoProvider(_ p: LLMProvider, in container: ProvidersContainer) -> Bool {
        let key = p.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasStoredKey = APIKeyStore.getKey(for: p.id) != nil
        guard key.isEmpty, !hasStoredKey else { return false }

        let entryModels = container.allEntries(for: p.id).map { $0.baseModel.modelId }

        if p.label == "DeepSeek",
           p.providerType == .custom,
           p.customBaseURL == "https://api.deepseek.com",
           p.isEnabled,
           entryModels.count == 2,
           entryModels.contains("deepseek-chat"),
           entryModels.contains("deepseek-reasoner") {
            return true
        }
        if p.label == "OpenAI",
           p.providerType == .openai,
           p.customBaseURL.isEmpty,
           p.isEnabled,
           entryModels.isEmpty {
            return true
        }
        return false
    }
}
