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
                    // 2026-11-14 修：原为无 properties 的空对象 ⇒ 模型（尤其小模型）不知道
                    // 该往里放什么，直接把 url 写到了顶层，导致 navigate 必然失败
                    // （真机实证：params="" + 顶层 url=https://zh.wikipedia.org/wiki/...）。
                    // 这里把最关键的 url 显式列进结构，其余 action 专用键仍由 description 说明。
                    "params": JSONSchema.JSONProperty(
                        type: "object",
                        description: String(localized: "param_browser_params_flat"),
                        properties: [
                            "url": JSONSchema.JSONProperty(
                                type: "string",
                                description: String(localized: "param_url_http")
                            ),
                        ]
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

        var params = Self.normalizedActionParams(parameters)
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

        // [P1-15] 内网/回环目标默认拒绝（防网页内容注入驱动的 SSRF）；
        // 用户确实要让 AI 管理路由器 / 访问 NAS 时，可在
        // 设置 → 通用设置 → 浏览器 → 允许访问局域网地址 打开。
        if action == "navigate" || action == "fetch",
           let rawURL = (params["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let target = URL(string: rawURL),
           let reason = Self.blockedHostReason(target, allowPrivateNetwork: await SettingsStore.shared.snapshot().browser.allowPrivateNetwork) {
            return ToolResult(success: false, text: "blocked: \(reason) (\(target.host ?? "-")). 如需访问，请在 设置 → 通用设置 → 浏览器 中打开「允许访问局域网地址」。")
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
                // 诊断：把「模型实际给了什么形状」记下来，线上可直接在控制台定位
                // （此前这里只有 UI 文案，罐里只有 TOOL ENTER/DONE，无法判断是模型写错还是工具读错）。
                let topKeys = parameters.keys.sorted().joined(separator: ",")
                let paramsShape = String(describing: type(of: parameters["params"] ?? NSNull()))
                AppLogger.shared.warn(
                    "[BrowserTool] navigate 缺 params.url — 顶层键=[\(topKeys)] params类型=\(paramsShape) activity=\(activity.prefix(40))",
                    category: "Browser"
                )
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

    // MARK: - 参数归一化（外部边界防御，单一入口）

    /// 顶层结构键：不参与「并入 params」的归一化。
    private static let structuralParamKeys: Set<String> = ["activity", "action", "params", "tab_index", "tab_id"]

    /// action 参数白名单（与 `params` 语义一致）。用于把模型误写到顶层的参数并回 `params`。
    /// 只收「明确属于操作参数」的键，顶层结构键永不迁移。
    private static let actionParamKeys: Set<String> = [
        "url", "max_length", "selector", "text", "script", "query", "index",
        "x", "y", "dx", "dy", "key", "value", "timeout", "wait_ms", "filename", "format",
    ]

    /// 把模型/网关输出归一化成 action 参数字典。**不针对任何单一 action 加特例**：
    /// 1. `params` 被网关序列化成 JSON 字符串（甚至空串）时还原为字典——
    ///    真机实证 `"params": ""` 会让 `as? [String: Any]` 静默得到空字典；
    /// 2. 模型把操作参数写到顶层时（违反 schema 说明），按白名单并回 `params`。
    /// 正常调用（params 已是字典且顶层无操作参数）语义完全不变。
    static func normalizedActionParams(_ parameters: [String: Any]) -> [String: Any] {
        var params: [String: Any] = [:]
        switch parameters["params"] {
        case let dict as [String: Any]:
            params = dict
        case let raw as String:
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty,
               let data = trimmed.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                params = parsed
            }
        default:
            break
        }
        for (key, value) in parameters
        where Self.actionParamKeys.contains(key) && !Self.structuralParamKeys.contains(key) && params[key] == nil {
            params[key] = value
        }
        return params
    }

    /// 是否禁止访问的目标（回环 / 私有网段 / 链路本地）。
    ///
    /// [P1-15] 之前只做 http→https 升级，并且**显式保留** localhost 的 http，
    /// 等于允许模型被网页内容诱导去访问 `127.0.0.1:18231`（MCP OAuth 本地回调）
    /// 或路由器后台（192.168.x.1）。这里统一拒绝，返回给模型可读的原因。
    /// - Parameter allowPrivateNetwork: 用户显式开启"允许访问局域网"时为 true。
    ///   注意：**本机回环（127.0.0.1 / ::1 / localhost）始终拒绝**——那是 OAuth 本地回调
    ///   与其他本机服务的地址，被网页注入利用的后果最重；管理路由器/NAS 也不需要它。
    static func blockedHostReason(_ url: URL, allowPrivateNetwork: Bool) -> String? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return "invalid host" }
        if host == "localhost" || host == "::1" { return "loopback address is not allowed" }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        let isLoopback = parts.count == 4 && parts[0] == 127
        if isLoopback { return "loopback address is not allowed" }
        guard !allowPrivateNetwork else { return nil }
        if host.hasSuffix(".local") { return "local address is not allowed" }
        if parts.count == 4 {
            let a = parts[0], b = parts[1]
            if a == 10 || a == 0 { return "private address is not allowed" }
            if a == 169 && b == 254 { return "link-local address is not allowed" }
            if a == 172 && (16...31).contains(b) { return "private address is not allowed" }
            if a == 192 && b == 168 { return "private address is not allowed" }
            if a == 100 && (64...127).contains(b) { return "carrier-grade NAT address is not allowed" }
        }
        return nil
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
