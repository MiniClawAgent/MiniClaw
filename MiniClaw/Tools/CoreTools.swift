import Foundation
import UIKit
import PDFKit

// MARK: - File Read Tool

struct FileReadTool: AgentTool {
    let name = "file_read"
    /// 当前会话 ID：注入后该工具读取的文件走本会话的隔离命名空间
    /// /var/MiniClaw/{workspace,attachments,browser,offloads}，与其他会话互不污染。
    let currentSessionID: UUID?
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "file_read",
            description: L10n.l("file_read_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "path": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_abs_path_required")),
                    "offset": JSONSchema.JSONProperty(type: "integer", description: L10n.l("param_start_line")),
                    "limit": JSONSchema.JSONProperty(type: "integer", description: L10n.l("param_max_read_lines")),
                    "tail": JSONSchema.JSONProperty(type: "integer", description: L10n.l("param_tail_lines")),
                ],
                required: ["path"]
            )
        )
    )

    init(currentSessionID: UUID? = nil) {
        self.currentSessionID = currentSessionID
    }

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let path = parameters["path"] as? String else {
            throw ToolError.invalidParameters(L10n.l("err_missing_path"))
        }

        let offset = parameters["offset"] as? Int
        let limit = parameters["limit"] as? Int
        let tail = parameters["tail"] as? Int

        do {
            let content = try FileSystemManager.shared.readFile(at: path, offset: offset, limit: limit, tail: tail, sessionID: currentSessionID)
            return ToolResult(success: true, text: content)
        } catch {
            return ToolResult(success: false, text: error.localizedDescription)
        }
    }
}

// MARK: - List Directory Tool

struct ListDirTool: AgentTool {
    let name = "list_dir"
    /// 当前会话 ID：注入后列出的目录走本会话的隔离命名空间。
    let currentSessionID: UUID?
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "list_dir",
            description: L10n.l("list_dir_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "path": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_abs_path_example")),
                ],
                required: ["path"]
            )
        )
    )

    init(currentSessionID: UUID? = nil) {
        self.currentSessionID = currentSessionID
    }

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let path = parameters["path"] as? String else {
            throw ToolError.invalidParameters(L10n.l("err_missing_path"))
        }

        do {
            let entries = try FileSystemManager.shared.listDirectory(at: path, sessionID: currentSessionID)
            if entries.isEmpty {
                return ToolResult(success: true, text: L10n.l("dir_empty_or_unreadable"))
            }
            return ToolResult(success: true, text: entries.joined(separator: "\n"))
        } catch {
            return ToolResult(success: false, text: error.localizedDescription)
        }
    }
}

// MARK: - File Write Tool

struct FileWriteTool: AgentTool {
    var resumePolicy: ResumePolicy { .requiresUserConfirmation }
    let name = "file_write"
    /// 当前会话 ID：注入后该工具写入的文件走本会话的隔离命名空间。
    let currentSessionID: UUID?
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "file_write",
            description: L10n.l("file_write_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "path": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_abs_path_required")),
                    "content": JSONSchema.JSONProperty(type: "string", description: L10n.l("file_content")),
                    "append": JSONSchema.JSONProperty(type: "boolean", description: L10n.l("param_append_mode")),
                    "create_dirs": JSONSchema.JSONProperty(type: "boolean", description: L10n.l("param_create_dirs")),
                ],
                required: ["path", "content"]
            )
        )
    )

    init(currentSessionID: UUID? = nil) {
        self.currentSessionID = currentSessionID
    }

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let path = parameters["path"] as? String,
              let content = parameters["content"] as? String else {
            throw ToolError.invalidParameters(L10n.l("err_missing_path_content"))
        }

        let append = parameters["append"] as? Bool ?? false
        let createDirs = parameters["create_dirs"] as? Bool ?? true

        do {
            try FileSystemManager.shared.writeFile(at: path, content: content, append: append, createDirs: createDirs, sessionID: currentSessionID)
            return ToolResult(success: true, text: String(format: L10n.l("core_file_written"), path))
        } catch {
            return ToolResult(success: false, text: error.localizedDescription)
        }
    }
}

