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

