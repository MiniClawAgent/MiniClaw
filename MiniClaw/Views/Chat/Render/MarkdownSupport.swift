import MiniClawKit
import SwiftUI

let imgLogger = AppLogger(category: "MiniClawImage")
let nativeAudioExts: Set<String> = ["mp3", "m4a", "wav", "aac", "ogg", "flac"]
import UIKit
import Foundation
import Combine
enum MiniClawToast {
    static func show(_ message: String,duration: TimeInterval = 1.6,
                     systemImage: String = "checkmark.circle.fill") {
        if Thread.isMainThread {
            present(message,duration: duration,systemImage: systemImage)
        } else {
            DispatchQueue.main.async { present(message,duration: duration,systemImage: systemImage) }
        }
    }

    static func present(_ message: String,duration: TimeInterval,
                                systemImage: String = "checkmark.circle.fill") {
        guard let window = keyWindow() else { return }

        let label = UILabel()
        label.text = message
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        label.numberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false

        let check = UIImageView(image: UIImage(systemName: systemImage))
        check.tintColor = .white
        check.contentMode = .scaleAspectFit
        check.translatesAutoresizingMaskIntoConstraints = false

        let capsule = UIView()
        capsule.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        capsule.layer.cornerRadius = 18
        capsule.layer.cornerCurve = .continuous
        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.alpha = 0

        capsule.addSubview(check)
        capsule.addSubview(label)
        window.addSubview(capsule)

        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: capsule.leadingAnchor,constant: 16),
            check.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 16),
            check.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: check.trailingAnchor,constant: 8),
            label.trailingAnchor.constraint(equalTo: capsule.trailingAnchor,constant: -16),
            label.topAnchor.constraint(equalTo: capsule.topAnchor,constant: 10),
            label.bottomAnchor.constraint(equalTo: capsule.bottomAnchor,constant: -10),
            capsule.centerXAnchor.constraint(equalTo: window.centerXAnchor),
            capsule.bottomAnchor.constraint(equalTo: window.safeAreaLayoutGuide.bottomAnchor,constant: -48),
            capsule.leadingAnchor.constraint(greaterThanOrEqualTo: window.leadingAnchor,constant: 24),
            capsule.trailingAnchor.constraint(lessThanOrEqualTo: window.trailingAnchor,constant: -24),
        ])

        UIView.animate(withDuration: 0.25) { capsule.alpha = 1 }
        UIView.animate(withDuration: 0.3,delay: duration,options: [.curveEaseIn]) {
            capsule.alpha = 0
        } completion: { _ in
            capsule.removeFromSuperview()
        }
    }

    private static func keyWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        return windows.first { $0.isKeyWindow } ?? windows.first
    }
}

extension UIView {
    func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let r = responder {
            if let vc = r as? UIViewController { return vc }
            responder = r.next
        }
        return nil
    }

    func enclosingScrollView() -> UIScrollView? {
        var current = self.superview
        while let v = current {
            if let sv = v as? UIScrollView { return sv }
            current = v.superview
        }
        return nil
    }
}

struct ScrollRestoringDismissWrapper<Content: View>: View {
    private weak var scrollView: UIScrollView?
    let savedOffset: CGPoint?
    let content: Content

    init(scrollView: UIScrollView?,savedOffset: CGPoint?,@ViewBuilder content: () -> Content) {
        self.scrollView = scrollView
        self.savedOffset = savedOffset
        self.content = content()
    }

    var body: some View {
        content
            .onDisappear {
                if let scrollView,let savedOffset {
                    DispatchQueue.main.asyncAfter(deadline: .now()+0.1) {
                        scrollView.setContentOffset(savedOffset,animated: false)
                    }
                }
            }
    }
}

extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        let combined = fontDescriptor.symbolicTraits.union(traits)
        guard let descriptor = fontDescriptor.withSymbolicTraits(combined) else { return self }
        return UIFont(descriptor: descriptor,size: 0)
    }
}