// MARK: - File Edit Tool

struct FileEditTool: AgentTool {
    var resumePolicy: ResumePolicy { .requiresUserConfirmation }
    let name = "file_edit"
    /// 当前会话 ID：注入后该工具编辑的文件走本会话的隔离命名空间。
    let currentSessionID: UUID?
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "file_edit",
            description: L10n.l("file_edit_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "path": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_abs_path_required")),
                    "old_string": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_text_to_replace")),
                    "new_string": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_replacement_text")),
                ],
                required: ["path", "old_string", "new_string"]
            )
        )
    )

    init(currentSessionID: UUID? = nil) {
        self.currentSessionID = currentSessionID
    }

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let path = parameters["path"] as? String,
              let oldStr = parameters["old_string"] as? String,
              let newStr = parameters["new_string"] as? String else {
            throw ToolError.invalidParameters(L10n.l("err_missing_required"))
        }

        do {
            try FileSystemManager.shared.editFile(at: path, oldString: oldStr, newString: newStr, sessionID: currentSessionID)
            return ToolResult(success: true, text: String(format: L10n.l("core_file_edited"), path))
        } catch {
            return ToolResult(success: false, text: error.localizedDescription)
        }
    }
}

// MARK: - Read Image Tool

struct ReadImageTool: AgentTool {
    let name = "read_image"
    /// 当前会话 ID：注入后读取的图片走本会话的隔离命名空间。
    let currentSessionID: UUID?
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "read_image",
            description: L10n.l("read_image_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "path": JSONSchema.JSONProperty(type: "string", description: L10n.l("image_path_param")),
                ],
                required: ["path"]
            )
        )
    )

    init(currentSessionID: UUID? = nil) {
        self.currentSessionID = currentSessionID
    }

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let path = parameters["path"] as? String else {
            throw ToolError.invalidParameters(L10n.l("err_missing_path"))
        }

        do {
            let url = try FileSystemManager.shared.imageURL(at: path, sessionID: currentSessionID)
            let imageData = try Data(contentsOf: url)
            guard let image = UIImage(data: imageData) else {
                return ToolResult(success: false, text: String(format: L10n.l("core_image_decode_failed"), path))
            }
            let base64 = imageData.base64EncodedString()
            let mimeType = mimeTypeFor(path: path)
            return ToolResult(
                success: true,
                text: String(format: L10n.l("core_image_read"), Int(image.size.width), Int(image.size.height)),
                data: ["base64": base64, "mime_type": mimeType]
            )
        } catch {
            return ToolResult(success: false, text: error.localizedDescription)
        }
    }

    private func mimeTypeFor(path: String) -> String {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Vision Analyze Tool (Apple Vision Framework)

/// 使用 Apple 本地 Vision 框架分析图片，返回场景分类、OCR 文字、人脸检测结果。
/// 适用于**所有模型**——即使是不支持原生视觉输入的文本模型（如 DeepSeek），
/// 也可以通过此工具"看到"图片内容。这是 MiniClaw 的核心视觉能力工具。
struct VisionAnalyzeTool: AgentTool {
    let name = "vision_analyze"
    let currentSessionID: UUID?
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "vision_analyze",
            description: L10n.l("vision_analyze_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "path": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_image_path")),
                ],
                required: ["path"]
            )
        )
    )

    init(currentSessionID: UUID? = nil) {
        self.currentSessionID = currentSessionID
    }

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let path = parameters["path"] as? String, !path.isEmpty else {
            throw ToolError.invalidParameters(L10n.l("err_missing_path"))
        }

        // 尝试通过 FileSystemManager 解析路径（支持会话隔离路径）
        let resolvedPath: String
        do {
            let url = try FileSystemManager.shared.imageURL(at: path, sessionID: currentSessionID)
            resolvedPath = url.path
        } catch {
            // 如果 FileSystemManager 解析失败，直接使用原始路径（可能是绝对路径）
            resolvedPath = path
        }

        let result = await VisionAnalyzer.shared.analyze(imageAt: resolvedPath)

        if let error = result.error {
            return ToolResult(success: false, text: String(format: L10n.l("core_image_analysis_failed"), error))
        }

        // 返回格式化后的结构化文本（LLM 可直接阅读）
        return ToolResult(
            success: true,
            text: result.formattedText()
        )
    }
}

