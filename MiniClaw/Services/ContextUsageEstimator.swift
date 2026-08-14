import Foundation
import ImageIO

/// 全口径上下文估算：消息 + 工具 schema + 易变段 + 多模态。
///
/// 文本按内容类型分密度：自然语言 ~4 字符/词元（中文 ~1.6 字/词元），
/// JSON / 代码 ~3 字符/词元（符号密集，token 更碎）。
enum ContextUsageEstimator {

    /// 文本密度档位。
    enum Density {
        /// 自然语言（system prompt、对话正文）。
        case prose
        /// JSON / 代码 / 工具参数（符号密集）。
        case structured

        var latinDivisor: Double {
            switch self {
            case .prose: return 4.0
            case .structured: return 3.0
            }
        }

        var cjkDivisor: Double {
            switch self {
            case .prose: return 1.6
            case .structured: return 1.4
            }
        }
    }

    /// 每条消息的固定结构开销（role、分隔 token 等）。OpenAI 官方口径约 3~4。
    static let perMessageOverhead = 4
    /// tools 数组本身的固定包装开销。
    static let toolsWrapperOverhead = 16

    // MARK: 文本

    static func estimate(text: String, density: Density = .prose) -> Int {
        guard !text.isEmpty else { return 0 }
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if (0x3400...0x9FFF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value) {
                cjk += 1
            } else if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                other += 1
            }
        }
        return Int((Double(cjk) / density.cjkDivisor).rounded(.up))
            + Int((Double(other) / density.latinDivisor).rounded(.up))
    }

    // MARK: 工具 schema

    /// 工具定义的 token 开销：把 schema 编码成 JSON 后按 structured 密度估算。
    /// 结果按 schema 指纹缓存——工具集在一次会话内基本不变，避免每轮重复编码大 JSON。
    static func estimate(tools: [ToolSchema]?) -> Int {
        guard let tools, !tools.isEmpty else { return 0 }
        let fingerprint = tools.reduce(into: Hasher()) { hasher, tool in
            hasher.combine(tool.function.name)
            hasher.combine(tool.function.description.count)
        }.finalize()
        if let cached = toolTokenCache.value(for: fingerprint, count: tools.count) {
            return cached
        }
        var total = toolsWrapperOverhead
        if let data = try? JSONEncoder().encode(tools),
           let json = String(data: data, encoding: .utf8) {
            total += estimate(text: json, density: .structured)
        } else {
            // 兜底：按名称 + 描述粗算。
            for tool in tools {
                total += estimate(text: tool.function.name, density: .structured)
                total += estimate(text: tool.function.description, density: .prose)
                total += 40
            }
        }
        toolTokenCache.store(total, for: fingerprint, count: tools.count)
        return total
    }

    // MARK: 多模态

    /// 图片 词元 估算，采用 OpenAI 的 tile 口径：85 + 170 * ceil(w/512) * ceil(h/512)（high detail）。
    /// 只读图片元数据拿宽高（不整图解码），并按 data URI 指纹缓存，避免重复解码开销。
    static func estimateImageTokens(dataURI: String, detail: String) -> Int {
        let fingerprint = imageFingerprint(dataURI)
        if let cached = imageTokenCache.value(for: fingerprint, count: dataURI.count) {
            return cached
        }

        var tokens = 85 // 基础开销
        if detail.lowercased() != "low" {
            if let size = imagePixelSize(dataURI: dataURI) {
                // 先按 OpenAI 规则缩放：长边 <= 2048，短边 <= 768。
                var w = Double(size.width)
                var h = Double(size.height)
                let longSide = max(w, h)
                if longSide > 2048 {
                    let scale = 2048 / longSide
                    w *= scale
                    h *= scale
                }
                let shortSide = min(w, h)
                if shortSide > 768 {
                    let scale = 768 / shortSide
                    w *= scale
                    h *= scale
                }
                let tiles = Int(ceil(w / 512)) * Int(ceil(h / 512))
                tokens = 85 + 170 * max(1, tiles)
            } else {
                // 拿不到尺寸时按 base64 体积粗估（限制在 1 ~ 6 个 tile 之间）。
                let approxTiles = min(6, max(1, dataURI.count / 200_000))
                tokens = 85 + 170 * approxTiles
            }
        }
        imageTokenCache.store(tokens, for: fingerprint, count: dataURI.count)
        return tokens
    }

    /// 音频 / 文件附件的粗略开销：按 base64 体积折算（无官方公式，保守估计）。
    static func estimateBinaryTokens(base64Length: Int) -> Int {
        guard base64Length > 0 else { return 0 }
        // base64 每 4 字符 = 3 字节；按每 KB 原始数据约 12 词元 折算，封顶 8K。
        let bytes = base64Length / 4 * 3
        return min(8_192, max(16, bytes / 1024 * 12))
    }

    // MARK: 消息

    /// 估算一条消息的 词元（含结构开销）。
    static func estimate(message: ChatCompletionMessage) -> (text: Int, media: Int) {
        var text = 0
        var media = 0

        switch message.content {
        case .some(.text(let raw)):
            text += estimate(text: raw, density: message.role == "tool" ? .structured : .prose)
        case .some(.parts(let parts)):
            for part in parts {
                switch part {
                case .text(let raw):
                    text += estimate(text: raw, density: .prose)
                case .imageURL(let url, let detail):
                    media += estimateImageTokens(dataURI: url, detail: detail)
                case .inputAudio(let data, _):
                    media += estimateBinaryTokens(base64Length: data.count)
                case .file(let fileData, _, let filename):
                    media += estimateBinaryTokens(base64Length: fileData?.count ?? 0)
                    text += estimate(text: filename ?? "", density: .prose)
                }
            }
        case .none:
            break
        }

        if let volatile = message.volatileSuffix, !volatile.isEmpty {
            text += estimate(text: volatile, density: .prose)
        }
        if let name = message.name {
            text += estimate(text: name, density: .structured)
        }
        if let calls = message.toolCalls {
            for call in calls {
                text += estimate(text: call.function.name, density: .structured)
                text += estimate(text: call.function.arguments, density: .structured)
                text += 8 // tool_call 结构（id/type 包装）
            }
        }
        return (text, media)
    }

    /// 估算一次完整请求的上下文占用（这就是真正发给模型的那一份）。
    static func breakdown(messages: [ChatCompletionMessage], tools: [ToolSchema]?) -> ContextUsageBreakdown {
        var result = ContextUsageBreakdown()
        result.tools = estimate(tools: tools)
        result.overhead = messages.count * perMessageOverhead

        // 最后一条 user 消息视作「本轮输入」，其余为历史。
        let lastUserIndex = messages.lastIndex { $0.role == "user" }
        for (index, message) in messages.enumerated() {
            let (text, media) = estimate(message: message)
            result.media += media
            if message.role == "system" || message.role == "developer" {
                result.system += text
            } else if index == lastUserIndex {
                result.current += text
            } else {
                result.history += text
            }
        }
        return result
    }

    /// 便捷入口：只要总量。
    static func estimate(messages: [ChatCompletionMessage], tools: [ToolSchema]?) -> Int {
        breakdown(messages: messages, tools: tools).total
    }

    // MARK: - 私有：缓存与图片元数据

    /// 轻量单槽缓存（工具集/图片在一次会话里基本不变，单槽足够且零并发风险）。
    private final class SingleSlotCache: @unchecked Sendable {
        private let lock = NSLock()
        private var key: Int?
        private var count: Int = -1
        private var stored: Int = 0

        func value(for key: Int, count: Int) -> Int? {
            lock.lock(); defer { lock.unlock() }
            guard self.key == key, self.count == count else { return nil }
            return stored
        }

        func store(_ value: Int, for key: Int, count: Int) {
            lock.lock(); defer { lock.unlock() }
            self.key = key
            self.count = count
            self.stored = value
        }
    }

    private static let toolTokenCache = SingleSlotCache()
    private static let imageTokenCache = SingleSlotCache()

    /// data URI 的廉价指纹：长度 + 首尾片段哈希（避免对整个 base64 求哈希）。
    private static func imageFingerprint(_ dataURI: String) -> Int {
        var hasher = Hasher()
        hasher.combine(dataURI.count)
        hasher.combine(dataURI.prefix(64))
        hasher.combine(dataURI.suffix(32))
        return hasher.finalize()
    }

    /// 只读图片头部元数据获取像素尺寸（不做整图解码）。
    private static func imagePixelSize(dataURI: String) -> (width: Int, height: Int)? {
        guard let commaIndex = dataURI.firstIndex(of: ","), dataURI.hasPrefix("data:") else { return nil }
        let base64 = String(dataURI[dataURI.index(after: commaIndex)...])
        // 只取前 64KB 足以覆盖 JPEG/PNG/HEIC 的头部信息。
        let headSlice = base64.count > 87_400 ? String(base64.prefix(87_400)) : base64
        guard let data = Data(base64Encoded: headSlice, options: .ignoreUnknownCharacters) else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }
}

// MARK: - 真值校准

/// 用服务商回传的真实 prompt_tokens 校准本地估算：
/// factor = 真实 / 估算，后续未测量的轮次乘以该因子。
/// 单会话内工具集与语言风格稳定，一次校准即可显著收敛误差（对标 的真值基线思路）。