final class TableCellLabel: UILabel,UIGestureRecognizerDelegate,UIContextMenuInteractionDelegate {
    var selectableAttributedText: NSAttributedString?
    var copyTableAction: (() -> Void)?
    /// Closure that copies the full table as a PNG image.
    var copyTableImageAction: (() -> Void)?
    nonisolated(unsafe) private weak var activeTextView: TableCellTextView?
    private var dismissTap: UITapGestureRecognizer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        let lp = UILongPressGestureRecognizer(target: self,action: #selector(handleLongPress(_:)))
        lp.minimumPressDuration = 0.4
        addGestureRecognizer(lp)

        let dt = UITapGestureRecognizer(target: self,action: #selector(handleDoubleTap(_:)))
        dt.numberOfTapsRequired = 2
        addGestureRecognizer(dt)

        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    @available(*,unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        removeTapGesture()
        activeTextView?.removeFromSuperview()
    }

    // The label has no NSLayoutManager, so
    // keeps `.backgroundColor` so its MiniClawLayoutManager painter still fires.

    override var attributedText: NSAttributedString? {
        get { super.attributedText }
        set { super.attributedText = newValue.map(Self.strippingSquareCodeBackground) }
    }

    private static func strippingSquareCodeBackground(_ attr: NSAttributedString) -> NSAttributedString {
        let full = NSRange(location: 0,length: attr.length)
        var hasCode = false
        attr.enumerateAttribute(.inlineCodeBackground,in: full,options: []) { value,_,stop in
            if value != nil { hasCode = true; stop.pointee = true }
        }
        guard hasCode else { return attr }
        let mutable = NSMutableAttributedString(attributedString: attr)
        attr.enumerateAttribute(.inlineCodeBackground,in: full,options: []) { value,range,_ in
            if value != nil { mutable.removeAttribute(.backgroundColor,range: range) }
        }
        return mutable
    }

    override func drawText(in rect: CGRect) {
        drawInlineCodeBG()
        super.drawText(in: rect)
    }

    private func drawInlineCodeBG() {
        guard let attr = super.attributedText,attr.length>0,
              let ctx = UIGraphicsGetCurrentContext() else { return }
        let full = NSRange(location: 0,length: attr.length)
        var codeRanges: [NSRange] = []
        attr.enumerateAttribute(.inlineCodeBackground,in: full,options: []) { value,range,_ in
            if value != nil { codeRanges.append(range) }
        }
        guard !codeRanges.isEmpty else { return }

        let storage = NSTextStorage(attributedString: attr)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: bounds.width,height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = numberOfLines
        container.lineBreakMode = lineBreakMode
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)

        let usedHeight = manager.usedRect(for: container).height
        let yOffset = max(0,(bounds.height-usedHeight)/2)

        let bgColor = miniClawInlineCodeBackgroundColor.resolvedColor(with: traitCollection)
        ctx.saveGState()
        ctx.setFillColor(bgColor.cgColor)
        for range in codeRanges {
            let glyphRange = manager.glyphRange(forCharacterRange: range,actualCharacterRange: nil)
            manager.enumerateEnclosingRects(forGlyphRange: glyphRange,
                                            withinSelectedGlyphRange: NSRange(location: NSNotFound,length: 0),
                                            in: container) { rectPtr,_ in
                let r = rectPtr.offsetBy(dx: 0,dy: yOffset).insetBy(dx: -1,dy: -0.5)
                guard r.width>2 else { return }
                let path = UIBezierPath(roundedRect: r,cornerRadius: 5)
                ctx.addPath(path.cgPath)
            }
        }
        ctx.fillPath()
        ctx.restoreGState()
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        promoteToTextViewMode()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        promoteToTextViewMode()
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        promoteToTextViewMode()
        return nil
    }

    private func promoteToTextViewMode() {
        guard let parent = superview,activeTextView == nil else { return }

        let tv = TableCellTextView()
        tv.isEditable = false
        tv.isScrollEnabled = false
        // [Fix 2026-09-14] 同 `MarkdownTextView`：TextKit 的非连续布局必须关掉，否则按字形范围取值
        //（`usedRect` / `glyphRange(forBoundingRect:)`）只覆盖部分文本 ⇒ 测量偏小、尾部不绘制。
        tv.layoutManager.allowsNonContiguousLayout = false
        tv.backgroundColor = .clear
        tv.textContainer.lineFragmentPadding = 0
        tv.attributedText = selectableAttributedText ?? attributedText

        let extraPad: CGFloat = 12
        tv.frame = CGRect(
            x: frame.origin.x,
            y: frame.origin.y-extraPad,
            width: frame.width,
            height: frame.height+extraPad*2
        )
        tv.textContainerInset = UIEdgeInsets(top: extraPad,left: 0,bottom: extraPad,right: 0)

        tv.onResignFirstResponder = { [weak self] in
            self?.demoteTextViewMode()
        }

        tv.copyTableAction = copyTableAction
        tv.copyTableImageAction = copyTableImageAction

        activeTextView = tv
        isHidden = true
        parent.addSubview(tv)

        // Image.
        UIMenuController.shared.menuItems = [
            UIMenuItem(title: String(localized: "Add to Chat Input"), action: #selector(TableCellTextView.addSelectionToChatInput(_:))),
            UIMenuItem(title: String(localized: "Copy Table"), action: #selector(TableCellTextView.copyTable)),
            //
            UIMenuItem(title: String(localized: "Copy Table Image"), action: #selector(TableCellTextView.copyTableImage)),
        ]

        DispatchQueue.main.async { [weak self,weak tv] in
            guard let tv else { return }
            tv.becomeFirstResponder()
            tv.selectedRange = NSRange(location: 0,length: tv.attributedText?.length ?? 0)

            UIMenuController.shared.showMenu(from: tv,rect: tv.bounds)

            DispatchQueue.main.asyncAfter(deadline: .now()+0.3) { [weak self] in
                self?.addDismissTap()
            }
        }
    }

    private func addDismissTap() {
        guard let window = activeTextView?.window,dismissTap == nil else { return }
        let tap = UITapGestureRecognizer(target: self,action: #selector(handleDismissTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
        dismissTap = tap
    }

    private func removeTapGesture() {
        if let tap = dismissTap {
            tap.view?.removeGestureRecognizer(tap)
            dismissTap = nil
        }
    }

    @objc private func handleDismissTap(_ gesture: UITapGestureRecognizer) {
        // Let the text view resign naturally — this triggers demoteTextViewMode()
        // via onResignFirstResponder. Calling demoteTextViewMode() directly here
        activeTextView?.resignFirstResponder()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === dismissTap,UIMenuController.shared.isMenuVisible {
            return false
        }
        return true
    }

    private func demoteTextViewMode() {
        removeTapGesture()
        activeTextView?.onResignFirstResponder = nil
        activeTextView?.removeFromSuperview()
        activeTextView = nil
        isHidden = false
        UIMenuController.shared.menuItems = nil
    }
}

// MARK: - MiniClawToast

/// Lightweight, self-dismissing toast for one-shot action
func resolveMiniClawFileURLForNativeText(url: URL) -> URL? {
    guard url.scheme == "miniclaw" else { return nil }
    guard let host = url.host else {
        imgLogger.warning("[MiniClawImage][Resolve] no host in URL: \(url.absoluteString)")
        return nil
    }
    // same tolerant resolution the other 4 miniclaw:// resolvers already use; this
    let subPaths = MiniClawURLPathDecoding.subPathCandidates(for: url)
    imgLogger.info("[MiniClawImage][Resolve] BEGIN url=\(url.absoluteString) host=\(host) subPaths=\(subPaths) activeSession=\(MessageListModel.activeSessionId ?? "nil")")
    let fm = FileManager.default

    // [2026-09-13 路径统一·渲染侧收敛] 会话目录的路径此前是**本函数自己拼**的
    //（`persistBase/<sid>/<host>/<subPath>`），与 `FileSystemManager` 里那份是**两份实现** ——
    // 多一处漂移就多一类"写进去了却显示不出来"。现统一走唯一的 parse + 映射出口：
    //   `MiniClawResource`（parse 一次，两种写法→同一个值）→ `url(for:policy:.displayFallback)`
    //   （会话目录优先；miss 才回落扁平，且**两者都要求文件存在**）。
    // 保留 `subPaths` 容错候选与"命中即返回"的顺序 ⇒ 对**已存在**的文件行为逐字一致；
    // 唯一差异：会话目录 miss 时会再试一次扁平目录（隔离前遗留文件的**只读**兼容，本次新增）。
    // ⚠️ 这里**刻意不做跨会话扫描** —— 历史事故：B 会话渲染出 A 会话的图。
    // `activeSessionId` 是 UUID **字符串**（`MiniClawResource` 收 `UUID?`），这里显式转换。
    let activeSID = MessageListModel.activeSessionId.flatMap { UUID(uuidString: $0) }
    for subPath in subPaths {
        guard let res = MiniClawResource(rawValue: "/var/MiniClaw/\(host)/\(subPath)",
                                         sessionID: activeSID) else { continue }
        if let u = try? FileSystemManager.shared.url(for: res, policy: .displayFallback),
           fm.fileExists(atPath: u.path) {
            let size = (try? fm.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? -1
            imgLogger.info("[MiniClawImage][Resolve] FOUND via unified resolver path=\(u.path) size=\(size)")
            return u
        }
    }
    imgLogger.info("[MiniClawImage][Resolve] NOT via unified resolver host=\(host) activeSession=\(MessageListModel.activeSessionId ?? "nil")")

    if host == "skills" {
        for subPath in subPaths {
            let candidate = MessageListModel.miniClawSkillsPersistentDir.appendingPathComponent(subPath)
            imgLogger.info("[MiniClawImage][Resolve] checking global skills path=\(candidate.path)")
            if fm.fileExists(atPath: candidate.path) {
                let size = (try? fm.attributesOfItem(atPath: candidate.path)[.size] as? Int64) ?? -1
                imgLogger.info("[MiniClawImage][Resolve] FOUND global skills path=\(candidate.path) size=\(size)")
                return candidate
            }
        }
    } else if host == "memory" {
        for subPath in subPaths {
            let candidate = MessageListModel.miniClawMemoryPersistentDir.appendingPathComponent(subPath)
            imgLogger.info("[MiniClawImage][Resolve] checking global memory path=\(candidate.path)")
            if fm.fileExists(atPath: candidate.path) {
                let size = (try? fm.attributesOfItem(atPath: candidate.path)[.size] as? Int64) ?? -1
                imgLogger.info("[MiniClawImage][Resolve] FOUND global memory path=\(candidate.path) size=\(size)")
                return candidate
            }
        }
    }

    // [T-ios-miniClawurl-cross-session-isolation] DO NOT scan all session dirs.
    // leak fixed in resolveMiniClawFileURL — session B rendering
    // model-use-zimage-0.jpg would resolve to session A's image. miniclaw:// is
    //
    // The rootfs `/var/miniclaw/<host>` fallback is kept ONLY for the global,
    let globalHosts: Set<String> = ["skills", "memory", "shared"]
    if globalHosts.contains(host) {
        for subPath in subPaths {
            let rootfsURL = RootfsManager.shared.dataPath
                .appendingPathComponent("var/miniclaw", isDirectory: true)
                .appendingPathComponent(host,isDirectory: true)
                .appendingPathComponent(subPath)
            if fm.fileExists(atPath: rootfsURL.path) {
                let size = (try? fm.attributesOfItem(atPath: rootfsURL.path)[.size] as? Int64) ?? -1
                imgLogger.info("[MiniClawImage][Resolve] FOUND in global rootfs path=\(rootfsURL.path) size=\(size)")
                return rootfsURL
            }
        }
    }

    imgLogger.warning("[MiniClawImage][Resolve] NOT FOUND in active session / global dirs url=\(url.absoluteString) host=\(host) subPaths=\(subPaths) (cross-session scan disabled for isolation)")
    return nil
}

extension Array where Element == InlineNode {
    var plainText: String {
        map { node -> String in
            switch node {
            case .text(let t): return t
            case .code(let c): return c
            case .emphasis(let ch),.strong(let ch),.strikethrough(let ch): return ch.plainText
            case .link(_,let ch),.image(_,let ch): return ch.plainText
            case .softBreak: return " "
            case .lineBreak: return "\n"
            case .html(let h): return h
            case .inlineMath(let latex): return latex
            }
        }.joined()
    }
}

// MARK: - URL Resolution (bridged from ChatView)

/// Resolves a `miniclaw://` URL to a local file URL.
/// Keeps resolution behavior aligned with ChatView's miniclaw resolver.
final class MarkdownNSRenderer: @unchecked Sendable {
    private(set) var theme: MarkdownTheme

    /// Assistant message this renderer belongs to. Set by `MarkdownView`
    var messageId: UUID?
    var blockId: UUID?

    init(baseFontSize: CGFloat? = nil) {
        self.theme = MarkdownTheme(baseFontSize: baseFontSize)
    }

    func applyFontSizeChange(_ size: CGFloat) {
        theme = MarkdownTheme(baseFontSize: size)
        blockMemo.removeAll()   // [Stage 4 · 块级 memo] 主题随字号变 ⇒ 整表失效
    }
    private var bodyLineSpacing: CGFloat { theme.baseFontSize*0.25 }
    /// miniClawChat list item: .em(0.25) top margin
    private var listItemTopMargin: CGFloat { theme.baseFontSize*0.25 }
    /// miniClawChat headings: .em(1) top and bottom
    private var headingTopMargin: CGFloat { theme.baseFontSize }
    private var headingBottomMargin: CGFloat { theme.baseFontSize }

    var imageAttachmentCache: [String: ImageAttachment] = [:]
    var videoAttachmentCache: [String: VideoAttachment] = [:]
    var audioAttachmentCache: [String: AudioAttachment] = [:]
    var codeBlockAttachmentCache: [Int: CodeBlockAttachment] = [:]
    var codeBlockContentHashes: [Int: Int] = [:]
    ///
    /// was 27 s of main-thread typesetter pin (ips MiniClaw-2026-05-14-094312).
    var tableAttachmentCache: [Int: TableAttachment] = [:]
    var tableAttachmentLRU: [Int] = []
    private let tableAttachmentCacheCap = 64
    /// `refreshAttachViews` swap only the affected TableScrollView in
    var tableSlotCache: [String: TableAttachment] = [:]
    var tableAttachmentReverseKey: [ObjectIdentifier: Int] = [:]
    var mathAttachmentCache: [String: MathAttachment] = [:]
    private var codeBlockIndex = 0
    private var tableIndex = 0

    struct RenderedBlock {
        let attributed: NSAttributedString
        let topMargin: CGFloat?
        let bottomMargin: CGFloat?
        let isBlockAttachment: Bool

        init(attributed: NSAttributedString,topMargin: CGFloat?,bottomMargin: CGFloat?,isBlockAttachment: Bool = false) {
            self.attributed = attributed
            self.topMargin = topMargin
            self.bottomMargin = bottomMargin
            self.isBlockAttachment = isBlockAttachment
        }
    }

    // ── [2026-09-17 · Stage 4] 块级 memo ────────────────────────────────────────
    /// 依据（真机实测）：单次 render 里「逐块渲染」占 84%，而流式期每来一个 delta 就把整条消息的
    /// 全部块重渲一遍。顶层块渲染是「内容 → 产物」的**纯函数**（上下文恒为 `listDepth=0, quoteDepth=0`），故可 memo。
    ///
    /// 三条边界（构造性判据，不靠约定）：
    /// 1. **只缓存产物中不含 `.attachment` 的块** —— 附件实例带 `messageId/blockIndex/needsViewRebuild`
    ///    等可变身份，跨次复用正是本文件 1256–1270 行注释记录过的坑。以「产物里有没有附件」为判据，
    ///    天然排除表格/代码块/公式/图片；也因此**不会扰动** `codeBlockIndex`/`tableIndex`。
    /// 2. **命中要求 `blockId` 一致** —— `MarkdownView` 渲染前会设置 `renderer.blockId`。不一致即视为
    ///    未命中并**覆盖**，故不会返回错内容，也不会让表无限增长。
    /// 3. **字号/主题变化 ⇒ 整表失效**（见 `applyFontSizeChange`）。
    private struct BlockMemoEntry {
        let rendered: RenderedBlock
        let blockId: UUID?
    }
    private var blockMemo: [BlockNode: BlockMemoEntry] = [:]
    #if DEBUG
    private var memoHit = 0
    private var memoMissNew = 0
    private var memoMissBlockId = 0
    private var memoStored = 0
    private var memoHasAttachment = 0
    private var aggN = 0
    private var aggTotalMs = 0.0
    private var aggBlockMs = 0.0
    private var aggMergeMs = 0.0
    private var aggWorstMs = 0.0
    private var aggLastLogAt: CFAbsoluteTime = 0
    #endif

    private static func ms(_ v: Double) -> String { String(format: "%.1f", v) }

    func render(blocks: [BlockNode]) -> NSAttributedString {
        codeBlockIndex = 0
        tableIndex = 0
        let t0 = CFAbsoluteTimeGetCurrent()
        let tableCountBefore = tableAttachmentCache.count

        // 与 `renderBlockSeq(blocks,listDepth:0,quoteDepth:0,tightSpacing:false)` **等价展开**
        // （该函数体就是下面这两句）：逐块渲染走 memo，并把「逐块」与「合并」分开计时。
        let renderedBlocks = blocks.map { renderTopLevelBlock($0) }
        let t1 = CFAbsoluteTimeGetCurrent()
        let result = mergeRenderedBlocksNow(renderedBlocks,tightSpacing: false).attributed
        let t2 = CFAbsoluteTimeGetCurrent()
        let elapsed = (t2-t0)*1000
        let blockMs = (t1-t0)*1000
        let mergeMs = (t2-t1)*1000

        #if DEBUG
        logAggregateIfDue(elapsed: elapsed,blockMs: blockMs,mergeMs: mergeMs)
        #endif

        if elapsed >= 20 || tableIndex>0 {
            let level = elapsed >= 100 ? "🔥" : ""
            let mid = messageId?.uuidString.prefix(8) ?? "?"
            let rId = String(ObjectIdentifier(self).hashValue&0xFFFFFF,radix: 16)
            let msg = "[RND]\(level) mid=\(mid) rnd=\(rId) blocks=\(blocks.count) tables=\(tableIndex) codeBlocks=\(codeBlockIndex) attrLen=\(result.length) \(Self.ms(elapsed))ms 拆分[逐块=\(Self.ms(blockMs))ms 合并=\(Self.ms(mergeMs))ms] tableCache=\(tableCountBefore)→\(tableAttachmentCache.count)"
            #if DEBUG
            // category `MarkdownRenderer` 在 `AppLogger.quietInfoCategories` 里 ⇒ 原 `info` 级既不落盘也不打印
            // （实测当天日志 `[RND]` 0 条）。慢样本（≥20ms）改走 `warn` 以确保落盘；量很小。
            if elapsed >= 20 { Self.rendererLogger.warn(msg) } else { Self.rendererLogger.info(msg) }
            #else
            Self.rendererLogger.info(msg)
            #endif
        }
        return result
    }

    /// 顶层块的 memo 化渲染：命中即复用；未命中则渲染，且仅在产物**不含附件**时入表。
    private func renderTopLevelBlock(_ block: BlockNode) -> RenderedBlock {
        if let e = blockMemo[block] {
            if e.blockId == blockId {
                #if DEBUG
                memoHit += 1
                #endif
                return e.rendered
            }
            #if DEBUG
            memoMissBlockId += 1
            #endif
        } else {
            #if DEBUG
            memoMissNew += 1
            #endif
        }
        let rendered = renderBlock(block,listDepth: 0,quoteDepth: 0)
        if Self.containsAttachment(rendered.attributed) {
            #if DEBUG
            memoHasAttachment += 1
            #endif
        } else {
            blockMemo[block] = BlockMemoEntry(rendered: rendered,blockId: blockId)
            #if DEBUG
            memoStored += 1
            #endif
        }
        return rendered
    }

    /// memo 的**唯一**排除判据：产物里是否含 `NSTextAttachment`。
    private static func containsAttachment(_ s: NSAttributedString) -> Bool {
        guard s.length > 0 else { return false }
        var found = false
        s.enumerateAttribute(.attachment,in: NSRange(location: 0,length: s.length),options: []) { v,_,stop in
            if v != nil { found = true; stop.pointee = true }
        }
        return found
    }

    #if DEBUG
    /// [Stage 4] **本渲染器**的累计成本 + memo 归因，5s 节流打 `warn`。
    /// 为什么必须要它：`[M7]` 只覆盖 `renderMarkdownBlocks`（throwaway renderer）那一路，
    /// 而真正跑流式的是**复用渲染器**这一路 —— 它的会话累计成本此前**无处可见**。
    private func logAggregateIfDue(elapsed: Double,blockMs: Double,mergeMs: Double) {
        aggN += 1
        aggTotalMs += elapsed
        aggBlockMs += blockMs
        aggMergeMs += mergeMs
        if elapsed > aggWorstMs { aggWorstMs = elapsed }
        let now = CFAbsoluteTimeGetCurrent()
        // [降噪 2026-09-17] 首次调用只初始化时间戳：**一次性（throwaway）渲染器占多数**，
        // 若每条都打，探针自己就成了新的噪声源（实测 40 行/40 秒，占新会话日志 27%）。
        if aggLastLogAt == 0 { aggLastLogAt = now }
        guard aggN > 1 else { return }              // 只报"被复用"的渲染器 —— 那才是流式路径
        guard now-aggLastLogAt >= 5.0 else { return }
        aggLastLogAt = now
        let rId = String(ObjectIdentifier(self).hashValue&0xFFFFFF,radix: 16)
        let mid = messageId?.uuidString.prefix(8) ?? "?"
        let total = memoHit+memoMissNew+memoMissBlockId
        let pct = total > 0 ? Double(memoHit)/Double(total)*100 : 0
        Self.rendererLogger.warn("[RNDΣ] rnd=\(rId) mid=\(mid) n=\(aggN) 合计=\(Self.ms(aggTotalMs))ms 逐块=\(Self.ms(aggBlockMs))ms 合并=\(Self.ms(aggMergeMs))ms worst=\(Self.ms(aggWorstMs))ms ‖ memo hit=\(memoHit) miss新=\(memoMissNew) miss换id=\(memoMissBlockId) 含附件=\(memoHasAttachment) 命中率=\(Self.ms(pct))% 表=\(blockMemo.count)")
    }
    #endif

    fileprivate static let rendererLogger = AppLogger(category: "MarkdownRenderer")

    private func renderBlock(_ block: BlockNode,listDepth: Int,quoteDepth: Int) -> RenderedBlock {
        switch block {
        case .paragraph(let content):
            return renderParagraph(content,quoteDepth: quoteDepth)
        case .heading(let level,let content):
            return renderHeading(level: level,content: content,quoteDepth: quoteDepth)
        case .codeBlock(let fenceInfo,let content):
            return renderCodeBlockAttachment(fenceInfo: fenceInfo,content: content,quoteDepth: quoteDepth)
        case .blockquote(let children):
            return renderBlockquote(children: children,listDepth: listDepth,quoteDepth: quoteDepth)
        case .bulletedList(let isTight,let items):
            return renderBulletList(isTight: isTight,items: items,listDepth: listDepth,quoteDepth: quoteDepth)
        case .numberedList(let isTight,let start,let items):
            return renderNumberList(isTight: isTight,start: start,items: items,listDepth: listDepth,quoteDepth: quoteDepth)
        case .taskList(let isTight,let items):
            return renderTaskListView(isTight: isTight,items: items,listDepth: listDepth,quoteDepth: quoteDepth)
        case .table(let alignments,let rows):
            return renderTableAttach(alignments: alignments,rows: rows)
        case .thematicBreak:
            return renderThematicBreakAttach()
        case .htmlBlock(let content):
            return renderHTMLBlockNow(content,quoteDepth: quoteDepth)
        case .mathBlock(let content):
            return renderMathBlockAttach(latex: content)
        }
    }

    private func renderBlockSeq(_ blocks: [BlockNode],listDepth: Int,quoteDepth: Int,tightSpacing: Bool) -> RenderedBlock {
        mergeRenderedBlocksNow(
            blocks.map { renderBlock($0,listDepth: listDepth,quoteDepth: quoteDepth) },
            tightSpacing: tightSpacing
        )
    }

    private func mergeRenderedBlocksNow(_ blocks: [RenderedBlock],tightSpacing: Bool) -> RenderedBlock {
        guard let first = blocks.first else {
            return RenderedBlock(attributed: NSAttributedString(),topMargin: nil,bottomMargin: nil)
        }

        let result = NSMutableAttributedString(attributedString: first.attributed)
        for i in 1..<blocks.count {
            let previous = blocks[i-1]
            let current = blocks[i]
            let suppressBottom = tightSpacing && !previous.isBlockAttachment && !current.isBlockAttachment
            let previousBottom = suppressBottom ? 0 : (previous.bottomMargin ?? 0)
            let spacing = max(current.topMargin ?? 0,previousBottom)
            addBlockSpacing(result,spacing: spacing)
            result.append(blockSeparator(height: spacing))
            result.append(current.attributed)
        }

        return RenderedBlock(
            attributed: result,
            topMargin: first.topMargin,
            bottomMargin: blocks.last?.bottomMargin
        )
    }

    private func blockSeparator(height: CGFloat) -> NSAttributedString {
        let separator = NSMutableAttributedString(string: "\n")
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 0
        style.maximumLineHeight = 0.01
        style.lineSpacing = 0
        separator.addAttributes([
            .font: UIFont.systemFont(ofSize: 0.01),
            .paragraphStyle: style,
        ],range: NSRange(location: 0,length: 1))
        return separator
    }

    private func addBlockSpacing(_ attrStr: NSMutableAttributedString,spacing: CGFloat) {
        guard attrStr.length>0 else { return }
        let text = attrStr.string as NSString
        let lastParaRange = text.paragraphRange(for: NSRange(location: max(text.length-1,0),length: 0))
        let style: NSMutableParagraphStyle
        if let existing = attrStr.attribute(.paragraphStyle,at: lastParaRange.location,effectiveRange: nil) as? NSParagraphStyle {
            style = existing.mutableCopy() as! NSMutableParagraphStyle
        } else {
            style = NSMutableParagraphStyle()
        }
        style.paragraphSpacing = spacing
        attrStr.addAttribute(.paragraphStyle,value: style,range: lastParaRange)
    }

    private func renderParagraph(_ inlines: [InlineNode],quoteDepth: Int) -> RenderedBlock {
        var baseAttrs = baseAttributes(quoteDepth: quoteDepth)
        let style: NSMutableParagraphStyle
        if let existing = baseAttrs[.paragraphStyle] as? NSParagraphStyle {
            style = existing.mutableCopy() as! NSMutableParagraphStyle
        } else {
            style = NSMutableParagraphStyle()
        }
        style.lineSpacing = bodyLineSpacing
        // 2026-08-12:AI 消息段落/图片硬左对齐(LTR 默认 natural 也是左,显式保证
        // 不受未来 paragraphStyle 复用/继承影响,满足"AI 发送的文件靠左显示")。
        style.alignment = .left
        baseAttrs[.paragraphStyle] = style
        return RenderedBlock(
            attributed: renderInlines(inlines,baseAttributes: baseAttrs),
            topMargin: 0,
            bottomMargin: 12
        )
    }

    private func renderHeading(level: Int,content: [InlineNode],quoteDepth: Int) -> RenderedBlock {
        var attrs = baseAttributes(quoteDepth: quoteDepth)
        attrs[.font] = theme.headingFont(level: level)
        let style = NSMutableParagraphStyle()
        // miniClawChat doesn't set relativeLineSpacing for headings
        style.lineSpacing = 0
        if quoteDepth>0 {
            style.headIndent = CGFloat(quoteDepth)*Self.quoteIndentPerLevel
            style.firstLineHeadIndent = style.headIndent
        }
        attrs[.paragraphStyle] = style
        return RenderedBlock(
            attributed: renderInlines(content,baseAttributes: attrs),
            topMargin: headingTopMargin,
            bottomMargin: headingBottomMargin
        )
    }

    private func renderCodeBlockAttachment(fenceInfo: String?,content: String,quoteDepth: Int = 0) -> RenderedBlock {
        // A fence with no info string (a bare
        let parsedLang = fenceInfo?.split(separator: " ").first.map(String.init)
        let language = (parsedLang?.isEmpty == false) ? parsedLang : "text"
        let trimmed = content.hasSuffix("\n") ? String(content.dropLast()) : content
        let idx = codeBlockIndex
        codeBlockIndex += 1

        var hasher = Hasher()
        hasher.combine(trimmed)
        hasher.combine(language)
        let contentHash = hasher.finalize()

        let attachment: CodeBlockAttachment
        if let cached = codeBlockAttachmentCache[idx],codeBlockContentHashes[idx] == contentHash {
            cached.blockIndex = idx
            attachment = cached
        } else {
            // The previous view will be updated in-place by refreshAttachViews via codeBlockViewCache.
            attachment = CodeBlockAttachment(code: trimmed,language: language,theme: theme,quoteDepth: quoteDepth)
            attachment.blockIndex = idx
            codeBlockAttachmentCache[idx] = attachment
            codeBlockContentHashes[idx] = contentHash
        }

        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font,value: theme.baseFont,range: NSRange(location: 0,length: result.length))
        return RenderedBlock(
            attributed: result,
            topMargin: 6,
            bottomMargin: 4,
            isBlockAttachment: true
        )
    }

    private func renderBlockquote(children: [BlockNode],listDepth: Int,quoteDepth: Int) -> RenderedBlock {
        let newDepth = quoteDepth+1
        let renderedChildren = renderBlockSeq(children,listDepth: listDepth,quoteDepth: newDepth,tightSpacing: false)
        let result = NSMutableAttributedString(attributedString: renderedChildren.attributed)
        let fullRange = NSRange(location: 0,length: result.length)
        if fullRange.length>0 {
            // 2026-08-11 嵌套引用修复:先收集本段内已有的更高深度(内层嵌套
            // 块渲染时已写入 depth=2/3…),无条件覆盖会把它压成 1,导致
            // 二级/三级嵌套引用只画一根竖线(drawQuoteBars 按 depth 画线)。
            // 覆盖后写回更高深度,内层 span 才能画多根。
            var deeperRanges: [(NSRange,Int)] = []
            result.enumerateAttribute(.blockquoteDepth,in: fullRange,options: []) { value,range,_ in
                if let d = value as? Int, d > newDepth {
                    deeperRanges.append((range,d))
                }
            }
            result.addAttribute(.blockquoteDepth,value: newDepth,range: fullRange)
            for (r,d) in deeperRanges {
                result.addAttribute(.blockquoteDepth,value: d,range: r)
            }
            // miniClawChat blockquote uses secondaryText color
            // 2026-08-11 引用内链接/行内代码/标题变色修复:与上方 blockquoteDepth
            // 同模式——先收集本段内已有的特殊前景色(链接 linkColor、行内代码
            // inlineCodeColor、标题 labelColor),再覆盖为引用灰,最后写回,
            // 否则 > [链接](url) 和 > `code` 会被压成灰色(链接仍可点但不可辨识)。
            var specialColorRanges: [(NSRange,UIColor)] = []
            result.enumerateAttribute(.foregroundColor,in: fullRange,options: []) { value,range,_ in
                guard let color = value as? UIColor else { return }
                if color != theme.secondaryLabelColor {
                    specialColorRanges.append((range,color))
                }
            }
            result.addAttribute(.foregroundColor,value: theme.secondaryLabelColor,range: fullRange)
            for (r,c) in specialColorRanges {
                result.addAttribute(.foregroundColor,value: c,range: r)
            }
        }
        // Blockquote inherits margins from children (no explicit markdownMargin in miniClawChat)
        return RenderedBlock(
            attributed: result,
            topMargin: renderedChildren.topMargin,
            bottomMargin: renderedChildren.bottomMargin
        )
    }

    private func renderBulletList(isTight: Bool,items: [RawListItem],listDepth: Int,quoteDepth: Int) -> RenderedBlock {
        var renderedItems: [RenderedBlock] = []
        let itemStartIndent = CGFloat(quoteDepth)*Self.quoteIndentPerLevel+CGFloat(listDepth)*Self.listIndentPerLevel
        let itemContentIndent = itemStartIndent+Self.listIndentPerLevel

        // device hit a fresh 0x8BADF00D watchdog (ips MiniClaw-2026-05-14-
        //
        // 0  filled circle "•" U+2022
        // 1  hollow circle "◦" U+25E6
        // 2+ filled square "▪" U+25AA
        let bulletGlyph: String
        switch listDepth {
        case 0: bulletGlyph = "\u{2022}" // •
        case 1: bulletGlyph = "\u{25E6}" // ◦
        default: bulletGlyph = "\u{25AA}" // ▪
        }
        let bulletColor = quoteDepth>0 ? theme.secondaryLabelColor : theme.labelColor
        var bulletAttrs = baseAttributes(quoteDepth: quoteDepth)
        bulletAttrs[.foregroundColor] = bulletColor
        bulletAttrs[.font] = UIFont.systemFont(ofSize: theme.baseFontSize*1.25,weight: .bold)
        bulletAttrs[.baselineOffset] = -theme.baseFontSize*0.05

        for item in items {
            let itemResult = NSMutableAttributedString()
            itemResult.append(NSAttributedString(string: bulletGlyph,attributes: bulletAttrs))
            itemResult.append(NSAttributedString(string: " ", attributes: baseAttributes(quoteDepth: quoteDepth)))
            let child = renderListItemsChildren(item.children,listDepth: listDepth+1,quoteDepth: quoteDepth,isTight: isTight)
            itemResult.append(child.attributed)
            applyListIndentWidth(
                to: itemResult,
                firstLineIndent: itemStartIndent,
                continuationIndent: itemContentIndent
            )
            renderedItems.append(
                RenderedBlock(
                    attributed: itemResult,
                    topMargin: listItemTopMargin,
                    bottomMargin: child.bottomMargin
                )
            )
        }
        let merged = mergeRenderedBlocksNow(renderedItems,tightSpacing: isTight)
        return RenderedBlock(
            attributed: merged.attributed,
            topMargin: merged.topMargin,
            bottomMargin: max(merged.bottomMargin ?? 0,16)
        )
    }

    private func renderNumberList(isTight: Bool,start: Int,items: [RawListItem],listDepth: Int,quoteDepth: Int) -> RenderedBlock {
        var renderedItems: [RenderedBlock] = []
        let itemStartIndent = CGFloat(quoteDepth)*Self.quoteIndentPerLevel+CGFloat(listDepth)*Self.listIndentPerLevel
        let itemContentIndent = itemStartIndent+Self.listIndentPerLevel

        for (i,item) in items.enumerated() {
            let number = "\(start + i). "
            let itemResult = NSMutableAttributedString(string: number,attributes: baseAttributes(quoteDepth: quoteDepth))
            let child = renderListItemsChildren(item.children,listDepth: listDepth+1,quoteDepth: quoteDepth,isTight: isTight)
            itemResult.append(child.attributed)
            applyListIndentWidth(
                to: itemResult,
                firstLineIndent: itemStartIndent,
                continuationIndent: itemContentIndent
            )
            renderedItems.append(
                RenderedBlock(
                    attributed: itemResult,
                    topMargin: listItemTopMargin,
                    bottomMargin: child.bottomMargin
                )
            )
        }
        let merged = mergeRenderedBlocksNow(renderedItems,tightSpacing: isTight)
        return RenderedBlock(
            attributed: merged.attributed,
            topMargin: merged.topMargin,
            bottomMargin: max(merged.bottomMargin ?? 0,16)
        )
    }

    private func renderTaskListView(isTight: Bool,items: [RawTaskListItem],listDepth: Int,quoteDepth: Int) -> RenderedBlock {
        var renderedItems: [RenderedBlock] = []
        let itemStartIndent = CGFloat(quoteDepth)*Self.quoteIndentPerLevel+CGFloat(listDepth)*Self.listIndentPerLevel
        let itemContentIndent = itemStartIndent+Self.listIndentPerLevel

        for item in items {
            let checkbox = item.isCompleted ? "☑ " : "☐ "
            let itemResult = NSMutableAttributedString(string: checkbox,attributes: baseAttributes(quoteDepth: quoteDepth))
            let child = renderListItemsChildren(item.children,listDepth: listDepth+1,quoteDepth: quoteDepth,isTight: isTight)
            itemResult.append(child.attributed)
            applyListIndentWidth(
                to: itemResult,
                firstLineIndent: itemStartIndent,
                continuationIndent: itemContentIndent
            )
            renderedItems.append(
                RenderedBlock(
                    attributed: itemResult,
                    topMargin: listItemTopMargin,
                    bottomMargin: child.bottomMargin
                )
            )
        }
        let merged = mergeRenderedBlocksNow(renderedItems,tightSpacing: isTight)
        return RenderedBlock(
            attributed: merged.attributed,
            topMargin: merged.topMargin,
            bottomMargin: max(merged.bottomMargin ?? 0,16)
        )
    }

    private func renderListItemsChildren(_ children: [BlockNode],listDepth: Int,quoteDepth: Int,isTight: Bool) -> RenderedBlock {
        renderBlockSeq(children,listDepth: listDepth,quoteDepth: quoteDepth,tightSpacing: isTight)
    }

    private func applyListIndentWidth(to attributed: NSMutableAttributedString,firstLineIndent: CGFloat,continuationIndent: CGFloat) {
        guard attributed.length>0 else { return }

        let text = attributed.string as NSString
        let total = NSRange(location: 0,length: text.length)
        var cursor = total.location
        var isFirstParagraph = true

        while cursor<NSMaxRange(total) {
            let paragraphRange = text.paragraphRange(for: NSRange(location: cursor,length: 0))
            let effectiveRange = NSIntersectionRange(paragraphRange,total)
            guard effectiveRange.length>0 else { break }

            let style: NSMutableParagraphStyle
            if let existing = attributed.attribute(.paragraphStyle,at: effectiveRange.location,effectiveRange: nil) as? NSParagraphStyle {
                style = existing.mutableCopy() as! NSMutableParagraphStyle
            } else {
                style = NSMutableParagraphStyle()
            }
            style.lineSpacing = max(style.lineSpacing,bodyLineSpacing)
            // 2026-08-11 列表内引用缩进修复:带 .blockquoteDepth 的段落
            // (baseAttributes 已按 quoteDepth*13 设好 headIndent)不再被列表
            // continuationIndent 抬走——否则引用文字被推到列表缩进(24-48pt),
            // 而竖线 drawQuoteBars 只按 quoteDepth 画在最左 1-17pt,线文错位。
            let isQuotePara = attributed.attribute(.blockquoteDepth,at: effectiveRange.location,effectiveRange: nil) != nil
            if !isQuotePara {
                style.headIndent = max(style.headIndent,continuationIndent)
                if isFirstParagraph {
                    style.firstLineHeadIndent = max(style.firstLineHeadIndent,firstLineIndent)
                    isFirstParagraph = false
                } else {
                    style.firstLineHeadIndent = max(style.firstLineHeadIndent,continuationIndent)
                }
            }
            attributed.addAttribute(.paragraphStyle,value: style,range: effectiveRange)

            cursor = NSMaxRange(paragraphRange)
        }
    }

    private func renderTableAttach(alignments: [RawTableColumnAlignment],rows: [RawTableRow]) -> RenderedBlock {
        let idx = tableIndex
        tableIndex += 1

        // 任务D：renderer 身份(rnd) + messageId(mid) 用于定位冷 MISS 来自哪条路径
        // （mid=? 即 renderMarkdownBlocks 的 throwaway renderer）。
        let mid = messageId?.uuidString.prefix(8) ?? "?"
        let rnd = String(ObjectIdentifier(self).hashValue & 0xFFFFFF, radix: 16)

        var hasher = Hasher()
        hasher.combine(alignments)
        hasher.combine(rows)
        // 任务C：字号变更后旧字号构建的 TableAttachment 高度不符，纳入字号使
        // 不同字号得到不同缓存键，避免改字号后命中旧字号缓存（stale HIT）。
        hasher.combine(theme.baseFontSize)
        let contentHash = hasher.finalize()

        // (a) stays the SAME as one table streams in, but
        // (b) DIFFERS between two genuinely distinct tables in the same message.
        //
        // top of every `render(blocks:)` call — and in the cell-per-block list
        //
        //
        // When blockId is available (cell-per-block list), include it to
        //
        let slotKey = "\(messageId?.uuidString ?? "nil"):\(blockId?.uuidString ?? "_"):\(idx)"

        let attachment: TableAttachment
        if let cached = tableAttachmentCache[contentHash] {
            attachment = cached
            if let pos = tableAttachmentLRU.firstIndex(of: contentHash) {
                tableAttachmentLRU.remove(at: pos)
            }
            tableAttachmentLRU.append(contentHash)
            tableSlotCache[slotKey] = cached
            tableAttachmentReverseKey[ObjectIdentifier(cached)] = contentHash
            Self.rendererLogger.info("[RND] table#\(idx) CACHE HIT rows=\(rows.count) cols=\(alignments.count) hash=\(contentHash) rnd=\(rnd) mid=\(mid)")
        } else if let slotAttachment = tableSlotCache[slotKey] {
            // alive and refreshAttachViews swaps only this attachment's
            slotAttachment.update(alignments: alignments,rows: rows)
            attachment = slotAttachment
            if let oldHash = tableAttachmentReverseKey[ObjectIdentifier(slotAttachment)] {
                if let pos = tableAttachmentLRU.firstIndex(of: oldHash) {
                    tableAttachmentLRU.remove(at: pos)
                }
                tableAttachmentCache.removeValue(forKey: oldHash)
            }
            tableAttachmentCache[contentHash] = slotAttachment
            tableAttachmentLRU.append(contentHash)
            tableAttachmentReverseKey[ObjectIdentifier(slotAttachment)] = contentHash
            Self.rendererLogger.info("[RND] table#\(idx) CACHE UPDATE rows=\(rows.count) cols=\(alignments.count) newHash=\(contentHash) rnd=\(rnd) mid=\(mid)")
        } else {
            // 任务B：MISS 分支同步清掉同 slot 下的旧 hash，止住流式期间缓存 churn
            // （UPDATE 分支已做，MISS 分支漏了，导致旧 hash 滞留缓存直至 LRU 淘汰）。
            // 注意别删掉即将写入的新条目：仅当旧 hash 与新 contentHash 不同才清理。
            if let oldSlot = tableSlotCache[slotKey],
               let oldHash = tableAttachmentReverseKey[ObjectIdentifier(oldSlot)],
               oldHash != contentHash {
                if let pos = tableAttachmentLRU.firstIndex(of: oldHash) {
                    tableAttachmentLRU.remove(at: pos)
                }
                tableAttachmentCache.removeValue(forKey: oldHash)
                tableAttachmentReverseKey.removeValue(forKey: ObjectIdentifier(oldSlot))
            }
            attachment = TableAttachment(alignments: alignments,rows: rows,theme: theme)
            tableAttachmentCache[contentHash] = attachment
            tableAttachmentLRU.append(contentHash)
            tableSlotCache[slotKey] = attachment
            tableAttachmentReverseKey[ObjectIdentifier(attachment)] = contentHash
            while tableAttachmentLRU.count>tableAttachmentCacheCap {
                let evict = tableAttachmentLRU.removeFirst()
                if let dropped = tableAttachmentCache.removeValue(forKey: evict) {
                    tableAttachmentReverseKey.removeValue(forKey: ObjectIdentifier(dropped))
                    for (slot,att) in tableSlotCache where att === dropped {
                        tableSlotCache.removeValue(forKey: slot)
                    }
                }
            }
            Self.rendererLogger.info("[RND] table#\(idx) CACHE MISS rows=\(rows.count) cols=\(alignments.count) newHash=\(contentHash) cacheSize=\(tableAttachmentCache.count)")
        }

        let result = NSMutableAttributedString()
        let separatorPara = NSMutableParagraphStyle()
        separatorPara.paragraphSpacing = 0
        separatorPara.paragraphSpacingBefore = 0
        separatorPara.lineSpacing = 0
        let sepAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 0.01),
            .paragraphStyle: separatorPara,
        ]
        result.append(NSAttributedString(string: "\u{2028}", attributes: sepAttrs))
        let attachPart = NSMutableAttributedString(attachment: attachment)
        attachPart.addAttribute(.font,value: theme.baseFont,range: NSRange(location: 0,length: attachPart.length))
        result.append(attachPart)
        result.append(NSAttributedString(string: "\u{2028}", attributes: sepAttrs))
        return RenderedBlock(
            attributed: result,
            topMargin: theme.baseFontSize*0.6,
            bottomMargin: theme.baseFontSize*0.6,
            isBlockAttachment: true
        )
    }

    private func renderThematicBreakAttach() -> RenderedBlock {
        let attachment = ThematicBreakAttachment(theme: theme)
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font,value: theme.baseFont,range: NSRange(location: 0,length: result.length))
        return RenderedBlock(attributed: result,topMargin: 16,bottomMargin: 16,isBlockAttachment: true)
    }

    private func renderHTMLBlockNow(_ content: String,quoteDepth: Int) -> RenderedBlock {
        var attrs = baseAttributes(quoteDepth: quoteDepth)
        let style: NSMutableParagraphStyle
        if let existing = attrs[.paragraphStyle] as? NSParagraphStyle {
            style = existing.mutableCopy() as! NSMutableParagraphStyle
        } else {
            style = NSMutableParagraphStyle()
        }
        style.lineSpacing = bodyLineSpacing
        attrs[.paragraphStyle] = style
        return RenderedBlock(
            attributed: NSAttributedString(string: content,attributes: attrs),
            topMargin: 0,
            bottomMargin: 16
        )
    }

    private func renderImageAttach(source: String) -> NSAttributedString {
        let attachment: ImageAttachment
        if let cached = imageAttachmentCache[source] {
            AppLogger.shared.info("[IMG][RENDER] REUSE src=\(ImageAttachment.shortSrc(source)) ptr=\(ObjectIdentifier(cached).hashValue & 0xFFFFFF) loaded=\(cached.loadedImage != nil)", category: "ChatList.Attach")
            imgLogger.info("[MiniClawImage][RenderAttach] REUSE cached attachment src=\(source) loaded=\(cached.loadedImage != nil) imgSize=\(cached.loadedImage.map { "\($0.size.width)x\($0.size.height)" } ?? "nil")")
            cached.messageId = messageId
            let currentFp = miniClawMediaCacheKey(for: source)
            if let loadedFp = cached.loadedFingerprint,loadedFp != currentFp {
                AppLogger.shared.info("[IMG][RENDER] FINGERPRINT-DROP src=\(ImageAttachment.shortSrc(source)) old=\(loadedFp) new=\(currentFp) — bitmap invalidated, will reload", category: "ChatList.Attach")
                imgLogger.info("[MiniClawImage][RenderAttach] FINGERPRINT CHANGED src=\(source) old=\(loadedFp) new=\(currentFp) — invalidating cached image")
                cached.invalidateLoadedImage()
            }
            attachment = cached
        } else {
            AppLogger.shared.info("[IMG][RENDER] CREATE src=\(ImageAttachment.shortSrc(source)) cacheCount=\(self.imageAttachmentCache.count) — fresh ImageAttachment, ObjectIdentifier changed, view WILL be rebuilt", category: "ChatList.Attach")
            imgLogger.info("[MiniClawImage][RenderAttach] CREATE new ImageAttachment src=\(source) cacheCount=\(self.imageAttachmentCache.count)")
            attachment = ImageAttachment(source: source,theme: theme,messageId: messageId)
            imageAttachmentCache[source] = attachment
        }
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font,value: theme.baseFont,range: NSRange(location: 0,length: result.length))
        // 2026-08-12 治本:图片字符必须带显式 .left 段落样式——append 不继承属性,
        // 缺 .paragraphStyle 时 TextKit 回退 .natural(实测居中),造成"文字靠左、图片居中"。
        let imagePara = NSMutableParagraphStyle()
        imagePara.alignment = .left
        result.addAttribute(.paragraphStyle,value: imagePara,range: NSRange(location: 0,length: result.length))
        return result
    }

    private func renderVideoAttach(source: String) -> NSAttributedString {
        let attachment: VideoAttachment
        if let cached = videoAttachmentCache[source] {
            attachment = cached
        } else {
            attachment = VideoAttachment(source: source,theme: theme)
            videoAttachmentCache[source] = attachment
        }
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font,value: theme.baseFont,range: NSRange(location: 0,length: result.length))
        // 2026-08-12 治本:视频卡片同图片——显式 .left 段落样式,避免缺属性回退居中。
        let videoPara = NSMutableParagraphStyle()
        videoPara.alignment = .left
        result.addAttribute(.paragraphStyle,value: videoPara,range: NSRange(location: 0,length: result.length))
        return result
    }

