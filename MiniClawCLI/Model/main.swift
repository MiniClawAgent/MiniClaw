import Foundation

// MARK: - miniclaw-model-cli — 模型调用专用 CLI（Layer 2）
//
// 无头调用已配置的服务商（OpenAI 兼容 /chat/completions）。
// apiKey 从 providers.json 读取并作为 Bearer 注入；也可用 --env API_KEY=... 覆盖（spec 12.2.1）。
// 调用本身为普通操作，可直接无头完成。

func run() -> Int32 {
    let all = Array(CommandLine.arguments.dropFirst())
    guard !all.isEmpty else { usage(); return 1 }
    let args = Args(all)
    let command = all[0]

    switch command {
    case "completion":
        return awaitCompletion(args: args)
    case "models":
        return listModels(args: args)
    case "-h", "--help":
        usage(); return 0
    default:
        print(fail("未知命令: \(command)。可用: completion / models"))
        return 1
    }
}

func listModels(args: Args) -> Int32 {
    guard let document = loadProviders(args.string("config") ?? locateProvidersJSON()) else {
        print(fail("未找到 providers.json；用 --config 指定或在模拟器运行 MiniClaw。")); return 1
    }
    var out: [[String: Any]] = []
    for p in document.providers {
        if let models = p["models"] as? [[String: Any]] {
            for m in models { out.append(["provider": p["label"] ?? "", "modelId": m["modelId"] ?? "", "displayName": m["displayName"] ?? ""]) }
        }
    }
    print(ok(["models": out]))
    return 0
}

struct ProvidersJSONDocument {
    let root: [String: Any]
    let providers: [[String: Any]]

    var selectedProviderId: String? { root["selectedProviderId"] as? String }
    var selectedModelId: String? { root["selectedModelId"] as? String }
}

func loadProviders(_ path: String?) -> ProvidersJSONDocument? {
    guard let p = path,
          let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let providers = root["providers"] as? [[String: Any]] else {
        return nil
    }
    return ProvidersJSONDocument(root: root, providers: providers)
}

func pickProvider(_ document: ProvidersJSONDocument, id: String?) -> [String: Any]? {
    if let id {
        return document.providers.first(where: { ($0["id"] as? String) == id })
    }
    if let selectedId = document.selectedProviderId,
       let selected = document.providers.first(where: {
           ($0["id"] as? String) == selectedId && (($0["isEnabled"] as? Bool) ?? true)
       }) {
        return selected
    }
    return document.providers.first(where: { ($0["isEnabled"] as? Bool) ?? true })
}

private final class ExitCodeState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func markFailed() {
        lock.lock()
        value = 1
        lock.unlock()
    }

    func current() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return Int32(value)
    }
}

func awaitCompletion(args: Args) -> Int32 {
    let prompt = args.string("prompt") ?? args.positionals.dropFirst().joined(separator: " ")
    guard !prompt.isEmpty else { print(fail("completion 需要 --prompt")); return 1 }
    guard let document = loadProviders(args.string("config") ?? locateProvidersJSON()),
          let provider = pickProvider(document, id: args.string("id")) else {
        print(fail("未找到可用的服务商；用 --config/--id 指定或在模拟器运行 MiniClaw。")); return 1
    }

    // 允许用 --env API_KEY=... 覆盖存储的 key（机密不落明文）
    // 注意：providers.json 已不含明文 apiKey（迁移至 iOS Keychain，CLI 进程无法读取），
    // 故必须通过 --env API_KEY=... 传入密钥。
    var apiKey = (provider["apiKey"] as? String) ?? ""
    if let override = args.flags["env"]?.split(separator: "=", maxSplits: 1).map(String.init),
       override.count == 2, override[0] == "API_KEY" { apiKey = override[1] }

    guard !apiKey.isEmpty else {
        print(fail("该服务商未在 providers.json 中保存明文密钥（已迁移至 iOS Keychain，CLI 不可读取）。请通过 --env API_KEY=... 传入密钥后重试。"))
        return 1
    }

    let baseRaw = (provider["customBaseURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = (baseRaw?.isEmpty == false ? baseRaw! : "https://api.openai.com")
    let providerModels = provider["models"] as? [[String: Any]] ?? []
    let selectedModelId = document.selectedModelId.flatMap { selectedId in
        providerModels.first(where: { ($0["id"] as? String) == selectedId })?["modelId"] as? String
    }
    let modelId = args.string("model")
        ?? selectedModelId
        ?? providerModels.first?["modelId"] as? String
        ?? ""
    guard !modelId.isEmpty else { print(fail("无法确定模型 id")); return 1 }

    let url = URL(string: base.hasSuffix("/") ? base + "chat/completions" : base + "/chat/completions")!
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body: [String: Any] = [
        "model": modelId,
        "messages": [["role": "user", "content": prompt]],
        "stream": false
    ]
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)

    let sem = DispatchSemaphore(value: 0)
    let exitCode = ExitCodeState()
    let task = URLSession.shared.dataTask(with: req) { data, resp, err in
        defer { sem.signal() }
        if let err {
            print(fail("请求失败: \(err.localizedDescription)")); exitCode.markFailed(); return
        }
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) else {
            print(fail("响应解析失败")); exitCode.markFailed(); return
        }
        // 抽取首个 choice 的 content
        if let obj = json as? [String: Any],
           let choices = obj["choices"] as? [[String: Any]],
           let msg = choices.first?["message"] as? [String: Any],
           let content = msg["content"] as? String {
            print(ok(["model": modelId, "content": content]))
        } else {
            print(prettyJSON(json))
        }
    }
    task.resume()
    sem.wait()
    return exitCode.current()
}

func usage() {
    print("""
    miniclaw-model-cli — 模型调用专用 CLI（Layer 2）

    用法:
      miniclaw-model-cli <command> [参数]

    命令:
      completion --prompt "<文本>" [--id <providerId>] [--model <modelId>] [--env API_KEY=...]
      models                                 列出所有可用模型

    说明:
      - 默认读取模拟器 Documents/MiniClaw/config/providers.json；兼容上一轮 models/ 与更早的根层旧路径，也可用 --config <path> 指定。
      - API Key 已迁移至 iOS Keychain，providers.json 不含明文；请通过 --env API_KEY=... 传入密钥（避免明文留在命令历史）。
      - 调用为普通操作，可直接无头完成。
    """)
}

let code = run()
exit(code)
