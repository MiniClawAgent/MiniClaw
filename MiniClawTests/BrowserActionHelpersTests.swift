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

    // MARK: - 参数归一化（2026-11-14 真机失败回归）

    /// 真机失败现场：模型把 url 写在顶层、params 给成空串 ⇒ navigate 必然报缺参。
    func testNormalizeTopLevelUrlAndEmptyParamsString() {
        let params = BrowserTool.normalizedActionParams([
            "action": "navigate",
            "activity": "打开维基百科黄仁勋页面查找照片",
            "params": "",
            "url": "https://zh.wikipedia.org/wiki/黄仁勋",
        ])
        XCTAssertEqual(params["url"] as? String, "https://zh.wikipedia.org/wiki/黄仁勋")
        XCTAssertNil(params["action"], "顶层结构键不得并入 params")
        XCTAssertNil(params["activity"], "顶层结构键不得并入 params")
    }

    /// 网关把嵌套对象序列化成 JSON 字符串时应还原为字典。
    func testNormalizeStringifiedParamsObject() {
        let params = BrowserTool.normalizedActionParams([
            "action": "navigate",
            "params": "{\"url\":\"https://example.com\",\"max_length\":200}",
        ])
        XCTAssertEqual(params["url"] as? String, "https://example.com")
        XCTAssertEqual(params["max_length"] as? Int, 200)
    }

    /// 正常调用（params 已是字典）语义不变，且顶层结构键不被污染。
    func testNormalizeKeepsNormalParamsUntouched() {
        let params = BrowserTool.normalizedActionParams([
            "action": "get_readable",
            "params": ["url": "https://example.com", "max_length": 100],
            "tab_index": 1,
        ])
        XCTAssertEqual(params["url"] as? String, "https://example.com")
        XCTAssertEqual(params["max_length"] as? Int, 100)
        XCTAssertNil(params["tab_index"])
    }
}