    private func renderAudioAttach(source: String) -> NSAttributedString {
        let attachment: AudioAttachment
        if let cached = audioAttachmentCache[source] {
            attachment = cached
        } else {
            attachment = AudioAttachment(source: source,theme: theme)
            audioAttachmentCache[source] = attachment
        }
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font,value: theme.baseFont,range: NSRange(location: 0,length: result.length))
        // 2026-08-12 治本:音频卡片同图片——显式 .left 段落样式,避免缺属性回退居中。
        let audioPara = NSMutableParagraphStyle()
        audioPara.alignment = .left
        result.addAttribute(.paragraphStyle,value: audioPara,range: NSRange(location: 0,length: result.length))
        return result
    }

    /// 非媒体文件(pdf/md/docx/txt 等 markdown 图片语法的未知扩展名)→ 渲染为
    /// 带边框 + SF 图标的文件指示器(2026-08-13 治本:替代大矩形占位,区别于工具/思考指示器)。
    /// 文件名超 10 字截断 + …;点击走系统预览(QL)。
    func renderFileAttach(source: String, altText: String) -> NSAttributedString {
        let rawName: String
        if let url = URL(string: source), !url.lastPathComponent.isEmpty {
            rawName = url.lastPathComponent
        } else {
            rawName = altText.isEmpty ? "file" : altText
        }
        let name = rawName.count > 10 ? String(rawName.prefix(10)) + "…" : rawName
        let attachment = FileAttachment(fileName: name, source: source, theme: theme)
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font, value: theme.baseFont, range: NSRange(location: 0, length: result.length))
        // 治本:显式 lineSpacing=0,让文件卡片所在行的行高 = 卡片高(40),
        // 四角圆角完整落在行内,既不露黑也不会上圆下直。
        let filePara = NSMutableParagraphStyle()
        filePara.alignment = .left
        filePara.lineSpacing = 0
        result.addAttribute(.paragraphStyle, value: filePara, range: NSRange(location: 0, length: result.length))
        return result
    }

    ///
    /// file_write returns a singly-encoded
    /// miniclaw_url (e.g. `miniclaw://workspace/GitHub%E7%83%AD….md`). When the model
    private func normalizeLinkURL(from destination: String) -> URL? {
        let fallback = URL(string: destination)
        // Only miniclaw:// links are affected; everything else is untouched.
        guard destination.hasPrefix("miniclaw://") else {
            return fallback
        }
        // URL(string:) returned nil — on iOS
        // emitted unencoded inside a miniclaw:// link). The link would otherwise be
        guard let base = fallback else {
            return encodeRawMiniClawURL(destination)
        }
        // A correctly singly-encoded miniclaw_url decodes cleanly: `base.path`
        guard base.path.contains("%"),
              let once = destination.removingPercentEncoding,
              once.hasPrefix("miniclaw://"),
              let fixed = URL(string: once) else {
            return base
        }
        return fixed
    }

    private func renderInlines(_ inlines: [InlineNode],baseAttributes attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for inline in inlines {
            result.append(renderInline(inline,attributes: attrs))
        }
        return result
    }

    private func renderInline(_ node: InlineNode,attributes attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        switch node {
        case .text(let text):
            return NSAttributedString(string: text,attributes: attrs)

        case .code(let code):
            var codeAttrs = attrs
            codeAttrs[.font] = theme.inlineCodeFont
            codeAttrs[.foregroundColor] = theme.inlineCodeColor
            codeAttrs[.inlineCodeBackground] = true
            codeAttrs[.inlineCodeText] = code
            // Set .backgroundColor to trigger fillBackgroundRectArray in MiniClawLayoutManager
            codeAttrs[.backgroundColor] = theme.inlineCodeBackground
            return NSAttributedString(string: "\u{200A}\(code)\u{200A}", attributes: codeAttrs)

        case .emphasis(let children):
            var emphAttrs = attrs
            if let font = attrs[.font] as? UIFont {
                emphAttrs[.font] = font.withTraits(.traitItalic)
            }
            return renderInlines(children,baseAttributes: emphAttrs)

        case .strong(let children):
            var strongAttrs = attrs
            if let font = attrs[.font] as? UIFont {
                let descriptor = font.fontDescriptor.addingAttributes([
                    .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.bold]
                ])
                strongAttrs[.font] = UIFont(descriptor: descriptor,size: font.pointSize)
            }
            return renderInlines(children,baseAttributes: strongAttrs)

        case .strikethrough(let children):
            var strikeAttrs = attrs
            strikeAttrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            return renderInlines(children,baseAttributes: strikeAttrs)

        case .link(let destination,let children):
            var linkAttrs = attrs
            if let url = normalizeLinkURL(from: destination) {
                linkAttrs[.link] = url
            }
            linkAttrs[.foregroundColor] = theme.linkColor
            linkAttrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            return renderInlines(children,baseAttributes: linkAttrs)

        case .image(let source,let children):
            // [2026-09-14 降噪] 原有两行**逐节点**日志（`.image node src=… alt=…` 215 行 + `routing to IMAGE …`
            // 207 行，合计全天 422 行）。它们报的是"解析器看见了什么语法/选了哪条分支"，
            // 而落地信号在 `[RenderAttach] CREATE new` 与 `[IMG][NEW]`（真的建了附件），后者保留。
            // ⚠️ `children`/`altText` **必须保留**：下面的"非媒体 → FILE 附件"分支要用它当文件名。
            let ext = URL(string: source)?.pathExtension.lowercased() ?? ""
            let altText = children.plainText
            if nativeAudioExts.contains(ext) {
                return renderAudioAttach(source: source)
            } else if nativeVideoExts.contains(ext) {
                return renderVideoAttach(source: source)
            } else if nativeImageExts.contains(ext) || ext.isEmpty {
                return renderImageAttach(source: source)
            } else {
                // 非媒体文件(pdf/md/docx 等)→「📃文件名」文本附件(2026-08-13 治本:
                // 替代加载失败的大矩形占位)。
                imgLogger.info("[MiniClawImage][InlineParse] non-media ext=\(ext), routing to FILE attachment src=\(source)")
                return renderFileAttach(source: source, altText: altText)
            }

        case .html(let html):
            return NSAttributedString(string: html,attributes: attrs)

        case .softBreak:
            return NSAttributedString(string: " ", attributes: attrs)

        case .lineBreak:
            return NSAttributedString(string: "\n", attributes: attrs)

        case .inlineMath(let latex):
            return renderInlineMathAttach(latex: latex)
        }
    }

    /// Per-depth indent: 3pt bar + 10pt leading padding (matches miniClawChat blockquote padding)
    private static let quoteIndentPerLevel: CGFloat = 13
    private static let listIndentPerLevel: CGFloat = 24

    private func baseAttributes(quoteDepth: Int) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: theme.baseFont,
            .foregroundColor: quoteDepth>0 ? theme.secondaryLabelColor : theme.labelColor,
            // 反色外阴影（最终定稿 2026-09-08）：浅色白晕 / 深色黑影，普通文字 run
            // 统一携带；代码块/内联代码有独立渲染路径不经过本函数，自带底色不受污染。
            // ⚠️ 描边路线已实验否决（-1.5 糊 / -1.0 真机仍不如白晕），勿再引入 stroke。
            .shadow: theme.textShadow,
        ]
        if quoteDepth>0 {
            attrs[.blockquoteDepth] = quoteDepth
            let style = NSMutableParagraphStyle()
            let indent = CGFloat(quoteDepth)*Self.quoteIndentPerLevel
            style.headIndent = indent
            style.firstLineHeadIndent = indent
            style.lineSpacing = bodyLineSpacing
            attrs[.paragraphStyle] = style
        }
        return attrs
    }

    private func renderMathBlockAttach(latex: String) -> RenderedBlock {
        let key = "D:\(Int(theme.baseFontSize)):"+latex
        let attachment: MathAttachment
        if let cached = mathAttachmentCache[key] {
            attachment = cached
        } else {
            attachment = MathAttachment(latex: latex,isBlock: true,theme: theme)
            mathAttachmentCache[key] = attachment
        }
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font,value: theme.baseFont,range: NSRange(location: 0,length: result.length))
        return RenderedBlock(attributed: result,topMargin: bodyLineSpacing,bottomMargin: bodyLineSpacing,isBlockAttachment: true)
    }

    private func renderInlineMathAttach(latex: String) -> NSAttributedString {
        let key = "I:\(Int(theme.baseFontSize)):"+latex
        let attachment: MathAttachment
        if let cached = mathAttachmentCache[key] {
            attachment = cached
        } else {
            attachment = MathAttachment(latex: latex,isBlock: false,theme: theme)
            mathAttachmentCache[key] = attachment
        }
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font,value: theme.baseFont,range: NSRange(location: 0,length: result.length))
        return result
    }
}

