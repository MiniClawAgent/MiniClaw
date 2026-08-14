import XCTest
@testable import MiniClaw

/// MarkdownParser（手写解析器）正确性测试。
/// 覆盖：标题 / 无序有序任务列表 / 引用 / 表格 / 代码块 / 媒体行 / 主题分隔 / 链接引用 / 纯文本 / 媒体类型分类。
final class MarkdownParserTests: XCTestCase {

    private func firstBlock(_ text: String) -> MarkdownBlock? {
        MarkdownParser.parseMarkdown(text).first
    }

    // MARK: - 标题

    func testHeadingLevel2() {
        guard case .heading(let level, let content, _) = firstBlock("## 二级标题") else {
            return XCTFail("应解析为 heading，实际: \(String(describing: firstBlock("## 二级标题")))")
        }
        XCTAssertEqual(level, 2)
        XCTAssertEqual(content, "二级标题")
    }

    func testHeadingLevel1WithSpace() {
        guard case .heading(let level, let content, _) = firstBlock("# 一级") else {
            return XCTFail("应解析为 heading")
        }
        XCTAssertEqual(level, 1)
        XCTAssertEqual(content, "一级")
    }

    // MARK: - 列表

    func testBulletList() {
        let blocks = MarkdownParser.parseMarkdown("- 苹果\n- 香蕉\n- 橘子")
        guard case .bulletList(let items, let indent, _) = blocks.first else {
            return XCTFail("应解析为 bulletList，实际: \(blocks)")
        }
        XCTAssertEqual(items, ["苹果", "香蕉", "橘子"])
        XCTAssertEqual(indent, 0)
    }

    func testOrderedList() {
        let blocks = MarkdownParser.parseMarkdown("1. 第一步\n2. 第二步")
        guard case .orderedList(let items, _, let start, _) = blocks.first else {
            return XCTFail("应解析为 orderedList，实际: \(blocks)")
        }
        XCTAssertEqual(items, ["第一步", "第二步"])
        XCTAssertEqual(start, 1)
    }

    func testTaskList() {
        let blocks = MarkdownParser.parseMarkdown("- [x] 已完成\n- [ ] 未完成")
        guard case .taskList(let items, _, _) = blocks.first else {
            return XCTFail("应解析为 taskList，实际: \(blocks)")
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].isCompleted, true)
        XCTAssertEqual(items[0].content, "已完成")
        XCTAssertEqual(items[1].isCompleted, false)
        XCTAssertEqual(items[1].content, "未完成")
    }

    // MARK: - 引用

    func testBlockquote() {
        let blocks = MarkdownParser.parseMarkdown("> 引用内容")
        guard case .blockquote(let content, _) = blocks.first else {
            return XCTFail("应解析为 blockquote，实际: \(blocks)")
        }
        XCTAssertEqual(content, "引用内容")
    }

    // MARK: - 表格

