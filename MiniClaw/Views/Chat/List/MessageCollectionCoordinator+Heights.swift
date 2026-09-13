import MiniClawKit
import SwiftUI
import UIKit
import Combine
import Foundation

extension MessageCollectionView.Coordinator {

        /// Measure with the REAL render
        /// engine: an offscreen MarkdownTextView (MiniClawLayoutManager +
        ///
        static func measureAttributedStringHeight(_ attrStr: NSAttributedString,width: CGFloat) -> CGFloat {
            // [T-perf 2026-09-08] ≤8000 分支从 measureTextView.sizeThatFits 换成
            // **CTFramesetter**（纯 CoreText，无 TextKit1 的 NSLayoutManager 全量
            // 排版——428 块种子循环 4.5s 的主体）。CT 对内联代码/粗体有 +2..36pt
            // over-measure——**调用方（seedHeight）把结果写 precalc/估算，首帧占位
            // 语义**，hosting 实测/settle 修正会覆盖，偏差可接受（换 70 倍速度）。
            // 语义：含 8pt inset（与 tv 路径一致）。
            //
            // [2026-09-08 修复] CT **不能**用于含附件的字符串：CTFramesetter 不调用
            // 自定义 NSTextAttachment 的 attachmentBounds（表格/代码块/图片/公式/音
            // 视频/文件/分隔线），高度会塌成占位 → precalc 严重偏矮 → 首帧矮一大截、
            // 实测后修正 = 「流式结束跳高 + 上滑抖动」。故含附件块一律走 TextKit。
            // （MarkdownView 的 sizeThatFits 早有同款 hasAnyAttachment 门，此处漏了。）
            if attrStr.length <= 8000, !attrStr.hasAnyAttachment {
                // [2026-09-13 去重] 复用全库唯一 CT 测量入口，不再内联重写一遍。
                // 等价性：共享实现用 `CFRange(length: 0)`（Apple 语义=整串），内联版原用
                // `length: attrStr.length`，二者同义；`+8`（= textContainerInset 4+4）由本
                // 调用点承担，与 `+Heights:151`、`Snapshot:637` 的调用口径一致。
                return MarkdownView.ctFramesetterHeight(for: attrStr, width: width) + 8
            }
            // [2026-09-12 裁尾修复·测量引擎同源] 本函数原设计（见上方注释）就是用**离屏
            // MarkdownTextView**（与屏上渲染同一个类、同一 MiniClawLayoutManager、
            // 同一 textContainerInset）作真实引擎；实测代码却退化成「裸 NSLayoutManager +
            // NSTextContainer」自建栈。两者在同一字符串、同一宽度下**差 12.3pt**
            // （真机实证：本栈 usedRect+8 = 1699，屏上 MarkdownTextView.sizeThatFits = 1711.3，
            // 仅差一个 line fragment 的舍入累积）→ 播种把这个矮值写进统一缓存
            // （`[SEED] idx=173 src=textkit uiH=1699`）→ 屏上 `sizeThatFits` 命中同一缓存
            // → cell 少 12.3pt（1703 而非 1715.3）→ 尾部半行永久被裁。
            // 恢复同源：直接用与渲染完全相同的类测量（`measureTextView` 与
            // MarkdownView.sizeThatFits 的 mtv 路径是同一个实例、同一口径）。
            let mtv = Self.measureTextView
            mtv.textContainer.size = CGSize(width: width,height: .greatestFiniteMagnitude)
            mtv.textStorage.setAttributedString(attrStr)
            // 返回值语义不变：MarkdownTextView.sizeThatFits 已含 textContainerInset(8pt)。
            return ceil(mtv.sizeThatFits(CGSize(width: width,height: .greatestFiniteMagnitude)).height)
        }

        static let measureTextView = MarkdownTextView()

