import Foundation
import UIKit
import PDFKit

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

