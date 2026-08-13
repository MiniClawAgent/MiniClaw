import Foundation
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 上下文预算与占用估算
//
// 设计要点（对标常见 Agent 实现的上下文管理）：
// 1. 统计口径必须等于「真正发给模型的那一份请求」：system(稳定段 + 易变段) + 工具 schema 定义
//    + 历史消息 + 本轮输入 + 多模态图片，而不只是消息正文（旧实现漏算工具定义与易变段，系统性低估）。
// 2. 有 API 真值就不用估算：服务商回传的 prompt_tokens 是权威值，用它校准估算器（比例因子），
//    后续未测量的轮次按校准后的估算走（ 的「真值基线 + 增量」思路）。
// 3. 阈值按上下文窗口分档：小窗口按比例早压，大窗口按「剩余绝对余量」压，
//    避免 200K 窗口在 160K 就压缩、白白浪费 40K 可用空间（ ContextPolicy 思路）。

/// 上下文占用明细（供 UI 拆解展示，仿 /context 拆解）。
struct ContextUsageBreakdown: Equatable, Sendable {
    /// 系统提示词（稳定段 + 易变段）。
    var system: Int = 0
    /// 工具 schema 定义（API tools 数组的固定开销）。
    var tools: Int = 0
    /// 历史对话（含工具调用与工具结果文本）。
    var history: Int = 0
    /// 本轮用户输入（messages 中最后一条 user 消息）。
    var current: Int = 0
    /// 多模态图片/音频/文件的附加 词元。
    var media: Int = 0
    /// 消息结构固定开销（role/分隔符等）。
    var overhead: Int = 0

    var total: Int { system + tools + history + current + media + overhead }
}

/// 一次上下文占用快照：给 UI 圆环与详情页使用。
struct ContextUsageSnapshot: Equatable, Sendable {
    /// 估算/实测的已占用 词元。
    let tokens: Int
    /// 模型上下文窗口；<= 0 表示未配置（UI 显示 ∞）。
    let window: Int
    /// 触发自动压缩的 token 阈值（0 = 该档位不自动压缩）。
    let compactThreshold: Int
    /// 是否来自服务商回传的真实 prompt_tokens（true）还是本地估算（false）。
    let measured: Bool
    /// 明细拆解（measured 时为「上次估算的明细按真值比例缩放」的近似值）。
    let breakdown: ContextUsageBreakdown
    /// 生成时间（UI 可展示"刚刚更新"）。
    let updatedAt: Date

    var isUnlimited: Bool { window <= 0 }

    /// 占用比例（0...1）；无窗口返回 0。
    var ratio: Double {
        guard window > 0 else { return 0 }
        return min(1.0, max(0, Double(tokens) / Double(window)))
    }

    /// 压缩阈值在环上的位置（0...1），UI 用它决定「变红点」，保证圆环变红 == 真的会压缩。
    var thresholdRatio: Double {
        guard window > 0, compactThreshold > 0 else { return 0.8 }
        return min(1.0, max(0.1, Double(compactThreshold) / Double(window)))
    }

    static let empty = ContextUsageSnapshot(
        tokens: 0, window: 0, compactThreshold: 0,
        measured: false, breakdown: ContextUsageBreakdown(), updatedAt: .distantPast
    )
}

// MARK: - 分档策略

/// 按上下文窗口大小分档给出压缩/警戒阈值。
///
/// 分档理由（~80% 占用触发自动压缩）：
/// - 小窗口（< 32K）：输出本身就要占掉不少空间，按 70% 提早压缩，否则一次长回复就爆窗。
/// - 中窗口（32K–128K）：沿用业界通行的 80%。
/// - 大窗口（≥ 128K）：改用「剩余绝对余量」——留 24K 给后续输入与输出即可，
///   等价比例约 88%（200K 窗口），避免过早压缩浪费上下文。
struct ContextPolicy: Equatable, Sendable {
    /// 上下文窗口（<= 0 表示未知/无限制）。
    let window: Int
    /// 触发自动压缩的 词元 数（0 = 不自动压缩）。
    let compactThreshold: Int
    /// 硬裁剪预算：即便压缩失败，也不应把超过该 词元 数的消息发出去。
    let hardTrimBudget: Int
    /// 是否允许自动压缩（窗口未知时关闭）。
    let autoCompactEnabled: Bool