        /// Accurate height for a USER
        ///
        /// Layout constants mirror ChatView.userRow:
        /// - font: .system(size: scaledMessage(16.5))
        /// - bubble: .padding(.horizontal,14) .padding(.vertical,10) → +20 height, -28 width
        /// - row: HStack { Spacer(minLength: 60); VStack(spacing:6){ attachments?; bubble } }
        /// - cell: .padding(.horizontal, 16) on the whole row
        /// 进程级持久缓存（2026-09-08）：此前调用方每次传入新建的 throwaway 字典，
        /// 缓存形同虚设 → 种子循环对每条 user 消息反复 UILabel/boundingRect 测量
        ///（386-item 会话种子循环 1411ms 的主要构成）。
        /// [2026-09-11 审计收敛] 与实例侧 userBubbleHeightCache 双轨合一（同 key 同值
        /// 两份拷贝、失效路径分叉）；并发策略对齐 _sharedMeasuredHeights（os_unfair_lock）。
        private nonisolated(unsafe) static var _userBubbleLock = os_unfair_lock_s()
        private nonisolated(unsafe) static var _userBubbleMemo: [String: CGFloat] = [:]
        static func userBubbleMemoValue(forKey key: String) -> CGFloat? {
            os_unfair_lock_lock(&_userBubbleLock)
            defer { os_unfair_lock_unlock(&_userBubbleLock) }
            return _userBubbleMemo[key]
        }
        static func setUserBubbleMemoValue(_ h: CGFloat,forKey key: String) {
            os_unfair_lock_lock(&_userBubbleLock)
            defer { os_unfair_lock_unlock(&_userBubbleLock) }
            _userBubbleMemo[key] = h
        }
        /// 进程级 memo 的清理入口（会话切换/清高度缓存时调用）。
        static func clearUserBubbleMemo() {
            os_unfair_lock_lock(&_userBubbleLock)
            defer { os_unfair_lock_unlock(&_userBubbleLock) }
            _userBubbleMemo.removeAll(keepingCapacity: false)
        }
        static func measureUserBubbleHeight(for message: RenderMessage,cvWidth: CGFloat,
                                            allowRender: Bool = true) -> CGFloat? {
            var text = message.content
            if let start = text.range(of: "<user-attached-files>") {
                let end = text.range(of: "</user-attached-files>")
                let endBound = end?.upperBound ?? text.endIndex
                text = String(text[text.startIndex..<start.lowerBound]+text[endBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let attachCount = message.attachments.isEmpty
                ? message.inputAttachments.count : message.attachments.count

            // Attachment tiles (70pt rows) sit above the bubble with 6pt spacing.
            // Reuses the same formula as estimateItemHeight(.user).
            let fontSize = FontSettings.shared.scaledMessage(16.5)
            let usableTextWidth = max(cvWidth-32 /*cell*/ - 60 /*Spacer*/ - 28 /*bubble pad*/,80)

            var attachH: CGFloat = 0
            if attachCount>0 {
                let tilesPerRow = max(1,Int((cvWidth-32-60)/70))
                let rows = ceil(CGFloat(attachCount)/CGFloat(tilesPerRow))
                attachH = rows*70+6 /*VStack spacing*/
            }

            guard !text.isEmpty else {
                return attachCount>0 ? attachH : nil
            }

            let key = "\(text.count)|\(Int(usableTextWidth))|\(Int(fontSize))|\(attachCount)|\(text.hashValue)"
            if let cached = userBubbleMemoValue(forKey: key) { return cached }

            // [2026-09-09 同源修复] 用户气泡正文改由 MarkdownSurface（cmark +
            // UITextView）渲染后，高度必须**同源**：此前用 UILabel 量纯文本，与
            // cmark 的段落间距 / 列表缩进 / 行距完全不符（多行差 10–30pt），
            // precalc 与真实布局不一致 → 每个用户气泡入视口都触发自 sizing
            // 迭代修正，表现为「AI↔用户消息连接处定点卡一下」。
            // 改为走 cmark 管线的同一测量口径（CTFramesetter，与 assistant
            // 文本块一致），并复用统一高度缓存（按宽度分存，旋转自动覆盖）。
            let renderKey = MarkdownRenderCache.key(for: text, fontSize: fontSize)
            if let h = MarkdownRenderCache.shared.cachedHeight(for: renderKey, width: Int(usableTextWidth)) {
                let total = h+20+attachH+1
                setUserBubbleMemoValue(total,forKey: key)
                return total
            }
            // [2026-09-09] 种子循环（applySnapshot 对**全部** item 调 seedHeight）
            // 走 `allowRender = false`：50+ 消息会话有上百个 item，若每条都在主线程
            // 跑一次 cmark 解析 + 富文本构造，进入会话就是串行几百毫秒的卡顿。
            // 这里退回便宜的纯文本 boundingRect 估算——精度由 cell 首次自 sizing
            // 修正（一次性），并且**不写 memo**（避免把不准的值当精确值缓存住）。
            if !allowRender {
                let font = UIFont.systemFont(ofSize: fontSize)
                let cheap = NSAttributedString(string: text,attributes: [.font: font])
                let bounds = cheap.boundingRect(
                    with: CGSize(width: usableTextWidth,height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin,.usesFontLeading],
                    context: nil
                )
                return ceil(bounds.height)+20+attachH+1
            }
            // 精确路径（真正要显示时）：走 cmark 管线，与渲染同源。
            let parsed = MarkdownContent(prepareMarkdownForRender(text))
            let attr = renderMarkdownBlocks(parsed.blocks)
            // +8 = MarkdownTextView 的 textContainerInset（top 4 + bottom 4）。
            // 含富语法（代码块/表格等附件）时 CT 快路径高度失真（CTFramesetter
            // 不调用 attachmentBounds），退回 TextKit 精测——其返回值已含 8pt。
            let measured: CGFloat
            if text.contains("```") || text.contains("|") {
                measured = ceil(Self.measureAttributedStringHeight(attr,width: usableTextWidth))
            } else {
                measured = ceil(MarkdownView.ctFramesetterHeight(for: attr, width: usableTextWidth)) + 8
            }
            MarkdownRenderCache.shared.store(height: measured, key: renderKey, width: Int(usableTextWidth))
            // bubble 垂直 padding (10*2) + 附件块 + 1pt 安全余量。
            // 原 CJK +7 补偿已删：那是补偿 UILabel 与 SwiftUI Text 的行盒差异，
            // 现在测量与渲染同走 TextKit，不再需要。
            let total = measured+20+attachH+1
            setUserBubbleMemoValue(total,forKey: key)
            return total
        }

        /// The owning message id for a list
        static func messageId(of item: MessageListItem) -> UUID? {
            switch item {
            case .wholeMessage(let id): return id
            case .assistantHeader(let id): return id
            case .assistantFooter(let id): return id
            case .assistantBlock(let mid,_): return mid
            }
        }

        /// Stable per-content key for the
        #if DEBUG
        /// Stable content-hash identity for a cell.
        static func stableCellTag(for item: MessageListItem,messages: [RenderMessage],messageIndex: [UUID: Int]) -> String {
            func digest(_ s: String) -> String {
                var h: UInt32 = 5381
                for b in s.prefix(96).utf8 { h = (h &* 33) &+ UInt32(b) }
                return String(h,radix: 36)
            }
            func msg(_ id: UUID) -> RenderMessage? {
                guard let i = messageIndex[id],i<messages.count else { return nil }
                return messages[i]
            }
            switch item {
            case .wholeMessage(let id):
                let c = msg(id)?.content ?? ""
                return "w#\(digest(c))#\(c.count)"
            case .assistantHeader(let id):
                let c = msg(id)?.blocks.first?.content ?? ""
                return "h#\(digest(c))"
            case .assistantFooter(let id):
                let c = msg(id)?.blocks.first?.content ?? ""
                return "f#\(digest(c))"
            case .assistantBlock(let mid,let bid):
                guard let b = msg(mid)?.blocks.first(where: { $0.id == bid }) else { return "b#?" }
                let c = b.content
                return "b#\(digest(c))#\(c.count)#\(b.kind)"
            }
        }
        #endif

        static func contentKey(for item: MessageListItem,messages: [RenderMessage],messageIndex: [UUID: Int]) -> String {
            func msg(_ id: UUID) -> RenderMessage? {
                guard let i = messageIndex[id],i<messages.count else { return nil }
                return messages[i]
            }
            switch item {
            case .wholeMessage(let id):
                let n = msg(id)?.content.count ?? 0
                let a = msg(id)?.attachments.count ?? 0
                return "w:\(id.uuidString):\(n):\(a)"
            case .assistantHeader(let id):
                return "h:\(id.uuidString)"
            case .assistantFooter(let id):
                return "f:\(id.uuidString)"
            case .assistantBlock(let mid,let bid):
                let block = msg(mid)?.blocks.first(where: { $0.id == bid })
                let n = block?.content.count ?? 0
                // [2026-09-09 高度裁切修复] thinking 块的 key 掺入展开态：
                // 收起态量得的高度（如 40pt）会经进程级 memo 在展开后回灌播种，
                // 把 340pt 的展开内容裁成一行（20:21 日志 idx=29 340→40 实证，
                // 无任何 Collapse 日志 = 状态没变、是播种回灌）。展开/收起各占
                // 一个 memo 槽位，互不污染；text 等其他块无此状态，key 不变。
                if case .thinking = block?.kind {
                    let e = (block?.isThinkingExpanded ?? false) ? 1 : 0
                    return "b:\(mid.uuidString):\(bid.uuidString):\(n):e\(e)"
                }
                return "b:\(mid.uuidString):\(bid.uuidString):\(n)"
            }
        }

        static func estimateItemHeight(_ item: MessageListItem,messages: [RenderMessage],width: CGFloat) -> CGFloat {
            let scale = FontSettings.shared.scaledMessage(16)
            let lineHeight = scale*1.4
            let hPad: CGFloat = 80

            switch item {
            case .wholeMessage(let msgId):
                guard let msg = messages.first(where: { $0.id == msgId }) else { return 44 }
                switch msg.role {
                case .compactDivider: return 44
                case .systemInfo: return 36
                case .user:
                    // Use the SAME accurate
            if let h = Self.measureUserBubbleHeight(for: msg,cvWidth: width) {
                return h
            }
                    let tw = max(width-hPad,100)
                    let attachCount = msg.attachments.count
                    let imgH: CGFloat
                    if attachCount>0 {
                        let tilesPerRow = max(1,Int(tw/70))
                        let rows = ceil(CGFloat(attachCount)/CGFloat(tilesPerRow))
                        imgH = rows*70
                    } else {
                        imgH = 0
                    }
                    return imgH+44
                case .assistant: return 200
                }
            case .assistantHeader:
                return 28
            case .assistantBlock(let msgId,let blockId):
                guard let msg = messages.first(where: { $0.id == msgId }),
                      let block = msg.blocks.first(where: { $0.id == blockId }) else { return 44 }
                switch block.kind {
                case .text:
                    // [2026-09-11 尾部行裁切修复] 仅**新鲜**渲染结果可用于精确高度：
                    // 陈旧 attr 按旧内容算高 → 矮值 → 尾部行被裁。判据与 precalc 路径、
                    // 渲染侧 prebuilt 采用点共用同一事实源（hasFreshRenderedContent）。
                    if let attrStr = block.cachedAttributedString, block.hasFreshRenderedContent {
                        let textWidth = max(width-32,100)
                        // [2026-09-12 裁尾修复·估算必须同源] 此前无条件走 CTFramesetter（`+12`）。
                        // CT 与渲染引擎（MarkdownTextView）在同一内容/宽度下矮 12.3pt
                        // （真机实证：CT 1891→ 估算 1703，而屏上真实需要 1715.3）→ 滑动中新
                        // 创建的 cell 以该估算为初始高度 → `FIRST-MEASURE CORRECTION`
                        // cellH=1703 vs newH=1711.3。优先读**统一高度缓存**（由与渲染同源的
                        // 测量写入，含 8pt textContainerInset），命中即与渲染一致；
                        // miss 才退回 CT 粗估（首帧占位语义不变）。
                        let uKeyEst = MarkdownRenderCache.key(
                            for: block.content, fontSize: FontSettings.shared.scaledMessage(16.5))
                        if let uH = MarkdownRenderCache.shared.cachedHeight(for: uKeyEst, width: Int(textWidth)) {
                            return uH+SelfSizingCell.assistantBlockVerticalChrome   // uH 已含 8pt inset，+4 = 块上下 padding
                        }
                        let textH = MarkdownView.ctFramesetterHeight(for: attrStr,width: textWidth)
                        return textH+12
                    }
                    return Self.estimateTextBlockHeight(block.content,width: width,scale: scale,lineHeight: lineHeight)
                case .thinking:
                    // capsules,).
                    let headerH: CGFloat = 40
                    guard block.isThinkingExpanded,!block.content.isEmpty else {
                        return headerH
                    }
                    let innerWidth = max(width-24,100) // 12pt horizontal pad each side
                    let innerLineHeight: CGFloat = 13*1.4+3 // .lineSpacing(3) on 13pt font
                    let lines = block.content.split(separator: "\n", omittingEmptySubsequences: false)
                    var textH: CGFloat = 0
                    let cpl = max(1,innerWidth/7) // ~7pt per CJK/wide glyph at 13pt
                    for line in lines {
                        let wrapped = max(1,ceil(CGFloat(line.count)/cpl))
                        textH += wrapped*innerLineHeight
                    }
                    let contentH = min(textH+10,300) // ScrollView capped at 300pt
                    let total = headerH+contentH
                    return total
                // Tool capsules measure exactly
                case .readImageTool: return 36
                case .file: return 40
                case .info:
                    let lineCount = max(1, block.content.components(separatedBy: "\n").count)
                    return CGFloat(20+lineCount*16)
                default: return 36 // Tool capsules (execute, browser, etc.): no wrapper pad
                }
            case .assistantFooter:
                return 4
            }
        }

        static func estimateTextBlockHeight(_ content: String,width: CGFloat,scale: CGFloat,lineHeight: CGFloat) -> CGFloat {
            // [T-ios-empty-textblock-gapH] An empty text block renders nothing
            guard !content.isEmpty else { return 0 }
            // [2026-09-13 估高同源·高估方向修复] 原先这里是 `80` ⇒ `tw = width-80`，
            // 而**同一种块**（assistant 文本）的精确路径一律用 `max(cvWidth-32,100)`
            //（见上方 `.assistantBlock` 的 `.text` 分支与 `seedHeight` 的同一分支）。
            // 渲染侧的真实内容宽 = cell 宽 − 2×`blockHPadding`(=16) = **cell 宽 − 32**，
            // 故 80 比真实**窄了 48pt**。
            //
            // 后果不是单纯的"不准"，而是**单向有害**：窄 ⇒ 每行字数少算约 15%
            //（390pt 宽屏：310 vs 358）⇒ 行数偏多 ⇒ 高度**系统性偏高**。而手势期
            // `deferSelfSizing` 的策略是「**只拒绝收缩**、增长放行」⇒ 高出的那一截**变成可见空白**，
            // 且只有松手 settle 才消失 —— 与"手不离开屏幕就出现空白"的症状同构。
            // 反向（低估）的高度会在首次实测时增长（手势期放行、不产生空白），
            // 故本函数的取向应是「**宁短勿长**」；改成与渲染同源的 −32 同时满足
            // "更准"与"更安全"两个方向。
            let hPad: CGFloat = 32
            let tw = max(width-hPad,100)
            let cpl = tw/(scale*0.5)
            var total: CGFloat = 4

            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            var i = 0
            while i<lines.count {
                let line = lines[i]
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if trimmed.hasPrefix("```") {
                    var codeLines = 0
                    i += 1
                    while i<lines.count {
                        let cl = lines[i].trimmingCharacters(in: .whitespaces)
                        if cl.hasPrefix("```") { i += 1; break }
                        codeLines += 1
                        i += 1
                    }
                    total += 32+CGFloat(max(codeLines,1))*18+24
                    continue
                }

                if trimmed.hasPrefix("|") && trimmed.contains("|") {
                    var tableRows = 0
                    while i<lines.count {
                        let tl = lines[i].trimmingCharacters(in: .whitespaces)
                        if tl.hasPrefix("|") && tl.contains("|") {
                            if !tl.contains("---") { tableRows += 1 }
                            i += 1
                        } else {
                            break
                        }
                    }
                    total += CGFloat(max(tableRows,1))*36+16
                    continue
                }

                if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                    total += 16
                    i += 1
                    continue
                }

                if trimmed.hasPrefix("![") && trimmed.contains("](") {
                    total += Self.estimateMarkdownImageHeight(line: trimmed,containerWidth: tw)
                    i += 1
                    continue
                }

                if trimmed == "$$" {
                    i += 1
                    while i<lines.count && lines[i].trimmingCharacters(in: .whitespaces) != "$$" {
                        i += 1
                    }
                    i += 1
                    total += 80
                    continue
                }

                if trimmed.isEmpty {
                    total += lineHeight*0.5
                } else {
                    let charCount = CGFloat(trimmed.count)
                    let wrappedLines = max(1,ceil(charCount/cpl))
                    total += wrappedLines*lineHeight
                }
                i += 1
            }

            // +4 to match the measured-path baseline
            return max(total,lineHeight+4)+4
        }

        static func estimateMarkdownImageHeight(line: String,containerWidth: CGFloat) -> CGFloat {
            let maxImageWidth: CGFloat = 400
            guard let openParen = line.range(of: "]("),
                  let closeParen = line.range(of: ")", range: openParen.upperBound..<line.endIndex) else {
                return 200
            }
            let src = String(line[openParen.upperBound..<closeParen.lowerBound])
            if let cached = NativeMediaImageCache.shared.image(for: src) {
                let imgWidth = min(min(containerWidth,cached.size.width),maxImageWidth)
                let aspect = cached.size.height/max(cached.size.width,1)
                let maxH = UIScreen.main.bounds.height/2
                return min(imgWidth*aspect,maxH)+6
            }
            return 200
        }

}
