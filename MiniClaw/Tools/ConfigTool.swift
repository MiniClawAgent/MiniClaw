import Foundation

// MARK: - miniclaw_config Tool（对齐 spec 9.2）

/// 让 Agent 通过 Tool Protocol 读写运行时配置，等价于 spec 的 `miniclaw_config` 工具。
/// 子命令：get / set / add / audit-list / audit-revert / list-topics / topic-help
struct ConfigTool: AgentTool {
    let name = "miniclaw_config"

    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "miniclaw_config",
            description: "运行时配置读写工具（等价于 miniclaw_config 工具）。子命令：get 读取、set 写入、add 新增子项、audit-list 查看变更历史、audit-revert 回滚、list-topics 列出域、topic-help 查看域字段。路径形如 topic.field 或 topic.<id>.field（数组域按 UUID 定位）。敏感字段（apiKey）只写不可回读。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "subcommand": JSONSchema.JSONProperty(type: "string", description: "子命令", enum: ["get", "set", "add", "audit-list", "audit-revert", "list-topics", "topic-help"]),
                    "topic": JSONSchema.JSONProperty(type: "string", description: "配置域：providers/groups/soul/envvars/session/chat/speech/memory/browser/appearance/background/files/permissions/defaults"),
                    "path": JSONSchema.JSONProperty(type: "string", description: "点分路径，如 providers.<uuid>.label"),
                    "value": JSONSchema.JSONProperty(type: "string", description: "set 的值（字符串，自动按字段类型转换）"),
                    "json": JSONSchema.JSONProperty(type: "string", description: "add 的子项 JSON（如新增 provider）"),
                    "id": JSONSchema.JSONProperty(type: "string", description: "audit-revert 的审计记录 id"),
                    "limit": JSONSchema.JSONProperty(type: "integer", description: "audit-list 返回条数（默认 20）"),
                ],
                required: ["subcommand"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let sub = parameters["subcommand"] as? String else {
            return ToolResult(success: false, text: "缺少 subcommand 参数")
        }

        switch sub {
        case "list-topics":  return listTopics()
        case "topic-help":   return topicHelp(parameters["topic"] as? String)
        case "audit-list":   return auditList(parameters["limit"] as? Int)
        case "audit-revert": return auditRevert(parameters["id"] as? String)
        case "get":          return getConfig(topic: parameters["topic"] as? String, path: parameters["path"] as? String)
        case "set":          return setConfig(topic: parameters["topic"] as? String, path: parameters["path"] as? String, value: parameters["value"] as? String)
        case "add":          return addItem(topic: parameters["topic"] as? String, json: parameters["json"] as? String)
        default:
            return ToolResult(success: false, text: "未知子命令: \(sub)")
        }
    }

    // MARK: - 权限

    /// 写操作需用户授权（spec 9.5：配置变更需确认 / 9.2.9 permissions.miniclawConfigWrite）
    private func writeAllowed() -> Bool {
        SettingsStore.shared.settings.permissions.miniclawConfigWrite
    }

    private func denied() -> ToolResult {
        ToolResult(success: false,
                   text: "⛔ 写入被拒绝：请在 设置 → 权限 中开启「允许 miniclaw-config 写入」后重试。")
    }

    // MARK: - 子命令实现

    private func listTopics() -> ToolResult {
        let lines = TOPIC_DESCRIPTIONS.map { "• \($0.key) — \($0.value)" }
        return ToolResult(success: true, text: "可配置域：\n" + lines.joined(separator: "\n"))
    }

    private func topicHelp(_ topic: String?) -> ToolResult {
        guard let t = topic, let fields = TOPIC_FIELDS[t] else {
            return ToolResult(success: false, text: "未知或缺失 topic。先用 list-topics 查看可用域。")
        }
        let lines = fields.map { "  - \($0.key) (\($0.type)): \($0.desc)" }
        return ToolResult(success: true, text: "域 `\(t)` 字段：\n" + lines.joined(separator: "\n"))
    }

    private func auditList(_ limit: Int?) -> ToolResult {
        let max = min(limit ?? 20, 100)
        let entries = SettingsStore.shared.auditEntries.prefix(max)
        if entries.isEmpty {
            return ToolResult(success: true, text: "暂无审计记录。")
        }
        let lines = entries.map { e in
            let ts = ISO8601DateFormatter().string(from: e.timestamp)
            return "[\(e.id.uuidString.prefix(8))] \(ts) \(e.domain) — \(e.summary)"
        }
        return ToolResult(success: true, text: "最近 \(entries.count) 条变更：\n" + lines.joined(separator: "\n"))
    }

    private func auditRevert(_ idStr: String?) -> ToolResult {
        guard let idStr, let id = UUID(uuidString: idStr) else {
            return ToolResult(success: false, text: "缺少或无效的 audit id（需完整 UUID）。")
        }
        let ok = SettingsStore.shared.rollback(to: id)
        return ToolResult(success: ok, text: ok ? "已回滚至审计记录 \(id.uuidString.prefix(8))" : "回滚失败：未找到该记录。")
    }

    private func getConfig(topic: String?, path: String?) -> ToolResult {
        let (t, idStr, field) = resolvePath(topic: topic, path: path)
        guard let t else {
            return ToolResult(success: false, text: "缺少 topic 或 path。")
        }
        let isArray = (t == "providers" || t == "groups")

        // 数组域（providers / groups）
        if isArray {
            guard let arr = loadArray(topic: t) else {
                return ToolResult(success: false, text: "域 \(t) 加载失败。")
            }
            if let idStr {
                guard let idx = arr.firstIndex(where: { ($0["id"] as? String) == idStr }) else {
                    return ToolResult(success: false, text: "未找到 id=\(idStr) 的 \(t) 子项。")
                }
                let item = arr[idx]
                if let field {
                    if isSensitive(field: field) {
                        return ToolResult(success: true, text: "\(field): *** 受保护，不可回读 ***")
                    }
                    return ToolResult(success: true, text: "\(field): \(stringify(item[field]))")
                }
                return ToolResult(success: true, text: prettyJSON(maskSensitive(item)))
            }
            return ToolResult(success: true, text: prettyJSON(maskSensitive(arr)))
        }

        // 域级（单对象）
        guard let obj = loadDomainObject(topic: t) else {
            return ToolResult(success: false, text: "域 \(t) 不存在。")
        }
        if let field {
            if isSensitive(field: field) {
                return ToolResult(success: true, text: "\(field): *** 受保护，不可回读 ***")
            }
            return ToolResult(success: true, text: "\(field): \(stringify(obj[field]))")
        }
        return ToolResult(success: true, text: prettyJSON(maskSensitive(obj)))
    }

    private func setConfig(topic: String?, path: String?, value: String?) -> ToolResult {
        guard writeAllowed() else { return denied() }
        let (t, idStr, field) = resolvePath(topic: topic, path: path)
        guard let t, let field else {
            return ToolResult(success: false, text: "set 需要 topic.field 形式的 path（数组域需含 <id>）。")
        }
        guard let raw = value else {
            return ToolResult(success: false, text: "缺少 value 参数。")
        }
        let isArray = (t == "providers" || t == "groups")

        // 数组域（providers / groups）
        if isArray {
            guard let idStr else {
                return ToolResult(success: false, text: "数组域 \(t) 的 set 需包含 <id>，如 \(t).<uuid>.<field>。")
            }
            guard var arr = loadArray(topic: t) else {
                return ToolResult(success: false, text: "域 \(t) 加载失败。")
            }
            guard let idx = arr.firstIndex(where: { ($0["id"] as? String) == idStr }) else {
                return ToolResult(success: false, text: "未找到 id=\(idStr) 的 \(t) 子项。")
            }
            let existing = arr[idx][field] ?? ""
            arr[idx][field] = coerce(raw: raw, existing: existing)
            guard saveArray(topic: t, arr: arr) else {
                return ToolResult(success: false, text: "保存 \(t) 失败。")
            }
            return ToolResult(success: true, text: "已更新 \(t).<\(idStr)>).\(field)")
        }

        // 域级单对象
        guard var obj = loadDomainObject(topic: t) else {
            return ToolResult(success: false, text: "域 \(t) 不存在。")
        }
        let existing = obj[field] ?? ""
        obj[field] = coerce(raw: raw, existing: existing)
        guard saveDomainObject(topic: t, dict: obj) else {
            return ToolResult(success: false, text: "保存 \(t) 失败。")
        }
        return ToolResult(success: true, text: "已更新 \(t).\(field)")
    }

    private func addItem(topic: String?, json: String?) -> ToolResult {
        guard writeAllowed() else { return denied() }
        guard let t = topic, let json, !json.isEmpty else {
            return ToolResult(success: false, text: "add 需要 topic 与 json 参数。")
        }
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ToolResult(success: false, text: "json 解析失败。")
        }

        switch t {
        case "providers":
            guard let p = try? JSONDecoder().decode(LLMProvider.self, from: json.data(using: .utf8)!) else {
                return ToolResult(success: false, text: "provider JSON 解析失败（需含 label/providerType 等）。")
            }
            var c = ProviderFileStore.load()
            c.providers.append(p)
            ProviderFileStore.save(c)
            return ToolResult(success: true, text: "已新增 provider: \(p.label) (id=\(p.id.uuidString.prefix(8)))")
        case "groups":
            guard let g = try? JSONDecoder().decode(ModelGroup.self, from: json.data(using: .utf8)!) else {
                return ToolResult(success: false, text: "group JSON 解析失败。")
            }
            SettingsStore.shared.update(domain: .groups, summary: "config add group") { (groups: inout [ModelGroup]) in
                groups.append(g)
            }
            return ToolResult(success: true, text: "已新增 group: \(g.name) (id=\(g.id.uuidString.prefix(8)))")
        default:
            return ToolResult(success: false, text: "topic \(t) 不支持 add（仅 providers / groups）。")
        }
    }

    // MARK: - 路径 / 加载 / 保存 辅助

    /// 解析出 (topic, idOrNil, fieldOrNil)
    private func resolvePath(topic: String?, path: String?) -> (String?, String?, String?) {
        if let path, !path.isEmpty {
            let parts = path.split(separator: ".", maxSplits: 2).map(String.init)
            if parts.count == 1 {
                return (parts[0], nil, nil)
            } else if parts.count == 2 {
                return (parts[0], nil, parts[1])
            } else {
                return (parts[0], parts[1], parts[2])
            }
        }
        if let topic { return (topic, nil, nil) }
        return (nil, nil, nil)
    }

    private func loadDomainObject(topic: String) -> [String: Any]? {
        let s = SettingsStore.shared.settings
        switch topic {
        case "envvars":     return enc(s.envvars)
        case "soul":        return enc(s.soul)
        case "session":     return enc(s.session)
        case "chat":        return enc(s.chat)
        case "speech":      return enc(s.speech)
        case "memory":      return enc(s.memory)
        case "browser":     return enc(s.browser)
        case "appearance":  return enc(s.appearance)
        case "background":  return enc(s.background)
        case "files":       return enc(s.files)
        case "permissions": return enc(s.permissions)
        case "defaults":    return enc(s.defaults)
        default:            return nil
        }
    }

    private func saveDomainObject(topic: String, dict: [String: Any]) -> Bool {
        let summary = "config set \(topic)"
        switch topic {
        case "groups":      if let v: [ModelGroup] = dec(dict) { SettingsStore.shared.update(domain: .groups, summary: summary) { $0 = v }; return true }
        case "envvars":     if let v: [EnvVariable] = dec(dict) { SettingsStore.shared.update(domain: .envvars, summary: summary) { $0 = v }; return true }
        case "soul":        if let v: SoulConfig = dec(dict) { SettingsStore.shared.update(domain: .soul, summary: summary) { $0 = v }; return true }
        case "session":     if let v: SessionSettings = dec(dict) { SettingsStore.shared.update(domain: .session, summary: summary) { $0 = v }; return true }
        case "chat":        if let v: ChatSettings = dec(dict) { SettingsStore.shared.update(domain: .chat, summary: summary) { $0 = v }; return true }
        case "speech":      if let v: SpeechSettings = dec(dict) { SettingsStore.shared.update(domain: .speech, summary: summary) { $0 = v }; return true }
        case "memory":      if let v: MemorySettings = dec(dict) { SettingsStore.shared.update(domain: .memory, summary: summary) { $0 = v }; return true }
        case "browser":     if let v: BrowserSettings = dec(dict) { SettingsStore.shared.update(domain: .browser, summary: summary) { $0 = v }; return true }
        case "appearance":  if let v: AppearanceSettings = dec(dict) { SettingsStore.shared.update(domain: .appearance, summary: summary) { $0 = v }; return true }
        case "background":  if let v: BackgroundSettings = dec(dict) { SettingsStore.shared.update(domain: .background, summary: summary) { $0 = v }; return true }
        case "files":       if let v: FileSettings = dec(dict) { SettingsStore.shared.update(domain: .files, summary: summary) { $0 = v }; return true }
        case "permissions": if let v: PermissionConfig = dec(dict) { SettingsStore.shared.update(domain: .permissions, summary: summary) { $0 = v }; return true }
        case "defaults":    if let v: DefaultSettings = dec(dict) { SettingsStore.shared.update(domain: .defaults, summary: summary) { $0 = v }; return true }
        default:            return false
        }
        return false
    }

    /// providers / groups 是数组域
    private func loadArray(topic: String) -> [[String: Any]]? {
        switch topic {
        case "providers":
            return (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(ProviderFileStore.load().providers))) as? [[String: Any]]
        case "groups":
            guard let data = try? JSONEncoder().encode(SettingsStore.shared.settings.groups),
                  let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
            return arr
        default:
            return nil
        }
    }

    private func saveArray(topic: String, arr: [[String: Any]]) -> Bool {
        switch topic {
        case "providers":
            guard let providers = (try? JSONSerialization.data(withJSONObject: arr)).flatMap({ try? JSONDecoder().decode([LLMProvider].self, from: $0) }) else { return false }
            var c = ProviderFileStore.load()
            c.providers = providers
            ProviderFileStore.save(c)
            return true
        case "groups":
            if let v: [ModelGroup] = dec(arr) {
                SettingsStore.shared.update(domain: .groups, summary: "config set groups[]") { $0 = v }
                return true
            }
            return false
        default:
            return false
        }
    }

    // MARK: - 敏感 / 编码 辅助

    private func isSensitive(field: String) -> Bool {
        field.lowercased() == "apikey" || field.lowercased() == "secret" || field.lowercased() == "token"
    }

    /// 递归把 apiKey 等敏感字段掩码
    private func maskSensitive(_ value: Any) -> Any {
        if var dict = value as? [String: Any] {
            for (k, v) in dict {
                if isSensitive(field: k) {
                    dict[k] = "*** 受保护，不可回读 ***"
                } else {
                    dict[k] = maskSensitive(v)
                }
            }
            return dict
        } else if let arr = value as? [[String: Any]] {
            return arr.map { maskSensitive($0) as! [String: Any] }
        } else if let arr = value as? [Any] {
            return arr.map { maskSensitive($0) }
        }
        return value
    }

    /// 把字符串值按现有字段类型转换为 Bool/Int/Double/String
    private func coerce(raw: String, existing: Any) -> Any {
        if let _ = existing as? Bool {
            return raw == "true" || raw == "1" || raw == "yes"
        }
        if let _ = existing as? Int {
            return Int(raw) ?? 0
        }
        if let _ = existing as? Double {
            return Double(raw) ?? 0.0
        }
        return raw
    }

    private func enc<T: Encodable>(_ v: T) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(v) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func dec<T: Decodable>(_ dict: Any) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func stringify(_ value: Any?) -> String {
        guard let value else { return "<nil>" }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if let num = value as? NSNumber { return "\(num)" }
        if let str = value as? String { return str }
        if let data = try? JSONSerialization.data(withJSONObject: value),
           let str = String(data: data, encoding: .utf8) { return str }
        return "\(value)"
    }

    private func prettyJSON(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return stringify(value)
    }

    // MARK: - 字段说明（spec 9.2）

    private let TOPIC_DESCRIPTIONS: [String: String] = [
        "providers": "LLM 提供商实例（API Key / base URL / 模型）",
        "groups": "模型路由组（fallback / loadBalance）",
        "soul": "Agent 人格（对应 memory/SOUL.md）",
        "envvars": "注入 shell 的环境变量（机密，只写）",
        "session": "当前会话设置",
        "chat": "聊天 UI 设置",
        "speech": "语音 STT / TTS 设置",
        "memory": "记忆开关",
        "browser": "浏览器设置",
        "appearance": "外观主题",
        "background": "后台任务行为",
        "files": "文件管理设置",
        "permissions": "功能权限开关（含 miniclaw-config 写入）",
        "defaults": "Agent Loop 默认值",
    ]

    private let TOPIC_FIELDS: [String: [(key: String, type: String, desc: String)]] = [
        "providers": [
            ("id", "UUID", "实例唯一标识（只读）"),
            ("label", "string", "用户可见昵称"),
            ("providerType", "enum", "Anthropic/OpenAI/Gemini/OpenRouter/OpenAI-compatible（只读）"),
            ("credentialType", "enum", "apiKey / oauth（只读）"),
            ("apiKey", "string", "API Key，只写不可回读"),
            ("customBaseURL", "string", "自定义 API 端点，空=默认"),
            ("customUserAgent", "string", "自定义 User-Agent"),
            ("appendV1Suffix", "bool", "自动追加 /v1 到 base URL"),
            ("imageEndpointMode", "enum", "auto/images_generations/chat_completions"),
            ("isEnabled", "bool", "为 false 时 Agent Loop 不使用此实例"),
        ],
        "groups": [
            ("id", "UUID", "组唯一标识（只读）"),
            ("name", "string", "用户可见名称"),
            ("modelIds", "[string]", "关联的模型 ID 列表"),
            ("strategy", "enum", "fallback / loadBalance"),
            ("fallbackStrategy", "enum", "limited / always"),
            ("contextLimitTokens", "int", "上下文上限，0=无限制"),
            ("defaultThinkingLevel", "enum", "off/low/medium/high/xhigh/max/ultra"),
        ],
        "soul": [
            ("name", "string", "Agent 显示名称"),
            ("style", "string", "响应风格描述"),
            ("lang", "enum", "auto / zh / en"),
            ("body", "string", "Markdown 人格文本"),
        ],
        "envvars": [
            ("key", "string", "变量名（只读）"),
            ("value", "string", "值，只写不可回读"),
            ("isSecret", "bool", "是否为机密"),
            ("privacyMode", "bool", "开启后输出中的变量值被掩码（域级）"),
        ],
        "session": [
            ("autoGenerateTitle", "bool", "自动生成会话标题"),
            ("defaultModelId", "string", "默认模型 ID"),
            ("maxContextMessages", "int", "上下文最大消息数"),
            ("streamResponses", "bool", "流式响应"),
        ],
        "chat": [
            ("showThinking", "bool", "显示思考过程"),
            ("codeBlockTheme", "enum", "auto/light/dark"),
            ("enterToSend", "bool", "回车发送"),
        ],
        "speech": [
            ("sttEnabled", "bool", "语音输入"),
            ("ttsEnabled", "bool", "语音输出"),
            ("voiceIdentifier", "string", "语音标识符"),
            ("speechRate", "double", "语速"),
            ("preferredLanguage", "enum", "auto/zh-CN/en-US"),
        ],
        "memory": [
            ("isEnabled", "bool", "记忆功能开关"),
            ("autoSaveDaily", "bool", "每日记忆自动保存"),
            ("retentionDays", "int", "保留天数"),
        ],
        "browser": [
            ("maxTabs", "int", "最大标签数"),
            ("uaMode", "enum", "mobile/desktop/custom"),
            ("userAgent", "string", "自定义 UA（uaMode=custom 时生效）"),
            ("blockPopups", "bool", "拦截弹窗"),
        ],
        "appearance": [
            ("colorSchemeRaw", "enum", "system/dark/light"),
            ("useLargeText", "bool", "大文本"),
            ("accentColorRaw", "string", "强调色"),
        ],
        "background": [
            ("backgroundRun", "bool", "后台运行"),
            ("liveActivity", "bool", "实时活动"),
            ("notifications", "bool", "通知"),
        ],
        "files": [
            ("defaultWorkspace", "string", "默认工作区目录名"),
            ("autoOffloadThresholdKB", "int", "大输出转存阈值(KB)"),
            ("cleanupAttachmentsDays", "int", "附件清理周期(天)"),
        ],
        "permissions": [
            ("miniclawConfigWrite", "bool", "允许 miniclaw-config 写入"),
            ("location", "enum", "定位权限"),
            ("bluetooth", "enum", "蓝牙权限"),
            ("microphone", "enum", "麦克风权限"),
            ("speechRecognition", "enum", "语音识别权限"),
            ("camera", "enum", "相机权限"),
            ("photoLibrary", "enum", "相册权限"),
            ("notifications", "enum", "通知权限"),
            ("calendar", "enum", "日历权限"),
            ("reminders", "enum", "提醒权限"),
            ("healthKit", "enum", "健康权限"),
            ("homeKit", "enum", "HomeKit 权限"),
            ("nfc", "enum", "NFC 权限"),
            ("localNetwork", "enum", "本地网络权限"),
        ],
        "defaults": [
            ("defaultAgentName", "string", "默认 Agent 名称"),
            ("defaultLanguage", "enum", "auto/zh-CN/en-US"),
            ("confirmBeforeToolCall", "bool", "工具调用前确认"),
        ],
    ]
}