// [2026-09-10 治本·已回退共享 renderer] 本函数**每次调用新建 renderer**，不可改为共享单例：
//   · 产物会被存进 `AssistantBlock.cachedAttributedString`，而 `MarkdownView` 的 prebuilt
//     分支只在"内容含表格"时才拒绝它——含**图片/代码块/公式**的 prebuilt 会直接被采用显示。
//   · renderer 的 `imageAttachmentCache`/`codeBlockAttachmentCache`/`mathAttachmentCache`
//     /`videoAttachmentCache`/`audioAttachmentCache` 均按内容索引且**跨 `render()` 调用持久**
//     （`render(blocks:)` 只重置 `tableIndex`/`codeBlockIndex`，一个缓存都不清）。
//   二者叠加 ⇒ 共享 renderer 会让**同一张图/同一段代码/同一个公式在不同消息里共用一个附件
//   实例**，而实例上带 `messageId`（`MarkdownView` 还会给 prebuilt 里的 `ImageAttachment`
//   逐条改写它）、`blockIndex`、`needsViewRebuild` 等**按消息、按 cell** 的可变态 ⇒
//   点击路由错乱、`refreshAttachViews` 的视图复用错位。公式/代码片段在多条消息里重复出现
//   是常见情形，不是罕见路径。
//   收益侧也不成立：表格 MISS 的实际开销（`computeLayout`）已由进程级
//   `TableAttachment.sharedLayoutCache` 承担，重建 TableAttachment 实例本身很廉价。
#if DEBUG
/// [Stage 4 · 准入度量 M7] **全量 render 的频次与耗时**（计划 §3.1 M7）。
///
/// 为什么补它：Stage 4 的候选 **S4.5「Bridge 同步渲染复用 renderer」**要求
/// 「该项成本 ≥100ms/会话 或 ≥10% 累计」，而这个量此前**从未被度量**（M7 是计划里的"待测项"）。
/// 本探针只统计本函数 —— 它**每次调用都 new 一个 `MarkdownNSRenderer`**（注释自述：
/// `mid=?` 即 throwaway renderer），正是 S4.5 要消除的那个开销。
/// 5s 节流打 `warn`（不受控制台白名单限制）。**不统计 `MarkdownView.rendererCache` 那一路**
/// （复用路径的成本特征不同，混在一起会互相掩盖）。
@MainActor
enum BridgeRenderProbe {
    // [2026-09-17 细化] 原探针只记「总耗时」，回答不了「2.1s 花在构造还是渲染、是否随内容增大」。
    // 现拆成 ctor / render 两段，并按**产物长度**分档。日志只加两类，避免把日志量推得更高：
    //   ① 5s 节流的周期行（含分档直方图 + 最慢 5 个样本）
    //   ② **单次 >200ms 的慢样本**立即打点（首 40 条 + 每次刷新最坏值）
    private static var count = 0
    private static var totalCtorMs = 0.0
    private static var totalRenderMs = 0.0
    private static var worstCtorMs = 0.0
    private static var worstRenderMs = 0.0
    private static var worstTotalMs = 0.0
    private static var lastLogAt: CFAbsoluteTime = 0
    private static var slowLogged = 0