// MARK: - Read Document Tool

/// 让 智能体自行读取用户发送的各种格式附件（而非由 App 直接内联或静默丢弃）。
/// 支持：纯文本/代码/Markdown/JSON/CSV/XML/HTML 等（UTF-8）、PDF（PDFKit 抽取文本）、
/// 以及经过会话隔离路径（/var/MiniClaw/...）解析。Office 二进制（docx/xlsx/pptx 等）
/// 当前端侧暂无法抽取文本，会返回清晰提示请用户导出为 PDF/TXT。
struct ReadDocumentTool: AgentTool {
    let name = "read_document"
    let currentSessionID: UUID?
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "read_document",
            description: L10n.l("read_document_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "path": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_file_abs_path")),
                    "offset": JSONSchema.JSONProperty(type: "integer", description: L10n.l("param_start_line")),
                    "limit": JSONSchema.JSONProperty(type: "integer", description: L10n.l("param_max_read_lines")),
                    "tail": JSONSchema.JSONProperty(type: "integer", description: L10n.l("param_tail_lines")),
                ],
                required: ["path"]
            )
        )
    )

    init(currentSessionID: UUID? = nil) {
        self.currentSessionID = currentSessionID
    }

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let path = parameters["path"] as? String, !path.isEmpty else {
            throw ToolError.invalidParameters(L10n.l("err_missing_path"))
        }
        let offset = parameters["offset"] as? Int
        let limit = parameters["limit"] as? Int
        let tail = parameters["tail"] as? Int

        do {
            let url = try FileSystemManager.shared.resolveAgentPath(path, sessionID: currentSessionID)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return ToolResult(success: false, text: String(format: L10n.l("core_file_not_found"), path))
            }
            let ext = url.pathExtension.lowercased()
            let text: String
            switch ext {
            case "pdf":
                text = Self.extractPDFText(url)
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return ToolResult(success: false, text: L10n.l("pdf_no_text"))
                }
            case "txt", "md", "markdown", "json", "csv", "tsv", "log", "xml", "html", "htm",
                 "yaml", "yml", "swift", "py", "js", "ts", "java", "c", "cpp", "h", "hpp", "m", "mm",
                 "sh", "plist", "toml", "ini", "cfg", "css", "scss", "go", "rs", "kt", "rb", "php",
                 "sql", "r", "tex", "gitignore", "env":
                let raw = try String(contentsOf: url, encoding: .utf8)
                text = Self.paginate(raw, offset: offset, limit: limit, tail: tail)
            case "docx", "xlsx", "pptx", "doc", "xls", "ppt":
                return ToolResult(success: false, text: String(format: L10n.l("core_unsupported_office"), ext.uppercased()))
            default:
                // 兜底：尝试按 UTF-8 文本读取，失败则给出明确不支持提示。
                if let raw = try? String(contentsOf: url, encoding: .utf8), !raw.isEmpty {
                    text = Self.paginate(raw, offset: offset, limit: limit, tail: tail)
                } else {
                    return ToolResult(success: false, text: String(format: L10n.l("core_unreadable_text"), ext))
                }
            }
            let trimmed = text.count > 60_000
                ? String(text.prefix(60_000)) + L10n.l("truncated_paging_hint")
                : text
            return ToolResult(success: true, text: trimmed)
        } catch {
            return ToolResult(success: false, text: error.localizedDescription)
        }
    }

    /// 用 PDFKit 抽取整本文档文本。
    private static func extractPDFText(_ url: URL) -> String {
        guard let doc = PDFDocument(url: url) else { return "" }
        var out = ""
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), let pageText = page.string {
                out += pageText + "\n"
            }
        }
        return out
    }

    /// 按行分页：tail 优先，其次 offset+limit。
    private static func paginate(_ raw: String, offset: Int?, limit: Int?, tail: Int?) -> String {
        let lines = raw.components(separatedBy: "\n")
        if let tail = tail, tail > 0 {
            return lines.suffix(tail).joined(separator: "\n")
        }
        let start = max(0, offset ?? 0)
        let end = limit.map { min(lines.count, start + $0) } ?? lines.count
        guard start < lines.count else { return "" }
        return Array(lines[start..<end]).joined(separator: "\n")
    }
}

