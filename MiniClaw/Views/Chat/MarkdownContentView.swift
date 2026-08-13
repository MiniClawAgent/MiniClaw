@preconcurrency import SwiftUI
import AVKit
import PDFKit

struct MarkdownContentView: View {
    let content: String
    /// 流式输出中：解析结果不写持久化缓存（内容在变会产生垃圾条目），
    /// 流式结束后的最终解析（content 变化触发 .task 重解析）自然落盘。
    var isStreaming: Bool = false
    var onOpenURL: ((URL) -> Void)? = nil
    var onImageTap: ((URL) -> Void)? = nil
    /// 所属会话 ID：用于把 miniclaw:// 资源链接解析到当前会话隔离目录（避免回落扁平共享区而找不到文件）。
    var sessionID: UUID? = nil

    @State private var markdownViewerURL: URL? = nil
    @State private var fileContentURL: URL? = nil
    /// 解析结果缓存：流式输出期间 `content` 在每帧大多不变（节流后约 10fps 才变一次），
    /// 相同内容直接复用已解析的 block，避免重复全量解析（消除流式期 O(n²) 重解析开销）。
    @State private var parseCache: (content: String, blocks: [MarkdownBlock])? = nil
    /// 容器实际宽度（由 background GeometryReader 上报）：图片限宽用它保证不超出气泡，
    /// 避免固定 280pt 在小屏上溢出、右侧圆角被气泡 clipShape 裁掉。0 = 尚未测量。
    @State private var containerWidth: CGFloat = 0

    /// 图片块的最大宽度：容器未测量时回落 280；测量后取 min(280, 容器宽 - 8pt 余量)。
    private var maxImageWidth: CGFloat {
        containerWidth > 0 ? min(280, containerWidth - 8) : 280
    }

    var body: some View {
        // VStack（2026-08-07 回滚）：LazyVStack 会让子项被建议「占满容器宽度」，
        // 用户短消息气泡被拉满整行（很空）——块级虚拟化收益有限，回滚保气泡自适应宽度。
        VStack(alignment: .leading, spacing: 6) {
            ForEach(parsedBlocks, id: \.id) { block in
                renderBlock(block)
            }
        }
        // P28(对照 开源参考实现 ClipFix 经验):渲染侧底部呼吸垫——「测量口径必须与
        // 渲染口径一致,不一致时宁可偏大不可偏小」。测量与渲染共用本视图,加在内部
        // 后裁剪时裁的是空 padding 而非文字(覆盖块级与流式全部入口)。
        .padding(.bottom, 3)
        // 上报容器宽度（不影响布局）：图片等固定限宽内容据此自适应，防右侧溢出被裁剪。
        .background(GeometryReader { geo in
            Color.clear.preference(key: MarkdownContainerWidthKey.self, value: geo.size.width)
        })
        .onPreferenceChange(MarkdownContainerWidthKey.self) { w in
            containerWidth = w
        }
        // 解析结果缓存回写放在 .task(id:) 异步上下文（不在 body 同步求值期改 @State），
        // 消除「Modifying state during view update」刷屏警告。body 内 parsedBlocks 只读不写。
        .task(id: content) {
            // 后台解析（2026-08-07）：parseMarkdown 是 static 纯函数——
            // 流式期间全量解析移出主线程（主线程只做一次缓存写入），
            // 超长回复边流式边重解析不再卡 UI。渲染侧 parsedBlocks 未命中时仍同步解析兜底（首帧）。
            // 方案2防抖（2026-08-08）：流式期间 content 每 ~100ms 变化会取消本任务，
            // 先稳定 300ms 再真正解析，避免长文本被「取消-重启」循环饿死（解析 >100ms 时永远赶不上）。
            if isStreaming {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            let blocks = await Task.detached(priority: .userInitiated) {
                Self.parseMarkdown(content)
            }.value
            // 防抖窗口后内容已变 → 本次结果作废（新任务正在解析新内容），丢弃避免旧帧覆盖新帧。
            guard content == self.content else { return }
            parseCache = (content, blocks)
            // 持久化缓存：历史消息（非流式）解析完成即落盘，冷启动后首次进入也命中；
            // 流式中间态不写（内容在变会产生垃圾条目）。
            if !isStreaming {
                MarkdownCacheStore.shared.store(blocks, for: content)
            }
        }
        .sheet(isPresented: Binding(
            get: { markdownViewerURL != nil },
            set: { if !$0 { markdownViewerURL = nil } }
        )) {
            if let url = markdownViewerURL {
                MarkdownFileViewer(sourceURL: url)
            }
        }
        .sheet(isPresented: Binding(
            get: { fileContentURL != nil },
            set: { if !$0 { fileContentURL = nil } }
        )) {
            if let url = fileContentURL {
                FilePreviewView(fileURL: url)
            }
        }
    }

    // MARK: - Parser

    /// 动态字体基准（2026-08-09 字体适配）：以系统 body(17pt) 为基准，跟随系统动态字体缩放。
    /// 设为 static 以便同文件的 MarkdownTableView（表格单元格）也能复用。
    fileprivate static var bodyFontSize: CGFloat {
        UIFontMetrics.default.scaledValue(for: 16.5)
    }

    private var parsedBlocks: [MarkdownBlock] {
        // 三级缓存（2026-08-07）：① 实例级 → ② 全局持久化缓存（内存+磁盘，历史消息命中后
        // 首帧零解析，冷启动/杀进程后同样生效）→ ③ 未命中同步解析供本次渲染（回写异步完成）。
        if let cache = parseCache, cache.content == content {
            return cache.blocks
        }
        if let cached = MarkdownCacheStore.shared.blocks(for: content) {
            parseCache = (content, cached)
            return cached
        }
        if isStreaming {
            // 方案2（2026-08-08）：流式期间已有缓存帧时跳过主线程同步重解析——新帧由
            // .task(id:) 异步解析（带 300ms 防抖）更新，避免每 100ms 全量解析长文本卡 UI。
            // 但「首帧」（parseCache == nil，典型场景：重进正在流式的会话）必须同步解析一次，
            // 否则正文区域空白直到防抖窗口结束才"突然"出现（2026-08-08 真机日志实证）。
            if let cached = parseCache { return cached.blocks }
            return Self.parseMarkdown(content)
        }
        return Self.parseMarkdown(content)
    }

    /// 纯函数（不读实例状态/设置）：可安全在后台线程解析（2026-08-07 流式卡顿优化）。
    private nonisolated static func parseMarkdown(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var id = 0
        var buffer = ""
        var inCodeBlock = false
        var codeLanguage = ""
        var codeContent = ""
        var codeFenceChar: Character = "`"   // 围栏字符（``` 或 ~~~），闭合须同字符（2026-08-08 补齐）

        // 引用式链接定义收集（2026-08-08 补齐）：`[ref]: url` 定义行不渲染，
        // 正文中 `[text][ref]` / `[ref][]` 在文本块产出时替换为显式链接。
        var linkRefs: [String: String] = [:]
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let m = t.firstMatch(of: /^\[([^\]]+)\]:\s*(\S+)/) {
                linkRefs[String(m.1).lowercased()] = String(m.2)
            }
        }

        var pendingBulletItems: [(text: String, indent: Int)] = []
        var pendingOrderedItems: [(text: String, indent: Int, start: Int)] = []
        var pendingTaskItems: [(isCompleted: Bool, content: String, indent: Int)] = []

        func flushPendingLists() {
            if !pendingBulletItems.isEmpty {
                id += 1
                blocks.append(.bulletList(items: pendingBulletItems.map(\.text), indent: pendingBulletItems[0].indent, id: id))
                pendingBulletItems = []
            }
            if !pendingOrderedItems.isEmpty {
                id += 1
                blocks.append(.orderedList(items: pendingOrderedItems.map(\.text), indent: pendingOrderedItems[0].indent, start: pendingOrderedItems[0].start, id: id))
                pendingOrderedItems = []
            }
            if !pendingTaskItems.isEmpty {
                id += 1
                blocks.append(.taskList(items: pendingTaskItems.map { (isCompleted: $0.isCompleted, content: $0.content) }, indent: pendingTaskItems[0].indent, id: id))
                pendingTaskItems = []
            }
        }

        func flushTextBuffer() {
            let content = buffer.trimmingCharacters(in: .newlines)
            if !content.isEmpty {
                id += 1
                blocks.append(.text(content: content, id: id))
            }
            buffer = ""
        }

