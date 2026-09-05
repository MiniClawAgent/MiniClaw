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
            description: String(localized: "file_read_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "path": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_abs_path_required")),
                    "offset": JSONSchema.JSONProperty(type: "integer", description: String(localized: "param_start_line")),
                    "limit": JSONSchema.JSONProperty(type: "integer", description: String(localized: "param_max_read_lines")),
                    "tail": JSONSchema.JSONProperty(type: "integer", description: String(localized: "param_tail_lines")),
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
            throw ToolError.invalidParameters(String(localized: "err_missing_path"))
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
            description: String(localized: "list_dir_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "path": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_abs_path_example")),
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
            throw ToolError.invalidParameters(String(localized: "err_missing_path"))
        }

        do {
            let entries = try FileSystemManager.shared.listDirectory(at: path, sessionID: currentSessionID)
            if entries.isEmpty {
                return ToolResult(success: true, text: String(localized: "dir_empty_or_unreadable"))
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
            description: String(localized: "file_write_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "path": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_abs_path_required")),
                    "content": JSONSchema.JSONProperty(type: "string", description: String(localized: "file_content")),
                    "append": JSONSchema.JSONProperty(type: "boolean", description: String(localized: "param_append_mode")),
                    "create_dirs": JSONSchema.JSONProperty(type: "boolean", description: String(localized: "param_create_dirs")),
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
            throw ToolError.invalidParameters(String(localized: "err_missing_path_content"))
        }

        let append = parameters["append"] as? Bool ?? false
        let createDirs = parameters["create_dirs"] as? Bool ?? true

        do {
            try FileSystemManager.shared.writeFile(at: path, content: content, append: append, createDirs: createDirs, sessionID: currentSessionID)
            return ToolResult(success: true, text: String(format: String(localized: "core_file_written"), path))
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
            description: String(localized: "file_edit_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "path": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_abs_path_required")),
                    "old_string": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_text_to_replace")),
                    "new_string": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_replacement_text")),
                    "replace_all": JSONSchema.JSONProperty(type: "boolean", description: String(localized: "param_replace_all")),
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
            throw ToolError.invalidParameters(String(localized: "err_missing_required"))
        }
        let replaceAll = parameters["replace_all"] as? Bool ?? false
        guard !oldStr.isEmpty else {
            return ToolResult(success: false, text: String(localized: "err_edit_empty_old"))
        }

        // 经 FSM.readFile 读取：路径校验/二进制十六进制预览/notFound 全部复用
        let content: String
        do {
            content = try FileSystemManager.shared.readFile(at: path, sessionID: currentSessionID)
        } catch let FileError.notFound(p) {
            return ToolResult(success: false, text: String(format: String(localized: "err_edit_use_write"), p))
        } catch {
            return ToolResult(success: false, text: error.localizedDescription)
        }

        // 严格匹配
        var ranges = Self.allRanges(of: oldStr, in: content)

        // 模糊降级（2026-09-05，对齐 OpenMinis）：模型重发代码时常见智能引号
        // 变直引号、行尾空白丢失、连续空格合并——两边规范化后再匹配，但替换
        // 作用于原文精确范围（保留文件真实字节），成功消息注明 fuzzy。
        var fuzzy = false
        if ranges.isEmpty {
            let (normContent, contentMap) = Self.fuzzyNormalize(content)
            let (normOld, oldMap) = Self.fuzzyNormalize(oldStr)
            var mapped: [Range<String.Index>] = []
            var scanIdx = normContent.startIndex
            while let r = normContent.range(of: normOld, range: scanIdx..<normContent.endIndex) {
                mapped.append(r)
                scanIdx = r.upperBound == scanIdx ? r.upperBound : r.upperBound
                if r.upperBound == scanIdx { break }
                scanIdx = r.upperBound
            }
            // 归一化偏移 → 原文 String.Index 区间（map 记录归一化字符对应的原文字符）
            var original: [Range<String.Index>] = []
            for r in mapped {
                let startOff = normContent.distance(from: normContent.startIndex, to: r.lowerBound)
                let endOff = normContent.distance(from: normContent.startIndex, to: r.upperBound)
                guard startOff < contentMap.count, endOff <= contentMap.count, endOff > startOff else { continue }
                let lo = contentMap[startOff]
                let hi = contentMap[endOff - 1]
                original.append(lo..<content.index(after: hi))
            }
            ranges = original
            fuzzy = !ranges.isEmpty
        }

        guard !ranges.isEmpty else {
            let preview = String(content.prefix(300))
            return ToolResult(success: false, text: String(format: String(localized: "err_edit_not_found_hint"), path, preview))
        }

        // 多命中防护：未声明 replace_all 时报错并告知命中数（此前静默替换第一处）
        if ranges.count > 1 && !replaceAll {
            return ToolResult(success: false, text: String(format: String(localized: "err_edit_multi_match"), path, ranges.count))
        }

        // 从后向前替换，保持前面的索引有效
        var updated = content
        for r in ranges.reversed() {
            updated.replaceSubrange(r, with: newStr)
        }

        do {
            // 走 FSM.writeFile：写权限校验 + 原子写（复用既有校验，不重复造轮子）
            try FileSystemManager.shared.writeFile(at: path, content: updated, append: false, createDirs: false, sessionID: currentSessionID)
        } catch {
            return ToolResult(success: false, text: error.localizedDescription)
        }
        var text = String(format: String(localized: "core_file_edited"), path) + "（\(ranges.count) 处）"
        if fuzzy { text += String(localized: "file_edit_fuzzy_note") }
        return ToolResult(success: true, text: text)
    }

    /// 全部命中区间（首次出现向后推进，支持重叠规避）。
    private static func allRanges(of needle: String, in haystack: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var idx = haystack.startIndex
        while let r = haystack.range(of: needle, range: idx..<haystack.endIndex) {
            ranges.append(r)
            idx = r.upperBound == idx ? haystack.index(after: idx) : r.upperBound
        }
        return ranges
    }

    /// 模糊规范化：智能引号→直引号、连续空白折叠为单空格、行尾空白去除。
    /// 返回规范化文本 + 每个规范化字符对应的原文字符索引（用于映射回原文区间）。
    private static func fuzzyNormalize(_ s: String) -> (text: String, map: [String.Index]) {
        var out = ""
        var map: [String.Index] = []
        var previousWasSpace = false
        var idx = s.startIndex
        while idx < s.endIndex {
            let ch = s[idx]
            if ch == " " || ch == "\t" {
                let next = s.index(after: idx)
                let isTrailing = next == s.endIndex || s[next] == "\n"
                if previousWasSpace || isTrailing {
                    previousWasSpace = true
                    idx = s.index(after: idx)
                    continue
                }
                out.append(" ")
                map.append(idx)
                previousWasSpace = true
                idx = s.index(after: idx)
                continue
            }
            previousWasSpace = false
            switch ch {
            case "\u{201C}", "\u{201D}": out.append("\"")
            case "\u{2018}", "\u{2019}": out.append("'")
            default: out.append(ch)
            }
            map.append(idx)
            idx = s.index(after: idx)
        }
        return (out, map)
    }
}

