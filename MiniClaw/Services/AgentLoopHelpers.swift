import CryptoKit
import Foundation

/// Agent 循环引擎的纯逻辑工具（2026-08 提取：与引擎实例状态解耦，可独立单测）。
enum AgentLoopHelpers {

    /// 子代理树最大深度（P2-4）：深度达到该值的子代理不再获得 dispatch-subagent 工具，
    /// 从而在允许"子代理再派子代理"的同时给出硬性递归上界。
    static let maxSubagentDepth: Int = 2


    /// 当前引擎能否派发子代理：主引擎总是可以；
    /// 子代理引擎仅当已处于子代理层级且未触顶（0 < 深度 < 上限）时允许。
    /// 复盘/整理等受限后台引擎（isSubagentEngine=true 且 depth=0）
    /// 不在子代理层级内，不得派发（否则无人值守后台引擎会凭空派生子代理，浪费 token 且
    /// 子代理继承含 bypassConfirmation 的写工具，后台无确认写入）。
    static func canDispatchSubagents(subagentEngine: Bool, depth: Int) -> Bool {
        guard subagentEngine else { return true }
        return depth > 0 && depth < maxSubagentDepth
    }


    /// 子代理**静态**机制段（进缓存前缀）：不含任何随实例变化的信息，
    /// 因此所有子代理（乃至跨会话）逐字节一致 → 可被前缀缓存复用。
    /// 随实例变化的内容一律走 `subagentInstanceSection` 进 volatile 段。
    static var subagentStaticRules: String {
        """
        规则：
        - 只使用你手上的工具完成任务。
        - 直接、简洁地完成任务，最后用一段中文总结你的关键发现或结果，不要多余寒暄与自我介绍。
        - 你的最终回答会作为父代理的一个工具结果，请保证信息自包含、可被父代理直接引用。
        """
    }

    /// 子代理**实例**段（volatile）：focus（本次任务）与深度规则随实例变化，
    /// 若留在前缀里，每个子代理的 system 指纹都不同 → 彼此无法复用缓存
    /// （真机实测 3 个子代理 sys 指纹各异、命中 0%）。故必须沉到尾部。
    static func subagentInstanceSection(focus: String?, depth: Int, canDispatchDeeper: Bool) -> String {
        let recursionRule = canDispatchDeeper
        ? String(format: String(localized: "loop_subagent_depth_hint"), depth, maxSubagentDepth)
        : String(format: String(localized: "loop_subagent_max_depth"), depth, maxSubagentDepth)
        return """
        本次任务与层级：
        \(focus.map { String(format: String(localized: "subagent_focus_line"), $0) } ?? "")
        \(recursionRule)
        """
    }


    /// 归一化思考档位：官方允许 low / medium / high / xhigh / max（OpenAI 还支持 none / minimal）。
    /// 这里不再把 xhigh / max 折叠成 high——OpenAI / Responses API 官方就支持完整档位，
    /// 折叠会丢失高力度（catalog 的 thinkingLevels 已按各厂商实际支持范围约束 UI 可选项）。
    private static func normalizedThinkingLevel(_ level: String) -> String? {
        switch level {
        case "off": return nil
        case "low", "medium", "high", "xhigh", "max", "minimal", "none": return level
        default: return nil
        }
    }


    /// 计算本轮请求的 reasoning effort（深度思考等级）：
    /// - `forceThinkingLevel == nil`：未显式设置 → 跟随模型默认。仅当模型支持思考时默认开启（用 medium 档），
    ///   否则不发送推理参数。
    /// - `forceThinkingLevel == "off"`：用户显式关闭。
    ///     · OpenAI / OpenRouter（OpenAI 兼容基线）：发官方 `reasoning_effort: "none"` 真正关闭；
    ///     · Anthropic / Gemini：返回 nil，由各自构建器处理（Anthropic 用 thinking:{type:"disabled"}，Gemini 不开启）。
    /// - 具体档位：原样透传（不再折叠），由 catalog 保证该模型支持此档位。
    static func effectiveReasoningEffort(endpoint: ModelRouteEndpoint, forceThinkingLevel: String?) -> String? {
        if let ft = forceThinkingLevel {
            guard ft != "off" else {
                // OpenAI 兼容基线：用官方 "none" 真正关闭；其余基线返回 nil 交由构建器处理
                if endpoint.providerType == .openai || endpoint.providerType == .openRouter {
                    return endpoint.supportsDeepThinking ? "none" : nil
                }
                return nil
            }
            return normalizedThinkingLevel(ft)
        }
        // 未显式设置：思考模型默认开启，非思考模型不开启
        guard endpoint.supportsDeepThinking else { return nil }
        return normalizedThinkingLevel("medium")
    }


    /// 估算文本 词元 数（自然语言密度）。保留静态入口供既有调用方使用。
    static func estimateTokens(text: String) -> Int {
        ContextUsageEstimator.estimate(text: text, density: .prose)
    }


