import Foundation
import Vision
import UIKit

// MARK: - Vision Analysis Result

struct VisionAnalysisResult: Sendable {
    var classification: [VisionLabel] = []
    var ocrText: String = ""
    var faceCount: Int = 0
    var imageSize: CGSize = .zero
    var error: String?

    struct VisionLabel: Codable, Sendable {
        let label: String
        let confidence: Double
    }

    /// 格式化为 LLM 可读的结构化文本（模仿 apple-vision 输出格式）。
    func formattedText() -> String {
        var lines: [String] = []
        lines.append("{")
        lines.append("  \"action\" : \"analyze\",")

        // Classification
        if !classification.isEmpty {
            lines.append("  \"classification\" : [")
            for (idx, item) in classification.enumerated() {
                let comma = idx == classification.count - 1 ? "" : ","
                lines.append("    {")
                lines.append("      \"confidence\" : \(String(format: "%.15f", item.confidence)),")
                lines.append("      \"label\" : \"\(item.label)\"")
                lines.append("    }\(comma)")
            }
            lines.append("  ],")
        } else {
            lines.append("  \"classification\" : [],")
        }

        // OCR
        let escapedOCR = ocrText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        lines.append("  \"ocr\" : {")
        lines.append("    \"block_count\" : \(ocrText.isEmpty ? 0 : 1),")
        lines.append("    \"text\" : \"\(escapedOCR)\"")
        lines.append("  },")

        // Faces
        lines.append("  \"faces\" : {")
        lines.append("    \"count\" : \(faceCount)")
        lines.append("  },")

        // Image metadata
        lines.append("  \"image\" : {")
        if imageSize.width > 0 && imageSize.height > 0 {
            lines.append("    \"height\" : \(Int(imageSize.height)),")
            lines.append("    \"width\" : \(Int(imageSize.width))")
        } else {
            lines.append("    \"height\" : 0,")
            lines.append("    \"width\" : 0")
        }
        lines.append("  },")

        // Tool identifier
        lines.append("  \"ok\" : true,")
        let ts = ISO8601DateFormatter().string(from: Date())
        lines.append("  \"timestamp\" : \"\(ts)\",")
        lines.append("  \"tool\" : \"apple-vision\"")
        lines.append("}")

        return lines.joined(separator: "\n")
    }
}

// MARK: - Vision Analyzer

/// 封装 Apple Vision Framework，提供本地图片分析能力（分类 / OCR / 人脸检测）。
/// 无需网络，纯设备端执行，适用于所有模型（包括不支持原生视觉输入的文本模型）。
final class VisionAnalyzer: @unchecked Sendable {

    nonisolated(unsafe) static let shared = VisionAnalyzer()

    private init() {}

    /// 分析指定路径的图片，返回结构化结果。
    /// - Parameter path: 图片文件绝对路径（支持 jpg/png/gif/webp/heic 等 UIImage 可解码格式）
    /// - Returns: VisionAnalysisResult，包含分类标签、OCR 文本、人脸数量等
    /// 分析指定路径的图片，返回结构化结果。
    /// - Parameter path: 图片文件绝对路径（支持 jpg/png/gif/webp/heic 等 UIImage 可解码格式）
    /// - Returns: VisionAnalysisResult，包含分类标签、OCR 文本、人脸数量等
    /// - Note: 整段 Vision 计算与图片读取是同步阻塞的（VNImageRequestHandler.perform 在调用线程跑），
    ///   故用 withCheckedContinuation 卸载到全局队列执行——既避免占用协作线程池，更绝不阻塞主线程
    ///   （对齐原则：所有重 IO/计算一律 async 化，主线程永不真阻塞）。
    func analyze(imageAt path: String) async -> VisionAnalysisResult {
        await withCheckedContinuation { (cont: CheckedContinuation<VisionAnalysisResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: Self.performSyncAnalysis(path))
            }
        }
    }

    /// 同步执行 Vision 分析（在全局队列上跑，不占协作线程池）。
    private static func performSyncAnalysis(_ path: String) -> VisionAnalysisResult {
        AppLogger.shared.info("Vision analyze ENTER: \(path)", category: "Vision")
        let url = URL(fileURLWithPath: path)
        guard let imageData = try? Data(contentsOf: url),
              let image = UIImage(data: imageData) else {
            var result = VisionAnalysisResult()
            result.error = "无法读取或解码图片文件: \(path)"
            return result
        }

        var finalResult = VisionAnalysisResult()
        finalResult.imageSize = image.size
        guard let cgImage = image.cgImage else {
            finalResult.error = "无法获取 CGImage"
            return finalResult
        }

        let semaphore = DispatchSemaphore(value: 0)
        var completedCount = 0
        let totalRequests = 3
        let lock = NSLock()

        func markCompleted() {
            lock.lock()
            defer { lock.unlock() }
            completedCount += 1
            semaphore.signal()
        }

        // --- 1. 场景分类 (VNClassifyImageRequest) ---
        let classifyReq = VNClassifyImageRequest { request, error in
            defer { markCompleted() }
            if let error = error {
                AppLogger.shared.info("Vision 分类请求失败: \(error.localizedDescription)", category: "Vision")
                return
            }
            guard let results = request.results as? [VNClassificationObservation] else { return }
            // 取 confidence > 0 的结果，最多返回 10 个
            finalResult.classification = results.prefix(10).compactMap { obs in
                guard obs.confidence > 0 else { return nil }
                return VisionAnalysisResult.VisionLabel(
                    label: obs.identifier,
                    confidence: Double(obs.confidence)
                )
            }
        }

        // --- 2. 文字识别 OCR (VNRecognizeTextRequest) ---
        let ocrReq = VNRecognizeTextRequest { request, error in
            defer { markCompleted() }
            if let error = error {
                AppLogger.shared.info("Vision OCR 请求失败: \(error.localizedDescription)", category: "Vision")
                return
            }
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
            // 按位置排序（从上到下）
            let sorted = observations.sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }
            var texts: [String] = []
            for obs in sorted {
                if let topCandidate = obs.topCandidates(1).first {
                    texts.append(topCandidate.string)
                }
            }
            finalResult.ocrText = texts.joined(separator: "\n")
        }
        // 同时识别中英文
        ocrReq.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        // 使用精确模式（更慢但更准）
        ocrReq.recognitionLevel = .accurate

        // --- 3. 人脸检测 (VNDetectFaceRectanglesRequest) ---
        let faceReq = VNDetectFaceRectanglesRequest { request, error in
            defer { markCompleted() }
            if let error = error {
                AppLogger.shared.info("Vision 人脸检测失败: \(error.localizedDescription)", category: "Vision")
                return
            }
            guard let faces = request.results as? [VNFaceObservation] else { return }
            finalResult.faceCount = faces.count
        }

        // 并发执行三个请求
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([classifyReq, ocrReq, faceReq])
        } catch {
            AppLogger.shared.error("Vision 执行失败: \(error.localizedDescription)", category: "Vision")
            finalResult.error = error.localizedDescription
            return finalResult
        }

        // 等待所有异步回调完成
        for _ in 0..<totalRequests {
            _ = semaphore.wait(timeout: .now() + 10)
        }

        AppLogger.shared.info("Vision analyze DONE: \(path)", category: "Vision")
        return finalResult
    }
}
