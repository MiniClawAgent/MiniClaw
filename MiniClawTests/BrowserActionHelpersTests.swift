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

    func testUAConstantsNonEmpty() {
        XCTAssertTrue(BrowserActionHelpers.desktopUA.contains("Safari"))
        XCTAssertTrue(BrowserActionHelpers.mobileUA.contains("iPhone"))
        XCTAssertNotEqual(BrowserActionHelpers.desktopUA, BrowserActionHelpers.mobileUA)
    }

    func testUAProfileRawValues() {
        XCTAssertEqual(UAProfile.mobile.rawValue, "mobile")
        XCTAssertEqual(UAProfile.desktop.rawValue, "desktop")
    }
}
