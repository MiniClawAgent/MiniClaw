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
            description: """
            控制内置浏览器执行网页操作。所有操作通过 action 指定，params 为该操作的参数字典；除 activity/action/tab_index 外，操作参数必须放在 params 内。
            每次调用必须提供 activity：用简短中文描述当前这一步的具体业务行为（6-16字），供会话页工具指示器展示；不要写“调用浏览器”“browser”或原始 action。示例：查看新闻列表、打开新闻联播首页、读取今日头条正文、搜索附近咖啡店。
            重要：navigate 只负责打开地址，必须填写 params.url，例如 {"activity":"搜索世界杯赛程","action":"navigate","params":{"url":"https://www.baidu.com/s?wd=世界杯赛程"}}。max_length 仅属于 get_readable，严禁用于 navigate。
            支持的 action（共 22 个）：
            - navigate: 打开网页。params: {url: 必填字符串，仅支持 http(s)}
            - screenshot: 截图。params: {full_page: 布尔(可选, 默认 false)}
            - click: 点击元素。params: {selector: CSS选择器} 或 {x: 数字, y: 数字}
            - type: 在输入框键入。params: {selector: CSS选择器, text: 字符串}
            - get_text: 取元素文本。params: {selector: CSS选择器}；不传 selector 时自动降级为整页可读正文提取（等同 get_readable）
            - get_readable: 取可读性优化正文（去除脚本/样式/导航）。params: {max_length: 数字(可选)}
            - get_page_info: 取页面元信息(title/url/description/lang)。params: {}
            - get_backbone: 取简化 DOM 树。params: {}
            - scroll: 滚动。params: {direction: "up"|"down", amount: 数字} 或 {x: 数字, y: 数字}
            - scroll_and_collect: 滚动并收集内容（无限滚动）。params: {selector: 可选, max_rounds: 数字(可选)}
            - execute_js: 执行 JavaScript。params: {script: 字符串}。推荐直接写返回表达式（如 `new Date().toISOString()`）；若脚本以顶层 return 开头，系统会自动包装进函数后执行。
            - find_elements: 查找元素。params: {selector: CSS选择器, limit: 数字(可选)}
            - hover: 悬停元素。params: {selector: CSS选择器}
            - set_user_agent: 切换 UA。params: {preset: "mobile"|"desktop"} 或 {ua: 自定义字符串}
            - set_viewport: 设置视口。params: {width: 数字, height: 数字}
            - fetch: 下载资源到本地。params: {url: 字符串} → 返回 miniclaw://browser/ 链接
            - new_tab: 新建标签(最多3)。params: {url: 字符串(可选)}
            - close_tab: 关闭标签。params: {index: 数字(可选, 默认当前)}
            - list_tabs: 列出标签。params: {}
            - get_cookies: 取 Cookie。params: {url: 字符串}
            - set_cookies: 设置 Cookie。params: {url: 字符串, name: 字符串, value: 字符串, domain: 可选, path: 可选, expires_days: 可选}
            - wait_for_dom_stable: 等待 DOM 稳定。params: {timeout: 数字(可选, 秒)}
            说明：截图/资源/fetch 可返回 miniclaw:// 链接供聊天界面展示，但 miniclaw:// 是 App 内部链接，不能传给 navigate。
            """,
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "activity": JSONSchema.JSONProperty(
                        type: "string",
                        description: L10n.l("param_skill_action_name")
                    ),
                    "action": JSONSchema.JSONProperty(
                        type: "string",
                        description: L10n.l("param_action_name"),
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
                        description: L10n.l("param_browser_params_flat")
                    ),
                    "tab_index": JSONSchema.JSONProperty(type: "integer", description: L10n.l("param_target_tab_index")),
                    "tab_id": JSONSchema.JSONProperty(type: "integer", description: "Tab id (Int, from navigate/new_tab/list_tabs). 与 list_tabs 返回的 tab_id 一致。"),
                ],
                required: ["activity", "action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let action = parameters["action"] as? String else {
            return ToolResult(success: false, text: L10n.l("err_missing_action"))
        }

        var params = parameters["params"] as? [String: Any] ?? [:]
        let tabIndex = parameters["tab_index"] as? Int
        // 2026-08-12 修复:tab_id 兼容 Int(引擎池返回数字 id,如 0/1)与 UUID 字符串(旧实现)。
        // 此前 `as? String` 会把数字 tab_id 解析成 nil → 引擎寻址断裂,截图/读取静默截错标签。
        let tabIDRaw = parameters["tab_id"]
        let tabID: String? = (tabIDRaw as? String) ?? (tabIDRaw as? Int).map(String.init)

        if action == "navigate",
           ((params["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            let activity = (parameters["activity"] as? String) ?? ""
            if let query = searchQuery(from: activity), let searchURL = makeSearchURL(query: query) {
                params["url"] = searchURL
            } else {
                return ToolResult(
                    success: false,
                    text: L10n.l("browser_need_params_url")
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
            return ToolResult(success: false, text: String(format: L10n.l("browser_param_serialize_failed"), error.localizedDescription))
        }

        do {
            // 引擎作用域（子代理引擎经 TaskLocal 携带自身 subID → 独立 BrowserContext/标签组；
            // 主引擎为 nil → 回落 currentSessionID（父会话），行为与之前一致）。
            let scopeSessionID = AgentLoopEngine.EngineBrowserScope.sessionID ?? currentSessionID
            let result = try await BrowserController.shared.run(action: action, paramsData: paramsData, tabIndex: tabIndex, tabID: tabID, sessionID: scopeSessionID)
            return ToolResult(success: true, text: result)
        } catch {
            return ToolResult(success: false, text: String(format: L10n.l("browser_action_failed"), action, error.localizedDescription))
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

        let searchPrefixes = [L10n.l("search"), L10n.l("query_action"), L10n.l("find_action"), L10n.l("search_action")]
        guard let prefix = searchPrefixes.first(where: { trimmed.hasPrefix($0) }) else {
            return nil
        }

        let query = String(trimmed.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? nil : query
    }

    private func makeSearchURL(query: String) -> String? {
        var components = URLComponents(string: "https://www.baidu.com/s")
        components?.queryItems = [URLQueryItem(name: "wd", value: query)]
        return components?.url?.absoluteString
    }
}
