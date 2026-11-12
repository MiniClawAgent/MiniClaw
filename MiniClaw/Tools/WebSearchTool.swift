import Foundation

/// `web_search`：DeepSeek 联网搜索（`POST /v1/tools/search`）。
///
/// ## 为什么是「系统级内置工具」而不是 .mpk shell 插件
/// - 该接口是 DeepSeek 官方 JSON API，需要 Bearer Key 与结构化响应解析；
///   `.mpk` 的 shell 后端只能起子进程、无法安全持有 Key，也不适合解析 JSON。
/// - 归入 `com.miniclaw.builtin.tools`（系统能力工具包）：与 Apple 系统能力同一启停位，
///   默认启用；包内 `tools/web_search.json` 只做声明，schema/执行在 Swift 侧单一真相源。
///
/// ## 凭据
/// 复用用户在「设置 → 服务商」里已配置的 **DeepSeek** API Key（不新增单独配置项）：
/// 优先当前选中的服务商，其次任意可用 DeepSeek 实例；自定义 BaseURL（中转）同样生效。
/// 未配置时返回可操作提示，不静默失败。
///
/// ## 计费与输出
/// 服务端按**成功请求次数**计费；`need_content` 默认 false、正文按条截断，
/// 避免一次搜索把上下文撑爆。错误按 401/402/429/5xx 分类提示。
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
        // 接口约束：1–50；文档默认 10。
        let count = min(max((parameters["count"] as? Int) ?? 10, 1), 50)
        let needContent = (parameters["need_content"] as? Bool) ?? false
        let oriQuestion = (parameters["ori_question"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let credential = await Self.resolveCredential() else {
            return ToolResult(success: false, text: String(localized: "web_search_no_provider"))
        }

        var request = URLRequest(url: credential.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
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

        return ToolResult(success: true, text: Self.render(results, query: rawQuery, count: count, includeContent: needContent))
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

    /// 解析 DeepSeek 服务商与 Key；无可用实例返回 nil（由调用方给出可操作提示）。
    private static func resolveCredential() async -> Credential? {
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
        // 优先当前选中的 DeepSeek 实例，其次任意可用实例。
        let ordered = snapshot.providers.filter { $0.id == snapshot.selected }
            + snapshot.providers.filter { $0.id != snapshot.selected }
        guard let provider = ordered.first else { return nil }
        // 逐个实例找有 Key 的那个（选中的实例可能恰好没填 Key）。
        for candidate in ordered {
            guard let key = APIKeyStore.getKey(for: candidate.id)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { continue }
            guard let endpoint = endpointURL(for: candidate) else { return nil }
            return Credential(endpoint: endpoint, apiKey: key)
        }
        _ = provider
        return nil
    }

    /// 与模型端点同口径：自定义 BaseURL 若已带 `/v1` 先剥掉，避免拼出 `/v1/v1/...`。
    private static func endpointURL(for provider: ProviderSnapshot) -> URL? {
        let custom = provider.customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var base = custom.isEmpty ? provider.defaultBaseURL : custom
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

    /// 单条正文上限 4 000 字符、整体正文预算 24 000 字符：宁可截断，不撑爆上下文。
    private static let perResultContentCap = 4_000
    private static let totalContentBudget = 24_000

    private static func render(
        _ items: [Item],
        query: String,
        count: Int,
        includeContent: Bool
    ) -> String {
        var lines: [String] = [
            String(format: String(localized: "web_search_results_header"), items.count, query)
        ]
        var contentBudget = totalContentBudget
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
                let cap = min(perResultContentCap, contentBudget)
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
