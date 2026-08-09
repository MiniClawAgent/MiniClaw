import Foundation
import UIKit

// MARK: - 4.3 MiniClaw 基础设施工具（5个）

// MARK: - 1. miniclaw-open

struct MiniClawOpenTool: AgentTool {
    let name = "miniclaw-open"
    /// 当前会话 ID：用于将 /var/MiniClaw/ 虚拟路径解析为真实 host 路径。
    let currentSessionID: UUID?

    init(currentSessionID: UUID? = nil) {
        self.currentSessionID = currentSessionID
    }

    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "miniclaw-open",
            description: "内部路由：打开文件预览、浏览器、设置页面等。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "target": JSONSchema.JSONProperty(type: "string", description: "目标: browser / file:<path> / settings:<section>", enum: nil),
                    "path": JSONSchema.JSONProperty(type: "string", description: "文件路径或 URL"),
                ],
                required: ["target"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let target = parameters["target"] as? String else {
            throw ToolError.invalidParameters("缺少 target 参数")
        }

        if target == "browser" {
            let url = parameters["path"] as? String ?? "https://www.baidu.com"
            return ToolResult(success: true, text: "✅ 请在浏览器中打开: \(url)")
        } else if target.hasPrefix("file:") {
            let rawPath = String(target.dropFirst(5))
            // 将 /var/MiniClaw/ 虚拟路径通过 FileSystemManager 解析为真实 host 路径
            let resolvedURL: URL?
            if rawPath.hasPrefix("miniclaw://") {
                resolvedURL = FileSystemManager.shared.resolveMiniClawResourceURL(rawPath, sessionID: currentSessionID)
            } else if rawPath.hasPrefix("/var/MiniClaw/") {
                resolvedURL = try? FileSystemManager.shared.resolveAgentPath(rawPath, sessionID: currentSessionID)
            } else {
                resolvedURL = URL(fileURLWithPath: rawPath)
            }
            guard let url = resolvedURL else {
                return ToolResult(success: false, text: "无法解析路径: \(rawPath)")
            }
            let exists = FileManager.default.fileExists(atPath: url.path)
            return ToolResult(success: exists, text: exists ? "文件可访问: \(url.path)" : "文件不存在: \(rawPath)")
        } else if target.hasPrefix("settings:") {
            return ToolResult(success: true, text: "✅ 已导航到设置: \(target)")
        } else {
            return ToolResult(success: false, text: "不支持的目标: \(target)。支持: browser, file:<path>, settings:<section>")
        }
    }
}

// MARK: - 2. miniclaw-model-use

struct MiniClawModelUseTool: AgentTool {
    let name = "miniclaw-model-use"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "miniclaw-model-use",
            description: "调用其他 LLM 模型执行子任务。可选择不同提供商和模型。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "prompt": JSONSchema.JSONProperty(type: "string", description: "要发给子模型的提示词"),
                    "model_id": JSONSchema.JSONProperty(type: "string", description: "模型 ID（使用已配置的模型组或单独模型名）"),
                    "system_prompt": JSONSchema.JSONProperty(type: "string", description: "系统提示词（可选）"),
                    "temperature": JSONSchema.JSONProperty(type: "number", description: "温度参数 0-2（可选）"),
                    "max_tokens": JSONSchema.JSONProperty(type: "integer", description: "最大词元数（可选）"),
                ],
                required: ["prompt"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: "🔴 model-use 尚未接入。子模型调用需要多提供商 API 编排。")
    }
}

// MARK: - 3. miniclaw-browser-use

struct MiniClawBrowserUseTool: AgentTool {
    let name = "miniclaw-browser-use"

    /// 当前会话 ID：委托给 BrowserTool 时一并传递，保证浏览器上下文隔离。
    let currentSessionID: UUID?