    func testTable() {
        let md = """
        | 名称 | 数量 |
        | --- | --- |
        | 苹果 | 3 |
        | 香蕉 | 5 |
        """
        let blocks = MarkdownParser.parseMarkdown(md)
        guard case .table(let headers, let rows, let alignments, _) = blocks.first else {
            return XCTFail("应解析为 table，实际: \(blocks)")
        }
        XCTAssertEqual(headers, ["名称", "数量"])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], ["苹果", "3"])
        XCTAssertEqual(alignments.count, 2)
    }

    func testTableAlignmentCenter() {
        let md = """
        | 左 | 中 | 右 |
        | :-- | :-: | --: |
        | a | b | c |
        """
        let blocks = MarkdownParser.parseMarkdown(md)
        guard case .table(_, _, let alignments, _) = blocks.first else {
            return XCTFail("应解析为 table")
        }
        XCTAssertEqual(alignments, [.leading, .center, .trailing])
    }

    // MARK: - 代码块

    func testCodeBlock() {
        let md = "```swift\nlet x = 1\nprint(x)\n```"
        let blocks = MarkdownParser.parseMarkdown(md)
        guard case .codeBlock(let language, let content, _) = blocks.first else {
            return XCTFail("应解析为 codeBlock，实际: \(blocks)")
        }
        XCTAssertEqual(language, "swift")
        XCTAssertTrue(content.contains("let x = 1"))
    }

    func testCodeBlockNoLanguage() {
        let md = "```\nplain code\n```"
        let blocks = MarkdownParser.parseMarkdown(md)
        guard case .codeBlock(_, let content, _) = blocks.first else {
            return XCTFail("应解析为 codeBlock")
        }
        XCTAssertTrue(content.contains("plain code"))
    }

    // MARK: - 媒体行

    func testImage() {
        let blocks = MarkdownParser.parseMarkdown("![小猫](https://example.com/cat.png)")
        guard case .image(let alt, let url, _) = blocks.first else {
            return XCTFail("应解析为 image，实际: \(blocks)")
        }
        XCTAssertEqual(alt, "小猫")
        XCTAssertEqual(url, "https://example.com/cat.png")
    }

    func testMediaTypeClassification() {
        XCTAssertEqual(MarkdownParser.classifyMediaType("a.png"), .image)
        XCTAssertEqual(MarkdownParser.classifyMediaType("b.jpg"), .image)
        XCTAssertEqual(MarkdownParser.classifyMediaType("c.mp4"), .video)
        XCTAssertEqual(MarkdownParser.classifyMediaType("d.mov"), .video)
        XCTAssertEqual(MarkdownParser.classifyMediaType("e.mp3"), .audio)
        XCTAssertEqual(MarkdownParser.classifyMediaType("f.wav"), .audio)
        XCTAssertEqual(MarkdownParser.classifyMediaType("g.swift"), .code)
        XCTAssertEqual(MarkdownParser.classifyMediaType("h.pdf"), .pdf)
        XCTAssertEqual(MarkdownParser.classifyMediaType("i.docx"), .office)
        XCTAssertEqual(MarkdownParser.classifyMediaType("j.html"), .html)
        XCTAssertEqual(MarkdownParser.classifyMediaType("k.unknown_ext"), .file)
    }

    // MARK: - 主题分隔

    func testThematicBreak() {
        let blocks = MarkdownParser.parseMarkdown("---")
        guard case .thematicBreak = blocks.first! else {
            return XCTFail("--- 应解析为 thematicBreak，实际: \(blocks)")
        }
    }

    // MARK: - 纯文本

    func testPlainText() {
        let blocks = MarkdownParser.parseMarkdown("普通文本段落")
        guard case .text(let content, _) = blocks.first else {
            return XCTFail("应解析为 text，实际: \(blocks)")
        }
        XCTAssertEqual(content, "普通文本段落")
    }

    // MARK: - 链接引用

    func testLinkReferenceResolution() {
        let md = """
        [官网][ref]
        [ref]: https://example.com
        """
        let blocks = MarkdownParser.parseMarkdown(md)
        XCTAssertFalse(blocks.isEmpty, "链接引用应能解析出内容")
    }

    // MARK: - 混合文档

    func testMixedDocument() {
        let md = """
        # 总标题

        - 要点一
        - 要点二

        > 引用一段
        """
        let blocks = MarkdownParser.parseMarkdown(md)
        // 至少解析出 3 类块（标题/列表/引用）
        let kinds = Set(blocks.map { blockKind($0) })
        XCTAssertTrue(kinds.contains("heading"))
        XCTAssertTrue(kinds.contains("bulletList"))
        XCTAssertTrue(kinds.contains("blockquote"))
    }

    private func blockKind(_ block: MarkdownBlock) -> String {
        switch block {
        case .heading: return "heading"
        case .bulletList: return "bulletList"
        case .orderedList: return "orderedList"
        case .taskList: return "taskList"
        case .blockquote: return "blockquote"
        case .table: return "table"
        case .thematicBreak: return "thematicBreak"
        case .text: return "text"
        case .codeBlock: return "codeBlock"
        case .image: return "image"
        case .video: return "video"
        case .audio: return "audio"
        case .file: return "file"
        }
    }

    // MARK: - 空输入

    func testEmptyInput() {
        XCTAssertTrue(MarkdownParser.parseMarkdown("").isEmpty)
        XCTAssertTrue(MarkdownParser.parseMarkdown("   \n  ").isEmpty)
    }
}
