import XCTest
@testable import MiniClaw

/// BashismDetector 正确性与性能测试（自研，无第三方依赖）。
final class BashismDetectorTests: XCTestCase {

    // MARK: - 命中

    func testDetectsBashArray() {
        let hits = BashismDetector.detect("arr=(one two three)\necho done")
        XCTAssertTrue(hits.contains { $0.rule.contains("数组赋值") }, "应命中数组赋值，实际: \(hits)")
    }

    func testDetectsDoubleBracket() {
        let hits = BashismDetector.detect("if [[ -f /etc/passwd ]]; then echo yes; fi")
        XCTAssertTrue(hits.contains { $0.rule.contains("双中括号") }, "应命中双中括号，实际: \(hits)")
    }

    func testDetectsProcessSubstitution() {
        let hits = BashismDetector.detect("diff <(sort a.txt) <(sort b.txt)")
        XCTAssertTrue(hits.contains { $0.rule.contains("进程替换") }, "应命中进程替换，实际: \(hits)")
    }

    func testDetectsHereStringAndSource() {
        let hits = BashismDetector.detect("grep foo <<< \"$x\"\nsource ~/.profile")
        XCTAssertTrue(hits.contains { $0.rule.contains("here-string") }, "应命中 here-string")
        XCTAssertTrue(hits.contains { $0.rule.contains("source") }, "应命中 source")
    }

    // MARK: - 不误报（POSIX 兼容语法必须零命中）

    func testPosixCommandIsClean() {
        let hits = BashismDetector.detect("""
        for f in *.txt; do
          echo "processing $f" >&2
          grep -q error "$f" && exit 1
        done
        cat <<'EOF'
        literal {{x}} and $(not_command)
        EOF
        if [ -d /tmp ]; then cd /tmp; fi
        """)
        XCTAssertTrue(hits.isEmpty, "POSIX 命令不应命中，实际: \(hits)")
    }

    func testSingleQuotedHeredocMarkerDoesNotOpen() {
        // echo '<<EOF' 不应把后续行当 heredoc 吞掉
        let hits = BashismDetector.detect("echo '<<EOF'\nif [[ -f x ]]; then :; fi")
        XCTAssertTrue(hits.contains { $0.rule.contains("双中括号") }, "heredoc 误开导致漏检，实际: \(hits)")
    }

    func testDoubleQuotedApostropheDoesNotStripLine() {
        // "it's ok" 中的 ' 不应使整行进入单引号剥离状态
        let hits = BashismDetector.detect("echo \"it's ok\"\nif [[ -f x ]]; then :; fi")
        XCTAssertTrue(hits.contains { $0.rule.contains("双中括号") }, "双引号内撇号导致漏检，实际: \(hits)")
    }

    func testQuotedHeredocContentNotFlagged() {
        // 带引号 heredoc 标记内的 bashism 文本不应命中（<<'EOF' / <<"EOF"）
        for marker in ["'EOF'", "\"EOF\""] {
            let hits = BashismDetector.detect("""
            cat <<\(marker)
            if [[ -f x ]]; then
              arr=(1 2 3)
            fi
            EOF
            echo done
            """)
            XCTAssertTrue(hits.isEmpty, "heredoc 内容不应命中 (\(marker))，实际: \(hits)")
        }
    }

    func testCommentLineHeredocMarkerNotOpen() {
        // 注释行里的 <<EOF 不应误开 heredoc（否则吞掉后续行导致漏检）
        let hits = BashismDetector.detect("# comment <<EOF\nif [[ -f x ]]; then :; fi")
        XCTAssertTrue(hits.contains { $0.rule.contains("双中括号") }, "注释行 << 误开 heredoc，实际: \(hits)")
    }

    // MARK: - 性能与熔断

    func testLargeCommandStaysUnderBudgetAndDetects() {
        // 1000 行命令：预编译规则下应快速完成且仍能命中
        var lines: [String] = []
        for i in 0..<1000 {
            lines.append("echo line\(i) && ls /tmp")
        }
        lines.append("arr=(a b c)")
        let command = lines.joined(separator: "\n")
        let start = Date()
        let hits = BashismDetector.detect(command)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(hits.contains { $0.rule.contains("数组赋值") }, "大命令应仍命中")
        XCTAssertLessThan(elapsed, 0.2, "大命令检测应 <200ms，实际 \(elapsed)s")
    }

    func testOverlongLineSkipped() {
        let longLine = String(repeating: "a", count: 5000) + "[[x]]"
        XCTAssertTrue(BashismDetector.detect(longLine).isEmpty, "超长行应跳过")
    }
}