        let lines = text.components(separatedBy: "\n")
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // ── 代码块（``` 或 ~~~ 围栏；闭合须同字符）──
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushTextBuffer()
                flushPendingLists()
                if inCodeBlock {
                    if codeFenceChar == trimmed.first {
                        id += 1
                        blocks.append(
                            .codeBlock(
                                language: codeLanguage,
                                content: codeContent.trimmingCharacters(in: .newlines),
                                id: id
                            )
                        )
                        codeContent = ""
                        codeLanguage = ""
                        inCodeBlock = false
                    } else {
                        // 异字符围栏（如 ~~~ 里嵌 ```）：按内容行处理
                        codeContent += line + "\n"
                    }
                } else {
                    codeFenceChar = trimmed.first ?? "`"
                    codeLanguage = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                    inCodeBlock = true
                }
                index += 1
                continue
            }
            if inCodeBlock {
                codeContent += line + "\n"
                index += 1
                continue
            }

            // ── 空行 ──
            if trimmed.isEmpty {
                flushTextBuffer()
                flushPendingLists()
                index += 1
                continue
            }

            // ── 表格 ──
            if index + 1 < lines.count,
               isTableRow(trimmed),
               isTableSeparator(lines[index + 1]) {
                flushTextBuffer()
                flushPendingLists()

                let headers = parseTableCells(trimmed)
                let alignments = parseTableAlignments(lines[index + 1], columnCount: headers.count)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !candidate.isEmpty, isTableRow(candidate) else { break }
                    rows.append(normalizeTableRow(parseTableCells(candidate), columnCount: headers.count))
                    index += 1
                }

                id += 1
                blocks.append(.table(headers: headers, rows: rows, alignments: alignments, id: id))
                continue
            }


            // ── Setext 标题（2026-08-08 补齐）：下一行为 === 或 --- 时，本行变标题 ──
            // 2026-08-11 修复:检测前排除 ATX 标题(# 开头)与列表 marker 行,
            // 否则 `# 标题\n---` 被误当 H2 且 --- 消失、`- 项\n---` 列表项变 H2。
            if index + 1 < lines.count, !trimmed.hasPrefix("#"), !isListMarkerLine(trimmed) {
                let nextTrimmed = lines[index + 1].trimmingCharacters(in: .whitespaces)
                if !nextTrimmed.isEmpty, nextTrimmed.allSatisfy({ $0 == "=" }) {
                    flushTextBuffer()
                    flushPendingLists()
                    id += 1
                    blocks.append(.heading(level: 1, content: trimmed, id: id))
                    index += 2
                    continue
                }
                if nextTrimmed.count >= 3, nextTrimmed.allSatisfy({ $0 == "-" }) {
                    // 与表格分隔行区分：表格检查已先行（表头行 + 分隔行）；此处仅当本行不是表头
                    flushTextBuffer()
                    flushPendingLists()
                    id += 1
                    blocks.append(.heading(level: 2, content: trimmed, id: id))
                    index += 2
                    continue
                }
            }

            // ── 标题 H1-H6 ──
            if let heading = parseHeading(trimmed) {
                flushTextBuffer()
                flushPendingLists()
                id += 1
                blocks.append(.heading(level: heading.level, content: heading.content, id: id))
                index += 1
                continue
            }

            // ── 分隔线 ──
            if isThematicBreak(trimmed) {
                flushTextBuffer()
                flushPendingLists()
                id += 1
                blocks.append(.thematicBreak(id: id))
                index += 1
                continue
            }

            // ── 任务列表，必须先于普通无序列表识别（支持嵌套缩进，2026-08-08 补齐）──
            if let task = parseTaskItem(trimmed) {
                flushTextBuffer()
                if !pendingBulletItems.isEmpty || !pendingOrderedItems.isEmpty {
                    flushPendingLists()
                }
                if !pendingTaskItems.isEmpty, pendingTaskItems[0].indent != task.indent {
                    flushPendingLists()
                }
                pendingTaskItems.append((task.isCompleted, task.content, task.indent))
                index += 1
                continue
            }

            // ── 无序列表（支持缩进嵌套）──
            if let item = parseBulletItem(trimmed) {
                flushTextBuffer()
                // 缩进必须用原始行计算（trimmed 已去掉前导空格，恒为 0）；
                // 空格数折算成层级（2~9 空格 = 1 级），层级变化才拆块、同层连续行不拆。
                let indent = Self.indentLevel(Self.leadingWhitespaceCount(line))
                if !pendingBulletItems.isEmpty, pendingBulletItems[0].indent != indent {
                    flushPendingLists()
                }
                if !pendingOrderedItems.isEmpty || !pendingTaskItems.isEmpty {
                    flushPendingLists()
                }
                pendingBulletItems.append((item, indent))
                index += 1
                continue
            }

            // ── 有序列表（支持缩进嵌套 + 保留起始数字，2026-08-08 补齐）──
            if let parsed = parseOrderedItem(trimmed) {
                flushTextBuffer()
                // 同上：空格数折算成层级，层级变化才拆块
                let indent = Self.indentLevel(Self.leadingWhitespaceCount(line))
                if !pendingOrderedItems.isEmpty, pendingOrderedItems[0].indent != indent {
                    flushPendingLists()
                }
                if !pendingBulletItems.isEmpty || !pendingTaskItems.isEmpty {
                    flushPendingLists()
                }
                pendingOrderedItems.append((parsed.content, indent, parsed.start))
                index += 1
                continue
            }

            // ── 连续引用合并为一个块（含 CommonMark 续行：无 > 前缀的后续行也并入，2026-08-08 补齐）──
            if parseBlockquote(trimmed) != nil {
                flushTextBuffer()
                flushPendingLists()
                var quoteLines: [String] = []
                var inQuote = true
                while index < lines.count {
                    let l = lines[index].trimmingCharacters(in: .whitespaces)
                    if let quote = parseBlockquote(l) {
                        quoteLines.append(quote)
                        index += 1
                        continue
                    }
                    // 续行：非空、非块语法开头、非引用定义行 → 并入引用（CommonMark 引用续行语义）
                    if inQuote, !l.isEmpty,
                       !l.hasPrefix("#"), !l.hasPrefix("```"), !l.hasPrefix("~~~"),
                       l.firstMatch(of: /^[-*+]\s+/) == nil,
                       l.firstMatch(of: /^\d+\.\s+/) == nil,
                       l.firstMatch(of: /^\[.*\]:\s*\S+/) == nil,
                       l.firstMatch(of: /^[=]+$/) == nil, l.firstMatch(of: /^-{3,}$/) == nil {
                        quoteLines.append(l)
                        index += 1
                        continue
                    }
                    inQuote = false
                    break
                }
                id += 1
                blocks.append(.blockquote(content: quoteLines.joined(separator: "\n"), id: id))
                continue
            }

            // ── 图片 / 视频 / 音频 ![]() ——
            if let m = parseMediaLine(trimmed) {
                flushTextBuffer()
                flushPendingLists()
                id += 1
                switch m.type {
                case .image: blocks.append(.image(alt: m.alt, url: m.url, id: id))
                case .video: blocks.append(.video(alt: m.alt, url: m.url, id: id))
                case .audio: blocks.append(.audio(alt: m.alt, url: m.url, id: id))
                case .code, .pdf, .office, .html, .file:
                    blocks.append(.file(alt: m.alt, url: m.url, fileType: m.type, id: id))
                }
                index += 1
                continue
            }

            // ── 防御性：普通链接指向媒体文件时自动提升为内联渲染 ──
            // 智能体可能输出 [文件名](miniclaw://...png) 而非 ![](miniclaw://...png)。
            // 检测文本行中是否只含一个 markdown 链接且 URL 以媒体扩展名结尾，
            // 若是则提升为对应媒体块（图片/视频/音频/文档），避免灰框或「不支持的 URL」。
            if let m = parseMediaLinkInText(trimmed) {
                flushTextBuffer()
                flushPendingLists()
                id += 1
                switch m.type {
                case .image: blocks.append(.image(alt: m.alt, url: m.url, id: id))
                case .video: blocks.append(.video(alt: m.alt, url: m.url, id: id))
                case .audio: blocks.append(.audio(alt: m.alt, url: m.url, id: id))
                case .code, .pdf, .office, .html, .file:
                    blocks.append(.file(alt: m.alt, url: m.url, fileType: m.type, id: id))
                }
                index += 1
                continue
            }

            // ── 普通文本（含：引用定义行跳过 / 列表续行并入 / 缩进代码块）──
            // 引用定义行：不渲染（已在进入循环前收集）
            if trimmed.firstMatch(of: /^\[.*\]:\s*\S+/) != nil {
                index += 1
                continue
            }
            // 列表续行（2026-08-08 补齐）：列表进行中，无 marker 但缩进 ≥2 的普通行并入最后一项
            let ws = Self.leadingWhitespaceCount(line)
            if !pendingBulletItems.isEmpty || !pendingOrderedItems.isEmpty || !pendingTaskItems.isEmpty {
                if ws >= 2, trimmed.firstMatch(of: /^\[.*\]:\s*\S+/) == nil {
                    if !pendingBulletItems.isEmpty {
                        pendingBulletItems[pendingBulletItems.count - 1].text += "\n" + trimmed
                    } else if !pendingOrderedItems.isEmpty {
                        pendingOrderedItems[pendingOrderedItems.count - 1].text += "\n" + trimmed
                    } else if !pendingTaskItems.isEmpty {
                        pendingTaskItems[pendingTaskItems.count - 1].content += "\n" + trimmed
                    }
                    index += 1
                    continue
                }
            }
            // 缩进代码块（2026-08-08 补齐）：行首 ≥4 空格且不在任何列表/块上下文中 → 代码块
            if ws >= 4, pendingBulletItems.isEmpty, pendingOrderedItems.isEmpty, pendingTaskItems.isEmpty, buffer.isEmpty {
                flushPendingLists()
                var codeLines: [String] = []
                while index < lines.count {
                    let l = lines[index]
                    if Self.leadingWhitespaceCount(l) >= 4 {
                        codeLines.append(String(l.dropFirst(4)))
                        index += 1
                    } else if l.trimmingCharacters(in: .whitespaces).isEmpty {
                        // 空行：若后续仍是缩进行则继续（CommonMark 缩进代码块允许内部空行）
                        var lookahead = index + 1
                        var found = false
                        while lookahead < lines.count {
                            let la = lines[lookahead]
                            if la.trimmingCharacters(in: .whitespaces).isEmpty { lookahead += 1; continue }
                            found = Self.leadingWhitespaceCount(la) >= 4
                            break
                        }
                        if found {
                            codeLines.append("")
                            index += 1
                        } else {
                            break
                        }
                    } else {
                        break
                    }
                }
                id += 1
                blocks.append(.codeBlock(language: "", content: codeLines.joined(separator: "\n").trimmingCharacters(in: .newlines), id: id))
                continue
            }
            flushPendingLists()
            // 引用式链接替换（2026-08-08 补齐）：[text][ref] → [text](url)；[ref][] → [text](url)
            let lineBuf = linkRefs.isEmpty ? line : Self.applyLinkRefs(line, refs: linkRefs)
            buffer += lineBuf + "\n"
            index += 1
        }

        flushTextBuffer()
        flushPendingLists()
        if inCodeBlock {
            id += 1
            blocks.append(
                .codeBlock(
                    language: codeLanguage,
                    content: codeContent.trimmingCharacters(in: .newlines),
                    id: id
                )
            )
        }

        return blocks
    }

    // MARK: - 行级解析辅助

    private nonisolated static func parseHeading(_ line: String) -> (level: Int, content: String)? {
        guard let match = line.firstMatch(of: /^(#{1,6})\s+(.+)/) else { return nil }
        let level = match.1.count
        // 2026-08-08 补齐：剥离尾随闭合 #（`# foo #` → `foo`）
        var content = String(match.2).trimmingCharacters(in: .whitespaces)
        if let closing = content.firstMatch(of: /(?:\s*#+\s*)$/) {
            content = String(content.dropLast(closing.0.count)).trimmingCharacters(in: .whitespaces)
        }
        return (level, content)
    }

    /// 2026-08-11 新增:行是否列表 marker(任务/无序/有序),供 Setext 标题检测
    /// 排除列表行(`- 项\n---` 不应被误判为 H2)。
    private nonisolated static func isListMarkerLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }
        if parseTaskItem(trimmed) != nil { return true }
        if parseBulletItem(trimmed) != nil { return true }
        if parseOrderedItem(trimmed) != nil { return true }
        return false
    }

    private nonisolated static func parseTaskItem(_ line: String) -> (isCompleted: Bool, content: String, indent: Int)? {
        guard let match = line.firstMatch(of: /^\s{0,7}[-*+]\s+\[([ xX])\]\s+(.+)/) else { return nil }
        let marker = String(match.1).lowercased()
        // 任务列表嵌套（2026-08-08 补齐）：行首空格折算层级，与普通列表同口径
        let ws = Self.leadingWhitespaceCount(line)
        return (marker == "x", String(match.2), Self.indentLevel(ws))
    }


    /// 引用式链接替换（2026-08-08 补齐）：`[text][ref]` → `[text](url)`、`[ref][]` → `[ref](url)`。
    /// 不处理单独 `[ref]`（避免误伤普通文本方括号）。ref 大小写不敏感（CommonMark）。
    private nonisolated static func applyLinkRefs(_ line: String, refs: [String: String]) -> String {
        var result = line
        // 先替换 `[ref][]` 短形式（CommonMark：文本与引用名相同），再替换 `[text][ref]`。
        // ref 需转义正则元字符（如 v1.2 的 `.`）；输出不带尖括号（防 normalizeBareURLs 二次处理）。
        for (ref, url) in refs {
            _ = ref
            // 2026-08-11 修复:原正则 `\[ref\]\[\]\]` 无捕获组,模板 `$1` 替换成空串
            // → [text][] 链接文字丢失显示为空白链接。加捕获组保留文本。
            result = result.replacingOccurrences(
                of: "\\[([^\\[\\]]+)\\]\\[\\]",
                with: "[$1](\(url))",
                options: .regularExpression
            )
        }
        for (ref, url) in refs {
            let escaped = NSRegularExpression.escapedPattern(for: ref)
            result = result.replacingOccurrences(
                of: "\\[([^\\[\\]]+)\\]\\[\(escaped)\\]",
                with: "[$1](\(url))",
                options: .regularExpression
            )
        }
        return result
    }

    /// 行首空白（空格）计数：列表嵌套层级依据（tab 按 2 格计）。
    private nonisolated static func leadingWhitespaceCount(_ s: String) -> Int {
        var count = 0
        for ch in s {
            if ch == " " { count += 1 }
            else if ch == "\t" { count += 2 }
            else { break }
        }
        return count
    }

    /// 缩进空格数 → 嵌套层级（单一事实来源，解析/渲染共用）：
    /// 0~1 空格 = 顶层；2~9 空格 = 1 级；10~17 = 2 级；每 8 空格升一级。
    /// markdown 惯例 2~4 空格即 1 级嵌套，直接把空格数当层级会把缩进放大成离谱空白。
    private nonisolated static func indentLevel(_ spaces: Int) -> Int {
        guard spaces >= 2 else { return 0 }
        return (spaces - 2) / 8 + 1
    }

    private nonisolated static func parseBulletItem(_ line: String) -> String? {
        guard let match = line.firstMatch(of: /^[-*+]\s+(.+)/) else { return nil }
        return String(match.1)
    }

    private nonisolated static func parseOrderedItem(_ line: String) -> (start: Int, content: String)? {
        guard let match = line.firstMatch(of: /^(\d+)\.\s+(.+)/) else { return nil }
        // 2026-08-08 补齐：保留原始起始数字（`3.` 开头则从 3 编号）
        return (Int(match.1) ?? 1, String(match.2))
    }

    private nonisolated static func parseBlockquote(_ line: String) -> String? {
        guard let match = line.firstMatch(of: /^>\s?(.*)/) else { return nil }
        return String(match.1)
    }


    private nonisolated static func parseMediaLine(_ line: String) -> (alt: String, url: String, type: MediaType)? {
        guard let match = line.firstMatch(of: /^[\s]*!\[(.*?)\]\(([^\s)]+)\)[\s.,;:]*$/) else { return nil }
        let alt = String(match.1)
        let url = String(match.2)
        // 统一扩展名判定（图片/视频/音频/代码/PDF/Office/HTML，见 classifyMediaType）；
        // 未识别的扩展名（epub/zip/mobi 等）按「通用文件」处理，不再误判为图片——
        // epub 曾因此被 UIImage 加载失败、展示成灰框+路径文本。
        return (alt, url, classifyMediaType(url) ?? .file)
    }

    /// 媒体类型判定（单一事实来源）：根据 URL 扩展名分类；nil = 未识别的通用文件。
    /// 类型判定的**单一事实来源**：parseMediaLine / parseMediaLinkInText / FilePreviewView
    /// 共用，避免多处扩展名列表漂移。先剥离查询参数 / fragment 再取扩展名
    /// （URL 可能带 ?x=1 等后缀）。
    nonisolated static func classifyMediaType(_ urlString: String) -> MediaType? {
        let cleaned = urlString.split(separator: "?", maxSplits: 1)[0]
            .split(separator: "#", maxSplits: 1)[0]
        let ext = cleaned.components(separatedBy: ".").last?.lowercased() ?? ""
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "svg", "heic", "heif":
            return .image
        case "mp4", "mov", "webm", "m4v":
            return .video
        case "mp3", "wav", "ogg", "m4a", "aac":
            return .audio
        case "py", "json", "md", "txt", "yaml", "yml", "toml", "xml", "csv", "sh", "swift", "js", "ts", "css", "log",
             "ini", "conf", "env", "properties", "plist", "sql", "go", "rs", "java", "c", "h", "cpp", "hpp", "cc",
             "kt", "rb", "php", "pl", "lua", "r", "dart", "gradle", "bat", "ps1", "vue", "svelte", "scss", "less",
             "jsonc", "ipynb":
            return .code
        case "pdf":
            return .pdf
        case "docx", "xlsx", "pptx", "doc", "xls", "ppt":
            return .office
        case "html", "htm":
            return .html
        default:
            return nil
        }
    }

    /// 防御性检测：文本行中的普通 markdown 链接 `[alt](url)` 若 URL 以媒体扩展名结尾，
    /// 则提升为媒体块。仅匹配「整行（去首尾空白后）就是一个链接」的场景，避免误匹配
    /// 正常段落中夹杂的文件链接。
    private nonisolated static func parseMediaLinkInText(_ line: String) -> (alt: String, url: String, type: MediaType)? {
        // 匹配 [alt](url) 形式（无 ! 前缀），URL 不含空格和右括号
        guard let match = line.firstMatch(of: /^[\s]*\[(.*?)\]\(([^\s)]+)\)[\s.,;:]*$/) else { return nil }
        let alt = String(match.1)
        let url = String(match.2)
        // 仅对已知媒体扩展名提升（与 parseMediaLine 共用 classifyMediaType 单一实现）
        guard let type = classifyMediaType(url) else { return nil }
        return (alt, url, type)
    }

    private nonisolated static func isThematicBreak(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let marker = compact.first else { return false }
        guard marker == "-" || marker == "*" || marker == "_" else { return false }
        return compact.allSatisfy { $0 == marker }
    }

    private nonisolated static func isTableRow(_ line: String) -> Bool {
        parseTableCells(line).count >= 2
    }

    private nonisolated static func isTableSeparator(_ line: String) -> Bool {
        let cells = parseTableCells(line.trimmingCharacters(in: .whitespaces))
        guard cells.count >= 2 else { return false }
        return cells.allSatisfy { cell in
            let compact = cell.replacingOccurrences(of: " ", with: "")
            // 2026-08-08 放宽：GFM 允许 ≥1 个 `-`（`|-|` 合法），`:---:` 对齐保留
            return compact.firstMatch(of: /^:?-+:?$/) != nil
        }
    }

    /// 从分隔行（`| :--- | :---: | ---: |`）解析每列对齐方式。
    /// `:---` = leading, `:---:` = center, `---:` = trailing, `---` = leading（默认）。
    private nonisolated static func parseTableAlignments(_ line: String, columnCount: Int) -> [ColumnAlignment] {
        let cells = parseTableCells(line.trimmingCharacters(in: .whitespaces))
        var result: [ColumnAlignment] = []
        for cell in cells.prefix(columnCount) {
            let compact = cell.replacingOccurrences(of: " ", with: "")
            let hasLeadingColon = compact.hasPrefix(":")
            let hasTrailingColon = compact.hasSuffix(":")
            if hasLeadingColon && hasTrailingColon {
                result.append(.center)
            } else if hasTrailingColon {
                result.append(.trailing)
            } else {
                result.append(.leading)
            }
        }
        // 补齐到 columnCount（分隔行不足列数时默认 leading）
        while result.count < columnCount { result.append(.leading) }
        return result
    }

    private nonisolated static func parseTableCells(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }

        var cells: [String] = []
        var current = ""
        var isEscaped = false
        var isInCode = false

        for character in value {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" {
                isEscaped = true
                current.append(character)
                continue
            }
            if character == "`" {
                isInCode.toggle()
                current.append(character)
                continue
            }
            if character == "|" && !isInCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private nonisolated static func normalizeTableRow(_ row: [String], columnCount: Int) -> [String] {
        if row.count == columnCount { return row }
        if row.count > columnCount { return Array(row.prefix(columnCount)) }
        return row + Array(repeating: "", count: columnCount - row.count)
    }

    // MARK: - Render

    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let content, _):
            renderHeading(level: level, content: content)
        case .bulletList(let items, let indent, _):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .font(.body)
                            .foregroundStyle(.orange)
                        renderText(item)
                    }
                }
            }
            .padding(.leading, 4 + CGFloat(indent) * 16) // 嵌套层级缩进（二级/三级嵌套）
        case .orderedList(let items, let indent, let start, _):
            // 序号列宽 = 最大序号（最后一位）的自然文本宽度，< 10 项时为 0（取自然宽度即可）。
            let maxLabel = start + items.count - 1
            let labelMinWidth: CGFloat = items.count >= 2
                ? ceil(("\(maxLabel)." as NSString).size(withAttributes: [.font: UIFont.preferredFont(forTextStyle: .body)]).width)
                : 0
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(start + i).")
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: labelMinWidth, alignment: .leading)
                        renderText(item)
                    }
                }
            }
            .padding(.leading, 4 + CGFloat(indent) * 16)
        case .taskList(let items, let indent, _):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: item.isCompleted ? "checkmark.square.fill" : "square")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(item.isCompleted ? Color.green : Color.secondary)
                            .padding(.top, 2)
                        renderText(item.content)
                            .strikethrough(item.isCompleted, color: .secondary)
                            .foregroundStyle(item.isCompleted ? .secondary : .primary)
                    }
                }
            }
            .padding(.leading, 4 + CGFloat(indent) * 16)
            case .blockquote(let content, _):
            HStack(alignment: .top, spacing: 0) {
                Rectangle()
                    .fill(.orange.opacity(0.4))
                    .frame(width: 3)
                // 引用内容递归做块级解析（支持引用里的列表项/嵌套引用），深度受限防无限递归
                quotedBlocksView(content, depth: 0)
                    .padding(.leading, 13)  // 2026-08-08 对齐开源参考实现：每级 13pt 缩进
            }
            .padding(.vertical, 2)
        case .table(let headers, let rows, let alignments, _):
            MarkdownTableView(headers: headers, rows: rows, alignments: alignments)
        case .thematicBreak:
            Divider()
                .padding(.vertical, 4)
        case .text(let content, _):
            renderText(content)
        case .codeBlock(let language, let content, _):
            CodeBlockView(language: language, content: content)
        case .image(let alt, let url, _):
            mediaBlock(alt: alt, url: url, type: .image)
        case .video(let alt, let url, _):
            mediaBlock(alt: alt, url: url, type: .video)
        case .audio(let alt, let url, _):
            mediaBlock(alt: alt, url: url, type: .audio)
        case .file(let alt, let url, let fileType, _):
            mediaBlock(alt: alt, url: url, type: fileType)
        }
    }

    // MARK: - 引用内递归渲染（支持引用里的列表项/标题/嵌套引用）

    /// 引用内容按块级解析渲染；深度 ≥4 或内容为纯文本时回落行内渲染（防无限递归）。
    /// 递归路径用 AnyView 打破 opaque 类型自引用（Swift 6 编译要求）。
    @ViewBuilder
    private func quotedBlocksView(_ content: String, depth: Int) -> some View {
        let blocks = Self.parseMarkdown(content)
        if depth >= 4 {
            renderText(content)
        } else if blocks.count == 1, case .text = blocks[0] {
            renderText(content)
        } else {
            AnyView(
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                        quotedRenderBlock(block, depth: depth + 1)
                    }
                }
            )
        }
    }

    @ViewBuilder
    private func quotedRenderBlock(_ block: MarkdownBlock, depth: Int) -> some View {
        switch block {
        case .blockquote(let inner, _):
            // 引用套引用：继续递归（深度由 quotedBlocksView 兜底）
            AnyView(
                HStack(alignment: .top, spacing: 0) {
                    Rectangle()
                        .fill(.orange.opacity(0.4))
                        .frame(width: 3)
                    // 嵌套引用同级 13pt（2026-08-08 对齐开源参考实现，与一级一致）
                    // 2026-08-11 修复:传 depth+1(原 depth:0 让 ≥4 层防递归兜底永不触发,
                    // 深层嵌套无限累加缩进/反复全量解析)。
                    quotedBlocksView(inner, depth: depth + 1)
                        .padding(.leading, 13)
                }
                .padding(.vertical, 2)
            )
        default:
            renderBlock(block)
        }
    }

    // MARK: - Heading Render

    // MARK: - Media Block (image / video / audio)

    /// 统一解析媒体/文件链接：miniclaw:// 经文件系统映射；以 / 开头的绝对路径按本地文件处理；其余按普通 URL。
    private func resolveURL(_ urlString: String) -> URL? {
        if urlString.hasPrefix("miniclaw://") {
            return FileSystemManager.shared.resolveMiniClawResourceURL(urlString, sessionID: sessionID)
        }
        if urlString.hasPrefix("/") {
            return URL(fileURLWithPath: urlString)
        }
        return URL(string: urlString)
    }

    @ViewBuilder
    private func mediaBlock(alt: String, url urlString: String, type: MediaType) -> some View {
        // 解析 URL（解析失败时在 builder 外打印诊断，避免污染 @ViewBuilder 内容）
        let resolvedURL: URL? = {
            let r = resolveURL(urlString)
            if r == nil {
                NSLog("[MarkdownContentView] ⚠️ 媒体URL解析失败 sessionID=\(sessionID?.uuidString ?? "nil") raw=\(urlString)")
            }
            return r
        }()

        if let mediaURL = resolvedURL {
            switch type {
            case .image:
                // 本地文件（会话目录/附件/共享区里的图片）用 UIImage 直接加载更可靠：
                // AsyncImage 在 iOS 上对 file:// 协议经常静默失败，导致只剩灰框占位符。
                if mediaURL.isFileURL {
                    if let uiImage = Self.loadLocalImage(path: mediaURL.path, raw: urlString) {
                        // 显式显示尺寸(≤maxImageWidth/280 内等比)——与 AttachmentCell 同款写法：
                        // scaledToFit + frame(maxWidth:maxHeight:) 的组合在部分 iOS 版本上
                        // 圆角裁剪异常(右侧圆角丢失)，显式 width/height + clipShape 最可靠。
                        let cgW = max(uiImage.size.width, 1)
                        let cgH = max(uiImage.size.height, 1)
                        let ratio = min(maxImageWidth / cgW, 280 / cgH)
                        let w = max(1, cgW * ratio)
                        let h = max(1, cgH * ratio)
                        Image(uiImage: uiImage)
                            .resizable()
                            .frame(width: w, height: h)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                            .onTapGesture { onImageTap?(mediaURL) }
                    } else {
                        fallbackLabel(alt: alt, url: urlString, type: .image)
                    }
                } else {
                    AsyncImage(url: mediaURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: maxImageWidth, maxHeight: 280, alignment: .leading)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .onTapGesture { onImageTap?(mediaURL) }
                        case .failure:
                            fallbackLabel(alt: alt, url: urlString, type: .image)
                        case .empty:
                            ProgressView()
                                .frame(width: 200, height: 120)
                                .background(Color(.systemGray6))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        @unknown default: EmptyView()
                        }
                    }
                }
            case .video:
                VideoPlayer(player: AVPlayer(url: mediaURL))
                    .frame(maxWidth: 320, minHeight: 180, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            case .audio:
                AudioPlayerView(audioURL: mediaURL, title: alt)
            case .code:
                fileCard(alt: alt, url: urlString, icon: "doc.text", label: L10n.l("code_files"), color: .blue)
            case .pdf:
                fileCard(alt: alt, url: urlString, icon: "doc.richtext", label: L10n.l("pdf_document"), color: .red)
            case .office:
                fileCard(alt: alt, url: urlString, icon: "doc.fill", label: L10n.l("office_documents"), color: .orange)
            case .html:
                fileCard(alt: alt, url: urlString, icon: "safari", label: L10n.l("web_files"), color: .teal)
            case .file:
                fileCard(alt: alt, url: urlString, icon: "doc.fill", label: L10n.l("files"), color: .gray)
            }
        } else {
            fallbackLabel(alt: alt, url: urlString, type: type)
        }
    }

    /// 本地图片加载（带诊断日志）。解析成功但 UIImage 加载失败（文件不存在/格式不支持）时打印，便于排查灰框问题。
    /// 本地图片内存缓存（2026-08-07）：滚动回看含图消息时不再重复读盘 + 全尺寸解码
    /// （原实现每次重绘 UIImage(contentsOfFile:) 同步解码，是滚动卡顿来源之一）。
    /// NSCache 自动淘汰：上限 24 张 / 约 80MB，内存压力下系统先行回收。
    private static let localImageCache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 24
        c.totalCostLimit = 80 * 1024 * 1024
        return c
    }()

    private static func loadLocalImage(path: String, raw: String) -> UIImage? {
        let key = path as NSString
        if let cached = localImageCache.object(forKey: key) {
            return cached
        }
        guard let img = UIImage(contentsOfFile: path) else {
            NSLog("[MarkdownContentView] ⚠️ 图片加载失败 resolved=\(path) raw=\(raw)")
            return nil
        }
        localImageCache.setObject(img, forKey: key)
        return img
    }

    @ViewBuilder
    private func fileCard(alt: String, url urlString: String, icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(alt.isEmpty ? URL(string: urlString)?.lastPathComponent ?? label : alt)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(L10n.l("preview")) {
                openFilePreview(urlString: urlString)
            }
            .font(.caption)
            .buttonStyle(.borderedProminent)
            .tint(color)
            .controlSize(.small)
        }
        .padding(10)
        .frame(width: 280)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func openFilePreview(urlString: String) {
        let resolved = resolveURL(urlString)
        guard let resolved else { return }
        let lower = resolved.pathExtension.lowercased()
        if ["pdf","docx","xlsx","pptx","doc","xls","ppt"].contains(lower) {
            // PDF/Office → 统一预览容器（PDF 用 PDFKit；Office 走元信息卡片）
            Task {
                do {
                    let (data, _) = try await URLSession.shared.data(from: resolved)
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(resolved.lastPathComponent)
                    try data.write(to: tmp)
                    await MainActor.run { fileContentURL = tmp }
                } catch {}
            }
            return
        }
        if lower == "html" || lower == "htm" {
            onOpenURL?(resolved)
            return
        }
        // 代码/文本 → 内联查看器
        fileContentURL = resolved
    }

    @ViewBuilder
    private func fallbackLabel(alt: String, url: String, type: MediaType) -> some View {
        let icon: String = switch type {
        case .image: "photo"
        case .video: "play.rectangle"
        case .audio: "waveform"
        case .code, .html: "doc.text"
        case .pdf: "doc.richtext"
        case .office: "doc.fill"
        case .file: "doc.fill"
        }
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(alt.isEmpty ? url : alt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 200, height: 80)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func renderHeading(level: Int, content: String) -> some View {
        // 2026-08-09 对齐开源参考实现标题比例：H1×1.5 bold / H2×1.3 bold / H3×1.15 semibold /
        // H4×1.0 semibold / H5×0.875 semibold / H6×0.85 semibold；经 UIFontMetrics 随系统缩放。
        let ratio: CGFloat = {
            switch level {
            case 1: return 1.5
            case 2: return 1.3
            case 3: return 1.15
            case 5: return 0.875
            case 6: return 0.85
            default: return 1.0
            }
        }()
        let size = UIFontMetrics.default.scaledValue(for: 16.5 * ratio)
        // 开源参考实现对齐：H1/H2 bold，H3-H6 semibold；标题行距 0，上下 margin = 基准字号
        let weight: Font.Weight = (level == 1 || level == 2) ? .bold : .semibold
        let base = MarkdownContentView.bodyFontSize
        // 2026-08-11 修复:标题内容走行内 markdown 解析(加粗/斜体/链接/代码/删除线),
        // 之前 Text(content) 原样显示 `## **加粗**` 的星号,与列表项/正文行为不一致。
        // 用 parseInlineMarkdown(MarkdownContentView 自己的方法;inlineMarkdown 是
        // MarkdownTableView 的私有方法,跨类型调用会编译失败)。
        Text(parseInlineMarkdown(content))
            .font(Font.system(size: size, weight: weight))
            .foregroundStyle(.primary)
            .padding(.top, base)
            .padding(.bottom, base)
    }

    @ViewBuilder
    private func renderText(_ text: String) -> some View {
        // 软换行合并（markdown 规范 2026-08-06）：段落内单个 \n 渲染为空格，
        // 只有空行/双换行才分段（块级解析已处理）；行首尾空白折叠，避免双空格。
        // 硬换行（2026-08-08 补齐）：行尾两空格或反斜杠 → 保留换行（CommonMark hard break）。
        // 代码块/表格单元格不走本函数，换行原样保留。
        let normalized = Self.hardBreakRespectingSplit(text)
        let attributed = parseInlineMarkdown(normalized)
        Text(attributed)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                // miniclaw:// 内部链接：先解析成本地文件 URL 再路由，避免「不支持的 URL」。
                if url.scheme?.lowercased() == "miniclaw" {
                    if let resolved = FileSystemManager.shared.resolveMiniClawResourceURL(url.absoluteString, sessionID: sessionID) {
                        if resolved.pathExtension.lowercased() == "md" {
                            markdownViewerURL = resolved
                        } else {
                            openFilePreview(urlString: url.absoluteString)
                        }
                    }
                    return .handled
                }
                let path = url.absoluteString.lowercased()
                if path.hasSuffix(".md") || path.contains(".md?") || path.contains(".md#") {
                    markdownViewerURL = url
                } else if let handler = onOpenURL {
                    handler(url)
                }
                return .handled
            })
    }

    /// 硬换行感知的段落规范化（2026-08-08 补齐）：行尾两空格或反斜杠 → 保留为换行；
    /// 其余 \n 合并为空格（软换行）。行内图片 `![alt](url)` 同时转为显式链接（点击打开）。
    private nonisolated static func hardBreakRespectingSplit(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var parts: [String] = []
        for line in lines {
            let raw = line
            var l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty { continue }
            // 行内图片（2026-08-08 补齐）：段中 `![alt](url)` 转为显式链接（Text 无法混排图片，点击打开原图）
            l = l.replacingOccurrences(of: #"!\[([^\]]*)\]\(([^\s)]+)\)"#, with: "[$1]($2)", options: .regularExpression)
            // 硬换行判定必须在 trim 之前（两空格在 trim 后必然消失，2026-08-08 子代理审查修复）
            if raw.hasSuffix("\\") {
                l = String(l.dropLast()).trimmingCharacters(in: .whitespaces)
                parts.append(l)
                parts.append("\n")
            } else if l.hasSuffix("  ") {
                l = l.trimmingCharacters(in: .whitespaces)
                parts.append(l)
                parts.append("\n")
            } else {
                parts.append(l)
            }
        }
        return parts.joined(separator: " ")
            .replacingOccurrences(of: " \\n ", with: "\n")
    }

    /// 裸 URL → 显式 markdown 链接（`[url](<url>)`）。
    /// 覆盖两种形态：`https?://...` 与 `www.` 开头（无协议，如 `www.openmodel.ai`——
    /// 不覆盖无 www 的裸域名如 `openmodel.ai`，避免误伤 `3.14` / `a.b` 等句点文本）。
    /// 排除 `*`：`**URL**` 的闭合星号不能被吞进 URL（否则粗体配对失败）；
    /// 负向后顾 `(?<!\]\()` 排除已是显式链接目标的 URL（`[text](url)` / `![alt](url)`）。
    /// P25:修复 Foundation 强调解析缺陷——「标点结尾 + 紧贴 CJK」时闭合标记失效。
    /// 对成对 `**`/`__`(内容以标点结尾、闭合后紧跟非空白非标点)在闭合标记前插
    /// 零宽空格 U+200B。`***`(粗斜体)跳过交给解析器自身。正常文本零副作用。
    fileprivate static func fixEmphasisAfterPunctuation(_ text: String) -> String {
        var chars = Array(text)
        for marker in ["*", "_"] {
            let m = Character(marker)
            var i = 0
            while i < chars.count {
                guard chars[i] == m, i + 1 < chars.count, chars[i + 1] == m else { i += 1; continue }
                // `***` 粗斜体:跳过,交给解析器
                if i + 2 < chars.count, chars[i + 2] == m { i += 1; continue }
                // 找闭合标记
                var j = i + 2
                while j + 1 < chars.count, !(chars[j] == m && chars[j + 1] == m) { j += 1 }
                guard j + 1 < chars.count else { break } // 未闭合,放弃本段
                guard j > i + 2 else { i = j + 2; continue } // 空内容跳过
                let contentLast = chars[j - 1]
                let after = j + 2
                if isPunctuation(contentLast),
                   after < chars.count,
                   !chars[after].isWhitespace,
                   !isPunctuation(chars[after]) {
                    chars.insert("\u{200B}", at: j) // 闭合标记前插零宽空格
                }
                i = after
            }
        }
        return String(chars)
    }

    /// 全角/半角标点集合(含常见中文标点)
    private static func isPunctuation(_ c: Character) -> Bool {
        let puncts = "，。！？；：、（）()“”‘’「」『』【】《》〈〉…—–-·,.;:!?/\\|"
        return puncts.contains(c)
    }

    private static func normalizeBareURLs(_ text: String) -> String {
        // 2026-08-08 扩展：除 https?:// 与 www. 外，补充「无 www 裸域名」（如 openmodel.ai）——
        // 点分域名 + 2-6 位字母 TLD；负向后顾排除：已是链接目标（`](`）、尖括号包裹（`<`）、
        // 小数/邮箱/路径（`[\w.@:/]` 前）；否则显式链接的域名部分会被二次链接化损坏 URL。
        let pattern = #"(?<!\]\()(?<!<)(?:https?://|(?<![:/])www\.|(?<![\w.@:/])(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,6}(?=[/\s，。！？；：、“”‘’（）【】《》,.!?;:)\]\u2026]|$))[^\s*一-鿿　-〿＀-￯，。！？；：“”‘’（）【】《》、]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let r = m.range
            let url = ns.substring(with: r)
            result += ns.substring(with: NSRange(location: last, length: r.location - last))
            // www. 开头的裸域名补 https:// 作为链接目标（否则被当相对链接）。
            let target = url.hasPrefix("www.") ? "https://" + url : url
            result += "[\(url)](<\(target)>)"
            last = r.location + r.length
        }
        result += ns.substring(with: NSRange(location: last, length: ns.length - last))
        return result
    }

    /// 行内 HTML 标签种类（预处理后经 token 落到 AttributedString 属性）。
    private enum InlineHTMLKind {
        case underline   // <u>…</u>
        case highlight   // <mark>…</mark>
    }

    /// 轻量行内 HTML 预处理：
    /// · <u>/<mark> → 唯一 token（⟦U⟧/⟦/U⟧/⟦M⟧/⟦/M⟧），解析后在 AttributedString 里重扫描定位
    ///   （不依赖解析前偏移：markdown 语法如 ** 会被解析消费导致偏移漂移，旧 PUA 字符方案会越界）；
    /// · <em>/<i> → *，<strong>/<b> → **，<s>/<strike>/<del> → ~~（交给 markdown 解析）；
    /// · <p>/<br> → 换行；未知标签剥掉标签保留内容（不丢字）。
    /// 返回 (标记后文本, 按闭合顺序的 词元 配对)。
    private static func markInlineHTML(_ text: String) -> (String, [(open: String, close: String, kind: InlineHTMLKind)]) {
        let uS = "⟦U⟧", uE = "⟦/U⟧", mS = "⟦M⟧", mE = "⟦/M⟧"
        var result = ""
        var pairs: [(open: String, close: String, kind: InlineHTMLKind)] = []
        // 栈：未闭合的开始标记（start 为标记在 result 中的 UTF16 位置）
        var stack: [(start: Int, kind: InlineHTMLKind)] = []
        var remaining = text
        let pattern = /<\s*\/?\s*([a-zA-Z][a-zA-Z0-9]*)(\s[^<>]*)?\s*\/?>/

        while let m = remaining.firstMatch(of: pattern) {
            result += remaining[..<m.range.lowerBound]
            let tag = String(m.1).lowercased()
            let isClosing = remaining[m.range.lowerBound...].hasPrefix("</")
            switch (isClosing, tag) {
            case (false, "u"): result += uS; stack.append((result.utf16.count - uS.utf16.count, .underline))
            case (false, "mark"): result += mS; stack.append((result.utf16.count - mS.utf16.count, .highlight))
            case (true, "u"):
                if let idx = stack.lastIndex(where: { $0.kind == .underline }) {
                    result += uE
                    pairs.append((uS, uE, .underline))
                    stack.remove(at: idx)
                }
            case (true, "mark"):
                if let idx = stack.lastIndex(where: { $0.kind == .highlight }) {
                    result += mE
                    pairs.append((mS, mE, .highlight))
                    stack.remove(at: idx)
                }
            case (false, "em"), (false, "i"): result += "*"
            case (true, "em"), (true, "i"): result += "*"
            case (false, "strong"), (false, "b"): result += "**"
            case (true, "strong"), (true, "b"): result += "**"
            case (false, "s"), (false, "strike"), (false, "del"): result += "~~"
            case (true, "s"), (true, "strike"), (true, "del"): result += "~~"
            case (false, "p"), (true, "p"), (false, "br"): result += "\n"
            default: break // 未知标签：剥掉，保留内容
            }
            remaining = String(remaining[m.range.upperBound...])
        }
        // 未闭合的开始标记（栈内残留）：删除其 token，避免泄漏到正文
        for entry in stack.reversed() {
            let utf16Idx = result.utf16.index(result.utf16.startIndex, offsetBy: entry.start)
            if let strIdx = String.Index(utf16Idx, within: result) {
                let endIdx = result.utf16.index(utf16Idx, offsetBy: 3) // ⟦U⟧/⟦M⟧ 均 3 个 UTF16 单元
                if let endStrIdx = String.Index(endIdx, within: result) {
                    result.removeSubrange(strIdx..<endStrIdx)
                }
            }
        }
        result += remaining
        return (result, pairs)
    }

    private func parseInlineMarkdown(_ text: String) -> AttributedString {
        let (marked, htmlPairs) = Self.markInlineHTML(text)
        // 裸 URL 规范化（2026-08-07 修复）：
        // `AttributedString(markdown:)` 的自动链接检测会把「URL + 紧随的 CJK 文本」整段吞进链接
        // （链接范围无界延伸，中文被 URL 编码），并导致 `**URL**中文` 的粗体配对失败（星号残留）。
        // 解析前把裸 URL 转成显式链接 [url](<url>)：文本范围与目标显式界定，
        // 中文不再被吞；`**` 包裹显式链接可正常粗体。`](` 后的链接目标（显式链接/图片）不转换。
        let normalized = Self.normalizeBareURLs(marked)
        // P25:修复 Foundation AttributedString(markdown:) 的强调解析缺陷——
        // 「强调内容以标点结尾 + 闭合标记后紧跟非空白非标点(CJK)」时闭合标记
        // 不被识别,`**` 字面渲染(实测:`**鯛鱼（吸盘鱼）**头顶…` 三端复现)。
        // 在闭合标记前插入零宽空格 U+200B 即可正确解析,且不可见。
        let emphasisFixed = Self.fixEmphasisAfterPunctuation(normalized)
        do {
            var attributed = try AttributedString(
                markdown: emphasisFixed,
                options: AttributedString.MarkdownParsingOptions(
                    allowsExtendedAttributes: true,
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            )
            // 粗体（**...**）不够粗的根因：整体 `attributed.font = ...` 会把所有 run 的
            // 字重统一成 regular，系统对 stronglyEmphasized 在显式 font 下的加粗映射
            // 会退化（中文环境视觉尤其偏细）。先整体设常规字重，再按意图逐 run 设字体。
            // 2026-08-09 字体适配：正文基准 = 系统动态 body(17)，随系统字体设置缩放。
            let base = MarkdownContentView.bodyFontSize
            attributed.font = Font.system(size: base)
            // 行距 = 字号 × 0.25（2026-08-09 对齐开源参考实现基准；原 0.35 偏松）
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = base * 0.25
            var container = AttributeContainer()
            container.paragraphStyle = paragraph
            attributed.mergeAttributes(container, mergePolicy: .keepNew)
            // 样式 run 收集：粗体 / 斜体（含粗斜体 ***x***：解析为 emphasized 内嵌 stronglyEmphasized 两个 run）
            // 行内代码（2026-08-08 对齐开源参考实现）：收集 .code 意图 run，下方统一应用等宽+橙字
            var styleRanges: [(range: Range<AttributedString.Index>, isBold: Bool, isItalic: Bool)] = []
            var codeRanges: [Range<AttributedString.Index>] = []
            for run in attributed.runs {
                let intent = run.inlinePresentationIntent
                let isBold = intent?.contains(.stronglyEmphasized) == true
                let isItalic = intent?.contains(.emphasized) == true
                if intent?.contains(.code) == true { codeRanges.append(run.range) }
                if isBold || isItalic {
                    styleRanges.append((run.range, isBold, isItalic))
                }
            }
            // 行内代码样式（开源参考实现对齐：baseFont×0.845 等宽 + systemOrange 文字 +
            // 浅色 #F2F2F7 / 深色 #3A3A3C 底衬；圆角 5 需 TextKit 自绘，SwiftUI run 级
            // 仅能提供矩形底衬，先对齐底色）
            for range in codeRanges {
                attributed[range].font = Font.system(size: base * 0.845, design: .monospaced)
                attributed[range].foregroundColor = .orange
                attributed[range].backgroundColor = Color(UIColor { $0.userInterfaceStyle == .dark
                    ? UIColor(white: 0.227, alpha: 1)          // #3A3A3C
                    : UIColor(red: 0.949, green: 0.949, blue: 0.969, alpha: 1) })  // #F2F2F7
            }
            // 链接（开源参考实现对齐：systemBlue + 下划线）
            for run in attributed.runs where run.link != nil {
                attributed[run.range].underlineStyle = .single
                attributed[run.range].foregroundColor = .blue
            }
            // 粗斜体修复：内层粗体 run 若被外层斜体 run 包含，需补斜体（否则被上面的粗体覆盖丢失斜体）。
            for (range, isBold, isItalic) in styleRanges where isBold && !isItalic {
                let hasItalicAncestor = styleRanges.contains { candidate in
                    candidate.isItalic
                        && candidate.range.lowerBound <= range.lowerBound
                        && candidate.range.upperBound >= range.upperBound
                        && candidate.range != range
                }
                if hasItalicAncestor {
                    attributed[range].font = Font.system(size: base, weight: .bold).italic()
                }
            }
            for (range, isBold, isItalic) in styleRanges {
                var font = Font.system(size: base, weight: isBold ? .bold : .regular)
                if isItalic { font = font.italic() }
                attributed[range].font = font
            }
            // 粗斜体：内层粗体 run 若被外层斜体 run 包含，需补斜体（否则被上面的粗体覆盖丢失斜体）。
            for (range, isBold, isItalic) in styleRanges where isBold && !isItalic {
                let hasItalicAncestor = styleRanges.contains { candidate in
                    candidate.isItalic
                        && candidate.range.lowerBound <= range.lowerBound
                        && candidate.range.upperBound >= range.upperBound
                        && candidate.range != range
                }
                if hasItalicAncestor {
                    attributed[range].font = Font.system(size: base, weight: .bold).italic()
                }
            }
            // HTML <u>/<mark> → 下划线 / 荧光笔：在【解析后的】字符串上重扫描 词元 定位
            // （markdown 语法如 ** 会被解析消费，解析前偏移会漂移 → 必须解析后定位）。
            // 流程：① 按 kind 顺序配对 open/close token；② 先按配对范围加属性（只增不删，偏移稳定）；
            // ③ 收集全部 token 位置，按位置降序一次性删除（删除不影响更靠前的位置）。
            var result = attributed
            if !htmlPairs.isEmpty {
                let ns = NSMutableAttributedString(result)
                let str = ns.string
                var markers: [(pos: Int, len: Int)] = []

                for kind in [InlineHTMLKind.underline, InlineHTMLKind.highlight] {
                    guard let first = htmlPairs.first(where: { $0.kind == kind }) else { continue }
                    let open = first.open
                    let close = first.close
                    var opens: [Int] = []
                    var closes: [Int] = []
                    var scanIdx = str.startIndex
                    while scanIdx < str.endIndex {
                        let rest = str[scanIdx...]
                        if let r = rest.range(of: open) {
                            opens.append(str.utf16.distance(from: str.startIndex, to: r.lowerBound))
                            scanIdx = r.upperBound
                        } else if let r = rest.range(of: close) {
                            closes.append(str.utf16.distance(from: str.startIndex, to: r.lowerBound))
                            scanIdx = r.upperBound
                        } else {
                            break
                        }
                    }
                    for i in 0..<min(opens.count, closes.count) {
                        let o = opens[i], c = closes[i]
                        let contentRange = NSRange(location: o + open.utf16.count, length: c - o - open.utf16.count)
                        if contentRange.location >= 0, contentRange.length >= 0,
                           NSMaxRange(contentRange) <= ns.length {
                            switch kind {
                            case .underline:
                                ns.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: contentRange)
                            case .highlight:
                                ns.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.35), range: contentRange)
                            }
                        }
                        markers.append((o, open.utf16.count))
                        markers.append((c, close.utf16.count))
                    }
                }
                // 按位置降序删除全部 token（先删靠后的，前面的偏移不受影响）
                for marker in markers.sorted(by: { $0.pos > $1.pos }) {
                    if marker.pos + marker.len <= ns.length {
                        ns.deleteCharacters(in: NSRange(location: marker.pos, length: marker.len))
                    }
                }
                result = AttributedString(ns)
            }
            return result
        } catch {
            return AttributedString(text)
        }
    }
}

