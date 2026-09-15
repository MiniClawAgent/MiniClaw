import XCTest
@testable import MiniClaw

/// BrowserActionHelpers（浏览器纯逻辑工具）正确性测试。
final class BrowserActionHelpersTests: XCTestCase {

    // MARK: - tab_id 兼容解析

    func testResolveTabIdInt() {
        XCTAssertEqual(BrowserActionHelpers.resolveTabId(["tab_id": 1]), 1)
        XCTAssertEqual(BrowserActionHelpers.resolveTabId(["tab_id": 0]), 0)
    }

    func testResolveTabIdString() {
        XCTAssertEqual(BrowserActionHelpers.resolveTabId(["tab_id": "2"]), 2)
    }

    func testResolveTabIdInvalid() {
        XCTAssertNil(BrowserActionHelpers.resolveTabId([:]))
        XCTAssertNil(BrowserActionHelpers.resolveTabId(["tab_id": "abc"]))
        XCTAssertNil(BrowserActionHelpers.resolveTabId(["tab_id": 1.5]))
    }

    // MARK: - UA 预设解析

    func testResolveUAProfilePreset() {
        XCTAssertEqual(BrowserActionHelpers.resolveUAProfile(["preset": "mobile"]), .mobileSafari)
        XCTAssertEqual(BrowserActionHelpers.resolveUAProfile(["preset": "desktop"]), .desktopSafari)
        XCTAssertEqual(BrowserActionHelpers.resolveUAProfile(["preset": "mobile_safari"]), .mobileSafari)
        XCTAssertEqual(BrowserActionHelpers.resolveUAProfile(["preset": "desktop_safari"]), .desktopSafari)
    }

    func testResolveUAProfileUnknownPreset() {
        XCTAssertNil(BrowserActionHelpers.resolveUAProfile(["preset": "weird"]))
    }

    // MARK: - UA 字符串常量
    // [2026-09-15 体系统一] desktopUA/mobileUA 与旧 `UAProfile` 已随旧 UA 体系删除：
    // UA 的唯一事实来源是引擎池 `MiniClawUAProfile`（其 userAgentString 自带断言价值），
    // 这里不再重复断言一份已不存在的常量。
}
