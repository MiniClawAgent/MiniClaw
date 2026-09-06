import Foundation
import UIKit
import PDFKit

/// 读取图片并以 base64 返回，供支持原生视觉输入的模型直接「看图」。
///
/// 工具名归 `apple-` 前缀族：与 `apple-vision` 同为本文件的图片能力，
/// 都走 Apple 框架（UIKit / Vision）。会话 ID 用于解析会话隔离路径。
struct ReadImageTool: AgentTool {
    let name = "apple-image"
    /// 当前会话 ID：注入后读取的图片走本会话的隔离命名空间。
    let currentSessionID: UUID?
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-image",
            description: String(localized: "apple_image_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "path": JSONSchema.JSONProperty(type: "string", description: String(localized: "image_path_param")),
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
            let url = try FileSystemManager.shared.imageURL(at: path, sessionID: currentSessionID)
            let imageData = try Data(contentsOf: url)
            guard let image = UIImage(data: imageData) else {
                return ToolResult(success: false, text: String(format: String(localized: "core_image_decode_failed"), path))
            }
            // 视觉最佳分辨率护栏（2026-09-07）：长边 >1568px 时降采样再编码——
            // base64 体积与 token 双降，识别效果不降（视觉模型输入最佳区间）。
            let maxSide: CGFloat = 1568
            let outImage: UIImage
            if max(image.size.width, image.size.height) > maxSide {
                let scale = maxSide / max(image.size.width, image.size.height)
                let newSize = CGSize(width: floor(image.size.width * scale),
                                     height: floor(image.size.height * scale))
                outImage = UIGraphicsImageRenderer(size: newSize).image { _ in
                    image.draw(in: CGRect(origin: .zero, size: newSize))
                }
            } else {
                outImage = image
            }
            // 统一 JPEG 编码（质量 0.85）：截图类内容 PNG 压缩率极差（1.5MB+），
            // JPEG 同画质体积 1/6~1/8——服务商对请求体大小有上限（HTTP 413 实锤），
            // 视觉输入无需透明通道。PNG 截图 1.6MB → JPEG ~250KB。
            let outData = outImage.jpegData(compressionQuality: 0.85) ?? imageData
            let base64 = outData.base64EncodedString()
            return ToolResult(
                success: true,
                text: String(format: String(localized: "core_image_read"), Int(outImage.size.width), Int(outImage.size.height)),
                data: ["base64": base64, "mime_type": "image/jpeg"]
            )
        } catch {
            return ToolResult(success: false, text: error.localizedDescription)
        }
    }
}

// MARK: - Apple Vision Tool (Vision Framework)

/// 使用 Apple 本地 Vision 框架分析图片，返回场景分类、OCR 文字、人脸检测结果。
/// 适用于**所有模型**——即使是不支持原生视觉输入的文本模型（如 DeepSeek），
/// 也可以通过此工具"看到"图片内容。这是 MiniClaw 的核心视觉能力工具。
///
/// 原名 `vision_analyze`：改用 `apple-` 前缀族命名，与其余 Apple 框架能力一致，
/// 并随之迁进 `builtinFactories`（工具会出现在插件列表，可受插件开关控制）。
struct VisionAnalyzeTool: AgentTool {
    let name = "apple-vision"
    let currentSessionID: UUID?
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-vision",
            description: String(localized: "apple_vision_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "path": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_image_path")),
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
            return ToolResult(success: false, text: String(format: String(localized: "core_image_analysis_failed"), error))
        }

        // 返回格式化后的结构化文本（LLM 可直接阅读）
        return ToolResult(
            success: true,
            text: result.formattedText()
        )
    }
}

