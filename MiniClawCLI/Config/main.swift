import Foundation

// MARK: - miniclaw-config-cli — 配置管理专用 CLI（Layer 2）
//
// 管理 providers.json（服务商配置，App 通过 ProviderFileStore 持久化）。
// 普通读取 / 列出 / 非敏感字段写 可无头完成；
// 敏感字段（apiKey/secret/token/soul/permissions…）写 经 SecurityGate 需宿主 App 确认。
// 其余 SwiftData 域（chat/soul/...）由宿主 App 管理，此处仅说明。

func run() -> Int32 {
    let all = Array(CommandLine.arguments.dropFirst())
    guard !all.isEmpty else { usage(); return 1 }
    let command = all[0]
    let params = Array(all.dropFirst())
    let args = Args(params)
    let configPath = args.string("config") ?? locateProvidersJSON()

    switch command {
    case "list":
        return listProviders(configPath)
    case "get":
        return getProvider(configPath, ref: args.string("id") ?? args.positionals.first, field: args.string("field"))
    case "set":
        return setProvider(configPath, args: args)
    case "add":
        return addProvider(configPath, json: args.string("json"))
    case "select":
        return selectProvider(configPath, id: args.string("id") ?? args.positionals.first)
    case "-h", "--help":
        usage(); return 0
    default:
        print(fail("未知命令: \(command)。可用: list / get / set / add / select"))
        return 1
    }
}

// MARK: - 读写辅助

struct ProvidersJSONDocument {
    var root: [String: Any]

    var providers: [[String: Any]] {
        get { root["providers"] as? [[String: Any]] ?? [] }
        set { root["providers"] = newValue }
    }
}

func loadProviders(_ path: String?) -> (ProvidersJSONDocument?, String?) {
    guard let p = path else {
        return (nil, "未找到 providers.json；请用 --config <path> 指定，或先在模拟器运行 MiniClaw。")
    }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          root["providers"] is [[String: Any]] else {
        return (nil, "读取或解析 providers.json 失败: \(p)")
    }
    return (ProvidersJSONDocument(root: root), nil)
}

func saveProviders(_ document: ProvidersJSONDocument, path: String?) -> String? {
    guard let p = path else { return "未指定配置文件路径" }
    guard let data = try? JSONSerialization.data(
        withJSONObject: document.root,
        options: [.prettyPrinted, .sortedKeys]
    ) else { return "序列化失败" }

    let url = URL(fileURLWithPath: p)
    do {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        return nil
    } catch {
        return "写入 providers.json 失败: \(error.localizedDescription)"
    }
}

// MARK: - 命令实现

func listProviders(_ path: String?) -> Int32 {
    let (document, err) = loadProviders(path)
    if let err { print(fail(err)); return 1 }
    let summary = (document?.providers ?? []).map { ["id": $0["id"] ?? "", "label": $0["label"] ?? "", "type": $0["providerType"] ?? "", "enabled": $0["isEnabled"] ?? true] }
    print(ok(["providers": summary]))
    return 0
}

func getProvider(_ path: String?, ref: String?, field: String?) -> Int32 {
    let (document, err) = loadProviders(path)
    if let err { print(fail(err)); return 1 }
    guard let document, let ref,
          let item = document.providers.first(where: { ($0["id"] as? String) == ref }) else {
        print(fail("未找到 provider id=\(ref ?? "")")); return 1
    }
    if let field {
        if ["apikey", "secret", "token"].contains(field.lowercased()) {
            print(ok([field: "*** 受保护，不可回读 ***"])); return 0
        }
        print(ok([field: item[field] ?? NSNull()]))
    } else {
        var masked = item
        for k in masked.keys where ["apiKey", "secret", "token"].contains(k) { masked[k] = "*** 受保护，不可回读 ***" }
        print(ok(masked))
    }
    return 0
}

func setProvider(_ path: String?, args: Args) -> Int32 {
    let (loadedDocument, err) = loadProviders(path)
    if let err { print(fail(err)); return 1 }
    guard let ref = args.string("id") ?? args.positionals.first else {
        print(fail("set 需要 --id 与 --field --value")); return 1
    }
    guard let field = args.string("field"), let value = args.string("value") else {
        print(fail("set 需要 --field 与 --value")); return 1
    }
    // 敏感字段写：需宿主 App 确认
    switch SecurityGate.classify(domain: "config", operation: "set", detail: field) {
    case .direct:
        break
    case .requiresHostApproval(let cap, let reason):
        if !SecurityGate.isApproved(args) {
            print(SecurityGate.approvalResponse(domain: "config", operation: "set", capability: cap, reason: reason))
            return 2
        }
    }
    guard var document = loadedDocument,
          let idx = document.providers.firstIndex(where: { ($0["id"] as? String) == ref }) else {
        print(fail("未找到 provider id=\(ref)")); return 1
    }
    var providers = document.providers
    providers[idx][field] = coerce(value, existing: providers[idx][field])
    document.providers = providers
    if let e = saveProviders(document, path: path) { print(fail(e)); return 1 }
    print(ok(["updated": ref, "field": field]))
    return 0
}

func addProvider(_ path: String?, json: String?) -> Int32 {
    guard let json, let data = json.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        print(fail("add 需要 --json <provider JSON>")); return 1
    }
    let (loadedDocument, err) = loadProviders(path)
    if let err { print(fail(err)); return 1 }
    guard var document = loadedDocument else { print(fail("配置文件结构无效")); return 1 }
    var providers = document.providers
    let id = UUID().uuidString
    var item = dict
    item["id"] = id
    providers.append(item)
    document.providers = providers
    if let e = saveProviders(document, path: path) { print(fail(e)); return 1 }
    print(ok(["added": id]))
    return 0
}

func selectProvider(_ path: String?, id: String?) -> Int32 {
    guard let id else { print(fail("select 需要 --id")); return 1 }
    let (loadedDocument, err) = loadProviders(path)
    if let err { print(fail(err)); return 1 }
    guard var document = loadedDocument,
          document.providers.contains(where: { ($0["id"] as? String) == id }) else {
        print(fail("未找到 provider id=\(id)")); return 1
    }
    document.root["selectedProviderId"] = id
    if let e = saveProviders(document, path: path) { print(fail(e)); return 1 }
    print(ok(["selectedProviderId": id]))
    return 0
}

func coerce(_ raw: String, existing: Any?) -> Any {
    if existing is Bool { return raw == "true" || raw == "1" }
    if existing is Int { return Int(raw) ?? 0 }
    if existing is Double { return Double(raw) ?? 0.0 }
    return raw
}

func usage() {
    print("""
    miniclaw-config-cli — 配置管理专用 CLI（Layer 2）

    用法:
      miniclaw-config-cli <command> [参数]

    命令:
      list                                 列出所有服务商
      get <id> [--field <f>]
      set <id> --field <f> --value <v>    非敏感字段直连；apiKey/secret/token/soul/permissions 等敏感写需 --approved
      add --json '<provider JSON>'
      select <id>                          保存首选服务商到 providers.json

    说明:
      - 默认定位模拟器中 MiniClaw 的 Documents/MiniClaw/config/providers.json；兼容上一轮 models/ 与更早的根层旧路径，也可用 --config <path> 指定。
      - API Key 已迁移至 iOS Keychain，providers.json 不再含明文密钥（仅 hasApiKey 标记）；get 时仍掩码。
      - SwiftData 域（chat/soul/session/...）由宿主 App 管理，CLI 不直接写。
    """)
}

let code = run()
exit(code)
