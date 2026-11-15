import Foundation
import UIKit

// MARK: - 4.3 MiniClaw 基础设施工具（5个）

// MARK: - 1. miniclaw-open

struct MiniClawOpenTool: AgentTool {
    let name = "miniclaw_open"
    /// 当前会话 ID：用于将 /var/MiniClaw/ 虚拟路径解析为真实 host 路径。
    let currentSessionID: UUID?

    init(currentSessionID: UUID? = nil) {
        self.currentSessionID = currentSessionID
    }

    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "miniclaw_open",
            description: String(localized: "internal_routing_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "target": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_route_target"), enum: nil),
                    "path": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_file_path_or_url")),
                ],
                required: ["target"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let target = parameters["target"] as? String else {
            throw ToolError.invalidParameters(String(localized: "err_missing_target"))
        }

        if target == "browser" {
            let url = parameters["path"] as? String ?? "https://www.baidu.com"
            return ToolResult(success: true, text: String(format: String(localized: "infra_open_url"), url))
        } else if target.hasPrefix("file:") {
            let rawPath = String(target.dropFirst(5))
            // 将 /var/MiniClaw/ 虚拟路径通过 FileSystemManager 解析为真实 host 路径
            let resolvedURL: URL?
            if rawPath.hasPrefix("miniclaw://") {
                resolvedURL = FileSystemManager.shared.resolveMiniClawResourceURL(rawPath, sessionID: currentSessionID)
            } else if rawPath.hasPrefix("/var/MiniClaw/") {
                resolvedURL = try? FileSystemManager.shared.resolveAgentPath(rawPath, sessionID: currentSessionID)
            } else {
                // [2026-09-13 路径统一] 原为 `URL(fileURLWithPath: rawPath)` —— 任意宿主绝对路径
                //（`Documents/…`、`/var/mobile/Containers/…`）都会被当成可访问文件，是"越界读"入口。
                // 现统一走 `resolveAgentPath`（强制 `/var/MiniClaw/` 前缀 + 拒绝目录穿越 + 会话隔离）；
                // 解析不了就落到下面的 `infra_path_parse_failed`，**不再原样直读**。
                resolvedURL = try? FileSystemManager.shared.resolveAgentPath(rawPath, sessionID: currentSessionID)
            }
            guard let url = resolvedURL else {
                return ToolResult(success: false, text: String(format: String(localized: "infra_path_parse_failed"), rawPath))
            }
            let exists = FileManager.default.fileExists(atPath: url.path)
            // [2026-09-13 路径统一] 回传**规范化后的 guest 写法**（`/var/MiniClaw/...`），不再回传
            // `url.path`（宿主绝对路径 `Documents/...`）—— 宿主路径出圈会让模型拿它去调其它工具而失败。
            let shown = rawPath.hasPrefix("miniclaw://")
                ? "/var/MiniClaw/" + rawPath.dropFirst("miniclaw://".count)
                : rawPath
            return ToolResult(success: exists, text: exists ? String(format: String(localized: "infra_file_accessible"), shown) : String(format: String(localized: "infra_file_not_found"), shown))
        } else if target.hasPrefix("settings:") {
            return ToolResult(success: true, text: String(format: String(localized: "infra_navigated_settings"), target))
        } else {
            return ToolResult(success: false, text: String(format: String(localized: "infra_unsupported_target"), target))
        }
    }
}

// MARK: - 2. miniclaw-model-use

struct MiniClawModelUseTool: AgentTool {
    let name = "miniclaw_model_use"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "miniclaw_model_use",
            description: String(localized: "model_use_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "prompt": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_submodel_prompt")),
                    "model_id": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_model_id")),
                    "system_prompt": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_system_prompt")),
                    "temperature": JSONSchema.JSONProperty(type: "number", description: String(localized: "param_temperature")),
                    "max_tokens": JSONSchema.JSONProperty(type: "integer", description: String(localized: "param_max_tokens")),
                ],
                required: ["prompt"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: String(localized: "not_implemented_model_use"))
    }
}

// MARK: - 3. miniclaw-browser-use

struct MiniClawBrowserUseTool: AgentTool {
    let name = "miniclaw_browser_use"

    /// 当前会话 ID：委托给 BrowserTool 时一并传递，保证浏览器上下文隔离。
    let currentSessionID: UUID?

    init(currentSessionID: UUID? = nil) {
        self.currentSessionID = currentSessionID
    }

    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "miniclaw_browser_use",
            description: String(localized: "browser_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "activity": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_skill_action_hint")),
                    "action": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_browser_actions")),
                    "params": JSONSchema.JSONProperty(type: "object", description: String(localized: "param_browser_params")),
                    "tab_index": JSONSchema.JSONProperty(type: "integer", description: String(localized: "param_tab_index")),
                ],
                required: ["activity", "action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        // 委托给 BrowserTool（携带会话 ID，保证浏览器上下文隔离）
        let browserTool = BrowserTool(currentSessionID: currentSessionID)
        return try await browserTool.execute(parameters)
    }
}

// MARK: - 4. miniclaw-debug