    init(currentSessionID: UUID? = nil) {
        self.currentSessionID = currentSessionID
    }

    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "miniclaw-browser-use",
            description: "浏览器 CLI 封装。操作参数统一放入 params。navigate 必须提供 params.url；max_length 仅用于 get_readable。每次调用必须提供 activity，用6-16字中文描述当前具体业务行为。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "activity": JSONSchema.JSONProperty(type: "string", description: "必填。工具指示器显示的具体行为，如：搜索世界杯赛程"),
                    "action": JSONSchema.JSONProperty(type: "string", description: "浏览器操作: navigate, screenshot, click, type, get_text, scroll, execute_js, get_page_info, find_elements, hover, get_readable, set_user_agent, set_viewport, new_tab, close_tab, list_tabs, get_cookies, set_cookies, scroll_and_collect, wait_for_dom_stable, get_backbone, fetch"),
                    "params": JSONSchema.JSONProperty(type: "object", description: "操作参数字典。navigate 必须包含 url；get_readable 才可包含 max_length"),
                    "tab_index": JSONSchema.JSONProperty(type: "integer", description: "标签索引（0-based）"),
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
    let name = "miniclaw-debug"
    /// 当前会话 ID：sandbox_files 在收到 /var/MiniClaw/ 虚拟路径时用于解析为真实 host 路径。
    let currentSessionID: UUID?

    init(currentSessionID: UUID? = nil) {
        self.currentSessionID = currentSessionID
    }

    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "miniclaw-debug",
            description: "Debug 工具：查看视图树、沙盒文件列表、内存日志、截屏、应用状态。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: "操作: view_tree/sandbox_files/memory_logs/screenshot/app_state/disk_usage", enum: ["view_tree", "sandbox_files", "memory_logs", "screenshot", "app_state", "disk_usage"]),
                    "path": JSONSchema.JSONProperty(type: "string", description: "沙盒路径（用于 sandbox_files，默认 /var/MiniClaw/）"),
                    "max_depth": JSONSchema.JSONProperty(type: "integer", description: "最大递归深度（默认 2）"),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let action = parameters["action"] as? String else {
            throw ToolError.invalidParameters("缺少 action 参数")
        }

        let fs = FileSystemManager.shared
        let fm = FileManager.default

        switch action {
        case "sandbox_files":
            let rawPath = parameters["path"] as? String
            // 支持 /var/MiniClaw/ 虚拟路径：经 FileSystemManager 解析为真实 host 路径
            let base: String
            if let rawPath, rawPath.hasPrefix("/var/MiniClaw/") {
                base = (try? FileSystemManager.shared.resolveAgentPath(rawPath, sessionID: currentSessionID).path)
                    ?? rawPath
            } else {
                base = rawPath ?? fs.miniClawRoot.path
            }
            let depth = (parameters["max_depth"] as? Int) ?? 2
            let listing = listDirectory(at: base, maxDepth: depth, currentDepth: 0, prefix: "")
            return ToolResult(success: true, text: listing.isEmpty ? "(空目录)" : listing)

        case "memory_logs":
            let dir = fs.memoryDir
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]))?
                .filter { $0.pathExtension == "md" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
            if files.isEmpty {
                return ToolResult(success: true, text: "(暂无记忆日志)")
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
            let total = values?.volumeTotalCapacity.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "未知"
            let free = values?.volumeAvailableCapacity.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "未知"
            return ToolResult(success: true, text: """
            MiniClaw 根目录: \(root.path)
            文件系统总容量: \(total)
            可用空间: \(free)
            """)

        case "disk_usage":
            let usage = ByteCountFormatter.string(fromByteCount: Int64(diskUsage(at: fs.miniClawRoot)), countStyle: .file)
            return ToolResult(success: true, text: "MiniClaw 目录占用量: \(usage)")

        case "view_tree", "screenshot":
            return ToolResult(success: false, text: "🔴 \(action) 尚未实现。需要 UIApplication 级别的窗口访问。")

        default:
            return ToolResult(success: false, text: "不支持的操作: \(action)")
        }
    }

    private func listDirectory(at path: String, maxDepth: Int, currentDepth: Int, prefix: String) -> String {
        guard currentDepth <= maxDepth else { return "" }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: path) else { return "\(prefix)(无法读取)" }
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

