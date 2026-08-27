import Foundation

/// Agent 循环引擎的纯逻辑工具（2026-08 提取：与引擎实例状态解耦，可独立单测）。
enum AgentLoopHelpers {

    /// 子代理树最大深度（P2-4）：深度达到该值的子代理不再获得 dispatch_subagent 工具，
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


    /// 引擎运行时约束段：拼在 profile 正文之后（profile 负责"人设"，本段负责"机制"）。
    /// `canDispatchDeeper` 为 true 时（P2-4 多层编排，深度未触顶）允许继续往下派子代理。
    static func subagentEngineSuffix(focus: String?, depth: Int, canDispatchDeeper: Bool) -> String {
        let recursionRule = canDispatchDeeper
        ? String(format: L10n.l("loop_subagent_depth_hint"), depth, maxSubagentDepth)
        : String(format: L10n.l("loop_subagent_max_depth"), depth, maxSubagentDepth)
        return """
        规则：
        - 只使用你手上的工具完成任务。
        \(focus.map { "- 本次聚焦领域：\($0)。" } ?? "")
        \(recursionRule)
        - 直接、简洁地完成任务，最后用一段中文总结你的关键发现或结果，不要多余寒暄与自我介绍。
        - 你的最终回答会作为父代理的一个工具结果，请保证信息自包含、可被父代理直接引用。
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
