import XCTest
@testable import MiniClaw

/// 高度缓存的不变式：**按身份存，不按行号存**。
///
/// 回归背景：旧实现 `[Int: HeightEntry]` 在插入/删除后整体错位，靠 `remapHeights` 二次映射，
/// 映射失败即丢条目 → `prepare()` 落到兜底常量 → 用户看到"工具指示器间距异常"。
final class MessageHeightCacheTests: XCTestCase {

    private func item(_ message: UUID, _ block: UUID) -> MessageListItem {
        .assistantBlock(message, block)
    }

    // MARK: - I1：行号位移不丢条目

    func testHeightSurvivesInsertionAtTop() {
        let cache = MessageHeightCache()
        let a = item(UUID(), UUID())
        let b = item(UUID(), UUID())
        cache.setOrder([a, b])
        cache.set(height: 36, source: .measured, contentKey: "b:a", at: 0)
        cache.set(height: 80, source: .measured, contentKey: "b:b", at: 1)

        // 顶部插入一行 ⇒ 原有行号全部 +1
        let inserted = item(UUID(), UUID())
        cache.setOrder([inserted, a, b])

        XCTAssertEqual(cache.height(at: 1), 36, "a 跟着身份走，不该丢")
        XCTAssertEqual(cache.height(at: 2), 80, "b 跟着身份走，不该丢")
        XCTAssertNil(cache.height(at: 0), "新行才是真正没量过的那个")
    }

    func testHeightSurvivesDeletion() {
        let cache = MessageHeightCache()
        let a = item(UUID(), UUID())
        let b = item(UUID(), UUID())
        cache.setOrder([a, b])
        cache.set(height: 36, source: .measured, contentKey: "k", at: 0)
        cache.set(height: 80, source: .measured, contentKey: "k2", at: 1)

        cache.setOrder([b])   // 删掉 a
        XCTAssertEqual(cache.height(at: 0), 80)
    }

    // MARK: - I2：失效不产生空洞

    func testInvalidateKeepsHeightAndDemotesSource() {
        let cache = MessageHeightCache()
        let a = item(UUID(), UUID())
        cache.setOrder([a])
        cache.set(height: 200, source: .measured, contentKey: "k", at: 0)

        cache.invalidate(at: 0)

        XCTAssertEqual(cache.height(at: 0), 200, "失效只降级，不丢高度（否则会跳成兜底常量）")
        XCTAssertEqual(cache.source(at: 0), .estimated, "降级后允许任何新值覆盖")
    }

    func testInvalidateAllowsLowerPriorityToOverwrite() {
        let cache = MessageHeightCache()
        let a = item(UUID(), UUID())
        cache.setOrder([a])
        cache.set(height: 200, source: .measured, contentKey: "k", at: 0)
        cache.invalidate(at: 0)

        XCTAssertTrue(cache.set(height: 36, source: .estimated, contentKey: "k", at: 0))
        XCTAssertEqual(cache.height(at: 0), 36)
    }

    // MARK: - 优先级闸门

    func testMeasuredIsNotOverwrittenByEstimate() {
        let cache = MessageHeightCache()
        let a = item(UUID(), UUID())
        cache.setOrder([a])
        cache.set(height: 50, source: .measured, contentKey: "k", at: 0)

        XCTAssertFalse(cache.set(height: 36, source: .estimated, contentKey: "k", at: 0))
        XCTAssertEqual(cache.height(at: 0), 50)
    }

    func testEstimateCanBeReplacedByPrecalc() {
        let cache = MessageHeightCache()
        let a = item(UUID(), UUID())
        cache.setOrder([a])
        cache.set(height: 36, source: .estimated, contentKey: "k", at: 0)

        XCTAssertTrue(cache.set(height: 120, source: .precalc, contentKey: "k", at: 0))
        XCTAssertEqual(cache.height(at: 0), 120)
    }

    func testInvalidHeightRejected() {
        let cache = MessageHeightCache()
        let a = item(UUID(), UUID())
        cache.setOrder([a])
        XCTAssertFalse(cache.set(height: .nan, source: .estimated, contentKey: "k", at: 0))
        XCTAssertFalse(cache.set(height: -1, source: .estimated, contentKey: "k", at: 0))
        XCTAssertNil(cache.height(at: 0))
    }

    // MARK: - 过期判定

    func testContentChangeMarksStaleButKeepsHeight() {
        let cache = MessageHeightCache()
        let a = item(UUID(), UUID())
        cache.setOrder([a])
        cache.set(height: 100, source: .measured, contentKey: "b:1", at: 0)

        XCTAssertTrue(cache.isStale(at: 0, currentContentKey: "b:2"), "内容变了要能识别")
        XCTAssertEqual(cache.height(at: 0), 100, "识别过期 ≠ 丢掉高度")
    }

    func testSameContentIsNotStale() {
        let cache = MessageHeightCache()
        let a = item(UUID(), UUID())
        cache.setOrder([a])
        cache.set(height: 100, source: .measured, contentKey: "b:1", at: 0)
        XCTAssertFalse(cache.isStale(at: 0, currentContentKey: "b:1"))
    }

    // MARK: - 清理

    func testClearRemovesEverything() {
        let cache = MessageHeightCache()
        let a = item(UUID(), UUID())
        cache.setOrder([a])
        cache.set(height: 100, source: .measured, contentKey: "k", at: 0)

        cache.clear(keepingContent: false)
        XCTAssertNil(cache.height(at: 0))
    }
}