// MARK: - Memory Write Tool

struct MemoryWriteTool: AgentTool {
    /// 复盘分身等后台 Agent 使用免确认实例，避免触发（当前仅元数据的）确认策略。
    private let bypassConfirmation: Bool
    var resumePolicy: ResumePolicy { bypassConfirmation ? .retryable : .requiresUserConfirmation }
    let name = "memory_write"

    init(bypassConfirmation: Bool = false) {
        self.bypassConfirmation = bypassConfirmation
    }

    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "memory_write",
            description: L10n.l("memory_write_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "content": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_memory_content")),
                    "target": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_memory_target_desc"), enum: ["long_term", "daily"]),
                    "mode": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_mode_append_replace_edit"), enum: ["append", "replace", "edit"]),
                    "old_string": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_edit_old_string")),
                    "new_string": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_edit_new_string")),
                ],
                required: ["target", "mode"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        // 设置快照：后台线程不裸读 SettingsStore（2026-08-13 竞争修复）。
        let settings = await SettingsStore.shared.snapshot()
        // 记忆总开关：关闭时任何记忆写入都被拒绝（含后台复盘分身）。
        guard settings.memory.isEnabled else {
            return ToolResult(success: false, text: L10n.l("err_memory_disabled_write"))
        }
        guard let target = parameters["target"] as? String else {
            throw ToolError.invalidParameters(L10n.l("err_missing_target_long_daily"))
        }

        let modeString = parameters["mode"] as? String ?? "append"

        do {
            switch target {
            case "long_term":
                switch modeString {
                case "append", "replace":
                    guard let content = parameters["content"] as? String else {
                        throw ToolError.invalidParameters(String(format: L10n.l("core_missing_content_for_mode"), modeString))
                    }
                    let mode: LongTermMemoryWriteMode = modeString == "replace" ? .replace : .append
                    let path = try MemoryManager.shared.writeLongTermMemory(content, mode: mode, settings: settings)
                    return ToolResult(success: true, text: String(format: L10n.l("long_term_memory_written"), path))
                case "edit":
                    guard let oldString = parameters["old_string"] as? String,
                          let newString = parameters["new_string"] as? String else {
                        throw ToolError.invalidParameters(L10n.l("err_mode_edit_need_strings"))
                    }
                    let path = try MemoryManager.shared.editMemory(target: .longTerm, oldString: oldString, newString: newString, settings: settings)
                    return ToolResult(success: true, text: String(format: L10n.l("long_term_memory_updated"), path))
                default:
                    throw ToolError.invalidParameters(L10n.l("err_mode_invalid"))
                }
            case "daily":
                // 「自动保存每日记忆」开关：关闭时不写入每日记忆文件（不影响每日记忆的读取）。
                guard settings.memory.autoSaveDaily else {
                    return ToolResult(success: false, text: L10n.l("daily_memory_save_disabled"))
                }
                switch modeString {
                case "append":
                    guard let content = parameters["content"] as? String else {
                        throw ToolError.invalidParameters(L10n.l("err_mode_append_need_content"))
                    }
                    let path = try MemoryManager.shared.writeDailyMemory(content, settings: settings)
                    return ToolResult(success: true, text: String(format: L10n.l("daily_memory_written"), path))
                case "edit":
                    guard let oldString = parameters["old_string"] as? String,
                          let newString = parameters["new_string"] as? String else {
                        throw ToolError.invalidParameters(L10n.l("err_mode_edit_need_strings"))
                    }
                    let path = try MemoryManager.shared.editMemory(target: .daily, oldString: oldString, newString: newString, settings: settings)
                    return ToolResult(success: true, text: String(format: L10n.l("daily_memory_updated"), path))
                default:
                    throw ToolError.invalidParameters(L10n.l("err_daily_modes"))
                }
            default:
                throw ToolError.invalidParameters(L10n.l("err_target_invalid"))
            }
        } catch {
            return ToolResult(success: false, text: error.localizedDescription)
        }
    }
}