// MARK: - Media Type

enum MediaType: Codable { case image, video, audio, code, pdf, office, html, file }

// MARK: - Table Column Alignment

/// Markdown 表格列对齐方式（由分隔行 `:---:` / `---:` / `:---` 决定）。
enum ColumnAlignment: Codable {
    case leading, center, trailing
}

// MARK: - Markdown Block Types

enum MarkdownBlock: Codable {
    case heading(level: Int, content: String, id: Int)
    case bulletList(items: [String], indent: Int, id: Int)
    case orderedList(items: [String], indent: Int, start: Int, id: Int)
    case taskList(items: [(isCompleted: Bool, content: String)], indent: Int, id: Int)
    case blockquote(content: String, id: Int)
    case table(headers: [String], rows: [[String]], alignments: [ColumnAlignment], id: Int)
    case thematicBreak(id: Int)
    case text(content: String, id: Int)
    case codeBlock(language: String, content: String, id: Int)
    case image(alt: String, url: String, id: Int)
    case video(alt: String, url: String, id: Int)
    case audio(alt: String, url: String, id: Int)
    case file(alt: String, url: String, fileType: MediaType, id: Int)

    // MARK: Codable（持久化缓存用；taskList 的元组转 TaskItem 结构编解码）
    private enum Kind: String, Codable {
        case heading, bulletList, orderedList, taskList, blockquote, table,
             thematicBreak, text, codeBlock, image, video, audio, file
    }
    private struct TaskItem: Codable {
        let isCompleted: Bool
        let content: String
    }
    private enum CodingKeys: String, CodingKey {
        case kind, level, content, items, indent, start, headers, rows, alignments,
             language, alt, url, fileType, id
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .heading(let lv, let ct, let id):
            try c.encode(Kind.heading, forKey: .kind)
            try c.encode(lv, forKey: .level); try c.encode(ct, forKey: .content); try c.encode(id, forKey: .id)
        case .bulletList(let items, let indent, let id):
            try c.encode(Kind.bulletList, forKey: .kind)
            try c.encode(items, forKey: .items); try c.encode(indent, forKey: .indent); try c.encode(id, forKey: .id)
        case .orderedList(let items, let indent, let start, let id):
            try c.encode(Kind.orderedList, forKey: .kind)
            try c.encode(items, forKey: .items); try c.encode(indent, forKey: .indent)
            try c.encode(start, forKey: .start); try c.encode(id, forKey: .id)
        case .taskList(let items, let indent, let id):
            try c.encode(Kind.taskList, forKey: .kind)
            try c.encode(items.map { TaskItem(isCompleted: $0.isCompleted, content: $0.content) }, forKey: .items)
            try c.encode(indent, forKey: .indent); try c.encode(id, forKey: .id)
        case .blockquote(let ct, let id):
            try c.encode(Kind.blockquote, forKey: .kind)
            try c.encode(ct, forKey: .content); try c.encode(id, forKey: .id)
        case .table(let headers, let rows, let alignments, let id):
            try c.encode(Kind.table, forKey: .kind)
            try c.encode(headers, forKey: .headers); try c.encode(rows, forKey: .rows)
            try c.encode(alignments, forKey: .alignments); try c.encode(id, forKey: .id)
        case .thematicBreak(let id):
            try c.encode(Kind.thematicBreak, forKey: .kind)
            try c.encode(id, forKey: .id)
        case .text(let ct, let id):
            try c.encode(Kind.text, forKey: .kind)
            try c.encode(ct, forKey: .content); try c.encode(id, forKey: .id)
        case .codeBlock(let lang, let ct, let id):
            try c.encode(Kind.codeBlock, forKey: .kind)
            try c.encode(lang, forKey: .language); try c.encode(ct, forKey: .content); try c.encode(id, forKey: .id)
        case .image(let alt, let url, let id):
            try c.encode(Kind.image, forKey: .kind)
            try c.encode(alt, forKey: .alt); try c.encode(url, forKey: .url); try c.encode(id, forKey: .id)
        case .video(let alt, let url, let id):
            try c.encode(Kind.video, forKey: .kind)
            try c.encode(alt, forKey: .alt); try c.encode(url, forKey: .url); try c.encode(id, forKey: .id)
        case .audio(let alt, let url, let id):
            try c.encode(Kind.audio, forKey: .kind)
            try c.encode(alt, forKey: .alt); try c.encode(url, forKey: .url); try c.encode(id, forKey: .id)
        case .file(let alt, let url, let fileType, let id):
            try c.encode(Kind.file, forKey: .kind)
            try c.encode(alt, forKey: .alt); try c.encode(url, forKey: .url)
            try c.encode(fileType, forKey: .fileType); try c.encode(id, forKey: .id)
        }
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .heading:
            self = .heading(level: try c.decode(Int.self, forKey: .level),
                            content: try c.decode(String.self, forKey: .content),
                            id: try c.decode(Int.self, forKey: .id))
        case .bulletList:
            self = .bulletList(items: try c.decode([String].self, forKey: .items),
                               indent: try c.decode(Int.self, forKey: .indent),
                               id: try c.decode(Int.self, forKey: .id))
        case .orderedList:
            let oItems = try c.decode([String].self, forKey: .items)
            let oIndent = try c.decode(Int.self, forKey: .indent)
            let oStart = try c.decodeIfPresent(Int.self, forKey: .start) ?? 1
            let oID = try c.decode(Int.self, forKey: .id)
            self = .orderedList(items: oItems, indent: oIndent, start: oStart, id: oID)
        case .taskList:
            let items = try c.decode([TaskItem].self, forKey: .items)
            self = .taskList(items: items.map { (isCompleted: $0.isCompleted, content: $0.content) },
                             indent: try c.decodeIfPresent(Int.self, forKey: .indent) ?? 0,
                             id: try c.decode(Int.self, forKey: .id))
        case .blockquote:
            self = .blockquote(content: try c.decode(String.self, forKey: .content),
                               id: try c.decode(Int.self, forKey: .id))
        case .table:
            self = .table(headers: try c.decode([String].self, forKey: .headers),
                          rows: try c.decode([[String]].self, forKey: .rows),
                          alignments: try c.decode([ColumnAlignment].self, forKey: .alignments),
                          id: try c.decode(Int.self, forKey: .id))
        case .thematicBreak:
            self = .thematicBreak(id: try c.decode(Int.self, forKey: .id))
        case .text:
            self = .text(content: try c.decode(String.self, forKey: .content),
                         id: try c.decode(Int.self, forKey: .id))
        case .codeBlock:
            self = .codeBlock(language: try c.decode(String.self, forKey: .language),
                              content: try c.decode(String.self, forKey: .content),
                              id: try c.decode(Int.self, forKey: .id))
        case .image:
            self = .image(alt: try c.decode(String.self, forKey: .alt),
                          url: try c.decode(String.self, forKey: .url),
                          id: try c.decode(Int.self, forKey: .id))
        case .video:
            self = .video(alt: try c.decode(String.self, forKey: .alt),
                          url: try c.decode(String.self, forKey: .url),
                          id: try c.decode(Int.self, forKey: .id))
        case .audio:
            self = .audio(alt: try c.decode(String.self, forKey: .alt),
                          url: try c.decode(String.self, forKey: .url),
                          id: try c.decode(Int.self, forKey: .id))
        case .file:
            self = .file(alt: try c.decode(String.self, forKey: .alt),
                         url: try c.decode(String.self, forKey: .url),
                         fileType: try c.decode(MediaType.self, forKey: .fileType),
                         id: try c.decode(Int.self, forKey: .id))
        }
    }

    var id: Int {
        switch self {
        case .heading(_, _, let id): return id
        case .bulletList(_, _, let id): return id
        case .orderedList(_, _, _, let id): return id
        case .taskList(_, _, let id): return id
        case .blockquote(_, let id): return id
        case .table(_, _, _, let id): return id
        case .thematicBreak(let id): return id
        case .text(_, let id): return id
        case .codeBlock(_, _, let id): return id
        case .image(_, _, let id): return id
        case .video(_, _, let id): return id
        case .audio(_, _, let id): return id
        case .file(_, _, _, let id): return id
        }
    }
}