    /// 产物长度分档上界；最后一档表示「大于最后一档」。
    private static let bucketEdges = [256, 1024, 4096, 16384]
    private static var bucketN = [Int](repeating: 0, count: 5)
    private static var bucketMs = [Double](repeating: 0, count: 5)

    /// 只保留最慢的 5 个样本 —— 本探针要的是**定位最坏单次**，不是流水账。
    private static var slow: [(len: Int, blk: Int, ctor: Double, render: Double, total: Double)] = []

    private static func fmt(_ v: Double) -> String { String(format: "%.1f", v) }

    private static func bucketIndex(_ len: Int) -> Int {
        for (i, e) in bucketEdges.enumerated() where len <= e { return i }
        return bucketEdges.count
    }

    static func note(ctorMs: Double, renderMs: Double, blocks: Int, length: Int) {
        count &+= 1
        totalCtorMs += ctorMs
        totalRenderMs += renderMs
        if ctorMs > worstCtorMs { worstCtorMs = ctorMs }
        if renderMs > worstRenderMs { worstRenderMs = renderMs }
        let total = ctorMs + renderMs
        let isNewWorst = total > worstTotalMs
        if isNewWorst { worstTotalMs = total }
        let bi = bucketIndex(length)
        bucketN[bi] += 1
        bucketMs[bi] += total

        if total > 200, slowLogged < 40 || isNewWorst {
            slowLogged += 1
            slow.append((length, blocks, ctorMs, renderMs, total))
            slow.sort { $0.total > $1.total }
            if slow.count > 5 { slow.removeLast() }
            AppLogger.shared.warn("[Stage0][M7b] 慢样本 ctor=\(fmt(ctorMs))ms render=\(fmt(renderMs))ms total=\(fmt(total))ms len=\(length) blk=\(blocks)", category: "MarkdownSTF")
        }

        let now = CFAbsoluteTimeGetCurrent()
        guard now-lastLogAt >= 5.0 else { return }
        lastLogAt = now
        let hist = (0..<bucketN.count).map { i -> String in
            let label = i < bucketEdges.count ? "≤\(bucketEdges[i])" : ">\(bucketEdges[bucketEdges.count-1])"
            return "\(label):n=\(bucketN[i])/\(fmt(bucketMs[i]))ms"
        }.joined(separator: " ")
        let slowDesc = slow.isEmpty ? "无" : slow.map { "len=\($0.len),blk=\($0.blk),ctor=\(fmt($0.ctor)),render=\(fmt($0.render))" }.joined(separator: " | ")
        AppLogger.shared.warn("[Stage0][M7] 同步 render（Stage 4·S4.5 准入判据）n=\(count) total=\(fmt(totalCtorMs+totalRenderMs))ms avg=\(fmt((totalCtorMs+totalRenderMs)/Double(max(count,1))))ms worst=\(fmt(worstTotalMs))ms ‖ 拆分 ctor累计=\(fmt(totalCtorMs))ms worst=\(fmt(worstCtorMs))ms ｜ render累计=\(fmt(totalRenderMs))ms worst=\(fmt(worstRenderMs))ms ‖ 按产物长度 \(hist) ‖ 最慢5[\(slowDesc)] — 每次调用都 new 一个 MarkdownNSRenderer", category: "MarkdownSTF")
    }
}
#endif

