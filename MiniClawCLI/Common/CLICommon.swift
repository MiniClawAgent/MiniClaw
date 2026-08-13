import Foundation

// MARK: - MiniClaw 专用 CLI · 共享底座
//
// 所有专用 CLI（会话 / 配置 / 模型 / 浏览器 / iOS 原生 / 文件与 Shell）共用此模块：
// - 统一的 JSON 输出与错误封装；
// - 轻量参数解析；
// - $VAR 环境变量安全展开（spec 12.2.1）；
// - 安全门 SecurityGate：区分「可直接无头完成」与「需宿主 App 确认」的操作。

// MARK: - 错误

enum CLICLIError: LocalizedError {
    case storeNotFound
    case invalidArguments(String)
    case sessionNotFound(String)
    case missingArgument(String)
    case hostApprovalRequired(String)

    var errorDescription: String? {
        switch self {
        case .storeNotFound:
            return "未找到 MiniClaw 存储。请先运行一次 MiniClaw，或使用 --store <path> 指定。"
        case .invalidArguments(let m): return m
        case .sessionNotFound(let id): return "未找到会话 id=\(id)"
        case .missingArgument(let a): return "缺少参数: \(a)"
        case .hostApprovalRequired(let m): return m
        }
    }
}

// MARK: - 输出

/// 把任意 JSON 可序列化对象格式化为 pretty JSON 字符串。
func prettyJSON(_ obj: Any) -> String {
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
       let str = String(data: data, encoding: .utf8) {
        return str
    }
    return String(describing: obj)
}

/// 失败输出：{ "error": message }。
func fail(_ message: String) -> String {
    prettyJSON(["error": message])
}

/// 成功输出：直接序列化字典。
func ok(_ dict: [String: Any]) -> String {
    prettyJSON(dict)
}

// MARK: - 参数解析（支持 --key value / --key / 位置参数）

struct Args {
    var flags: [String: String] = [:]
    var positionals: [String] = []

    init(_ params: [String]) {
        var i = 0
        while i < params.count {
            let p = params[i]
            if p.hasPrefix("--") {
                let key = String(p.dropFirst(2))
                if i + 1 < params.count, !params[i + 1].hasPrefix("--") {
                    flags[key] = params[i + 1]
                    i += 2
                } else {
                    flags[key] = "true"
                    i += 1
                }
            } else {
                positionals.append(p)
                i += 1
            }
        }
    }

    func string(_ key: String) -> String? { flags[key] }
    func bool(_ key: String) -> Bool { flags[key] == "true" }
    func int(_ key: String) -> Int? { flags[key].flatMap(Int.init) }

    /// 显式批准标记（宿主 App 已确认）。
    var approved: Bool {
        bool("approved") || bool("yes") || ProcessInfo.processInfo.environment["MINICLAW_HOST_APPROVED"] == "1"
    }

    /// 会话 id：优先 --id，否则首个位置参数。
    var sessionRef: String? { flags["id"] ?? positionals.first }
}

// MARK: - $VAR 环境变量安全展开（spec 12.2.1）

enum EnvExpander {
    /// 把命令中的 $VAR / ${VAR} 用给定表安全替换；机密无需明文出现在命令里。
    static func expand(_ input: String, table: [String: String]) -> String {
        guard input.contains("$"), !table.isEmpty else { return input }
        let lookup = table
        let chars = Array(input)
        var result = ""
        result.reserveCapacity(input.count)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "$", i + 1 < chars.count {
                if chars[i + 1] == "{",
                   let close = chars[(i + 2)...].firstIndex(of: "}") {
                    let name = String(chars[(i + 2)..<close])
                    if let val = lookup[name] { result += val; i = close + 1; continue }
                }
                let next = chars[i + 1]
                if next.isLetter || next == "_" {
                    var j = i + 1
                    while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                    let name = String(chars[(i + 1)..<j])
                    if let val = lookup[name] { result += val; i = j; continue }
                }
            }
            result.append(c); i += 1
        }
        return result
    }
}

// MARK: - providers.json 定位（仿真器扫描，对齐 ProviderFileStore 路径）