// MARK: - Table View

struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]
    let alignments: [ColumnAlignment]

    var body: some View {
        let widths = columnWidths()
        let heights = rowHeights(widths: widths)
        return ScrollView(.horizontal) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                        cell(header, isHeader: true, column: index,
                             width: widths[safe: index] ?? 120,
                             height: heights[safe: 0] ?? 40)
                    }
                }

                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { columnIndex, value in
                            cell(value, isHeader: false, column: columnIndex,
                                 width: widths[safe: columnIndex] ?? 120,
                                 height: heights[safe: rowIndex + 1] ?? 40)
                        }
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(.separator).opacity(0.25), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .scrollIndicators(.visible)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 列宽（参考 deepseek-reasonix 会话表格：整表自然宽度 + 横向滚动）

    /// 单列兜底上限（pt，不含内边距）：一般情况列宽 = 内容单行自然宽度（不压缩、不换行），
    /// 总宽超容器时整表横向滚动（ScrollView(.horizontal) 已包）。
    /// 仅当单元格内容极端长（长 URL/无空格长串）时才在上限处换行兜底，防表格无限变宽。
    private static let columnMaxWidth: CGFloat = 520
    /// 单元格水平内边距（双侧），计入列宽。列间分隔线是 overlay 在 cell 外侧，
    /// 不占内容区，不计入列宽预算。
    private static let columnHPadding: CGFloat = 16 * 2

    /// 表格测量字体（列宽/切行/行高共用，与渲染 `.font(.body)` 同源）：
    /// preferredFont(.body) 含系统动态字体缩放，杜绝「测量 16pt vs 渲染 body 17pt」的宽度偏差；
    /// bold trait 为渲染字形的最宽近似（粗体=精确、等宽/斜体 < bold、中文粗体不增宽），
    /// 预算宽度 ≥ 渲染宽度 → 切行行数 = 渲染行数，无二次换行、无固定行高裁底。
    private static var tableMeasureFont: UIFont {
        let body = UIFont.preferredFont(forTextStyle: .body)
        let desc = body.fontDescriptor.withSymbolicTraits(.traitBold) ?? body.fontDescriptor
        return UIFont(descriptor: desc, size: 0) // size 0 = 保留 descriptor 字号
    }

    /// 计算每列宽度 = 该列最长单元格（含表头）的原始文本宽度 + 内边距，
    /// 仅在极端内容处夹到 columnMaxWidth。用 NSString.size(withAttributes:) 逐字符累加测宽，
    /// 与 wrappedLines 同一口径，消除 boundingRect 与 size 之间的测量误差。
    private func columnWidths() -> [CGFloat] {
        let columnCount = headers.count
        guard columnCount > 0 else { return [] }
        var widths = Array(repeating: CGFloat(0), count: columnCount)
        let font = Self.tableMeasureFont
        let attrs: [NSAttributedString.Key: Any] = [.font: font]

        func measure(_ text: String, column: Int) {
            guard column >= 0, column < columnCount else { return }
            let w = (text as NSString).size(withAttributes: attrs).width
            widths[column] = max(widths[column], ceil(w))
        }

        for (i, h) in headers.enumerated() { measure(h, column: i) }
        for row in rows {
            for (i, cell) in row.enumerated() { measure(cell, column: i) }
        }

        return widths.map { w in
            // +6pt buffer：size(withAttributes:) 比 SwiftUI Text 实际渲染窄几 pt（字符间 padding/line fragment 偏移），
            // 不加会导致 Text 截断成省略号。
            min(Self.columnMaxWidth, w + Self.columnHPadding + 6)
        }
    }

    /// 计算每行高度 = 该行所有单元格切行后的行数 × 单行高度 + 垂直内边距。
    /// 与渲染同源：都用 wrappedLines 切行，行数是确定值，高度必然吻合。
    private func rowHeights(widths: [CGFloat]) -> [CGFloat] {
        // 行高测量与渲染 .font(.body) 同源（preferredFont 含动态缩放）；行高与字形粗细无关，用常规体。
        let font = UIFont.preferredFont(forTextStyle: .body)
        let lineHeight = ceil(("A" as NSString).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        ).height) + 2

        func measureRow(_ cells: [String]) -> CGFloat {
            var maxH: CGFloat = 0
            for (i, text) in cells.enumerated() where i < widths.count {
                let wrapped = wrappedLines(text, width: max(1, widths[i] - Self.columnHPadding))
                let lineCount = wrapped.reduce(into: 1) { $0 += ($1 == "\n" ? 1 : 0) }
                maxH = max(maxH, CGFloat(lineCount) * lineHeight)
            }
            // 垂直内边距 16×2，且整行不低于 36pt（开源参考实现 minRowHeight=36）
            return max(maxH + 16 * 2, 36)
        }

        var heights: [CGFloat] = [measureRow(headers)]
        for row in rows { heights.append(measureRow(row)) }
        return heights
    }

    /// 按目标宽度把文本切成显式多行（逐字符装箱，插入 \n）。
    /// SwiftUI Text 对显式 \n 必定换行，不依赖任何断行引擎行为——
    /// 长链接/长英文词在切行时被断开，彻底避免省略号与溢出。
    /// 测量字体与 columnWidths 同口径（tableMeasureFont），防止渲染二次换行。
    private func wrappedLines(_ text: String, width: CGFloat) -> String {
        let font = Self.tableMeasureFont
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let target = max(8, width)
        var lines: [String] = []
        var current = ""
        var currentWidth: CGFloat = 0
        for ch in text {
            if ch == "\n" {
                lines.append(current)
                current = ""
                currentWidth = 0
                continue
            }
            let chWidth = (String(ch) as NSString).size(withAttributes: attrs).width
            if currentWidth + chWidth > target && !current.isEmpty {
                lines.append(current)
                current = String(ch)
                currentWidth = chWidth
            } else {
                current.append(ch)
                currentWidth += chWidth
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func cell(_ content: String, isHeader: Bool, column: Int, width: CGFloat, height: CGFloat) -> some View {
        // 文本先按列宽切成显式多行(wrappedLines):SwiftUI Text 对显式 \n 必定换行,
        // 长链接/长英文词在切行时被断开,不依赖任何断行引擎行为——无省略号、无溢出、无重叠。
        let wrapped = wrappedLines(content, width: width - Self.columnHPadding)
        let isSingleLine = !wrapped.contains("\n")
        // 列对齐：由分隔行 `:---:` / `---:` / `:---` 决定，默认 leading。
        let alignment: Alignment = {
            let col = alignments[safe: column] ?? .leading
            switch col {
            case .leading: return isSingleLine ? .leading : .topLeading
            case .center: return isSingleLine ? .center : .top
            case .trailing: return isSingleLine ? .trailing : .topTrailing
            }
        }()
        let textLabel = Text(inlineMarkdown(wrapped))
            .font(.body)
            .fontWeight(isHeader ? .semibold : .regular)
            .foregroundStyle(.primary)
            .textSelection(.enabled)

        let inner = textLabel
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: width, height: height, alignment: alignment)
            .background(isHeader ? Color.accentColor.opacity(0.10) : Color.clear)

        let trailingDivider = Group {
            if column < headers.count - 1 {
                Rectangle()
                    .fill(Color(.separator).opacity(0.25))
                    .frame(width: 1)
            }
        }
        let bottomDivider = Rectangle()
            .fill(Color(.separator).opacity(0.25))
            .frame(height: 1)

        inner
            .overlay(alignment: .trailing) { trailingDivider }
            .overlay(alignment: .bottom) { bottomDivider }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        do {
            // 不覆盖 font：让 markdown 解析出的 inlinePresentationIntent（bold/italic/code）
            // 正常生效，.font(.body) 在 Text 上设默认字体，inlinePresentationIntent 在其上叠加。
            // P26:同 P25——「标点结尾 + 紧贴 CJK」的强调闭合失效,先预处理
            return try AttributedString(
                markdown: MarkdownContentView.fixEmphasisAfterPunctuation(text),
                options: .init(
                    allowsExtendedAttributes: true,
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            )
        } catch {
            return AttributedString(text)
        }
    }
}

// MARK: - Code Block View

struct CodeBlockView: View {
    let language: String
    let content: String

    @State private var isCopied: Bool = false

    /// 代码块主题（来自 外观 → 聊天显示 设置）：auto 跟随系统、light 浅色、dark 深色。
    /// 开源参考实现对齐（2026-08-09）：auto = 亮色黑底绿字 / 深色 15% 白底浅绿字（原灰底单色）。
    private var theme: String { SettingsStore.shared.settings.chat.codeBlockTheme }
    private var codeBackground: Color {
        switch theme {
        case "light": return Color(white: 0.95)
        case "dark":  return Color(white: 0.12)
        default:
            return Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.15, alpha: 1) : .black })
        }
    }
    private var codeForeground: Color {
        switch theme {
        case "light": return Color(white: 0.1)
        case "dark":  return Color(white: 0.92)
        default:
            return Color(UIColor { $0.userInterfaceStyle == .dark
                ? UIColor(red: 0.55, green: 0.95, blue: 0.55, alpha: 1)
                : .systemGreen })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header（开源参考实现对齐：无语言标签，仅右上角复制按钮）
            HStack {
                Spacer()

                Button(action: copyCode) {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        Text(isCopied ? L10n.l("copied") : L10n.l("copy_action"))
                    }
                    .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Code Content（开源参考实现对齐：无折叠全量显示；Menlo 等宽 + 行距 4）
            ScrollView(.horizontal) {
                Text(content)
                    .font(Font.custom("Menlo", size: max(11, UIFontMetrics.default.scaledValue(for: 14))))
                    .lineSpacing(4)
                    .foregroundColor(codeForeground)
                    .padding(12)
            }
        }
        .background(codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(.separator).opacity(0.3), lineWidth: 1)
        )
    }

    private func copyCode() {
        UIPasteboard.general.string = content
        isCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isCopied = false
        }
    }
}