    init(window: Int, reservedOutputTokens: Int = 0) {
        self.window = window
        guard window > 0 else {
            compactThreshold = 0
            hardTrimBudget = 0
            autoCompactEnabled = false
            return
        }

        // 为模型输出预留空间（端点配置了 max_tokens 就按它，否则按窗口的 8% 兜底、上限 8K）。
        let reserve = reservedOutputTokens > 0
            ? min(reservedOutputTokens, max(1_024, window / 4))
            : min(8_192, max(1_024, window * 8 / 100))

        let threshold: Int
        if window < 32_000 {
            threshold = Int(Double(window) * 0.70)
        } else if window < 128_000 {
            threshold = Int(Double(window) * 0.80)
        } else {
            // 大窗口：留 24K 余量即可，但不低于 80%（防止极大窗口下阈值贴顶）。
            threshold = max(Int(Double(window) * 0.80), window - 24_000)
        }

        compactThreshold = max(1_000, threshold)
        // 硬裁剪线：窗口减去输出预留，再留 2% 安全边际。
        hardTrimBudget = max(compactThreshold, Int(Double(window - reserve) * 0.98))
        autoCompactEnabled = true
    }

    /// 当前占用是否应触发压缩。
    func shouldCompact(tokens: Int) -> Bool {
        autoCompactEnabled && compactThreshold > 0 && tokens >= compactThreshold
    }

    /// 该占用是否已越过硬裁剪线（压缩失败时仍需丢弃旧消息）。
    func exceedsHardTrim(tokens: Int) -> Bool {
        hardTrimBudget > 0 && tokens > hardTrimBudget
    }

    /// 阈值对应的占比（UI 红线位置）。
    var thresholdRatio: Double {
        guard window > 0, compactThreshold > 0 else { return 0.8 }
        return min(1.0, Double(compactThreshold) / Double(window))
    }
}

// MARK: - 估算器

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
final class ContextCalibrator: @unchecked Sendable {
    private let lock = NSLock()
    private var factor: Double = 1.0
    private var samples: Int = 0

    /// 记录一次真值样本。
    /// - Parameters:
    ///   - measured: 服务商回传的 prompt_tokens。
    ///   - estimated: 同一份请求的本地估算值。
    func calibrate(measured: Int, estimated: Int) {
        guard measured > 0, estimated > 0 else { return }
        let raw = Double(measured) / Double(estimated)
        // 限幅，避免异常样本（如服务商只回传增量）把因子带偏。
        let clamped = min(2.5, max(0.4, raw))
        lock.lock(); defer { lock.unlock() }
        if samples == 0 {
            factor = clamped
        } else {
            // 指数平滑，越往后越稳定。
            factor = factor * 0.6 + clamped * 0.4
        }
        samples += 1
    }

    /// 对估算值套用校准因子。
    func adjust(_ estimated: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard samples > 0 else { return estimated }
        return Int((Double(estimated) * factor).rounded())
    }

    var currentFactor: Double {
        lock.lock(); defer { lock.unlock() }
        return factor
    }

    var hasSamples: Bool {
        lock.lock(); defer { lock.unlock() }
        return samples > 0
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        factor = 1.0
        samples = 0
    }
}

// MARK: - 会话级快照存储

/// 各会话最新的上下文占用快照。引擎写入、UI 读取，避免占用率只在有活跃 runtime 时才存在。
@MainActor
final class ContextUsageStore: ObservableObject {
    static let shared = ContextUsageStore()

    @Published private(set) var snapshots: [UUID: ContextUsageSnapshot] = [:]

    private init() {}

    func update(_ snapshot: ContextUsageSnapshot, for sessionID: UUID) {
        snapshots[sessionID] = snapshot
    }

    func snapshot(for sessionID: UUID) -> ContextUsageSnapshot? {
        snapshots[sessionID]
    }

    func clear(sessionID: UUID) {
        snapshots.removeValue(forKey: sessionID)
    }
}
