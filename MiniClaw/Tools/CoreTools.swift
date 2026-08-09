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
            description: "读取 UTF-8 文本文件。支持 offset/limit 分页或 tail 读取末尾行；拒绝二进制文件。路径必须为 /var/MiniClaw/... 绝对路径。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "path": JSONSchema.JSONProperty(type: "string", description: "绝对路径，必须以 /var/MiniClaw/ 开头"),
                    "offset": JSONSchema.JSONProperty(type: "integer", description: "起始行（0 起，可选）"),
                    "limit": JSONSchema.JSONProperty(type: "integer", description: "最大读取行数（可选）"),
                    "tail": JSONSchema.JSONProperty(type: "integer", description: "读取文件末尾 N 行；指定后忽略 offset/limit"),
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
            throw ToolError.invalidParameters("缺少 path 参数")
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
            description: "列出目录内容（只读，不递归）。可列出 /var/MiniClaw/ 下任意子目录，包括「设置→挂载」中挂载的外部文件夹（路径形如 /var/MiniClaw/mounts/<name>/）。返回该目录下的文件名/子目录名（每行一个）。读取挂载内容**不依赖 shell/iSH**：先 list_dir 看挂载里有什么，再用 file_read 读具体文件。路径必须为 /var/MiniClaw/... 绝对路径。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "path": JSONSchema.JSONProperty(type: "string", description: "绝对路径，必须以 /var/MiniClaw/ 开头，例如 /var/MiniClaw/mounts/MyDrive/"),
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
            throw ToolError.invalidParameters("缺少 path 参数")
        }

        do {
            let entries = try FileSystemManager.shared.listDirectory(at: path, sessionID: currentSessionID)
            if entries.isEmpty {
                return ToolResult(success: true, text: "（目录为空或不存在可读内容）")
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
            description: "创建或覆写文本文件，支持 append/create_dirs。仅可写 attachments/workspace/shared/skills，以及已在「设置 → 挂载」中开启「允许写入」的外部挂载文件夹（路径形如 /var/MiniClaw/mounts/<名称>/…）；未开启写入的挂载为只读，写入会被拒绝。修改已有文件优先使用 file_edit。路径必须为 /var/MiniClaw/... 绝对路径。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "path": JSONSchema.JSONProperty(type: "string", description: "绝对路径，必须以 /var/MiniClaw/ 开头"),
                    "content": JSONSchema.JSONProperty(type: "string", description: "文件内容"),
                    "append": JSONSchema.JSONProperty(type: "boolean", description: "是否追加模式（默认 false）"),
                    "create_dirs": JSONSchema.JSONProperty(type: "boolean", description: "是否自动创建父目录（默认 true）"),
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
            throw ToolError.invalidParameters("缺少 path 或 content 参数")
        }

        let append = parameters["append"] as? Bool ?? false
        let createDirs = parameters["create_dirs"] as? Bool ?? true

        do {
            try FileSystemManager.shared.writeFile(at: path, content: content, append: append, createDirs: createDirs, sessionID: currentSessionID)
            return ToolResult(success: true, text: "文件写入成功: \(path)")
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
            description: "精确字符串替换（old_string → new_string）。仅修改已存在的文本文件；写入目录限制与 file_write 相同（含已在「设置 → 挂载」开启「允许写入」的外部挂载文件夹）。路径必须为 /var/MiniClaw/... 绝对路径。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "path": JSONSchema.JSONProperty(type: "string", description: "绝对路径，必须以 /var/MiniClaw/ 开头"),
                    "old_string": JSONSchema.JSONProperty(type: "string", description: "要替换的文本"),
                    "new_string": JSONSchema.JSONProperty(type: "string", description: "替换后的文本"),
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
            throw ToolError.invalidParameters("缺少必要参数")
        }

        do {
            try FileSystemManager.shared.editFile(at: path, oldString: oldStr, newString: newStr, sessionID: currentSessionID)
            return ToolResult(success: true, text: "文件编辑成功: \(path)")
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
            description: "读取图片文件，返回 base64 编码用于 LLM 视觉分析。支持 png/jpg/gif/webp。path 可为 /var/MiniClaw/... 绝对路径，或浏览器工具截图/fetch 返回的 miniclaw://browser/... 链接（会自动转换）。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "path": JSONSchema.JSONProperty(type: "string", description: "图片文件路径"),
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
            throw ToolError.invalidParameters("缺少 path 参数")
        }

        do {
            let url = try FileSystemManager.shared.imageURL(at: path, sessionID: currentSessionID)
            let imageData = try Data(contentsOf: url)
            guard let image = UIImage(data: imageData) else {
                return ToolResult(success: false, text: "无法解码图片: \(path)")
            }
            let base64 = imageData.base64EncodedString()
            let mimeType = mimeTypeFor(path: path)
            return ToolResult(
                success: true,
                text: "图片已读取 (\(Int(image.size.width))x\(Int(image.size.height)))",
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
            description: "使用 Apple Vision 框架本地分析图片，无需网络。可识别图片中的场景/物体分类、文字内容(OCR)、人脸数量等。当用户发送了图片但当前模型不支持原生视觉输入时，应优先调用此工具来理解图片内容。支持 jpg/png/gif/webp/heic 等常见格式。path 可为 /var/MiniClaw/... 绝对路径，或浏览器工具截图/fetch 返回的 miniclaw://browser/... 链接（会自动转换）。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "path": JSONSchema.JSONProperty(type: "string", description: "要分析的图片文件路径（绝对路径或会话内相对路径）"),
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
            throw ToolError.invalidParameters("缺少 path 参数")
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
            return ToolResult(success: false, text: "图片分析失败: \(error)")
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
            description: "读取用户附件中的文件内容。支持纯文本/代码/Markdown/JSON/CSV/XML/HTML/TXT 等（UTF-8）与 PDF（自动抽取文本）；支持 offset/limit 分页或 tail 读取末尾。Office 二进制（docx/xlsx/pptx 等）暂不支持端侧文本抽取，会提示用户导出为 PDF/TXT。路径必须为 /var/MiniClaw/... 绝对路径。当用户发送了文件但当前模型不支持直接读取时，应优先调用本工具读取文件来理解用户意图。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "path": JSONSchema.JSONProperty(type: "string", description: "文件绝对路径，必须以 /var/MiniClaw/ 开头，例如 /var/MiniClaw/attachments/报告.pdf"),
                    "offset": JSONSchema.JSONProperty(type: "integer", description: "起始行（0 起，可选）"),
                    "limit": JSONSchema.JSONProperty(type: "integer", description: "最大读取行数（可选）"),
                    "tail": JSONSchema.JSONProperty(type: "integer", description: "读取文件末尾 N 行；指定后忽略 offset/limit"),
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
            throw ToolError.invalidParameters("缺少 path 参数")
        }
        let offset = parameters["offset"] as? Int
        let limit = parameters["limit"] as? Int
        let tail = parameters["tail"] as? Int

        do {
            let url = try FileSystemManager.shared.resolveAgentPath(path, sessionID: currentSessionID)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return ToolResult(success: false, text: "文件不存在：\(path)")
            }
            let ext = url.pathExtension.lowercased()
            let text: String
            switch ext {
            case "pdf":
                text = Self.extractPDFText(url)
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return ToolResult(success: false, text: "PDF 已读取但未能提取到文本（可能是扫描件/图片型 PDF，端侧暂不支持 OCR）。")
                }
            case "txt", "md", "markdown", "json", "csv", "tsv", "log", "xml", "html", "htm",
                 "yaml", "yml", "swift", "py", "js", "ts", "java", "c", "cpp", "h", "hpp", "m", "mm",
                 "sh", "plist", "toml", "ini", "cfg", "css", "scss", "go", "rs", "kt", "rb", "php",
                 "sql", "r", "tex", "gitignore", "env":
                let raw = try String(contentsOf: url, encoding: .utf8)
                text = Self.paginate(raw, offset: offset, limit: limit, tail: tail)
            case "docx", "xlsx", "pptx", "doc", "xls", "ppt":
                return ToolResult(success: false, text: "暂不支持直接抽取 \(ext.uppercased()) 的文本内容（Office 文档为压缩二进制，端侧无内置解压库）。请先将文件导出为 PDF 或 TXT 后重新发送，再用 read_document 读取。")
            default:
                // 兜底：尝试按 UTF-8 文本读取，失败则给出明确不支持提示。
                if let raw = try? String(contentsOf: url, encoding: .utf8), !raw.isEmpty {
                    text = Self.paginate(raw, offset: offset, limit: limit, tail: tail)
                } else {
                    return ToolResult(success: false, text: "无法以文本方式读取该文件（扩展名：'\(ext)'）。read_document 当前支持纯文本/代码/Markdown/JSON/CSV/XML/HTML 与 PDF。")
                }
            }
            let trimmed = text.count > 60_000
                ? String(text.prefix(60_000)) + "\n…（内容过长，已截断；可使用 offset/limit 分页读取剩余部分）"
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
            description: "写入或修改记忆。target=long_term 时只写 memory/MEMORY.md（App 沙盒内）；target=daily 时写今日 YYYY-MM-DD.md。mode=append 追加（默认）；mode=replace 整体覆盖；mode=edit 把 old_string 替换为 new_string（定点修改某一行）。不得把长期记忆写入 GLOBAL.md；GLOBAL.md 是规则文件。不记录密码、API Key 等敏感信息。禁止用 file_edit/file_write 修改 memory/ 下的文件。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "content": JSONSchema.JSONProperty(type: "string", description: "要记录的记忆内容（mode=append/replace 时必填）"),
                    "target": JSONSchema.JSONProperty(type: "string", description: "必填。long_term 写 MEMORY.md；daily 写今日每日记忆", enum: ["long_term", "daily"]),
                    "mode": JSONSchema.JSONProperty(type: "string", description: "append 追加（默认）；replace 覆盖；edit 定点替换 old_string→new_string", enum: ["append", "replace", "edit"]),
                    "old_string": JSONSchema.JSONProperty(type: "string", description: "mode=edit 时必填，要被替换的原文"),
                    "new_string": JSONSchema.JSONProperty(type: "string", description: "mode=edit 时必填，替换后的新文本"),
                ],
                required: ["target", "mode"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        // 记忆总开关：关闭时任何记忆写入都被拒绝（含后台复盘分身）。
        guard SettingsStore.shared.settings.memory.isEnabled else {
            return ToolResult(success: false, text: "记忆功能已关闭，未写入。")
        }
        guard let target = parameters["target"] as? String else {
            throw ToolError.invalidParameters("缺少 target 参数；必须明确指定 long_term 或 daily")
        }

        let modeString = parameters["mode"] as? String ?? "append"

        do {
            switch target {
            case "long_term":
                switch modeString {
                case "append", "replace":
                    guard let content = parameters["content"] as? String else {
                        throw ToolError.invalidParameters("mode=\(modeString) 时缺少 content 参数")
                    }
                    let mode: LongTermMemoryWriteMode = modeString == "replace" ? .replace : .append
                    try MemoryManager.shared.writeLongTermMemory(content, mode: mode)
                    return ToolResult(success: true, text: "长期记忆已写入 memory/MEMORY.md（App 沙盒内）")
                case "edit":
                    guard let oldString = parameters["old_string"] as? String,
                          let newString = parameters["new_string"] as? String else {
                        throw ToolError.invalidParameters("mode=edit 时缺少 old_string 或 new_string 参数")
                    }
                    try MemoryManager.shared.editMemory(target: .longTerm, oldString: oldString, newString: newString)
                    return ToolResult(success: true, text: "长期记忆已更新 memory/MEMORY.md（App 沙盒内）")
                default:
                    throw ToolError.invalidParameters("mode 必须是 append、replace 或 edit")
                }
            case "daily":
                // 「自动保存每日记忆」开关：关闭时不写入每日记忆文件（不影响每日记忆的读取）。
                guard SettingsStore.shared.settings.memory.autoSaveDaily else {
                    return ToolResult(success: false, text: "每日记忆自动保存已关闭，未写入。")
                }
                switch modeString {
                case "append":
                    guard let content = parameters["content"] as? String else {
                        throw ToolError.invalidParameters("mode=append 时缺少 content 参数")
                    }
                    try MemoryManager.shared.writeDailyMemory(content)
                    return ToolResult(success: true, text: "每日记忆已写入今日日期文件")
                case "edit":
                    guard let oldString = parameters["old_string"] as? String,
                          let newString = parameters["new_string"] as? String else {
                        throw ToolError.invalidParameters("mode=edit 时缺少 old_string 或 new_string 参数")
                    }
                    try MemoryManager.shared.editMemory(target: .daily, oldString: oldString, newString: newString)
                    return ToolResult(success: true, text: "每日记忆已更新今日日期文件")
                default:
                    throw ToolError.invalidParameters("daily 仅支持 mode=append 或 edit")
                }
            default:
                throw ToolError.invalidParameters("target 必须是 long_term 或 daily")
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
            description: "搜索记忆。long_term 仅搜索 memory/MEMORY.md（App 沙盒内）；daily 仅搜索今日每日记忆；all 搜索 MEMORY.md 与所有日期记忆。GLOBAL.md 是规则文件，不属于记忆搜索。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "keyword": JSONSchema.JSONProperty(type: "string", description: "搜索关键字"),
                    "scope": JSONSchema.JSONProperty(type: "string", description: "搜索范围: long_term / daily / all", enum: ["long_term", "daily", "all"]),
                ],
                required: ["keyword"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        // 记忆总开关：关闭时禁止检索记忆（与 memory_write 一致）。
        guard SettingsStore.shared.settings.memory.isEnabled else {
            return ToolResult(success: false, text: "记忆功能已关闭，无法检索。")
        }
        guard let keyword = parameters["keyword"] as? String else {
            throw ToolError.invalidParameters("缺少 keyword 参数")
        }

        let scopeStr = parameters["scope"] as? String ?? "all"
        let scope: MemorySearchScope
        switch scopeStr {
        case "daily": scope = .daily
        case "long_term": scope = .longTerm
        case "all": scope = .all
        default: throw ToolError.invalidParameters("scope 必须是 long_term、daily 或 all")
        }

        let results = await MemoryIndexer.shared.search(keyword: keyword, scope: scope)

        if results.isEmpty {
            return ToolResult(success: true, text: "未找到匹配的记忆")
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
            description: "执行 Shell 命令（通过 iSH Alpine Linux 运行时）。安全契约：每个命令在独立进程中执行、无跨命令 session 持久化（但文件系统与已安装的软件包持久保留）；仅能访问 /var/MiniClaw/ 与已挂载目录；已配置的环境变量会真实注入进程环境，命令中的 $VAR / ${VAR} 由 /bin/sh 从环境展开，机密无需明文、也不会因特殊字符引发注入；子脚本与程序（如 python/node/aws/gcloud）可经 getenv/os.environ/process.env 直接读取这些变量。Alpine 为 BusyBox 环境，命令应避免 bash 特有语法。执行注意：安装软件/下载大文件等长任务请显式传足够大的 timeout；App 进入后台或锁屏后命令会中断（iOS 平台限制），长任务请分步执行（先安装、再验证、再使用），不要单条命令跑完整个流程。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "command": JSONSchema.JSONProperty(type: "string", description: "要执行的命令。可用 $VAR 或 ${VAR} 引用已配置的环境变量（变量已真实注入进程环境，机密无需明文粘贴）"),
                    "timeout": JSONSchema.JSONProperty(type: "integer", description: "超时时间（秒），默认 900。安装大型软件包/下载大文件/编译等长任务请显式传大值（如 3600）；App 进后台或锁屏会导致命令中断，长任务务必分步执行"),
                    "delay": JSONSchema.JSONProperty(type: "integer", description: "可选：执行前等待的秒数（默认 0）。等待发生在 App 侧、不占用 iSH shell——需要轮询等待（等服务启动/后台任务完成）时用它代替命令里的 sleep，这样等待期间其他命令仍可并发执行。轮询模式：delay 链式调用（如 delay=10 检查 → 未完成再 delay=10 检查），直到拿到结果或达到合理重试上限"),
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
        // 真实注入进程环境：已配置的环境变量经 /bin/sh 的进程环境下发，
        // 命令里写 $VAR / ${VAR} 由 sh 自身从环境展开（机密不进命令字符串，
        // 也不受特殊字符导致的命令注入影响）。不再使用字符串替换式展开。
        let environment = EnvVarStore.environmentDictionary

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
                bashReminder = "\n\n<system-reminder>检测到 bash 特有语法（\(names)），本执行器为 busybox sh 可能不兼容；如执行异常请改写为 POSIX sh 语法，或先用 apk add bash 安装 bash 后以 bash -lc 执行。</system-reminder>"
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
            let full = output.isEmpty ? "(无输出)" : output
            let masked = maskSecrets(full)
            let thresholdBytes = SettingsStore.shared.settings.files.autoOffloadThresholdKB * 1024
            var final = FileSystemManager.shared.offloadIfLarge(masked, thresholdBytes: thresholdBytes, sessionID: currentSessionID)
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
    private func maskSecrets(_ output: String) -> String {
        guard SettingsStore.shared.settings.envvarsPrivacyMode else { return output }
        var text = output
        for v in SettingsStore.shared.settings.envvars where !v.value.isEmpty {
            text = text.replacingOccurrences(of: v.value, with: "***")
        }
        return text
    }
}