// MARK: - File Preview (code / PDF / Office)

/// 统一文件预览容器（文件管理器 / 会话内文件卡片共用入口）。
/// 按类型分派到统一查看器，所有类型共用：sheet 下滑关闭 + 导航栏文件名 + 右上角分享按钮。
/// 类型判定与聊天消息媒体同一来源（classifyMediaType），不再各自维护清单。
struct FilePreviewView: View {
    let fileURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var mediaType: MediaType
    @State private var textContent: String?
    @State private var isTruncated: Bool
    @State private var fileSize: Int64
    @State private var modifiedAt: Date?
    @State private var showShare = false
    @State private var dragOffset: CGFloat = 0
    @State private var isImageZoomed = false

    /// 本地文件 **同步预读**（读取上限 2MB，毫秒级）：
    /// 打开预览即见内容，无「加载中」转圈——本地小文件预览不该有任何加载态。
    init(fileURL: URL) {
        self.fileURL = fileURL
        var type: MediaType = .file
        var text: String?
        var truncated = false
        var size: Int64 = 0
        var date: Date?

        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path) {
            size = (attrs[.size] as? Int64) ?? 0
            date = attrs[.modificationDate] as? Date
        }
        let rawType = MarkdownContentView.classifyMediaType(fileURL.absoluteString) ?? .file
        switch rawType {
        case .code, .html, .file:
            // 文本候选（白名单文本 + 未知扩展名内容探测）：读前 2MB 尝试 UTF-8 解码；
            // 含 NUL（二进制）或解码失败 → 回退元信息卡片。
            if let handle = try? FileHandle(forReadingFrom: fileURL) {
                let data = handle.readData(ofLength: 2_000_001)
                try? handle.close()
                if !data.isEmpty {
                    truncated = data.count > 2_000_000
                    let slice = truncated ? data.prefix(2_000_000) : data[...]
                    if !slice.prefix(8192).contains(where: { $0 == 0 }) {
                        text = String(data: Data(slice), encoding: .utf8)
                    }
                }
            }
            type = text != nil ? .code : .file
        default:
            type = rawType
        }

