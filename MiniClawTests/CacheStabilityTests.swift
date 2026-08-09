import XCTest
@testable import MiniClaw

/// 提示词缓存稳定性回归测试。
/// 守护三条铁律：
/// 1. 易变内容（时间戳 / 记忆 / 挂载）绝不进入缓存前缀（system 字段 + tools 字段），否则逐轮失效；
/// 2. tools 列表必须按名字确定性排序，否则 tools 缓存断点前缀逐轮变化 → 命中率归零；
/// 3. 相同输入必须产生字节一致的请求体（防止未来无意引入非确定性拼装）。
final class CacheStabilityTests: XCTestCase {

    private func makeClient() -> LLMClient {
        LLMClient(
            endpointURL: "https://api.anthropic.com/v1/messages",
            apiKey: "test-key",
            format: .chatCompletions,
            providerType: .anthropic
        )
    }

    private func systemMessage(stable: String, volatile: String) -> ChatCompletionMessage {
        var m = ChatCompletionMessage(role: "system", content: stable)
        m.volatileSuffix = volatile
        return m
    }

    private func userMessage(_ text: String) -> ChatCompletionMessage {
        ChatCompletionMessage(role: "user", content: text)
    }

    private func toolSchema(name: String) -> ToolSchema {
        ToolSchema(
            type: "function",
            function: ToolSchema.FunctionDef(
                name: name,
                description: "desc-\(name)",
                parameters: JSONSchema(type: "object")
            )
        )
    }

    /// 构造一个带历史消息的请求体：system(稳定+易变) + 历史 assistant + 当前 user。
    private func build(
        client: LLMClient,
        stable: String,
        volatile: String,
        tools: [ToolSchema],
        history: [ChatCompletionMessage] = [ChatCompletionMessage(role: "assistant", content: "好的，已记录。")]
    ) -> Data {
        let messages: [ChatCompletionMessage] = [systemMessage(stable: stable, volatile: volatile)] + history + [userMessage("请继续")]
        return client.buildAnthropicBody(
            model: "claude-3-5-sonnet-20241022",
            messages: messages,
            tools: tools,
            temperature: nil,
            topP: nil,
            maxTokens: 4096,
            reasoningEffort: nil,
            thinkingLevel: nil
        )
    }

    func testVolatileExcludedFromCachePrefix() throws {
        let stable = "STABLE_SYSTEM_CONTENT"
        let ts1 = "当前时间：2026-08-03T10:00:00 时间戳-A"
        let ts2 = "当前时间：2026-08-03T11:30:45 时间戳-B"

        let body1 = build(client: makeClient(), stable: stable, volatile: ts1,
                          tools: [toolSchema(name: "zeta"), toolSchema(name: "alpha")])
        let body2 = build(client: makeClient(), stable: stable, volatile: ts2,
                          tools: [toolSchema(name: "zeta"), toolSchema(name: "alpha")])

        let json1 = try XCTUnwrap(JSONSerialization.jsonObject(with: body1) as? [String: Any])
        let json2 = try XCTUnwrap(JSONSerialization.jsonObject(with: body2) as? [String: Any])

        // ① system 字段必须只含稳定内容，且两次完全一致（时间戳不得进入缓存前缀）
        let sys1 = try XCTUnwrap(json1["system"] as? [[String: Any]])
        let sys2 = try XCTUnwrap(json2["system"] as? [[String: Any]])
        XCTAssertEqual(sys1, sys2, "两次请求的 system 字段必须字节一致")
        let sysText = (sys1.compactMap { $0["text"] as? String }.joined(separator: "\n"))
        XCTAssertFalse(sysText.contains("时间戳-A"), "易变时间戳不得出现在 system 缓存前缀")
        XCTAssertFalse(sysText.contains("时间戳-B"), "易变时间戳不得出现在 system 缓存前缀")

        // ② 易变内容必须落在最后一条 user 消息（当前输入）里，而非 system / 历史
        let messages1 = try XCTUnwrap(json1["messages"] as? [[String: Any]])
        let lastMessage = try XCTUnwrap(messages1.last)
        let lastRole = try XCTUnwrap(lastMessage["role"] as? String)
        XCTAssertEqual(lastRole, "user", "易变后缀必须注入到当前 user 消息")
        let lastContent: String
        if let s = lastMessage["content"] as? String {
            lastContent = s
        } else if let blocks = lastMessage["content"] as? [[String: Any]] {
            lastContent = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            lastContent = ""
        }
        XCTAssertTrue(lastContent.contains("时间戳-A"), "易变时间戳必须随当前 user 输入发送")
    }

    func testToolsDeterministicallySorted() throws {
        let tools = [toolSchema(name: "zeta"), toolSchema(name: "alpha"), toolSchema(name: "mike")]
        let body = build(client: makeClient(), stable: "STABLE", volatile: "V", tools: tools)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let toolList = try XCTUnwrap(json["tools"] as? [[String: Any]])
        let names = toolList.compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["alpha", "mike", "zeta"], "tools 必须按名字升序确定性排序")
    }

    func testIdenticalInputProducesIdenticalBody() throws {
        let tools = [toolSchema(name: "b"), toolSchema(name: "a")]
        let b1 = build(client: makeClient(), stable: "STABLE", volatile: "V", tools: tools)
        let b2 = build(client: makeClient(), stable: "STABLE", volatile: "V", tools: tools)
        XCTAssertEqual(b1, b2, "相同输入必须产生字节一致的请求体")
    }

    func testHistoryCarriesCacheBreakpoint() throws {
        let body = build(client: makeClient(), stable: "STABLE", volatile: "V",
                         tools: [toolSchema(name: "a")])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        // 当前 user 是最后一条；其前一条（最后一条历史消息）应带 cache_control 断点
        XCTAssertGreaterThan(messages.count, 1)
        let historyMsg = messages[messages.count - 2]
        let hasBreakpoint: Bool
        if let blocks = historyMsg["content"] as? [[String: Any]] {
            hasBreakpoint = blocks.contains { $0["cache_control"] != nil }
        } else {
            hasBreakpoint = false
        }
        XCTAssertTrue(hasBreakpoint, "最后一条历史消息应带 cache_control 断点，使 system+tools+历史整体命中缓存")
    }
}