struct MiniClawDebugTool: AgentTool {
    let name = "miniclaw_debug"
    /// 当前会话 ID：sandbox_files 在收到 /var/MiniClaw/ 虚拟路径时用于解析为真实 host 路径。
    let currentSessionID: UUID?

    init(currentSessionID: UUID? = nil) {
        self.currentSessionID = currentSessionID
    }

    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "miniclaw_debug",
            description: String(localized: "debug_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: String(localized: "op_debug_actions"), enum: ["view_tree", "sandbox_files", "memory_logs", "screenshot", "app_state", "disk_usage"]),
                    "path": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_sandbox_path")),
                    "max_depth": JSONSchema.JSONProperty(type: "integer", description: String(localized: "param_max_recursion_depth")),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let action = parameters["action"] as? String else {
            throw ToolError.invalidParameters(String(localized: "err_missing_action"))
        }

        let fs = FileSystemManager.shared
        let fm = FileManager.default

        switch action {
        case "sandbox_files":
            let rawPath = parameters["path"] as? String
            // [2026-09-13 路径统一] 统一按 **guest 写法**解析（`/var/MiniClaw/<子目录>`）：
            // 模型给相对写法时补全前缀、给 `miniclaw://` 时换前缀。原实现在"不是 /var/MiniClaw/ 开头"
            // 时直接把原始串当宿主路径用（相对串会相对进程 cwd 解析 ⇒ 读不到；绝对宿主路径则可越界读），
            // 且失败时静默回落宿主根。现改为解析失败**显式失败**。
            // 注：`listDirectory` 只输出**条目名**（不带 base 前缀），故列表本身不会泄漏宿主路径。
            let trimmed = (rawPath ?? "").trimmingCharacters(in: .whitespaces)
            let guestBase: String
            if trimmed.isEmpty {
                guestBase = "/var/MiniClaw/"
            } else if trimmed.hasPrefix("/var/MiniClaw/") {
                guestBase = trimmed
            } else if trimmed.hasPrefix("miniclaw://") {
                guestBase = "/var/MiniClaw/" + trimmed.dropFirst("miniclaw://".count)
            } else {
                guestBase = "/var/MiniClaw/" + trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            let base: String
            do {
                base = try FileSystemManager.shared.resolveAgentPath(guestBase, sessionID: currentSessionID).path
            } catch {
                return ToolResult(success: false, text: String(format: String(localized: "infra_path_parse_failed"), guestBase))
            }
            let depth = (parameters["max_depth"] as? Int) ?? 2
            let listing = listDirectory(at: base, maxDepth: depth, currentDepth: 0, prefix: "")
            return ToolResult(success: true, text: listing.isEmpty ? String(localized: "empty_directory") : listing)

        case "memory_logs":
            let dir = fs.memoryDir
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]))?
                .filter { $0.pathExtension == "md" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
            if files.isEmpty {
                return ToolResult(success: true, text: String(localized: "no_memory_logs"))
            }
            let list = files.map { url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return "\(url.lastPathComponent) (\(size) bytes)"
            }.joined(separator: "\n")
            return ToolResult(success: true, text: list)

        case "app_state":
            let root = fs.miniClawRoot
            let keys: [URLResourceKey] = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]
            let values = try? root.resourceValues(forKeys: Set(keys))
            let total = values?.volumeTotalCapacity.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? String(localized: "unknown")
            let free = values?.volumeAvailableCapacity.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? String(localized: "unknown")
            // [2026-09-13 路径统一] 回传 **guest 根**（`/var/MiniClaw`），不再回传 `root.path`
            //（宿主 `Documents/MiniClaw`）—— 宿主路径出圈会让模型拿它去调其它工具而失败。
            // `root` 仍用于上面读容量（那是宿主 URL，只用于取值、不用于展示）。
            return ToolResult(success: true, text: """
            MiniClaw 根目录: /var/MiniClaw
            文件系统总容量: \(total)
            可用空间: \(free)
            """)

        case "disk_usage":
            let usage = ByteCountFormatter.string(fromByteCount: Int64(diskUsage(at: fs.miniClawRoot)), countStyle: .file)
            return ToolResult(success: true, text: String(format: String(localized: "infra_usage"), usage))

        case "view_tree", "screenshot":
            return ToolResult(success: false, text: String(format: String(localized: "infra_not_implemented"), action))

        default:
            return ToolResult(success: false, text: String(format: String(localized: "infra_unsupported_action"), action))
        }
    }

    private func listDirectory(at path: String, maxDepth: Int, currentDepth: Int, prefix: String) -> String {
        guard currentDepth <= maxDepth else { return "" }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: path) else { return String(format: String(localized: "infra_prefix_unreadable"), prefix) }
        var result = ""
        for item in items.sorted() {
            let full = (path as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isDir)
            result += "\(prefix)\(item)\(isDir.boolValue ? "/" : "")\n"
            if isDir.boolValue && currentDepth < maxDepth {
                result += listDirectory(at: full, maxDepth: maxDepth, currentDepth: currentDepth + 1, prefix: prefix + "  ")
            }
        }
        return result
    }

    private func diskUsage(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            total += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

