import Foundation

/// 浏览器操作工具：智能体通过单一 `browser` 工具驱动内置浏览器。
/// action 决定操作，params 为该操作的参数字典，tab_index 指定目标标签（省略=当前激活）。
struct BrowserTool: AgentTool {
    let name = "browser"

    /// 当前会话 ID：智能体浏览器调用必须绑定到自己的会话上下文，
    /// 避免泄漏到首页/手动浏览的共享上下文（见 BrowserController.run(sessionID:)）。
    let currentSessionID: UUID?

    init(currentSessionID: UUID? = nil) {
        self.currentSessionID = currentSessionID
    }

    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "browser",
            description: String(localized: "browser_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "activity": JSONSchema.JSONProperty(
                        type: "string",
                        description: String(localized: "param_skill_action_name")
                    ),
                    "action": JSONSchema.JSONProperty(
                        type: "string",
                        description: String(localized: "param_action_name"),
                        enum: [
                            "navigate", "screenshot", "click", "type", "get_text", "get_readable",
                            "get_page_info", "get_backbone", "scroll", "scroll_and_collect",
                            "execute_js", "find_elements", "hover", "set_user_agent", "set_viewport",
                            "fetch", "new_tab", "close_tab", "list_tabs", "get_cookies",
                            "set_cookies", "wait_for_dom_stable"
                        ]
                    ),
                    "params": JSONSchema.JSONProperty(
                        type: "object",
                        description: String(localized: "param_browser_params_flat")
                    ),
                    "tab_index": JSONSchema.JSONProperty(type: "integer", description: String(localized: "param_target_tab_index")),
                    "tab_id": JSONSchema.JSONProperty(type: "integer", description: String(localized: "browser_tab_id_desc")),
                ],
                required: ["activity", "action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let action = parameters["action"] as? String else {
            return ToolResult(success: false, text: String(localized: "err_missing_action"))
        }

        var params = parameters["params"] as? [String: Any] ?? [:]
        let tabIndex = parameters["tab_index"] as? Int
        // 2026-08-12 修复:tab_id 兼容 Int(引擎池返回数字 id,如 0/1)与 UUID 字符串(旧实现)。
        // 此前 `as? String` 会把数字 tab_id 解析成 nil → 引擎寻址断裂,截图/读取静默截错标签。
        let tabIDRaw = parameters["tab_id"]
        let tabID: String? = (tabIDRaw as? String) ?? (tabIDRaw as? Int).map(String.init)

        // [2026-09-14 唐唐 · 遵守度观测探针] **只读、不参与任何决策**，用来验证快照里那条
        // 「工具选择决策优先级」规则到底有没有被遵守。判据：navigate/fetch 选中的主机
        // 是否落在快照的「可用」列表里（`isSearchEngine=1` 且 host 是 google ⇒ 未遵守的典型）。
        // 按 §11：不影响功能的诊断探针直接加，不单独征求许可。
        if action == "navigate" || action == "fetch",
           let rawURL = (params["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawURL.isEmpty {
            let host = URL(string: rawURL)?.host?.lowercased() ?? "-"
            // 探针本地常量（**不参与任何决策**，仅用于把日志一眼读成"选了哪个引擎"）。
            let knownSearchHosts: Set<String> = [
                "google.com", "www.google.com", "bing.com", "www.bing.com", "cn.bing.com",
                "baidu.com", "www.baidu.com", "sogou.com", "www.sogou.com",
                "duckduckgo.com", "www.duckduckgo.com", "so.com", "www.so.com"
            ]
            let isSearch = knownSearchHosts.contains(host) ? 1 : 0
            let act = (parameters["activity"] as? String) ?? ""
            AppLogger.shared.info(
                "[NetPolicy] action=\(action) host=\(host) isSearchEngine=\(isSearch) activity=\(act.prefix(40))",
                category: "NetPolicy")
        }

        // [2026-09-14 搜索引擎策略] 按 `SearchEnginePolicy`（用户偏好 > 地区先验 > 可达性事实）
        // 解析本轮应使用的引擎。设置快照按工程纪律走 `snapshot()`（@MainActor，
        // **不裸读 SettingsStore**，与 ShellTool 同款约束）。
        let engineSetting = await SettingsStore.shared.snapshot().browser.searchEngine

        if action == "navigate",
           ((params["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            let activity = (parameters["activity"] as? String) ?? ""
            if let query = searchQuery(from: activity),
               let searchURL = makeSearchURL(query: query, engineSetting: engineSetting) {
                params["url"] = searchURL
            } else {
                return ToolResult(
                    success: false,
                    text: String(localized: "browser_need_params_url")
                )
            }
        }

        // 强制 https：外网 http:// 链接升级为 https://（ATS 仅放行 localhost，http 外链必然失败；
        // 本地回环 / .local 局域网地址保留 http）。覆盖 navigate / fetch 等所有带 url 的操作。
        if let rawURL = params["url"] as? String {
            params["url"] = Self.upgradeToHTTPS(rawURL)
        }

        let paramsData: Data
        do {
            paramsData = try JSONSerialization.data(withJSONObject: params)
        } catch {
            return ToolResult(success: false, text: String(format: String(localized: "browser_param_serialize_failed"), error.localizedDescription))
        }

        do {
            // 引擎作用域（子代理引擎经 TaskLocal 携带自身 subID → 独立 BrowserContext/标签组；
            // 主引擎为 nil → 回落 currentSessionID（父会话），行为与之前一致）。
            let scopeSessionID = EngineBrowserScope.sessionID ?? currentSessionID
            let result = try await BrowserEngineAdapter.shared.run(action: action, paramsData: paramsData, tabIndex: tabIndex, tabID: tabID, sessionID: scopeSessionID)
            return ToolResult(success: true, text: result)
        } catch {
            return ToolResult(success: false, text: String(format: String(localized: "browser_action_failed"), action, error.localizedDescription))
        }
    }

    /// 把外网 `http://` 链接升级为 `https://`（ATS 仅放行 localhost，http 外链必然失败）。
    /// 本地回环地址（localhost / 127.0.0.1）与 `.local` 局域网地址保留 http（本地服务场景）。
    private static func upgradeToHTTPS(_ urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("http://") else { return trimmed }
        if let host = URL(string: trimmed)?.host?.lowercased() {
            if host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local") {
                return trimmed
            }
        }
        return "https://" + String(trimmed.dropFirst("http://".count))
    }

    private func searchQuery(from activity: String) -> String? {
        let trimmed = activity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let searchPrefixes = [String(localized: "search"), String(localized: "query_action"), String(localized: "find_action"), String(localized: "search_action")]
        guard let prefix = searchPrefixes.first(where: { trimmed.hasPrefix($0) }) else {
            return nil
        }

        let query = String(trimmed.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? nil : query
    }

    /// 按统一策略 `SearchEnginePolicy`（用户偏好 > 地区先验 > 可达性事实）解析搜索 URL。
    ///
    /// [2026-09-14 唐唐] 原为**硬编码百度**（`https://www.baidu.com/s?wd=…`），
    /// 完全忽略用户在「浏览器设置 → 搜索引擎」里的选择 ⇒ 智能体与地址栏各说各话。
    /// 现与地址栏搜索**共用同一套策略**：用户显式选定优先；「自动」/未设置时按
    /// 地区先验 + 代理信号解析。**注意 `google` 永远留在候选表内**（策略只排序、不过滤），
    /// 因为用户完全可能挂代理让 Google 可用（唐唐明确：不能一刀切不让访问）。
    private func makeSearchURL(query: String, engineSetting: String?) -> String? {
        SearchEnginePolicy
            .preferred(rawSetting: engineSetting)
            .searchURL(query: query)
    }
}