@MainActor
func renderMarkdownBlocks(_ blocks: [BlockNode]) -> NSAttributedString {
    #if DEBUG
    let t0 = CFAbsoluteTimeGetCurrent()
    let renderer = MarkdownNSRenderer(baseFontSize: FontSettings.shared.scaledMessage(16.5))
    let t1 = CFAbsoluteTimeGetCurrent()
    let out = renderer.render(blocks: blocks)
    BridgeRenderProbe.note(ctorMs: (t1-t0)*1000, renderMs: (CFAbsoluteTimeGetCurrent()-t1)*1000, blocks: blocks.count, length: out.length)
    return out
    #else
    return MarkdownNSRenderer(baseFontSize: FontSettings.shared.scaledMessage(16.5)).render(blocks: blocks)
    #endif
}

/// [2026-09-13 重构·内容指纹统一] 全库唯一的「内容是否变了」指纹。
///
/// **为什么需要它**：工程里原本有 4 处缓存各自拿「字符数 / `textStorage.length`」当指纹，
/// 而**等长改写**（长度不变、内容不同 —— 如 `A`→`B`、数字改动、翻页式替换）会被判成
/// "未变" ⇒ 缓存/高度/尺寸沿用旧值。这是真机 `flapping`（同一内容量出 `20.3` 与 `30.4/36/40`）
/// 与 `liveShrink` 族的结构成因之一。
///
/// **口径**：**长度 + 确定性全量哈希（FNV-1a）**。
/// - 含长度：让"追加型增长"必然变化，且空串与非空串不会撞；
/// - 用 FNV-1a 而**不用 `Hasher`**：`Hasher` 的种子逐进程随机，跨启动不稳定；
///   FNV-1a 与 `MiniClawChatAdapter.textBlockID` 的既有做法同源、跨进程稳定。
/// - 返回值**实际上几乎不可能为 0，但并不保证**：FNV-1a 对某些输入确实会输出 0。
///   ⚠️ 此处原先写的是「返回值**恒不为 0**（FNV 偏移基址非零）」——**该推理不成立**：
///   偏移基址非零只说明**初始**值非零，推不出**最终**哈希非零（2026-09-16 核对）。
///   消费方（如 `MarkdownTextView.lastSizedStorageFingerprint != 0`）把 `0` 当"未设置"哨兵，
///   属"实际可用但**无理论保证**"：风险是 2⁻⁶⁴ 量级，且失败方向良性（该内容每次多重测一次）。
///   若要让哨兵真正成立，应由**代码**兑现——在 `of` 末尾 `h == 0 ? 1 : Int(truncatingIfNeeded: h)`；
///   当前**未**兑现，故不得据此论证可以删除消费方的 `!= 0` 判据。
///
/// **使用边界（重要）**：只用于**相等性**判据。**序关系**判据（如
/// `lastStreamPendingSourceLen < markdown.count` 的"快照是否落后"）语义是"谁更短"，
/// 必须继续用长度比较，换成指纹会直接破坏语义。
enum ContentFingerprint {
    static func of(_ s: String) -> Int {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3
        }
        h ^= UInt64(truncatingIfNeeded: s.utf8.count)
        return Int(truncatingIfNeeded: h)
    }
}

