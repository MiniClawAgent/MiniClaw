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
            description: L10n.l("config_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "subcommand": JSONSchema.JSONProperty(type: "string", description: L10n.l("subcommand_label"), enum: ["get", "set", "add", "audit-list", "audit-revert", "list-topics", "topic-help"]),
                    "topic": JSONSchema.JSONProperty(type: "string", description: L10n.l("config_domains_list")),
                    "path": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_dotted_path")),
                    "value": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_set_value")),
                    "json": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_add_item_json")),
                    "id": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_audit_revert_id")),
                    "limit": JSONSchema.JSONProperty(type: "integer", description: L10n.l("param_audit_list_limit")),
                ],
                required: ["subcommand"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let sub = parameters["subcommand"] as? String else {
            return ToolResult(success: false, text: L10n.l("err_missing_subcommand"))
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
            return ToolResult(success: false, text: String(format: L10n.l("config_unknown_subcommand"), sub))
        }
    }

    // MARK: - 权限

    /// 写操作需用户授权（spec 9.5：配置变更需确认 / 9.2.9 permissions.miniclawConfigWrite）
    private func writeAllowed() -> Bool {
        SettingsStore.shared.settings.permissions.miniclawConfigWrite
    }

    private func denied() -> ToolResult {
        ToolResult(success: false,
                   text: L10n.l("err_write_rejected_perm"))
    }

    // MARK: - 子命令实现

    private func listTopics() -> ToolResult {
        let lines = TOPIC_DESCRIPTIONS.map { "• \($0.key) — \($0.value)" }
        return ToolResult(success: true, text: L10n.l("configurable_domains_header") + lines.joined(separator: "\n"))
    }

    private func topicHelp(_ topic: String?) -> ToolResult {
        guard let t = topic, let fields = TOPIC_FIELDS[t] else {
            return ToolResult(success: false, text: L10n.l("err_unknown_topic"))
        }
        let lines = fields.map { "  - \($0.key) (\($0.type)): \($0.desc)" }
        return ToolResult(success: true, text: String(format: L10n.l("config_domain_fields"), t) + lines.joined(separator: "\n"))
    }

    private func auditList(_ limit: Int?) -> ToolResult {
        let max = min(limit ?? 20, 100)
        let entries = SettingsStore.shared.auditEntries.prefix(max)
        if entries.isEmpty {
            return ToolResult(success: true, text: L10n.l("no_audit_records"))
        }
        let lines = entries.map { e in
            let ts = ISO8601DateFormatter().string(from: e.timestamp)
            return "[\(e.id.uuidString.prefix(8))] \(ts) \(e.domain) — \(e.summary)"
        }
        return ToolResult(success: true, text: String(format: L10n.l("config_recent_entries"), entries.count) + lines.joined(separator: "\n"))
    }

    private func auditRevert(_ idStr: String?) -> ToolResult {
        guard let idStr, let id = UUID(uuidString: idStr) else {
            return ToolResult(success: false, text: L10n.l("err_missing_audit_id"))
        }
        let ok = SettingsStore.shared.rollback(to: id)
        return ToolResult(success: ok, text: ok ? String(format: L10n.l("config_rollback_done"), String(id.uuidString.prefix(8))) : L10n.l("config_rollback_failed"))
    }

    private func getConfig(topic: String?, path: String?) -> ToolResult {
        let (t, idStr, field) = resolvePath(topic: topic, path: path)
        guard let t else {
            return ToolResult(success: false, text: L10n.l("err_missing_topic_path"))
        }
        let isArray = (t == "providers" || t == "groups")

        // 数组域（providers / groups）
        if isArray {
            guard let arr = loadArray(topic: t) else {
                return ToolResult(success: false, text: String(format: L10n.l("config_domain_load_failed"), t))
            }
            if let idStr {
                guard let idx = arr.firstIndex(where: { ($0["id"] as? String) == idStr }) else {
                    return ToolResult(success: false, text: String(format: L10n.l("config_item_not_found"), idStr, t))
                }
                let item = arr[idx]
                if let field {
                    if isSensitive(field: field) {
                        return ToolResult(success: true, text: String(format: L10n.l("config_protected_field"), field))
                    }
                    return ToolResult(success: true, text: "\(field): \(stringify(item[field]))")
                }
                return ToolResult(success: true, text: prettyJSON(maskSensitive(item)))
            }
            return ToolResult(success: true, text: prettyJSON(maskSensitive(arr)))
        }

        // 域级（单对象）
        guard let obj = loadDomainObject(topic: t) else {
            return ToolResult(success: false, text: String(format: L10n.l("config_domain_not_found"), t))
        }
        if let field {
            if isSensitive(field: field) {
                return ToolResult(success: true, text: String(format: L10n.l("config_protected_field"), field))
            }
            return ToolResult(success: true, text: "\(field): \(stringify(obj[field]))")
        }
        return ToolResult(success: true, text: prettyJSON(maskSensitive(obj)))
    }

    private func setConfig(topic: String?, path: String?, value: String?) -> ToolResult {
        guard writeAllowed() else { return denied() }
        let (t, idStr, field) = resolvePath(topic: topic, path: path)
        guard let t, let field else {
            return ToolResult(success: false, text: L10n.l("err_set_need_path"))
        }
        guard let raw = value else {
            return ToolResult(success: false, text: L10n.l("err_missing_value"))
        }
        let isArray = (t == "providers" || t == "groups")

        // 数组域（providers / groups）
        if isArray {
            guard let idStr else {
                return ToolResult(success: false, text: String(format: L10n.l("config_array_set_need_id"), t, t, field))
            }
            guard var arr = loadArray(topic: t) else {
                return ToolResult(success: false, text: String(format: L10n.l("config_domain_load_failed"), t))
            }
            guard let idx = arr.firstIndex(where: { ($0["id"] as? String) == idStr }) else {
                return ToolResult(success: false, text: String(format: L10n.l("config_item_not_found"), idStr, t))
            }
            let existing = arr[idx][field] ?? ""
            arr[idx][field] = coerce(raw: raw, existing: existing)
            guard saveArray(topic: t, arr: arr) else {
                return ToolResult(success: false, text: String(format: L10n.l("config_save_failed"), t))
            }
            return ToolResult(success: true, text: String(format: L10n.l("config_updated_array"), t, idStr, field))
        }

        // 域级单对象
        guard var obj = loadDomainObject(topic: t) else {
            return ToolResult(success: false, text: String(format: L10n.l("config_domain_not_found"), t))
        }
        let existing = obj[field] ?? ""
        obj[field] = coerce(raw: raw, existing: existing)
        guard saveDomainObject(topic: t, dict: obj) else {
            return ToolResult(success: false, text: String(format: L10n.l("config_save_failed"), t))
        }
        return ToolResult(success: true, text: String(format: L10n.l("config_updated_field"), t, field))
    }

    private func addItem(topic: String?, json: String?) -> ToolResult {
        guard writeAllowed() else { return denied() }
        guard let t = topic, let json, !json.isEmpty else {
            return ToolResult(success: false, text: L10n.l("err_add_need_topic_json"))
        }
        guard let data = json.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) != nil else {
            return ToolResult(success: false, text: L10n.l("err_json_parse"))
        }

        switch t {
        case "providers":
            guard let p = try? JSONDecoder().decode(LLMProvider.self, from: json.data(using: .utf8)!) else {
                return ToolResult(success: false, text: L10n.l("err_provider_json_parse"))
            }
            var c = ProviderFileStore.load()
            c.providers.append(p)
            ProviderFileStore.save(c)
            return ToolResult(success: true, text: String(format: L10n.l("config_provider_added"), p.label, String(p.id.uuidString.prefix(8))))
        case "groups":
            guard let g = try? JSONDecoder().decode(ModelGroup.self, from: json.data(using: .utf8)!) else {
                return ToolResult(success: false, text: L10n.l("err_group_json_parse"))
            }
            SettingsStore.shared.update(domain: .groups, summary: "config add group") { (groups: inout [ModelGroup]) in
                groups.append(g)
            }
            return ToolResult(success: true, text: String(format: L10n.l("config_group_added"), g.name, String(g.id.uuidString.prefix(8))))
        default:
            return ToolResult(success: false, text: String(format: L10n.l("config_add_not_supported"), t))
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
                    dict[k] = L10n.l("protected_not_readable")
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
        "providers": L10n.l("llm_provider_instance"),
        "groups": L10n.l("param_routing_group"),
        "soul": L10n.l("agent_persona_soul"),
        "envvars": L10n.l("param_shell_env"),
        "session": L10n.l("current_session_settings"),
        "chat": L10n.l("chat_ui_settings"),
        "speech": L10n.l("speech_stt_tts_settings"),
        "memory": L10n.l("memory_toggle"),
        "browser": L10n.l("browser_settings"),
        "appearance": L10n.l("appearance_theme"),
        "background": L10n.l("background_task_behavior"),
        "files": L10n.l("file_management_settings"),
        "permissions": L10n.l("permission_switches_desc"),
        "defaults": L10n.l("agent_loop_defaults"),
    ]

    private let TOPIC_FIELDS: [String: [(key: String, type: String, desc: String)]] = [
        "providers": [
            ("id", "UUID", L10n.l("param_instance_id")),
            ("label", "string", L10n.l("user_visible_nickname")),
            ("providerType", "enum", L10n.l("provider_types_readonly")),
            ("credentialType", "enum", L10n.l("api_key_oauth_readonly")),
            ("apiKey", "string", L10n.l("api_key_write_only")),
            ("customBaseURL", "string", L10n.l("param_custom_endpoint")),
            ("customUserAgent", "string", L10n.l("custom_user_agent")),
            ("appendV1Suffix", "bool", L10n.l("auto_append_v1")),
            ("imageEndpointMode", "enum", "auto/images_generations/chat_completions"),
            ("isEnabled", "bool", L10n.l("param_use_provider_flag")),
        ],
        "groups": [
            ("id", "UUID", L10n.l("param_group_id")),
            ("name", "string", L10n.l("user_visible_name")),
            ("modelIds", "[string]", L10n.l("param_associated_model_ids")),
            ("strategy", "enum", "fallback / loadBalance"),
            ("fallbackStrategy", "enum", "limited / always"),
            ("contextLimitTokens", "int", L10n.l("param_context_limit")),
            ("defaultThinkingLevel", "enum", "off/low/medium/high/xhigh/max/ultra"),
        ],
        "soul": [
            ("name", "string", L10n.l("agent_display_name")),
            ("style", "string", L10n.l("param_response_style")),
            ("lang", "enum", "auto / zh / en"),
            ("body", "string", L10n.l("markdown_persona_text")),
        ],
        "envvars": [
            ("key", "string", L10n.l("param_var_name")),
            ("value", "string", L10n.l("param_write_only_value")),
            ("isSecret", "bool", L10n.l("param_is_secret")),
            ("privacyMode", "bool", L10n.l("param_mask_enabled")),
        ],
        "session": [
            ("autoGenerateTitle", "bool", L10n.l("auto_generate_title")),
            ("defaultModelId", "string", L10n.l("default_model_id")),
            ("maxContextMessages", "int", L10n.l("param_context_max_messages")),
            ("streamResponses", "bool", L10n.l("streaming_response")),
        ],
        "chat": [
            ("showThinking", "bool", L10n.l("show_thinking_process")),
            ("codeBlockTheme", "enum", "auto/light/dark"),
            ("enterToSend", "bool", L10n.l("enter_to_send")),
        ],
        "speech": [
            ("sttEnabled", "bool", L10n.l("voice_input")),
            ("ttsEnabled", "bool", L10n.l("voice_output")),
            ("voiceIdentifier", "string", L10n.l("voice_identifier")),
            ("speechRate", "double", L10n.l("speech_rate")),
            ("preferredLanguage", "enum", "auto/zh-CN/en-US"),
        ],
        "memory": [
            ("isEnabled", "bool", L10n.l("memory_feature_switch")),
            ("autoSaveDaily", "bool", L10n.l("daily_memory_auto_save")),
            ("retentionDays", "int", L10n.l("param_retention_days")),
        ],
        "browser": [
            ("maxTabs", "int", L10n.l("param_max_tabs")),
            ("uaMode", "enum", "mobile/desktop/custom"),
            ("userAgent", "string", L10n.l("param_custom_ua")),
            ("blockPopups", "bool", L10n.l("block_pop_ups")),
        ],
        "appearance": [
            ("colorSchemeRaw", "enum", "system/dark/light"),
            ("useLargeText", "bool", L10n.l("large_text")),
            ("accentColorRaw", "string", L10n.l("accent_color")),
        ],
        "background": [
            ("backgroundRun", "bool", L10n.l("background_run")),
            ("liveActivity", "bool", L10n.l("live_activity")),
            ("notifications", "bool", L10n.l("notifications")),
        ],
        "files": [
            ("defaultWorkspace", "string", L10n.l("default_workspace_directory_name")),
            ("autoOffloadThresholdKB", "int", L10n.l("param_offload_threshold")),
            ("cleanupAttachmentsDays", "int", L10n.l("param_attachment_cleanup_days")),
        ],
        "permissions": [
            ("miniclawConfigWrite", "bool", L10n.l("allow_config_write")),
            ("location", "enum", L10n.l("location_permission")),
            ("microphone", "enum", L10n.l("microphone_permission")),
            ("speechRecognition", "enum", L10n.l("speech_recognition_permission")),
            ("photoLibrary", "enum", L10n.l("photo_library_permission")),
            ("calendar", "enum", L10n.l("calendar_permission")),
            ("reminders", "enum", L10n.l("reminder_permission")),
            ("healthKit", "enum", L10n.l("health_permission")),
            ("homeKit", "enum", L10n.l("homekit_permission")),
            ("localNetwork", "enum", L10n.l("local_network_permission")),
        ],
        "defaults": [
            ("defaultAgentName", "string", L10n.l("default_agent_name")),
            ("defaultLanguage", "enum", "auto/zh-CN/en-US"),
            ("confirmBeforeToolCall", "bool", L10n.l("confirm_before_tool_calls")),
        ],
    ]
}