/// 扫描 CoreSimulator，优先定位 MiniClaw 的 Documents/MiniClaw/config/providers.json。
/// 依次兼容上一轮迁移的 models/providers.json 与更早的根层 providers.json；找不到时返回 nil。
func locateProvidersJSON() -> String? {
    let fileManager = FileManager.default
    let home = fileManager.homeDirectoryForCurrentUser
    let base = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
    guard let devices = try? fileManager.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else {
        return nil
    }

    let bundleId = "com.neartop.miniclaw.app"
    var configCandidates: [URL] = []
    var currentCandidates: [URL] = []
    var legacyCandidates: [URL] = []

    for device in devices where device.hasDirectoryPath {
        let dataRoot = device.appendingPathComponent("data/Containers/Data/Application")
        guard let containers = try? fileManager.contentsOfDirectory(
            at: dataRoot,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { continue }

        for container in containers where container.hasDirectoryPath {
            let metadataURL = container.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
            guard let metadata = NSDictionary(contentsOf: metadataURL),
                  metadata["MCMMetadataIdentifier"] as? String == bundleId else {
                continue
            }

            let config = container.appendingPathComponent("Documents/MiniClaw/config/providers.json")
            if fileManager.fileExists(atPath: config.path) {
                configCandidates.append(config)
            }

            let current = container.appendingPathComponent("Documents/MiniClaw/models/providers.json")
            if fileManager.fileExists(atPath: current.path) {
                currentCandidates.append(current)
            }

            let legacy = container.appendingPathComponent("Documents/MiniClaw/providers.json")
            if fileManager.fileExists(atPath: legacy.path) {
                legacyCandidates.append(legacy)
            }
        }
    }

    // 跨全部模拟器优先新路径；同类候选取修改时间最新的一份。
    return newestFile(in: configCandidates)?.path
        ?? newestFile(in: currentCandidates)?.path
        ?? newestFile(in: legacyCandidates)?.path
}

private func newestFile(in candidates: [URL]) -> URL? {
    candidates.max { lhs, rhs in
        let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return lhsDate < rhsDate
    }
}

// MARK: - 安全门（Layer 2 策略核心）

enum OperationClass {
    case direct
    case requiresHostApproval(capability: String, reason: String)
}

struct SecurityGate {
    /// 分类某「域 + 操作」是否需要宿主 App 确认。
    static func classify(domain: String, operation: String, detail: String? = nil) -> OperationClass {
        switch (domain, operation) {
        // iOS 原生能力：全部需宿主 App 确认（权限不可由 CLI 绕过）
        case ("ios", _):
            return .requiresHostApproval(capability: operation, reason: "iOS 系统授权须由宿主 App 在设备上发起用户确认")

        // 浏览器：交互控制需确认；只读设置直连
        case ("browser", "render"), ("browser", "click"), ("browser", "navigate-control"),
             ("browser", "screenshot"), ("browser", "fill"):
            return .requiresHostApproval(capability: "browser.\(operation)", reason: "浏览器交互控制需宿主 App 的 WKWebView 上下文")

        // 文件与 Shell：shell 执行、越界写为高风险
        case ("fs", "shell"):
            return .requiresHostApproval(capability: "fs.shell", reason: "Shell 执行为高风险操作，需宿主 App 确认")
        case ("fs", "write"):
            if let path = detail, !path.hasPrefix("/var/MiniClaw/") {
                return .requiresHostApproval(capability: "fs.write.outside", reason: "写入受保护目录之外需宿主 App 确认")
            }
            return .direct

        // 配置：敏感域/敏感字段写需确认
        case ("config", "set"):
            if let field = detail {
                let sensitive = ["apikey", "secret", "token", "soul", "permissions", "miniclawconfigwrite",
                                 "location", "bluetooth", "microphone", "speechrecognition", "camera",
                                 "photolibrary", "notifications", "calendar", "reminders", "healthkit",
                                 "homekit", "nfc", "localnetwork"]
                if sensitive.contains(field.lowercased()) {
                    return .requiresHostApproval(capability: "config.set.\(field)", reason: "敏感设置变更需宿主 App 确认")
                }
            }
            return .direct

        // 会话：删除全部 / 清空为高风险
        case ("sessions", "delete-all"), ("sessions", "wipe"):
            return .requiresHostApproval(capability: "sessions.\(operation)", reason: "清空全部会话为高风险，需宿主 App 确认")

        // 模型调用：直连（apiKey 经 $VAR 注入，不落明文）
        case ("model", _):
            return .direct

        // 其余默认直连
        default:
            return .direct
        }
    }

    /// 构造「需宿主确认」的标准 JSON 响应（供调用方识别并转交宿主 App）。
    static func approvalResponse(domain: String, operation: String, capability: String, reason: String) -> String {
        ok([
            "requiresHostApproval": true,
            "domain": domain,
            "operation": operation,
            "capability": capability,
            "reason": reason
        ])
    }

    /// 判断调用方是否已持有宿主批准。
    static func isApproved(_ args: Args) -> Bool {
        args.approved
    }
}
