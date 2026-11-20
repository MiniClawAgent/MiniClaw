import Foundation
import UIKit
import PDFKit

struct ReadDocumentTool: AgentTool {
    let name = "read-document"
    let currentSessionID: UUID?
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "read-document",
            description: String(localized: "read_document_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "path": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_file_abs_path")),
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
        guard let path = parameters["path"] as? String, !path.isEmpty else {
            throw ToolError.invalidParameters(String(localized: "err_missing_path"))
        }
        let offset = parameters["offset"] as? Int
        let limit = parameters["limit"] as? Int
        let tail = parameters["tail"] as? Int

        do {
            let url = try FileSystemManager.shared.resolveAgentPath(path, sessionID: currentSessionID)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return ToolResult(success: false, text: String(format: String(localized: "core_file_not_found"), path))
            }
            let ext = url.pathExtension.lowercased()
            let text: String
            switch ext {
            case "pdf":
                text = Self.extractPDFText(url)
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return ToolResult(success: false, text: String(localized: "pdf_no_text"))
                }
            case "txt", "md", "markdown", "json", "csv", "tsv", "log", "xml", "html", "htm",
                 "yaml", "yml", "swift", "py", "js", "ts", "java", "c", "cpp", "h", "hpp", "m", "mm",
                 "sh", "plist", "toml", "ini", "cfg", "css", "scss", "go", "rs", "kt", "rb", "php",
                 "sql", "r", "tex", "gitignore", "env":
                let raw = try String(contentsOf: url, encoding: .utf8)
                text = Self.paginate(raw, offset: offset, limit: limit, tail: tail)
            case "docx", "xlsx", "pptx", "doc", "xls", "ppt":
                return ToolResult(success: false, text: String(format: String(localized: "core_unsupported_office"), ext.uppercased()))
            default:
                // 兜底：尝试按 UTF-8 文本读取，失败则给出明确不支持提示。
                if let raw = try? String(contentsOf: url, encoding: .utf8), !raw.isEmpty {
                    text = Self.paginate(raw, offset: offset, limit: limit, tail: tail)
                } else {
                    return ToolResult(success: false, text: String(format: String(localized: "core_unreadable_text"), ext))
                }
            }
            let trimmed = text.count > 60_000
                ? String(text.prefix(60_000)) + String(localized: "truncated_paging_hint")
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

