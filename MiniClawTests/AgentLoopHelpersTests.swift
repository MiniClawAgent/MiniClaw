import XCTest
@testable import MiniClaw

/// AgentLoopHelpers（引擎纯逻辑）正确性测试。
final class AgentLoopHelpersTests: XCTestCase {

    // MARK: - 词元估算

    func testEstimateTokensPositive() {
        XCTAssertGreaterThan(AgentLoopHelpers.estimateTokens(text: "这是一段中文文本"), 0)
        XCTAssertGreaterThan(AgentLoopHelpers.estimateTokens(text: "hello world"), 0)
        XCTAssertEqual(AgentLoopHelpers.estimateTokens(text: ""), 0)
    }

    // MARK: - 上下文缩放

    func testScalePreservesTotal() {
        var breakdown = ContextUsageBreakdown()
        breakdown.system = 100
        breakdown.tools = 50
        breakdown.history = 200
        breakdown.current = 30
        breakdown.media = 10
        breakdown.overhead = 10

        let target = 250
        let scaled = AgentLoopHelpers.scale(breakdown, to: target)
        XCTAssertEqual(scaled.total, target, "缩放后总和必须精确等于目标值")
        XCTAssertGreaterThanOrEqual(scaled.overhead, 0, "结构开销不能为负")
    }

    func testScaleSameTotalReturnsOriginal() {
        var breakdown = ContextUsageBreakdown()
        breakdown.system = 10
        breakdown.tools = 20
        let scaled = AgentLoopHelpers.scale(breakdown, to: 30)
        XCTAssertEqual(scaled.system, 10)
        XCTAssertEqual(scaled.tools, 20)
    }

    func testScaleZeroTarget() {
        var breakdown = ContextUsageBreakdown()
        breakdown.system = 10
        // 目标 0 或 total 0 时应原样返回（不崩溃）
        let scaled = AgentLoopHelpers.scale(breakdown, to: 0)
        XCTAssertEqual(scaled.system, 10)
    }

    // MARK: - 思考档位

    func testEffectiveReasoningEffortOff() {
        let endpoint = makeEndpoint(provider: .openai, supportsDeepThinking: true)
        // 显式关闭：OpenAI 兼容基线返回 "none"（真正关闭）
        XCTAssertEqual(AgentLoopHelpers.effectiveReasoningEffort(endpoint: endpoint, forceThinkingLevel: "off"), "none")
    }

    func testEffectiveReasoningEffortOffForAnthropic() {
        let endpoint = makeEndpoint(provider: .anthropic, supportsDeepThinking: true)
        // Anthropic 关闭思考：返回 nil（由构建器用 thinking:{type:"disabled"} 处理）
        XCTAssertNil(AgentLoopHelpers.effectiveReasoningEffort(endpoint: endpoint, forceThinkingLevel: "off"))
    }

    func testEffectiveReasoningEffortDefaultOn() {
        let endpoint = makeEndpoint(provider: .openai, supportsDeepThinking: true)
        // 未显式设置 + 模型支持思考 → 默认 medium
        XCTAssertEqual(AgentLoopHelpers.effectiveReasoningEffort(endpoint: endpoint, forceThinkingLevel: nil), "medium")
    }

    func testEffectiveReasoningEffortNonThinkingModel() {
        let endpoint = makeEndpoint(provider: .openai, supportsDeepThinking: false)
        XCTAssertNil(AgentLoopHelpers.effectiveReasoningEffort(endpoint: endpoint, forceThinkingLevel: nil))
    }

    func testEffectiveReasoningEffortPassthrough() {
        let endpoint = makeEndpoint(provider: .openai, supportsDeepThinking: true)
        XCTAssertEqual(AgentLoopHelpers.effectiveReasoningEffort(endpoint: endpoint, forceThinkingLevel: "high"), "high")
        // 非法档位 → nil
        XCTAssertNil(AgentLoopHelpers.effectiveReasoningEffort(endpoint: endpoint, forceThinkingLevel: "super-max"))
    }

    // MARK: - 子代理派发判定

    func testMainEngineAlwaysCanDispatch() {
        // 主引擎（subagentEngine=false）：深度 0 也允许派发
        XCTAssertTrue(AgentLoopHelpers.canDispatchSubagents(subagentEngine: false, depth: 0))
    }

    func testSubagentDepthBoundary() {
        // 子代理引擎：0 < depth < maxSubagentDepth 才可派发
        XCTAssertFalse(AgentLoopHelpers.canDispatchSubagents(subagentEngine: true, depth: 0))
        XCTAssertTrue(AgentLoopHelpers.canDispatchSubagents(subagentEngine: true, depth: 1))
        XCTAssertFalse(AgentLoopHelpers.canDispatchSubagents(subagentEngine: true, depth: AgentLoopHelpers.maxSubagentDepth))
    }

    // MARK: - 辅助

    private func makeEndpoint(provider: ProviderType, supportsDeepThinking: Bool) -> ModelRouteEndpoint {
        ModelRouteEndpoint(
            providerId: UUID(),
            modelConfigId: UUID(),
            url: "https://example.com",
            apiKey: "test-key",
            format: .chatCompletions,
            usesAzureAPIKey: false,
            modelId: "test-model",
            modelName: "Test Model",
            groupName: nil,
            fallbackStrategy: "fallback",
            contextLimitTokens: 128_000,
            thinkingLevel: "medium",
            supportsDeepThinking: supportsDeepThinking,
            maxOutputTokens: nil,
            supportsImageInput: true,
            supportsAudioInput: false,
            supportsVideoInput: false,
            organizationId: "",
            projectId: "",
            providerType: provider,
            customHeaders: [:]
        )
    }
}
