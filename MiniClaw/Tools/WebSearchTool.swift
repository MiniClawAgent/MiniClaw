import Foundation

/// 联网搜索插件的稳定 id（= 沙盒目录名）。
/// 工具、插件包 manifest、插件详情页的设置区都以此判别，避免三处各写一份字符串。
enum WebSearchPlugin {
    static let id = "com.miniclaw.builtin.websearch"
    /// 未配置自定义地址时的官方端点根（插件 Key 场景）。
    static let officialBaseURL = "https://api.deepseek.com"
}

/// `web_search`：DeepSeek 联网搜索（`POST /v1/tools/search`）。
///
/// ## 为什么是「系统级内置工具」而不是 .mpk shell 插件
/// - 该接口是 DeepSeek 官方 JSON API，需要 Bearer Key 与结构化响应解析；
///   `.mpk` 的 shell 后端只能起子进程、无法安全持有 Key，也不适合解析 JSON。
/// - 归入独立插件包 `com.miniclaw.builtin.websearch`（可与其它插件分别启停）；
///   包内 `tools/web_search.json` 只做声明，schema/执行在 Swift 侧单一真相源。
///
/// ## 凭据（插件设置优先）
/// 用户在「插件 → 联网搜索 → 设置」里填的 Key 走独立 Keychain 槽位；
/// 留空时回退到「设置 → 服务商」里已配置的 **DeepSeek** 实例（优先当前选中）。
/// Base URL 同理：插件设置 > 服务商自定义地址 > DeepSeek 官方地址。
///
/// ## 计费与输出
/// 服务端按**成功请求次数**计费；默认不返回正文，正文按「单条上限 / 总预算」截断，
/// 避免一次搜索把上下文撑爆。以上参数均可在插件设置里调整。
struct WebSearchTool: AgentTool {
    let name = "web_search"

    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "web_search",
            description: String(localized: "web_search_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "query": JSONSchema.JSONProperty(
                        type: "string",
                        description: String(localized: "web_search_param_query")
                    ),
                    "count": JSONSchema.JSONProperty(
                        type: "integer",
                        description: String(localized: "web_search_param_count")
                    ),
                    "need_content": JSONSchema.JSONProperty(
                        type: "boolean",
                        description: String(localized: "web_search_param_need_content")
                    ),
                    "ori_question": JSONSchema.JSONProperty(
                        type: "string",
                        description: String(localized: "web_search_param_ori_question")
                    ),
                ],
                required: ["query"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        let rawQuery = (parameters["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawQuery.isEmpty else {
            throw ToolError.invalidParameters(String(localized: "web_search_query_required"))
        }
        let settings = (await SettingsStore.shared.snapshot()).webSearch
        // 接口约束：1–50；未显式给 count 时用插件设置里的默认值。
        let count = min(max((parameters["count"] as? Int) ?? settings.defaultCount, 1), 50)
        let needContent = (parameters["need_content"] as? Bool) ?? settings.defaultNeedContent
        let oriQuestion = (parameters["ori_question"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let timeout = TimeInterval(min(max(settings.timeoutSeconds, 5), 120))

        guard let credential = await Self.resolveCredential(settings: settings) else {
            return ToolResult(success: false, text: String(localized: "web_search_no_provider"))
        }

        var request = URLRequest(url: credential.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credential.apiKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "query": rawQuery,
            "count": count,
            "need_content": needContent,
        ]
        if let oriQuestion, !oriQuestion.isEmpty {
            body["ori_question"] = oriQuestion
        }
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            return ToolResult(success: false, text: String(localized: "web_search_bad_response"))
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return ToolResult(
                success: false,
                text: String(format: String(localized: "web_search_network_error"), error.localizedDescription)
            )
        }

        guard let http = response as? HTTPURLResponse else {
            return ToolResult(success: false, text: String(localized: "web_search_bad_response"))
        }
        guard http.statusCode == 200 else {
            let detail = Self.errorDetail(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            return ToolResult(
                success: false,
                text: String(format: String(localized: "web_search_http_error"), http.statusCode, detail)
            )
        }

        guard let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data),
              let results = decoded.results else {
            return ToolResult(success: false, text: String(localized: "web_search_bad_response"))
        }
        guard !results.isEmpty else {
            return ToolResult(success: true, text: String(localized: "web_search_no_results"))
        }

        return ToolResult(
            success: true,
            text: Self.render(
                results,
                query: rawQuery,
                includeContent: needContent,
                perResultCap: max(200, settings.contentCapChars),
                totalBudget: max(0, settings.contentBudgetChars)
            )
        )
    }

    // MARK: - 响应模型

    private struct SearchResponse: Decodable {
        let results: [Item]?
    }

    private struct Item: Decodable {
        let rerank_score: Double?
        let title: String?
        let url: String?
        let snippet: String?
        let summary: String?
        let content: String?
        let site_name: String?
        let date: String?
        let authority: Int?
    }

    private struct APIErrorEnvelope: Decodable {
        struct APIError: Decodable {
            let message: String?
        }
        let error: APIError?
    }

    // MARK: - 凭据解析

    private struct ProviderSnapshot: Sendable {
        let id: UUID
        let customBaseURL: String
        let defaultBaseURL: String
    }

    private struct Credential {
        let endpoint: URL
        let apiKey: String
    }

    /// 插件 Key 优先；没有则回退 DeepSeek 服务商 Key。
    private static func resolveCredential(settings: WebSearchSettings) async -> Credential? {
        let configuredBase = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1) 插件设置里的独立 Key。
        if let pluginKey = APIKeyStore.getWebSearchKey()?
            .trimmingCharacters(in: .whitespacesAndNewlines), !pluginKey.isEmpty {
            let base = configuredBase.isEmpty ? WebSearchPlugin.officialBaseURL : configuredBase
            guard let endpoint = endpointURL(base: base) else { return nil }
            return Credential(endpoint: endpoint, apiKey: pluginKey)
        }

        // 2) 回退：已配置的 DeepSeek 服务商（优先当前选中实例）。
        let snapshot: (providers: [ProviderSnapshot], selected: UUID?) = await MainActor.run {
            guard let app = AppState.shared else { return ([], nil) }
            let providers = app.providers
                .filter { $0.providerType == .deepSeek && $0.isEnabled }
                .map {
                    ProviderSnapshot(
                        id: $0.id,
                        customBaseURL: $0.customBaseURL,
                        defaultBaseURL: $0.providerType.defaultBaseURL
                    )
                }
            return (providers, app.selectedProviderId)
        }
        let ordered = snapshot.providers.filter { $0.id == snapshot.selected }
            + snapshot.providers.filter { $0.id != snapshot.selected }
        for candidate in ordered {
            guard let key = APIKeyStore.getKey(for: candidate.id)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { continue }
            let base: String
            if !configuredBase.isEmpty {
                base = configuredBase
            } else {
                let providerBase = candidate.customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                base = providerBase.isEmpty ? candidate.defaultBaseURL : providerBase
            }
            guard let endpoint = endpointURL(base: base) else { return nil }
            return Credential(endpoint: endpoint, apiKey: key)
        }
        return nil
    }

    /// 与模型端点同口径：BaseURL 若已带 `/v1` 先剥掉，避免拼出 `/v1/v1/...`。
    private static func endpointURL(base rawBase: String) -> URL? {
        var base = rawBase
        if base.hasSuffix("/v1/") {
            base = String(base.dropLast("/v1/".count))
        } else if base.hasSuffix("/v1") {
            base = String(base.dropLast("/v1".count))
        }
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        return URL(string: base + "/v1/tools/search")
    }

    private static func errorDetail(from data: Data) -> String? {
        guard let env = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data),
              let message = env.error?.message, !message.isEmpty else { return nil }
        return message
    }

    // MARK: - 结果渲染

    private static func render(
        _ items: [Item],
        query: String,
        includeContent: Bool,
        perResultCap: Int,
        totalBudget: Int
    ) -> String {
        var lines: [String] = [
            String(format: String(localized: "web_search_results_header"), items.count, query)
        ]
        var contentBudget = totalBudget
        for (index, item) in items.enumerated() {
            var line = "\(index + 1). \(item.title?.isEmpty == false ? item.title! : "(untitled)")"
            if let url = item.url, !url.isEmpty {
                line += "\n   URL: \(url)"
            }
            var meta: [String] = []
            if let site = item.site_name, !site.isEmpty { meta.append("site: \(site)") }
            if let date = item.date, !date.isEmpty { meta.append("date: \(String(date.prefix(10)))") }
            if let authority = item.authority, authority >= 0 { meta.append("authority: \(authority)") }
            if let score = item.rerank_score { meta.append(String(format: "score: %.2f", score)) }
            if !meta.isEmpty { line += "\n   " + meta.joined(separator: " | ") }
            if let summary = item.summary, !summary.isEmpty {
                line += "\n   summary: \(summary)"
            } else if let snippet = item.snippet, !snippet.isEmpty {
                line += "\n   snippet: \(snippet)"
            }
            if includeContent, let content = item.content, !content.isEmpty, contentBudget > 0 {
                let cap = min(perResultCap, contentBudget)
                if content.count > cap {
                    line += "\n   content: " + String(content.prefix(cap))
                        + String(localized: "web_search_content_truncated")
                } else {
                    line += "\n   content: \(content)"
                }
                contentBudget -= min(content.count, cap)
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n\n")
    }
}