        _mediaType = State(initialValue: type)
        _textContent = State(initialValue: text)
        _isTruncated = State(initialValue: truncated)
        _fileSize = State(initialValue: size)
        _modifiedAt = State(initialValue: date)
    }

    var body: some View {
        ZStack {
            // 图片/视频 = 微信式黑色 80% 透明背景;其余(文档/文本/office/音频)= 系统默认背景。
            if mediaType == .image || mediaType == .video {
                Color.black.opacity(0.8).ignoresSafeArea()
            } else {
                Color(.systemBackground).ignoresSafeArea()
            }
            Group {
                switch mediaType {
                case .image: imageViewer
                case .video: videoPlayer
                case .audio: audioPlayer
                case .pdf: pdfViewer
                case .code: textViewer
                default:
                    // office / html / file（含压缩包、未知格式）→ 元信息卡片 + 分享
                    fileInfoCard
                }
            }
            // 内容区强制占满并左上对齐：否则内容垂直居中。
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // 右上角:分享 + 关闭(样式参考会话页选项按钮)。
            VStack {
                HStack(spacing: 12) {
                    Spacer()
                    previewButton("square.and.arrow.up") { showShare = true }
                    previewButton("xmark") { dismiss() }
                }
                Spacer()
            }
            .padding(.top, 12)
            .padding(.trailing, 12)
        }
        .sheet(isPresented: $showShare) {
            ActivityView(items: [fileURL])
        }
    }

    /// 右上角按钮:圆形 secondarySystemBackground 底 + primary 图标 32×32。
    private func previewButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color(.secondarySystemBackground))
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .frame(width: 32, height: 32)
            .contentShape(Circle())
        }
    }

    /// 下滑关闭:图片向下拖动超过阈值即关闭,否则回弹。
    private var downToDismissGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                // 放大状态下下滑是看图(由 UIScrollView 滚动),不触发关闭(2026-08-13)。
                guard !isImageZoomed else { return }
                let dy = value.translation.height
                if dy > 0 { dragOffset = dy }
            }
            .onEnded { value in
                guard !isImageZoomed else { return }
                if value.translation.height > 150 || value.predictedEndTranslation.height > 300 {
                    dismiss()
                } else {
                    withAnimation(.spring()) { dragOffset = 0 }
                }
            }
    }

    // MARK: - 各类型统一查看器

    /// 文本：与日志系统同款的 **UITextView 桥接**（ReadonlyLogTextView）——
    /// SwiftUI `Text` 对大段文本全量布局会卡秒级，UITextView 懒布局秒开。
    /// 等宽 12pt、自动换行、可选中复制；大文件截断提示。
    private var textViewer: some View {
        ReadonlyLogTextView(text: textContent ?? "")
            .overlay(alignment: .topTrailing) {
            if isTruncated {
                Text(L10n.l("file_too_large_truncated_for_preview"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.bar, in: RoundedRectangle(cornerRadius: 6))
                    .padding(8)
            }
        }
    }

    /// 图片:原比例 + 双指捏合放大 + 双击恢复/放大 + 下滑关闭。
    private var imageViewer: some View {
        Group {
            if let image = UIImage(contentsOfFile: fileURL.path) {
                PreviewZoomableImageView(image: image, onZoomChange: { zoomed in
                    isImageZoomed = zoomed
                    // 放大时复位下滑偏移,避免残留的位移影响看图。
                    if zoomed { dragOffset = 0 }
                })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .offset(y: dragOffset)
                    .simultaneousGesture(downToDismissGesture)
            } else {
                fileInfoCard
            }
        }
    }

    /// 视频:AVPlayer 播放器(背景由外层 80% 黑承载)。
    private var videoPlayer: some View {
        VideoPlayer(player: AVPlayer(url: fileURL))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 音频：统一音频播放器（与会话消息内同一组件）。
    private var audioPlayer: some View {
        VStack {
            Spacer()
            AudioPlayerView(audioURL: fileURL, title: fileURL.lastPathComponent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// PDF：PDFKit 统一查看器（自动缩放、支持翻页）。
    private var pdfViewer: some View {
        PDFKitView(url: fileURL)
    }

    /// 元信息卡片：office / 压缩包 / 未知格式兜底（名称 / 大小 / 类型 / 修改时间 + 分享引导）。
    private var fileInfoCard: some View {
        VStack(spacing: 12) {
            Image(systemName: mediaType == .office ? "doc.text" : "doc")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(fileURL.lastPathComponent)
                .font(.headline)
                .multilineTextAlignment(.center)
            if fileSize > 0 || modifiedAt != nil {
                let sizeText = fileSize > 0 ? ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file) : ""
                let dateText = modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? ""
                Text([sizeText, dateText].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(L10n.l("content_preview_is_not_supported_for_this_type_use_the_share_button_in_the_top_right_to_export"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// PDFKit 桥接：PDF 统一查看器（自动缩放）。
private struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {}
}


struct AudioPlayerView: View {
    let audioURL: URL
    let title: String
    @State private var player = AVPlayer()
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 1

    var body: some View {
        HStack(spacing: 10) {
            Button(action: togglePlay) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color(red: 0.098, green: 0.549, blue: 0.996), in: Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(title.isEmpty ? audioURL.lastPathComponent : title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Slider(value: $currentTime, in: 0...max(duration, 1)) { editing in
                    if !editing { player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600)) }
                }
                .tint(Color(red: 0.098, green: 0.549, blue: 0.996))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 280)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onAppear {
            let item = AVPlayerItem(url: audioURL)
            player.replaceCurrentItem(with: item)
            addTimeObserver()
        }
        .onDisappear { player.pause() }
    }

    private func togglePlay() {
        isPlaying ? player.pause() : player.play()
        isPlaying.toggle()
    }

    private func addTimeObserver() {
        // iOS16 兼容:闭包标注 @Sendable 的 API 内访问 MainActor 属性需 assumeIsolated(队列已是 .main)。
        player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { time in
            MainActor.assumeIsolated {
                currentTime = time.seconds
                duration = player.currentItem?.duration.seconds ?? 1
            }
        }
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { _ in
            MainActor.assumeIsolated {
                isPlaying = false
                player.seek(to: .zero)
            }
        }
    }
}

// MARK: - 容器宽度上报

/// MarkdownContentView 容器宽度（供图片等固定限宽内容自适应，防右侧溢出被气泡裁剪）。
struct MarkdownContainerWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
