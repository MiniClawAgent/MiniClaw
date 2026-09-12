import XCTest
@testable import MiniClaw

/// 滚动抖动分析器的回归测试。
///
/// 判据来源：MiniClaw 真机事故（详见 `ScrollMetricsAnalyzer` 文档）。
/// 分析器是**纯函数**，输入即 `ScrollMetricsRecorder` 落盘的 JSON 事件数组，
/// 因此这里用合成事件流覆盖「稳定 / 三类异常」四组场景，不依赖真机与截屏。
final class ScrollMetricsAnalyzerTests: XCTestCase {

    private func event(_ kind: String,
                       idx: Int = 0,
                       a: Double = 0,
                       b: Double = 0,
                       key: String = "b:x",
                       pos: String = "inside",
                       note: String = "") -> [String: Any] {
        ["kind": kind, "idx": idx, "a": a, "b": b, "key": key, "pos": pos, "note": note]
    }

    /// 平稳滑动：高度只单调增长一次、无上方变化、无手势内收缩 ⇒ 不应报任何发现。
    func testStableSessionYieldsNoFindings() {
        let events = [
            event("scroll", a: 0, b: 1200),
            event("prepare", a: 10, b: 1200),
            event("measure", idx: 3, a: 40, b: 120, key: "b:a"),
            event("inv", idx: 3, a: 40, b: 120, key: "b:a", pos: "below", note: "drag"),
        ]
        XCTAssertTrue(ScrollMetricsAnalyzer.analyze(events: events).isEmpty)
    }

    /// 同一 key 被反复改成不同高度（≥3 次且极差 >0.5）⇒ 报 flapping。
    func testRepeatedHeightChangesFlaggedAsFlapping() {
        let events = [
            event("inv", idx: 7, a: 36, b: 70, key: "b:flap"),
            event("inv", idx: 7, a: 70, b: 36, key: "b:flap"),
            event("inv", idx: 7, a: 36, b: 70, key: "b:flap"),
        ]
        let findings = ScrollMetricsAnalyzer.analyze(events: events)
        XCTAssertEqual(findings.filter { $0.kind == "flapping" }.count, 1)
        XCTAssertTrue(findings.first?.detail.contains("b:flap") ?? false)
    }

    /// 视口上方的高度变化合计非零 ⇒ 报 aboveShift（会 1:1 平移可见内容）。
    func testAboveViewportShiftFlagged() {
        let events = [
            event("inv", idx: 1, a: 100, b: 134, key: "b:up", pos: "above"),
            event("inv", idx: 2, a: 100, b: 90, key: "b:up2", pos: "above"),
        ]
        let findings = ScrollMetricsAnalyzer.analyze(events: events)
        XCTAssertEqual(findings.filter { $0.kind == "aboveShift" }.count, 1)
    }

    /// 拖动中出现高度**收缩** ⇒ 报 liveShrink；同一相位内的**增长**（流式）不报。
    func testShrinkDuringGestureFlaggedButGrowthIsNot() {
        let shrink = [event("inv", idx: 5, a: 70, b: 36, key: "b:s", note: "drag")]
        XCTAssertEqual(ScrollMetricsAnalyzer.analyze(events: shrink).filter { $0.kind == "liveShrink" }.count, 1)

        let growth = [event("inv", idx: 5, a: 36, b: 70, key: "b:s", note: "drag")]
        XCTAssertTrue(ScrollMetricsAnalyzer.analyze(events: growth).isEmpty)
    }
}