    /// 估算一组消息的输入 词元 数（含结构开销、多模态与易变段；不含工具 schema）。
    /// 需要「完整请求口径」时请用 `ContextUsageEstimator.estimate(messages:tools:)`。
    static func estimateTokens(messages: [ChatCompletionMessage]) -> Int {
        ContextUsageEstimator.estimate(messages: messages, tools: nil)
    }


    /// 按比例缩放明细，使各项之和等于给定总量（把服务商真值分摊回 System/Tools/History/Current）。
    static func scale(_ breakdown: ContextUsageBreakdown, to target: Int) -> ContextUsageBreakdown {
        let total = breakdown.total
        guard total > 0, target > 0, total != target else { return breakdown }
        let factor = Double(target) / Double(total)
        var scaled = ContextUsageBreakdown()
        scaled.system = Int(Double(breakdown.system) * factor)
        scaled.tools = Int(Double(breakdown.tools) * factor)
        scaled.history = Int(Double(breakdown.history) * factor)
        scaled.current = Int(Double(breakdown.current) * factor)
        scaled.media = Int(Double(breakdown.media) * factor)
        // 余数并入结构开销，保证总和精确等于 target。
        scaled.overhead = max(0, target - (scaled.system + scaled.tools + scaled.history + scaled.current + scaled.media))
        return scaled
    }
}

/// 缓存前缀指纹（2026-08-31 诊断）：对实际发出的请求按「system 段 / 工具 schema /
/// 逐条历史消息」分别取 SHA256 前 8 位 hex 指纹，跨轮对比即可定位服务端前缀缓存
/// 从哪一段开始失效——system 或 tools 哈希变化意味着前缀在历史之前就断了；
/// history 首差异位置指明历史内第几条消息开始变化。
/// 注意：最后一条 user 消息（本轮新输入）不计入 history——它每轮必然不同，
/// 属设计内的尾部增量。volatileSuffix 是独立字段，不参与指纹。
struct CachePrefixFingerprint: Equatable {
    let system: String
    let toolsHash: String
    /// 工具名 → 单工具 schema 哈希：tools 整段哈希变化时，用它定位具体是哪个工具在变。
    let toolHashes: [String: String]
    let history: [String]

    static func shortHash(_ s: String) -> String {
        String(SHA256.hash(data: Data(s.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined())
    }

    /// 键序确定编码器：与请求体序列化（OpenAIProviderAdapter.cacheStableEncoder）同口径，
    /// 保证指纹只反映内容差异、不掺入 Foundation 字典键序抖动。
    private static let hashEncoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return enc
    }()

    init(messages: [ChatCompletionMessage], tools: [ToolSchema]?) {
        var sysParts: [String] = []
        var histHashes: [String] = []
        var perTool: [String: String] = [:]
        let lastUserIdx = messages.lastIndex { $0.role == "user" }
        for (i, m) in messages.enumerated() {
            let text = m.content?.asText ?? ""
            let calls = (m.toolCalls ?? []).map { $0.function.name + ":" + $0.function.arguments }.joined(separator: ",")
            let line = "\(m.role)|\(text)|\(calls)|\(m.reasoningContent ?? "")"
            if m.role == "system" || m.role == "developer" {
                sysParts.append(line)
            } else if i != lastUserIdx {
                histHashes.append(Self.shortHash(line))
            }
        }
        system = Self.shortHash(sysParts.joined(separator: "\n"))
        if let tools, !tools.isEmpty {
            for t in tools {
                let data = (try? Self.hashEncoder.encode(t)) ?? Data()
                perTool[t.function.name] = Self.shortHash(String(decoding: data, as: UTF8.self))
            }
            toolsHash = Self.shortHash(String(decoding: (try? Self.hashEncoder.encode(tools)) ?? Data(), as: UTF8.self))
        } else {
            toolsHash = "none"
        }
        toolHashes = perTool
        history = histHashes
    }

    /// 与上一轮指纹对比，产出人读差异描述（first = 首轮无参照）。
    func diffDescription(against last: CachePrefixFingerprint) -> String {
        var diffs: [String] = []
        if last.system != system { diffs.append("sys变") }
        if last.toolsHash != toolsHash {
            let changed = toolHashes
                .compactMap { name, h -> String? in last.toolHashes[name] != h ? name : nil }
                .sorted()
            if changed.isEmpty {
                diffs.append("tools变(组合或数量)")
            } else {
                let shown = changed.prefix(4).joined(separator: ",")
                let more = changed.count > 4 ? "等\(changed.count)个" : ""
                diffs.append("tools变[\(shown)\(more)]")
            }
        }
        let common = min(last.history.count, history.count)
        let firstDiffIdx = (0..<common).first { last.history[$0] != history[$0] }
        if let idx = firstDiffIdx {
            diffs.append("hist第\(idx + 1)条起变(旧\(last.history.count)/新\(history.count)条)")
        } else if last.history.count != history.count {
            diffs.append("hist前\(common)条同,新增\(history.count - last.history.count)条")
        }
        return diffs.isEmpty ? "完全相同" : diffs.joined(separator: ",")
    }
}