// MARK: - Memory Get Tool

struct MemoryGetTool: AgentTool {
    let name = "memory_get"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "memory_get",
            description: L10n.l("memory_search_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "keyword": JSONSchema.JSONProperty(type: "string", description: L10n.l("search_keyword_param")),
                    "scope": JSONSchema.JSONProperty(type: "string", description: L10n.l("search_scope_param"), enum: ["long_term", "daily", "all"]),
                ],
                required: ["keyword"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        // 设置快照：后台线程不裸读 SettingsStore（2026-08-13 竞争修复）。
        let settings = await SettingsStore.shared.snapshot()
        // 记忆总开关：关闭时禁止检索记忆（与 memory_write 一致）。
        guard settings.memory.isEnabled else {
            return ToolResult(success: false, text: L10n.l("err_memory_disabled_search"))
        }
        guard let keyword = parameters["keyword"] as? String else {
            throw ToolError.invalidParameters(L10n.l("err_missing_keyword"))
        }

        let scopeStr = parameters["scope"] as? String ?? "all"
        let scope: MemorySearchScope
        switch scopeStr {
        case "daily": scope = .daily
        case "long_term": scope = .longTerm
        case "all": scope = .all
        default: throw ToolError.invalidParameters(L10n.l("err_scope_invalid"))
        }

        let results = await MemoryIndexer.shared.search(keyword: keyword, scope: scope)

        if results.isEmpty {
            return ToolResult(success: true, text: L10n.l("memory_not_found"))
        }

        return ToolResult(success: true, text: results.joined(separator: "\n\n---\n\n"))
    }
}

// MARK: - Shell Execute Tool (Placeholder)

