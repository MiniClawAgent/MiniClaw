import XCTest
@testable import MiniClaw

/// ChatCommandParser（斜杠命令解析）正确性测试。
final class ChatCommandParserTests: XCTestCase {

    // MARK: - 内置命令匹配

    func testMatchesClearCommand() {
        let item = ChatCommandParser.builtinCommand(matching: "/clear")
        XCTAssertNotNil(item, "/clear 应命中内置命令")
        XCTAssertEqual(item?.id, "clear")
    }

    func testMatchesCommandWithArguments() {
        // "/thinking high" 这类带参数的内置命令
        let item = ChatCommandParser.builtinCommand(matching: "/thinking high")
        XCTAssertNotNil(item, "带参数的内置命令应命中")
        XCTAssertEqual(item?.id, "thinking")
    }

    func testUnknownCommandReturnsNil() {
        XCTAssertNil(ChatCommandParser.builtinCommand(matching: "/not_a_real_command"))
    }

    func testPlainTextReturnsNil() {
        XCTAssertNil(ChatCommandParser.builtinCommand(matching: "你好，帮我查一下"))
        XCTAssertNil(ChatCommandParser.builtinCommand(matching: ""))
    }

    func testSingleSlashReturnsNil() {
        XCTAssertNil(ChatCommandParser.builtinCommand(matching: "/"))
    }

    // MARK: - 技能命令解析

    @MainActor
    func testNonSlashTextIsNotSkillCommand() {
        XCTAssertNil(ChatCommandParser.parseSkillCommand("随便一句话"))
    }

    @MainActor
    func testUnknownSkillReturnsNil() {
        // 测试环境未加载任何技能 → 未知名称必然返回 nil（不崩溃）
        XCTAssertNil(ChatCommandParser.parseSkillCommand("/definitely_not_a_skill 任务"))
    }

    @MainActor
    func testEmptySkillNameReturnsNil() {
        XCTAssertNil(ChatCommandParser.parseSkillCommand("/"))
    }

    // MARK: - 思考档位常量

    func testThinkingLevelsCoverage() {
        // 档位常量应包含完整档位集合（与 normalizedThinkingLevel 对齐）
        let ids = ChatCommandParser.thinkingLevels.map(\.id)
        XCTAssertTrue(ids.contains("low"))
        XCTAssertTrue(ids.contains("medium"))
        XCTAssertTrue(ids.contains("high"))
        XCTAssertTrue(ids.contains("xhigh"))
        XCTAssertTrue(ids.contains("max"))
        // 标签查表应能命中每个档位
        for id in ids {
            XCTAssertNotNil(ChatCommandParser.thinkingLevelLabels[id], "档位 \(id) 应有标签")
        }
    }
}
