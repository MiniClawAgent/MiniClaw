import Foundation
import UIKit
import PDFKit

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