struct ShellExecuteTool: AgentTool {
    var resumePolicy: ResumePolicy { .requiresUserConfirmation }
    let name = "shell_execute"
    /// 当前会话 ID：注入后该工具执行的 Shell 命令会被隔离到本会话的
    /// /var/MiniClaw/{workspace,attachments,browser,offloads}，与其他会话互不污染。
    let currentSessionID: UUID?
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "shell_execute",
            description: L10n.l("shell_execute_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "command": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_shell_command")),
                    "timeout": JSONSchema.JSONProperty(type: "integer", description: L10n.l("param_shell_timeout")),
                    "delay": JSONSchema.JSONProperty(type: "integer", description: L10n.l("param_shell_delay")),
                ],
                required: ["command"]
            )
        )
    )

    init(currentSessionID: UUID? = nil) {
        self.currentSessionID = currentSessionID
    }

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        let rawCommand = parameters["command"] as? String ?? ""
        let timeout = parameters["timeout"] as? Int ?? 900
        let delay = parameters["delay"] as? Int ?? 0
        // delay 参数：App 侧等待（不占用 iSH shell），供轮询/等待服务启动用——
        // 等待期间其他命令可并发执行；命令本身未被调度前就占着 shell。
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
        }
        // 设置快照必须先取：environmentDictionary 同样读 envvars，不能裸读
        // SettingsStore（2026-08-13 竞争修复）。maskSecrets/threshold 共用同一份快照。
        let settings = await SettingsStore.shared.snapshot()
        // 真实注入进程环境：已配置的环境变量经 /bin/sh 的进程环境下发，
        // 命令里写 $VAR / ${VAR} 由 sh 自身从环境展开（机密不进命令字符串，
        // 也不受特殊字符导致的命令注入影响）。不再使用字符串替换式展开。
        let environment = EnvVarStore.environmentDictionary(using: settings.envvars)

        // —— Bashism 检测与 bash 升级执行（自研，见 BashismDetector/BashSupport）——
        // 检测到 bash 特有语法时：bash 可用 → 用 bash -lc 包装执行（执行前决策，
        // 无重复副作用；环境变量随进程环境继承，$VAR 由 bash 展开）；
        // bash 不可用 → 尝试按需安装（独立预算+退避）；仍不可用 → 原样 sh 执行，
        // 并在结果附 system-reminder 提醒模型改写为 POSIX 语法。
        let hits = BashismDetector.detect(rawCommand)
        var effectiveCommand = rawCommand
        var bashReminder: String?
        if !hits.isEmpty {
            if await BashSupport.ensureInstalled() {
                effectiveCommand = "bash -lc " + Self.singleQuoteEscape(rawCommand)
            } else {
                let names = hits.map { $0.rule }.joined(separator: "、")
                bashReminder = String(format: L10n.l("core_bash_syntax_hint"), names)
            }
        }

        do {
            let result = try await ShellRuntimeFactory.runtime.execute(
                command: effectiveCommand,
                environment: environment,
                workingDirectory: nil,
                timeout: TimeInterval(timeout),
                onLine: nil,
                sessionID: currentSessionID
            )
            let output = result.stdout + (result.stderr.isEmpty ? "" : "\n[stderr]\n\(result.stderr)")
            let full = output.isEmpty ? L10n.l("no_output") : output
            let masked = maskSecrets(full, settings: settings)
            let thresholdBytes = settings.files.autoOffloadThresholdKB * 1024
            var final = FileSystemManager.shared.offloadIfLarge(masked, thresholdBytes: thresholdBytes, sessionID: currentSessionID)
            // 治本(2026-08-13):附上工作目录,消除 AI 对 shell 默认 cwd 的误判。
            // workingDirectory 传 nil 时命令在 iSH 会话根执行(/var/MiniClaw/sessions/<uuid>),
            // 但 AI 常误以为文件落在 /tmp 或"文件不见了"而反复扑空。附上 cwd 让 AI 明确:
            // 相对路径生成的文件落在此目录。
            let cwd = currentSessionID.map { "/var/MiniClaw/sessions/\($0.uuidString)" } ?? "/var/MiniClaw"
            final += "\n[env] cwd: \(cwd) (relative paths resolve here)"
            if let bashReminder { final += bashReminder }
            return ToolResult(success: result.exitCode == 0, text: final)
        } catch {
            return ToolResult(success: false, text: error.localizedDescription)
        }
    }

    /// 单引号包裹命令（' 转义为 '\''），供 `bash -lc '...'` 包装使用。
    private static func singleQuoteEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 当 envvars.privacyMode 开启时，把输出中的环境变量值替换为 ***
    /// 2026-08-13 改传主线程快照：不再后台线程裸读 SettingsStore（竞争修复）。
    private func maskSecrets(_ output: String, settings: AppSettings) -> String {
        guard settings.envvarsPrivacyMode else { return output }
        var text = output
        for v in settings.envvars where !v.value.isEmpty {
            text = text.replacingOccurrences(of: v.value, with: "***")
        }
        return text
    }
}