extension NSAttributedString.Key {
    static let inlineCodeBackground = NSAttributedString.Key("miniClawInlineCodeBackground")
    static let inlineCodeText = NSAttributedString.Key("miniClawInlineCodeText")
    static let blockquoteDepth = NSAttributedString.Key("miniClawBlockquoteDepth")
}

extension NSAttributedString {
    /// 是否含任意 `NSTextAttachment`。
    ///
    /// 全库唯一实现：此前有 4 处逐字同形的扫描（测量快路径 / 渲染写回 / 两处
    /// `sizeThatFits` 分支），任一处判据漂移都会让「带附件」块走错路径。
    /// 命中即 `stop`，成本只到第一个附件为止。
    var hasAnyAttachment: Bool {
        guard length > 0 else { return false }
        var found = false
        enumerateAttribute(.attachment,
                           in: NSRange(location: 0, length: length),
                           options: []) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }
}

extension UITextView {
    /// 沿 superview 链向上找承载本视图的列表容器。
    ///
    /// 全库唯一实现：正文 `MarkdownTextView` 与表格 `TableCellTextView` 此前各写了
    /// 一份逐字相同的实现。
    func findCollectionView() -> NoAnimationCollectionView? {
        var view: UIView? = superview
        while let v = view {
            if let cv = v as? NoAnimationCollectionView { return cv }
            view = v.superview
        }
        return nil
    }
}

let attachLogger = AppLogger(category: "AttachDebug")

// MARK: - miniclaw:// URL encoding

/// Percent-encode the path of a `miniclaw://` destination that contains raw,
/// unencoded inside a miniclaw:// link), returning a parseable URL (or nil if it
/// still can't be formed). Used by both the link path (MarkdownTheme)
func encodeRawMiniClawURL(_ destination: String) -> URL? {
    let prefix = "miniclaw://"
    guard destination.hasPrefix(prefix) else { return URL(string: destination) }
    let rest = String(destination.dropFirst(prefix.count))
    let encoded = rest.split(separator: "/", omittingEmptySubsequences: false)
        .map { percentEncodePathSegmentIdempotent(String($0)) }
        .joined(separator: "/")
    return URL(string: prefix+encoded)
}
