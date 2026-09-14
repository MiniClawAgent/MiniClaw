import MiniClawKit
import SwiftUI
import UIKit
import Photos
import Foundation
import Combine

// MARK: - Markdown 统一渲染/测量缓存（2026-09-08 治本收口）
//
/// 此前同职责散落 5 处（block.cachedAttributedString / attrStringMemo /
/// heightMemo×2 / coord.cachedSizes），各管一段、互相不知情，每轮优化都在打补丁。
/// 统一为一个进程级缓存：
///
///   key   = markdown 源文 + 字号（同一 markdown 唯一确定渲染结果）
///   entry = 渲染好的 NSAttributedString + 各宽度下的实测高度
///
/// 三条消费路径全部走它：
///   ① 渲染（updateUIView）——命中免全量解析+构造
///   ② 测量（sizeThatFits）——命中免 TextKit 全量重排（50-100ms/次）
///   ③ 种子（applySnapshot precalc）——命中免算术估算误差
/// 无附件块才缓存 attributed（附件与 renderer 上下文身份耦合）；高度按宽度分存。
@MainActor
final class MarkdownRenderCache {
    static let shared = MarkdownRenderCache()

    private struct Entry {
        // [2026-09-09 根源修复] nil = 该条目只有高度（height-only，prewarm/种子/
        // PLAF 先写高度的正常路径）。此前用**空 NSAttributedString 占位**，而
        // `cachedAttributed` 只判 nil → 所有"先有高度"的块在渲染/测量时命中
        // **空串当有效渲染结果** → 渲染出 attrText=0 的空帧，空值又经 onRendered
        // 回写块缓存 → 渲染层 prebuilt 再命中空 → 空白死锁（漏消息的直接根源）。
        // 「无」必须表达为 nil，不能是空串。
        let attributed: NSAttributedString?
        var heights: [Int: CGFloat] = [:]
        let insertedAt: CFAbsoluteTime
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    // [T-perf 2026-09-08] 48 → 256：386-item 会话有数百个块，48 条 LRU 把活跃块
    // 反复淘汰 → 测量永远 MISS → 反复 1.2s 全量排版（真机 SLOW MEASURE 1196ms）。
    // 无附件块的 attributed 较小（纯文本+样式），256 条 ≈ 数 MB 内存，可接受。
    private let limit = 1024

    // [缓存观测 2026-09-10] 唐唐要求：缓存写入/读取命中必须全部可见于设备日志，
    // 用于判定「回看不稳」到底是没读缓存、缓存被破坏还是时机不对。
    // 策略：STORE/MISS 全打（每个内容 key 一生各一次，量可控）；HIT 同 key 1s 节流。
    private static let cacheLogger = AppLogger(category: "RenderCache")
    private var hitLogAt: [String: CFAbsoluteTime] = [:]

    private func logHit(_ kind: String,key: String) {
        touch(key)  // LRU 续期（2026-09-11 审计发现：日志化改造时遗失 touch，缓存退化为 FIFO——已恢复）
        let now = CFAbsoluteTimeGetCurrent()
        if let t = hitLogAt[key],now-t < 1.0 { return }
        hitLogAt[key] = now
        Self.cacheLogger.info("[RC] HIT-\(kind) key=\(key)")
    }

    /// 统一 key：markdown 源文 + 字号。全库所有消费点必须用同一构造。
    static func key(for markdown: String, fontSize: CGFloat) -> String {
        var hasher = Hasher()
        hasher.combine(markdown)
        hasher.combine(fontSize)
        return "\(hasher.finalize())"
    }

    /// [2026-09-09 根源修复] 无条目 / height-only / 空串 一律返回 nil——
    /// 消费方"命中"语义 = 存在**非空**的有效渲染结果。
    func cachedAttributed(for key: String) -> NSAttributedString? {
        guard let entry = entries[key], let attr = entry.attributed, attr.length > 0 else {
            Self.cacheLogger.info("[RC] MISS-ATT key=\(key)")
            return nil
        }
        logHit("ATT",key: key)
        return attr
    }

    func cachedHeight(for key: String, width: Int) -> CGFloat? {
        guard let h = entries[key]?.heights[width] else {
            Self.cacheLogger.info("[RC] MISS-H key=\(key) w=\(width)")
            return nil
        }
        logHit("H",key: key)
        return h
    }

    /// [2026-09-12 裁尾修复·只补不覆盖] 仅当该 (key,width) **还没有**高度时才写入。
    ///
    /// 供**后台高度预热**（`scheduleHeightPrewarm`）使用。预热为了不阻塞主线程，用的是
    /// 私有「裸 `NSLayoutManager` + `NSTextContainer`」栈，实测与渲染引擎
    /// （`MarkdownTextView`）在同一内容、同一宽度下**矮 12.3pt**（1699 vs 1712）。
    /// 一旦它覆盖掉播种/自测量写下的同源值，屏上 `sizeThatFits` 就会读回矮值
    /// → cell 提交矮 12.3pt → 尾部半行被裁；且该值经 `recordMeasuredHeight` 污染布局
    /// memo → 播种短路后永久复现（真机实证：`[STF] EXIT src=attach-unified-cache h=1699.0`
    /// 出现后裁尾才发生，`FIRST-MEASURE CORRECTION cellH=1703.0 newH=1711.3`）。
    /// 预热的职责是「补齐缺失」而非「覆盖既有」，故语义必须是**只补不覆盖**：
    /// 既保留同源真值，又仍能为尚未测量的块（含 402 边界宽桶）预填。
    func storeHeightIfAbsent(height: CGFloat, key: String, width: Int) {
        if let existing = entries[key], existing.heights[width] != nil { return }
        store(height: height, key: key, width: width)
    }

    /// 命中后把 key 移到队尾（真 LRU）。旧实现命中不刷新 order → 退化为 FIFO：
    /// 386-item 会话里活跃块会被"先入"的冷块挤掉，测量反复 MISS。
    private func touch(_ key: String) {
        guard let idx = order.firstIndex(of: key), idx != order.count - 1 else { return }
        order.remove(at: idx)
        order.append(key)
    }

    func store(attributed: NSAttributedString, key: String) {
        // [2026-09-09 根源修复] 空渲染结果不入库（空 att 会被消费方当有效结果，
        // 曾致 height-only 空串占位连锁出「漏消息」死锁）。
        guard attributed.length > 0, entries[key] == nil else { return }
        entries[key] = Entry(attributed: attributed, insertedAt: CFAbsoluteTimeGetCurrent())
        order.append(key)
        while order.count > limit {
            let evict = order.removeFirst()
            entries.removeValue(forKey: evict)
        }
        Self.cacheLogger.info("[RC] STORE-ATT key=\(key) len=\(attributed.length)")
    }

    /// 高度写入**不依赖 attributed 是否存在**（2026-09-08 修复）：
    /// 旧实现 `guard var entry = entries[key] else { return }` → 附件块
    ///（表格/代码块/公式，按设计不缓存 attributed）永远没有 entry，高度
    /// 100% 存不进去，等于这次"缓存合并"对含附件的块完全没生效。
    /// 改为 height-only entry：无 attributed 时建一个占位条目专存高度。
    func store(height: CGFloat, key: String, width: Int) {
        if var entry = entries[key] {
            entry.heights[width] = height
            entries[key] = entry
        } else {
            var entry = Entry(attributed: nil, // height-only：无富文本，只有高度
                              insertedAt: CFAbsoluteTimeGetCurrent())
            entry.heights[width] = height
            entries[key] = entry
            order.append(key)
            while order.count > limit {
                entries.removeValue(forKey: order.removeFirst())
            }
        }
        Self.cacheLogger.info("[RC] STORE-H key=\(key) w=\(width) h=\(String(format: "%.0f", height))")
    }

    /// 内存告警时整体清空（2026-09-08）：1024 条 NSAttributedString 常驻，
    /// 收到系统内存警告时主动释放，避免被 jetsam 直接杀进程。
    func removeAll() {
        entries.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
        hitLogAt.removeAll()
    }

    /// 注册内存告警监听（进程内一次）。缓存可重建，宁可丢也不被杀。
    private static var memoryObserverInstalled = false
    static func installMemoryWarningObserver() {
        guard !memoryObserverInstalled else { return }
        memoryObserverInstalled = true
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { _ in
            MarkdownRenderCache.shared.removeAll()
        }
        #endif
    }
}

/// 反色外阴影修饰符（2026-09-07，全局强制）：SwiftUI 文字统一入口。
/// 浅色模式暗字配三层白色光晕塔（中心实、外围渐散，托住复杂背景图上的可读性）；
/// 深色模式亮字配单层黑影。shadow 恒在字形下层零侵入——中文小字禁用描边/贴脸
/// 紧实层（会吃笔画致整页发糊，真机教训，详见 MarkdownTheme.textShadow 注释）。
/// 覆盖：SwiftUI 文字入口（AI 名字行 BridgedAssistantHeader、消息状态行 AssistantStatusRow 等）；
/// 富文本正文走 MarkdownTheme.textShadow。
public struct LegibleTextShadow: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    public func body(content: Content) -> some View {
        // 最终定稿（2026-09-08）：浅色三层白晕加密塔（描边实验否决后回归）；
        // 深色单层黑影。
        content
            .shadow(color: colorScheme == .dark ? .black.opacity(0.8) : .white.opacity(1.0),
                    radius: 2)
            .shadow(color: colorScheme == .dark ? .black.opacity(0.0) : .white.opacity(1.0),
                    radius: 3.5)
            .shadow(color: colorScheme == .dark ? .black.opacity(0.0) : .white.opacity(0.85),
                    radius: 5.5)
    }
}

public extension View {
    /// 反色外阴影：所有浮在可换背景上的文字统一使用（见 LegibleTextShadow）。
    func legibleTextShadow() -> some View { modifier(LegibleTextShadow()) }
}

struct MarkdownTheme {
    let baseFontSize: CGFloat
    let codeBlockCornerRadius: CGFloat = 8
    let inlineCodeCornerRadius: CGFloat = 5

    init(baseFontSize: CGFloat? = nil) {
        self.baseFontSize = baseFontSize ?? 16.5
    }

    var baseFont: UIFont { .systemFont(ofSize: baseFontSize) }
    var labelColor: UIColor { .label }
    var secondaryLabelColor: UIColor { .secondaryLabel }

    /// 正文反色外阴影（2026-09-07，全局强制）：
    /// 深色模式文字为亮色 → 黑影；浅色模式文字为暗色 → 白影。
    /// 用 dynamic UIColor 与 .label 同机制（绘制时按 trait 解析，深浅色切换自动生效）。
    /// offset .zero 的阴影是纯绘制效果，不占布局空间，对高度估算/实测零影响；
    /// 同色系背景上阴影自然隐形（黑底黑影/白底白影），复杂背景图上承担可读性兜底。
    /// ⚠️ 刻意不用 .strokeWidth 描边（2026-09-07 真机教训）：stroke 是中心线描边，
    /// 一半侵入笔画内侧——16.5pt 中文字笔画仅 1~1.5pt，1.5pt 白描边直接把黑字
    /// 吃成灰字（整页发糊）。可读性兜底只靠下层光晕，永远不碰字形本身。
    /// 正文阴影（最终定稿 2026-09-08）：浅色反色白晕 / 深色黑影，dynamic 随深浅色切换。
    var textShadow: NSShadow {
        let s = NSShadow()
        s.shadowColor = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 0, alpha: 0.8)
                : UIColor(white: 1, alpha: 1.0)
        }
        s.shadowBlurRadius = 3
        s.shadowOffset = .zero
        return s
    }
    var accentColor: UIColor { .systemOrange }
    var linkColor: UIColor { .systemBlue }
    var codeBlockBackground: UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.15,alpha: 1) : .black }
    }
    var codeBlockTextColor: UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.55,green: 0.95,blue: 0.55,alpha: 1) : .systemGreen }
    }
    var inlineCodeBackground: UIColor { miniClawInlineCodeBackgroundColor }
    var inlineCodeColor: UIColor { .systemOrange }
    var blockquoteBarColor: UIColor { UIColor.systemOrange.withAlphaComponent(0.5) }
    var tableBorderColor: UIColor { UIColor.label.withAlphaComponent(0.25) }

    func headingFont(level: Int) -> UIFont {
        let size: CGFloat
        let weight: UIFont.Weight
        switch level {
        case 1: size = baseFontSize*1.5; weight = .bold
        case 2: size = baseFontSize*1.3; weight = .bold
        case 3: size = baseFontSize*1.15; weight = .semibold
        case 5: size = baseFontSize*0.875; weight = .semibold
        case 6: size = baseFontSize*0.85; weight = .semibold
        default: size = baseFontSize; weight = .semibold // H4 and fallback
        }
        return .systemFont(ofSize: size,weight: weight)
    }

    var inlineCodeFont: UIFont {
        let size = baseFontSize*0.845
        if let menlo = UIFont(name: "Menlo", size: size) {
            let descriptor = menlo.fontDescriptor.addingAttributes([
                .cascadeList: [UIFontDescriptor(fontAttributes: [.name: "PingFang SC"])]
            ])
            return UIFont(descriptor: descriptor,size: size)
        }
        return .monospacedSystemFont(ofSize: size,weight: .regular)
    }

    var codeBlockFont: UIFont {
        let size = baseFontSize*0.85
        if let menlo = UIFont(name: "Menlo", size: size) {
            let descriptor = menlo.fontDescriptor.addingAttributes([
                .cascadeList: [UIFontDescriptor(fontAttributes: [.name: "PingFang SC"])]
            ])
            return UIFont(descriptor: descriptor,size: size)
        }
        return .monospacedSystemFont(ofSize: size,weight: .regular)
    }
}

/// Intended for one-shot rendering of completed messages (e.g. caching in MessageListModel).
func percentEncodePathSegmentIdempotent(_ seg: String) -> String {
    let decoded = seg.removingPercentEncoding ?? seg
    return decoded.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? seg
}

// MARK: - MarkdownTheme

/// Inline-code span background, shared by the
/// 文件指示器附件:带边框的胶囊 + SF 文档图标 + 文件名(超 10 字截断)。
/// 区别于工具/思考指示器,让用户一眼识别是文件(2026-08-13)。

struct MarkdownView: UIViewRepresentable {
    let markdown: String
    var cachedContent: MarkdownContent?
    var cachedAttributedString: NSAttributedString?
    /// 所属块是否仍在流式输出（2026-09-08）：**显式终态信号**。
    /// 此前终态靠 `cachedAttributedString != nil || cachedContent != nil` 反推——
    /// 而 `cachedAttributedString` 又只能由终态回写（onRendered）产生 → 自依赖：
    /// 缓存不存在时永远判定为"流式"，回写分支永远打不开。以宿主传入的流式状态为准。
    var isStreaming: Bool = false
    var messageId: UUID?
    /// Optional block identity for table slot-cache keying. In the list
    var blockId: UUID?
    var onTapBlank: ((CGPoint) -> Void)?
    var onCopyScreenshot: (() -> Void)?
    /// "Read from Start" (whole reply) via MiniClaw TTS.
    var onReadAloud: (() -> Void)?
    /// "Read Selection" (selected text) via MiniClaw TTS.
    var onSpeakText: ((String) -> Void)?
    /// 终态渲染完成后回写富文本缓存（2026-09-08 性能修复）：
    /// `block.cachedAttributedString` 的写入方法 cacheRenderedContent() 此前从未被
    /// 接线调用 → 每个块在每个 cell 实例上首次配置都全量渲染（真机日志实证：
    /// 同一 1070 字符块滑动期间反复 MISS 30+ 次、累计近 1s 主线程）。渲染完成时
    /// 把结果写回缓存，同块的其他 cell 实例 / 重进会话直接命中（零额外成本，
    /// 复用本来就要做的渲染）。仅 finalized 且无 in-flight 表格后缀时回写。
    /// [2026-09-09 指纹同源修复 / 2026-09-13 指纹统一] **第二参数 = 本次渲染实际输入的
    /// 内容指纹**（调用点传 `ContentFingerprint.of(markdown)`；**原为长度 `markdown.count`**，
    /// 长度分不出等长改写 ⇒ 陈旧缓存会被误判为"对应当前内容"）。
    /// 调用方必须用它当缓存指纹，不得用回调时刻的
    /// block.content.count——SwiftUI body 求值与 sizeThatFits 可跨 runloop 迭代，
    /// 期间 Bridge 会改写 block.content（流式 ~100ms/次），两者不同源时指纹指向
    /// 新内容而 att 是旧内容的渲染结果 → prebuilt 长度校验恰好通过 → 正文被钉在
    /// 旧版本（回复中工具挂载后正文截短，滑动/复用均不恢复）。
    var onRendered: ((NSAttributedString, Int) -> Void)? = nil
    /// [2026-09-09 截短锁死修复] prebuilt 缓存的内容指纹 = **渲染输入的内容指纹**
    /// （`ContentFingerprint.of`，即 AssistantBlock.cachedAttrFingerprint，
    /// 由 onRendered 第二参数写入，与
    /// cachedAttributedString 同源）。背景：流式中工具挂载会让该块提前被判终态
    /// （isStreamingBlock 只认 blocks.last），onRendered 把**缺尾包的中间态**渲染
    /// 结果回写块缓存；100ms 后尾包 flush 内容变长，而 prebuilt 采用点
    /// （updateUIView）此前**不校验缓存对应哪一版内容**、回写条件又是 `== nil`
    /// 永不覆盖 → 中间态被永久锁死（显示截短且滑动/复用均不恢复，
    /// 真机 IMG_4605「好，继续给这一」）。nil = 调用方未提供指纹，保守放行
    /// （兼容其它调用点）；提供时不匹配即弃用 prebuilt 落全量渲染——覆盖式
    /// 回写会让缓存追赶内容，下一次测量自然对齐。
    var prebuiltFingerprint: Int? = nil
    /// [2026-09-12 裁尾修复] 宿主提供的**真实内容宽度**（= cell 宽 − 块左右内边距）。
    ///
    /// 为什么必须由宿主传入：`sizeThatFits` 在 SwiftUI 的**理想尺寸 pass** 里会被以
    /// **未指定/边界宽度**询问（真机日志 `[STF] call=1 proposal=402.0 container=0.0 view=0.0`
    /// —— 此时 `bounds.width == 0`，视图自身无从得知真实内容宽 370）。按 402 排版行数偏少
    /// → 高度偏矮（1699 vs 真实 1711.3），而 `.fixedSize(vertical: true)` 会把这次答案
    /// 当**理想高度**钉死 → cell 提交 1703（=1699+块 padding 4）→ 尾部半行永久被裁；
    /// 且该值经 `recordMeasuredHeight` 污染布局 memo，`FIRST-MEASURE CORRECTION` 也救不回。
    /// 传入后首次 pass 即按 370 测量，与渲染**同源**。nil = 非聊天列表场景（如
    /// MarkdownSurface 的文档页），退回原「proposal → bounds → 屏幕宽」解析链。
    var contentWidth: CGFloat? = nil
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator {
        let coord = Coordinator()
        if let mid = messageId,let existing = MarkdownView.rendererCache[mid] {
            coord.renderer = existing
        } else if let mid = messageId {
            MarkdownView.rendererCache[mid] = coord.renderer
        }
        return coord
    }

    @MainActor private static var rendererCache: [UUID: MarkdownNSRenderer] = [:]

    /// [T-perf 2026-09-08 缓存合并] 原 heightMemo（附件块 fallback 高度缓存）已
    /// 迁入统一缓存 MarkdownRenderCache.heights（key=renderCacheKey+width，与
    /// 无附件块/预填充/种子循环同一体系）——独立缓存不再维护。

    // （无附件块的渲染/测量/高度缓存已收口至 MarkdownRenderCache，见文件顶部——
    //   attrStringMemo 零散缓存已删除，不再维护多套。）

    func makeUIView(context: Context) -> MarkdownTextView {
        let textView = MarkdownTextView()
        textView.delegate = context.coordinator
        textView.setContentHuggingPriority(.required,for: .vertical)
        textView.setContentCompressionResistancePriority(.required,for: .vertical)
        context.coordinator.lastMarkdown = ""
        context.coordinator.openURL = openURL
        textView.onTapBlank = onTapBlank
        textView.onCopyScreenshot = onCopyScreenshot
        textView.onReadAloud = onReadAloud
        textView.onSpeakText = onSpeakText
        #if DEBUG
        // makeUIView creates a FRESH textView +
        let rId = String(ObjectIdentifier(context.coordinator.renderer).hashValue&0xFFFFFF,radix: 16)
        AppLogger.shared.info("[MK-VIEW] new textView rnd=\(rId)", category: "MarkdownRenderer")
        #endif
        return textView
    }

    func updateUIView(_ textView: MarkdownTextView,context: Context) {
        // [PerfTrace 2026-09-08] 渲染路径计时（此前只给测量侧打点，渲染侧是空白）
        let updateStart = CFAbsoluteTimeGetCurrent()
        context.coordinator.openURL = openURL
        textView.onTapBlank = onTapBlank
        textView.onCopyScreenshot = onCopyScreenshot
        textView.onReadAloud = onReadAloud
        textView.onSpeakText = onSpeakText

        let currentFontSize = FontSettings.shared.scaledMessage(16.5)
        let fontChanged = context.coordinator.lastFontSize != currentFontSize

        let imgCacheN = context.coordinator.renderer.imageAttachmentCache.count
        if imgCacheN>0 {
            let prevLen = context.coordinator.lastMarkdown.count
            let curLen = markdown.count
            let isAppend = curLen>prevLen && markdown.hasPrefix(context.coordinator.lastMarkdown)
            AppLogger.shared.info("[UPD] entry imgCache=\(imgCacheN) prevLen=\(prevLen) curLen=\(curLen) Δ\(curLen - prevLen) appendOnly=\(isAppend ? 1 : 0) fontChanged=\(fontChanged ? 1 : 0)", category: "ChatList.Attach")
        }

        let _curW = textView.textContainer.size.width
        let _prevW = context.coordinator.lastRenderedWidth
        let _widthChanged = _curW>1 && _prevW>1 && abs(_curW-_prevW)>0.5
        if _widthChanged && markdown == context.coordinator.lastMarkdown && !fontChanged {
            context.coordinator.fadeAnimator.cancelAll()
            let storage = textView.textStorage
        if storage.length>0 {
                var ranges: [NSRange] = []
                storage.enumerateAttribute(.attachment,in: NSRange(location: 0,length: storage.length),options: []) { value,range,_ in
                    if let table = value as? TableAttachment {
                        table.invalidateCachedLayoutForWidthChange()
                        ranges.append(range)
                    }
                }
                if !ranges.isEmpty,let lm = textView.layoutManager as? MiniClawLayoutManager {
                    for r in ranges {
                        lm.invalidateLayout(forCharacterRange: r,actualCharacterRange: nil)
                    }
                }
            }
            context.coordinator.cachedSizes.removeAll(keepingCapacity: true)
            textView.refreshAttachViews()
            textView.invalidateIntrinsicContentSize()
            textView.setNeedsLayout()
            textView.invalidateCellSizeIfChanged()
        }
        if _curW>1 {
            context.coordinator.lastRenderedWidth = _curW
        }
        // [2026-09-12 收尾清理] 原 [Probe] ENTER 显示链探针已移除（诊断使命完成）。
        // [2026-09-11 强制收敛·原判据] storage 缺了 markdown 结尾的纯散文行 = 显示停在旧短快照
        //（流式终帧丢在节流复用上、追赶回调丢失）→ 不许去重，强制重渲追平。
        // 真机 SHORT-DISPLAY 实锤：storageLen=367 mdLen=743（blk=74AFA8CF/16C9CF57，恰为
        // TAIL-HIT 全高块 ⇒「有行高但无内容填充」的空白区）。纯散文行判定与渲染侧 TAIL-MISS
        // 同口径（剔除语法符/数字行，宁漏不误）。
        // [2026-09-13 终态收敛·治本] 原判据要求 `markdown == lastMarkdown`（"内容没变、
        // 只是显示落后"）。**漏了一类真机形态**：最后一段正文是在**最后一个工具轮之后**才写出的
        //（`… → shell_execute → 最终总结`），它在流式期被**正常**渲染过一次 —— 那一刻内容
        // 确实只有那么长（真机停在 `![](miniclaw`，即 offset ~140/197）；随后流结束、内容不再
        // 增长 ⇒ 既没有新 markdown 触发的更新，也不满足任何"脏态"条件 ⇒ **没人再喊一次**，
        // storage 永久停在中间快照，直到退出重进（终态路径重渲一次才正常）。
        // 缺口本质：`streamSnapshotStale` 只管"复用了更旧的快照"，**不管"最后渲染的是个短内容"**。
        // 修法：**把「流结束」这件事本身当收敛触发** —— `isStreaming` true→false 是入参变化，
        // 必然带来一次 `updateUIView`，此时无条件核对一次 storage 完整性。
        // [终态收敛] 流刚结束的那一帧——`isStreaming` true→false 是入参变化，必然带来一次
        // `updateUIView`，是"最后一次渲染的是个短内容"的唯一可靠触发点。
        // 本判据现在只用于让下方 `[TruncL]` 在终态无条件量一次，不参与任何渲染决策。
        // ⚠️ 曾与之配套的 `storageMissingTail`（拿"markdown 原文能否在富文本里找到"当代理）
        // 已整块删除：含链接 / 行内代码的收尾行渲染后只剩显示文本 ⇒ **恒判缺失（误报判据）**，
        // 且曾在探针里"行动"造成每帧重渲（真机 23:22：22ms 一条、连打 14 次、日志 1.2MB→12.3MB）。
        let streamJustEnded = (context.coordinator.lastWasStreaming == true) && !isStreaming
        // [尾包修复 2026-09-10] `streamSnapshotStale` 必须放行：内容没变但 storage 停在
        // 缺尾旧快照（上一轮走了流式节流复用，窗长见 Coordinator.streamThrottleWindow）时，正是本条 updateUIView 要追平。
        // [2026-09-13 回退] 不再放行 `storageMissingTail`：它是**误报判据**（含链接 / 行内代码的
        // 收尾行渲染后只剩显示文本 ⇒ 永远找不到），放行它只会让整条链多跑一次渲染、解决不了任何问题。
        // [Fix 2026-09-14 「尾部被旧短快照覆盖」治本]
        // 流式期内容**只增长**。若本次进来的 `markdown` 是「上一次已渲染的那一份」的**真前缀**
        //（= 一份更旧的快照）就直接跳过整轮更新 —— 否则它会用旧短内容覆盖已经渲染好的更长内容。
        // 真机签名（12:34）：`storageLen=257 < attrLen=269`，显示恰好缺尾 12 字（与截图逐字吻合），
        // 且 cell 高度也按短内容算 ⇒ **看不到空白**（与「帧够高只是没画出来」是两类问题，别混）。
        // 用**前缀**判据而不是单纯比长度：真正的编辑（非前缀）不会被误拦。
        let prevRenderedMarkdown = context.coordinator.lastMarkdown
        if !markdown.isEmpty, markdown.count < prevRenderedMarkdown.count,
           prevRenderedMarkdown.hasPrefix(markdown) {
            let now = CACurrentMediaTime()
            if now - context.coordinator.lastStaleLogAt > 1.0 {
                context.coordinator.lastStaleLogAt = now
                AppLogger.shared.warning(
                    "[StaleRender] 拒绝更短的旧快照 mdCnt=\(markdown.count) lastCnt=\(prevRenderedMarkdown.count) blk=\(blockId?.uuidString.prefix(8) ?? "?") — 不覆盖已渲染的更长内容",
                    category: "RenderProbe")
            }
            return
        }
        guard markdown != context.coordinator.lastMarkdown || fontChanged
            || context.coordinator.streamSnapshotStale else {
            let shouldRecover = textView.window != nil
                && textView.needsAttachmentRecovery
                && !textView.hasScheduledRecoveryForCurrentContent

            if shouldRecover {
                textView.hasScheduledRecoveryForCurrentContent = true
                DispatchQueue.main.async { [weak textView] in
                    guard let textView,textView.window != nil else { return }
                    textView.refreshAttachViews()
                    textView.invalidateIntrinsicContentSize()
                    textView.setNeedsDisplay()
                    textView.setNeedsLayout()
                }
            }
            // [FadeLeak] 自愈第二道（2026-09-10）：本分支正是「用户点击/切页回来、
            // 内容未变」时走的路径——漏字现场被手动刷出前的那一次 updateUIView。
            // 交给 fade 动画器**按它自己的压暗记录**核对还原（不是「凡 alpha<1 拉满」：
            // 那会把引用块的 .secondaryLabel 一并刷成不透明黑，真机日志
            // IDLE-RESIDUE HEALED 最低alpha=0.61 即是该误伤的痕迹）。
            // 非流式态才查，避开动画进行中的正常半透明；每 coordinator 2s 节流防刷屏。
            if !isStreaming {
                let now = CACurrentMediaTime()
                if now - context.coordinator.lastFadeResidueScanAt > 2.0 {
                    context.coordinator.lastFadeResidueScanAt = now
                    context.coordinator.fadeTextView = textView
                    context.coordinator.fadeAnimator.traitProvider = textView
                    context.coordinator.fadeAnimator.healResidueIfNeeded()
                }
            }
            return
        }

        // .background → defer (always; final streaming
        // frame would otherwise be blank
        // until SwiftUI re-evaluates)
        // .inactive ≥ 30s → defer (long-running .inactive is
        // indistinguishable from background
        // for watchdog purposes — commit
        // e6efac23 fixed crashes here)
        // .inactive < 30s → render normally (control center
        // swipe, incoming call banner,
        // app-switcher peek — short enough
        // that the scene-transition
        // watchdog window has settled)
        // .active → render normally (falls through)
        //
        let appState = UIApplication.shared.applicationState
        let inactiveDuration: TimeInterval = appState == .inactive
            ? (context.coordinator.inactiveEnteredAt.map { Date().timeIntervalSince($0) } ?? 0)
            : 0
        let shouldDefer: Bool = {
            switch appState {
            case .background: return true
            case .inactive: return inactiveDuration >= 30.0
            default: return false
            }
        }()
        if shouldDefer {
            context.coordinator.deferRender(markdown) { [weak textView] in
                guard let textView else { return }
                context.coordinator.lastRenderedContentHash = nil
                self.updateUIView(textView,context: context)
            }
            return
        }
        // [FadeLeak 2026-09-10 内容身份判定] 判定当前 textView 承载的是哪一块内容：
        // 同一 coordinator（UIViewRepresentable 在 cell 复用/块重配时**复用同一个
        // textView**）被更新为另一块的内容时，无论新 markdown 是否恰好以旧内容为
        // 前缀，都必须 cancelAll——否则旧块的 in-flight fade word 落在新 storage 上
        // 继续改写 alpha（用旧块的颜色曲线写新块字符）→ 永久透明残留（漏字实锤，
        // 真机 IDLE-RESIDUE alpha=0.00 ×15）。cell 复用换块会稳定复现同一类故障
        // 后补上了同一防御（SelectableMarkdownView :7663-7702），移植时未带走。
        let contentId = blockId ?? messageId
        let previousContentId = context.coordinator.lastContentId
        context.coordinator.lastContentId = contentId
        let isDifferentContent = contentId != nil
            && previousContentId != nil
            && contentId != previousContentId
        if isDifferentContent {
            context.coordinator.fadeAnimator.cancelAll()
        }

        let oldMarkdown = context.coordinator.lastMarkdown
        context.coordinator.lastMarkdown = markdown

        if fontChanged {
            context.coordinator.renderer.applyFontSizeChange(currentFontSize)
            context.coordinator.lastFontSize = currentFontSize
            context.coordinator.lastRenderedContentHash = nil
            context.coordinator.renderer.mathAttachmentCache.removeAll()
            // 任务C：字号变更后清掉表格附件缓存，迫使按新字号重建 TableAttachment
            // （contentHash 已纳入字号，这里显式清掉旧字号残留，立即生效而非等 LRU 淘汰）。
            context.coordinator.renderer.tableAttachmentCache.removeAll()
            context.coordinator.renderer.tableAttachmentLRU.removeAll()
            context.coordinator.renderer.tableSlotCache.removeAll()
            context.coordinator.renderer.tableAttachmentReverseKey.removeAll()
            textView.clearAllAttachViews()
        }

        // 内容改写（非前缀）= 同一内容的重写，走破坏性重建路径；
        // 换块（isDifferentContent）走下方缓存/重建路径，不算 rewrite——上游
        // SelectableMarkdownView :7699-7701 的语义，防止复用时误清附件缓存。
        let isNewMessage = !oldMarkdown.isEmpty && !markdown.hasPrefix(oldMarkdown) && !isDifferentContent
        if isNewMessage {
            context.coordinator.fadeAnimator.cancelAll()
            let renderer = context.coordinator.renderer
            renderer.imageAttachmentCache.removeAll()
            renderer.videoAttachmentCache.removeAll()
            renderer.audioAttachmentCache.removeAll()
            renderer.codeBlockAttachmentCache.removeAll()
            renderer.codeBlockContentHashes.removeAll()
            renderer.mathAttachmentCache.removeAll()
            textView.clearAllAttachViews()
        }

        //
        // by `MessageListModel.cacheAttributedString(for:)`. After that
        // [尾包修复 2026-09-10] 终态信号与 sizeThatFits 分支**同源**（那里已用
        // `!isStreaming`，此处曾漏改）：旧条件只用缓存有无反推终态，缓存未回写时
        // 流式已结束仍按「流式中」切表格尾 → 显示串与测量串不同源（高度/显示错位），
        // 且表格要等缓存回写才成型。两处同源后显示与测量必然一致。
        let _isFinalised = !isStreaming || cachedAttributedString != nil || cachedContent != nil
        let _splitForUpdate = _isFinalised ? (prefix: markdown, plainSuffix: "") : splitStreamingTableTail(markdown)
        let _hasPlainSuffix = !_splitForUpdate.plainSuffix.isEmpty
        let prepared = prepareMarkdownForRender(_splitForUpdate.prefix)
        let content = (_hasPlainSuffix ? nil : cachedContent) ?? MarkdownContent(prepared)
        let imageMatches = markdown.ranges(of: /!\[([^\]]*)\]\(([^)]+)\)/)
        if !imageMatches.isEmpty {
            for match in imageMatches {
                let matchStr = String(markdown[match])
                imgLogger.info("[MiniClawImage][StreamParse] image markdown found: \(matchStr)")
            }
            let imageBlockCount = content.blocks.flatMap { Self.collectImageNodes(from: $0) }.count
            if imageBlockCount>0 {
                imgLogger.info("[MiniClawImage][StreamParse] parsed \(imageBlockCount) image node(s) from \(content.blocks.count) block(s), markdownLen=\(markdown.count)")
            }
        }

        var hasher = Hasher()
        hasher.combine(cachedContent != nil ? cachedContent!.blocks.hashValue : markdown.hashValue)
        hasher.combine(FontSettings.shared.scaledMessage(16.5))
        let contentHash: Int = hasher.finalize()
        // [尾包修复 2026-09-10] 跳过脏态下的去重：上一轮显示的是落后快照，其内容哈希
        // 已按**当前内容**记录，直接命中去重会把缺尾状态永久固化（正是本 bug 的帮凶）。
        if contentHash == context.coordinator.lastRenderedContentHash,
           !context.coordinator.streamSnapshotStale {
            if textView.textContainer.size.width>1 {
                textView.refreshAttachViews()
            }
            return
        }
        #if DEBUG
        // Hash MISS — log why so we can tell if
        if cachedContent != nil || cachedAttributedString != nil {
            let prev = context.coordinator.lastRenderedContentHash
            let usingBlocks = cachedContent != nil
            AppLogger.shared.info("[RND-MISS] hash=\(contentHash) prev=\(prev.map(String.init) ?? "nil") src=\(usingBlocks ? "blocks" : "markdown") hasPlainSuffix=\(_hasPlainSuffix) fontChanged=\(fontChanged) mdLen=\(markdown.count)", category: "MarkdownRenderer")
        }
        #endif
        context.coordinator.lastRenderedContentHash = contentHash

        let renderer = context.coordinator.renderer
        let attributed: NSAttributedString
        // `MessageListModel.cacheAttributedString(for:)` which uses a fresh
        let prebuiltHasTable: Bool = {
            guard let prebuilt = cachedAttributedString,prebuilt.length>0 else { return false }
            var found = false
            prebuilt.enumerateAttribute(.attachment,in: NSRange(location: 0,length: prebuilt.length),options: []) { value,_,stop in
                if value is TableAttachment {
                    found = true
                    stop.pointee = true
                }
            }
            return found
        }()
        // [2026-09-09 空缓存防御] prebuilt 可能被写入**空的** NSAttributedString
        //（渲染被 defer 丢弃/自愈循环期间的空产物回写）——用它渲染产出 attrText=0
        // → self-heal 重画 → 又命中同一个空 prebuilt → **永久空白死循环**（真机
        // 实证 len=16 块反复 self-heal②）。length=0 的 prebuilt 一律不采用，
        // 落走 renderer.render 重画。
        if let prebuilt = cachedAttributedString,prebuilt.length>0,!fontChanged,!prebuiltHasTable,!_hasPlainSuffix,
           // [2026-09-09 截短锁死修复] 指纹不匹配 = 缓存是旧中间态而内容已增长——
           // **必须弃用**落全量渲染（此前指纹判定只打日志、旧缓存仍被采用，等于没修）。
           prebuiltFingerprint == nil || prebuiltFingerprint == ContentFingerprint.of(markdown) {
            attributed = prebuilt
            context.coordinator.streamSnapshotStale = false
        } else {
            // [Prebuilt] 指纹不匹配被上层弃用的现场（低频：内容边界才触发）。
            // 覆盖式回写随后把缓存追平。
            if cachedAttributedString != nil, let fp = prebuiltFingerprint, fp != ContentFingerprint.of(markdown) {
                AppLogger.shared.warning("[Prebuilt] REJECT stale cache cachedFp=\(fp) mdFp=\(ContentFingerprint.of(markdown)) block=\(blockId?.uuidString.prefix(8) ?? "?") — 全量重渲染追赶", category: "MarkdownSTF")
            }
            if isStreaming,
              let prev = context.coordinator.lastStreamPending,
              CACurrentMediaTime() - context.coordinator.lastStreamRenderAt < Coordinator.streamThrottleWindow {
            // [2026-09-08 修复] 与 sizeThatFits 的测量节流**同频同源码**：
            // 此前渲染每 token 全量、测量节流复用旧 pending →「显示新内容、
            // 测旧内容」→ 高度系统性滞后 ≤节流窗并呈台阶跳。这里复用同一份
            // lastStreamPending，显示与测量必然同源（均滞后 ≤节流窗，下个 token 追上）。
            attributed = prev
            // [尾包修复 2026-09-10] 快照的渲染输入比当前内容短 = 本次显示**缺尾**。
            // 置脏让后续 updateUIView 放行（内容停止增长后守卫本来会把它拦死）并排追赶渲染。
            if context.coordinator.lastStreamPendingSourceLen < markdown.count {
                context.coordinator.streamSnapshotStale = true
            }
        } else {
            renderer.messageId = messageId
            renderer.blockId = blockId
            let renderedBody = autoreleasepool {
                renderer.render(blocks: content.blocks)
            }
            // [2026-09-09 渲染输入观测] 全量渲染路径的判凶观测。probe 只取**纯散文行**
            //（完全不含语法符 *|`#~[]()>+-· 与数字的行）末 12 字做包含判定——
            // 此前「过滤后比对」有两类系统性误报（20:19 日志 9 条 TAIL-MISS 全误报）：
            // ① 数字在 markdown 侧被滤掉但渲染输出里还在（「按 17:45 确立」）；
            // ② 行内代码渲染为 \u{200A}code\u{200A}（发丝空格包裹），普通空格匹配不上。
            // 找不到纯散文行 → probe 置空跳过判凶（宁漏不误）。
            var _probe = ""
            var _mdTailLine = ""
            let _syntaxChars = "*|`#~[]()>+-·0123456789"
            for line in markdown.split(whereSeparator: { $0.isNewline }).reversed() {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { continue }
                guard !t.contains(where: { _syntaxChars.contains($0) }) else { continue }
                if t.count >= 6 {
                    _probe = String(t.suffix(12))
                    _mdTailLine = String(t.suffix(40))
                    break
                }
            }
            let _tailHit = _probe.isEmpty || renderedBody.string.contains(_probe)
            if !_tailHit {
                AppLogger.shared.warning(
                    "[Render] TAIL-MISS block=\(blockId?.uuidString.prefix(8) ?? "?") mdCnt=\(markdown.count) attrCnt=\(renderedBody.length) — 渲染输出缺少 markdown 结尾（截短实锤）mdTail=\"\(_mdTailLine)\" probe=\"\(_probe)\"", category: "MarkdownSTF")
            }
            if isStreaming {
                context.coordinator.lastStreamPending = renderedBody
                context.coordinator.lastStreamRenderAt = CACurrentMediaTime()
                context.coordinator.lastStreamPendingSourceLen = markdown.count
            }
            // 全量渲染落地 = storage 追平内容，脏标记清除。
            context.coordinator.streamSnapshotStale = false
            if _hasPlainSuffix {
                let mut = NSMutableAttributedString(attributedString: renderedBody)
                let suffixAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: FontSettings.shared.scaledMessage(16.5)),
                    .foregroundColor: UIColor.label,
                ]
                mut.append(NSAttributedString(string: _splitForUpdate.plainSuffix,attributes: suffixAttrs))
                attributed = mut
            } else {
                attributed = renderedBody
            }
            }
        }
        // [每轮落盘 2026-09-10] 唐唐要求：AI 每轮循环的正文在**全量渲染落地瞬间**
        // 即写入进程级缓存（key=markdown+字号，内容敏感不存在陈旧），此后的测量/
        // 回看/预填充直接命中，与任何可能落后的中间快照彻底解耦。附件块不缓存
        //（附件实例与消息身份耦合，2026-09-09 回退教训）；带 plainSuffix 的流式
        // 表格尾不缓存（renderedBody 只是前缀，与 key 不对齐）。
        if attributed.length > 0,_splitForUpdate.plainSuffix.isEmpty,
           // 脏态（本条显示的是落后快照）不入库：快照短于当前 markdown，
           // 存进新内容的 key 就是投毒（同测量侧，2026-09-10）。
           !context.coordinator.streamSnapshotStale {
            if !attributed.hasAnyAttachment {
                MarkdownRenderCache.shared.store(
                    attributed: attributed,
                    key: MarkdownRenderCache.key(for: markdown,fontSize: FontSettings.shared.scaledMessage(16.5)))
            }
        }
        // 1. patch `messageId` (the cached path via renderMarkdownBlocks
        // creates attachments without one)
        // 2. invalidate any stale bitmap if the underlying file was
        // rewritten since the attachment last loaded (size+mtime
        // fingerprint mismatch). Skips the on-disk stat for
        // non-miniclaw schemes.
        attributed.enumerateAttribute(.attachment,
                                      in: NSRange(location: 0,length: attributed.length),
                                      options: []) { value,_,_ in
            guard let att = value as? ImageAttachment else { return }
            if let messageId { att.messageId = messageId }
            if let loadedFp = att.loadedFingerprint {
                let currentFp = miniClawMediaCacheKey(for: att.source)
                if loadedFp != currentFp {
                    imgLogger.info("[MiniClawImage][CachedAttr] FINGERPRINT CHANGED src=\(att.source) old=\(loadedFp) new=\(currentFp) — invalidating cached image")
                    att.invalidateLoadedImage()
                }
            }
        }
        // prefix of the NEW text — true for every streamed token.
        var fadeRevealRange: NSRange? = nil
        let oldStorage = textView.textStorage
        if oldStorage.length>0,
           attributed.length>oldStorage.length {
            let oldLen = oldStorage.length
            let oldStr = oldStorage.string as NSString
            let newStr = attributed.string as NSString
            if newStr.length >= oldLen,
               newStr.substring(to: oldLen) == (oldStr as String) {
                fadeRevealRange = NSRange(location: oldLen,length: attributed.length-oldLen)
            }
        }

        var fastPathTaken = false
        var newAttachInTail = 0
        let prevStorage = textView.textStorage
        if prevStorage.length>0,
           attributed.length>prevStorage.length {
            let prefixLen = prevStorage.length
            let newPrefix = attributed.attributedSubstring(from: NSRange(location: 0,length: prefixLen))
            let _oldPrefix = prevStorage.attributedSubstring(from: NSRange(location: 0,length: prefixLen))
            if Self.prefixesEqualIgnoringFontSubstitution(newPrefix,_oldPrefix) {
                let tailRange = NSRange(location: prefixLen,length: 0)
                let tail = attributed.attributedSubstring(from: NSRange(location: prefixLen,length: attributed.length-prefixLen))
                tail.enumerateAttribute(.attachment,in: NSRange(location: 0,length: tail.length),options: []) { v,_,_ in
                    if v != nil { newAttachInTail += 1 }
                }
                prevStorage.beginEditing()
                prevStorage.replaceCharacters(in: tailRange,with: tail)
                prevStorage.endEditing()
                fastPathTaken = true
            }
        }
        if !fastPathTaken {
            // [FadeLeak 2026-09-10] 内容与 storage 完全一致时跳过赋值：full-assign
            // 会重置全部属性，把在途 fade 的渐变状态抹掉（视觉=字突然变实再重新淡入），
            // 且 storage 若因此缩短会让 in-flight word 越界（STALE-DROP）。流式节流
            // 复用 lastStreamPending 时 attributed 与 storage 完全相同——典型触发场景。
            let sameAsStorage = attributed.length == textView.textStorage.length
                && attributed.string == textView.textStorage.string
            if !sameAsStorage {
                textView.attributedText = attributed
            }
        }
        // [Diag 修正 2026-09-14] 赋值后**同步**读一次存储长度。此前探针是在异步块里读
        // `textStorage.length`，却与**同步捕获**的 `attrLen` 相比 ⇒ **两帧混读**，
        // 会把"另一轮更新的结果"记成本轮的落差（12:34 那条 `storageLen=257 < attrLen=269`
        // 有可能是这么来的）。改为同刻取值，`storageBehind` 才可信。
        let storageLenAfterAssign = textView.textStorage.length

        if let revealRange = fadeRevealRange {
            context.coordinator.fadeTextView = textView
            context.coordinator.fadeAnimator.traitProvider = textView
            context.coordinator.fadeAnimator.scheduleAnimation(for: revealRange,in: textView.textStorage)
        }
        // [尾包修复 2026-09-10] 本条显示的是**落后快照** → 排一次追赶渲染。必须显式排期：
        // 内容停止增长（回复结束）后不会再有带新 markdown 的 SwiftUI 更新，靠「下一次
        // updateUIView」追平是不成立的（早退守卫还会把它拦下）。
        // [2026-09-13 终态收敛·治本] 除"脏态"外，**终态完整性核对不过**（`storageMissingTail`
        // —— 即"最后一次渲染的是个短内容"，见上方 `streamJustEnded`）同样必须排一次追赶：
        // 这种情况下内容已停止增长，绝不会有下一次带新 markdown 的更新来追平。
        // [2026-09-13 回退 `storageMissingTail`] 只保留 `streamSnapshotStale`：后者是**真落后**
        //（本条复用了更旧的快照），而前者是误报判据，参与排期会形成"每帧重渲"的循环。
        if context.coordinator.streamSnapshotStale {
            context.coordinator.scheduleStreamCatchUp { [weak textView] in
                guard let textView else { return }
                self.updateUIView(textView,context: context)
            }
        }
        // 记录本次的流式态：供下一次 updateUIView 判定"流是否刚刚结束"（终态收敛的触发点）。
        context.coordinator.lastWasStreaming = isStreaming
        textView.rawMarkdown = markdown
        textView.resetAttachmentRecovery()
        StreamingHangLogger.shared.recordAssignedText(
            messageId: messageId,
            markdown: markdown,
            attrLen: attributed.length,
            path: fastPathTaken ? "fast-append" : "full-assign",
            isStreaming: isStreaming
        )
        // [Diag 2026-09-13 截断定位 · 不影响功能，直接加不作询问] 每次渲染后量一遍几何。
        // ⚠️ 关键：**必须量到 cell 的 frame**。上一版探针只量到 textView 的**内部容器**
        //（那一层的高度永远等于内容高，所以"看起来没被裁"，看不出真凶）；
        // 若 cellH 明显小于 tvContentH，即 **cell 裁掉了尾部文字**，而不是渲染没上屏。
        // 降频：终态每次打；流式期只在滚动哨兵开启时打（避免刷屏）。
        // [Diag 2026-09-13 截断定位] 每次渲染后**延到下一帧**（布局已完成）量四层：
        // 存储 / 渲染 / cell 几何 / 字形可见范围。
        // **流式期只在"异常"时打**（防刷屏）：异常 = `storageLen≠attrLen`、或 `cellH<tvContentH`、
        // 或 `tailCut=1`。此前只打非流式帧 ⇒ **流式中途那一窗口完全没被记录**（正是唯一没量到的窗口）。
        let mdCntSnap = markdown.count
        let attrLenSnap = attributed.length
        let streamSnap = isStreaming
        let pathSnap = fastPathTaken ? "fast" : "full"
        let blkSnap = blockId?.uuidString.prefix(8) ?? "?"
        // 降频：非流式（含"流刚刚结束"那一帧）必打；流式期只在滚动哨兵开启时打。
        let forceLog = !isStreaming || streamJustEnded || ScrollMetricsRecorder.shared.isEnabled
        DispatchQueue.main.async { [weak textView] in
            guard let textView else { return }
            var cellH: CGFloat = -1
            var cellRef: SelfSizingCell?
            var probeView: UIView? = textView
            while let cur = probeView {
                if let cell = cur as? SelfSizingCell { cellH = cell.frame.height; cellRef = cell; break }
                probeView = cur.superview
            }
            let contentH = textView.contentSize.height
            let lm = textView.layoutManager
            let total = lm.numberOfGlyphs
            // `glyphRange(forBoundingRect:in:)` 要的是 **textContainer 坐标**；此前直接传 view 的
            // `bounds`（未扣 `textContainerInset`）⇒ 量到的是**超集**，数值偏乐观。
            // 查询前先 `ensureLayout`，否则数值随布局时机飘。
            let visEnd: Int
            if total > 0, textView.bounds.height > 1 {
                lm.ensureLayout(for: textView.textContainer)
                let containerRect = textView.bounds.offsetBy(
                    dx: -textView.textContainerInset.left,
                    dy: -textView.textContainerInset.top)
                visEnd = NSMaxRange(lm.glyphRange(forBoundingRect: containerRect, in: textView.textContainer))
            } else {
                visEnd = total
            }
            let tailCut = visEnd < total
            let storageBehind = storageLenAfterAssign != attrLenSnap
            let cellTooShort = cellH > 0 && cellH < contentH - 0.5
            // [判据可信度 2026-09-14] 流式期"视图比内容晚一帧"是**正常**的（下一帧自然追上），
            // 故 `tailCut` 只在**终态帧**参与异常判定；流式期只认下面三个更可靠的量。
            // 教训：`tailCut` 在流式期大量为 1，却与用户看到的截断**无关**（真因是 `[StaleRender]`），
            // 不收紧它就会持续把人往几何层引（本轮为此白追了好几轮）。
            let clippedNow: Bool = {
                guard let cell = cellRef else { return false }
                return textView.frame.maxY > cell.contentView.bounds.height + 0.5
            }()
            let bad = storageBehind || cellTooShort || clippedNow || (tailCut && !streamSnap)
            // [Fix 2026-09-13 「尾行被裁」根治] 真机签名：`storageLen == attrLen`（内容完整、已上屏）
            // 且 `cellShort=0`（cell 够高），**但 `tailCut=1`** —— 可见字形区间只覆盖到
            // `visEnd=28/89`、`121/132`、`165/252` ⇒ **尾部字形没进 textView 自己的可见范围**。
            // 即：内容与 cell 都对，**是 `MarkdownTextView` 自身高度没跟上内容**（cell 变高了，
            // textView 的 frame/intrinsic 尺寸没同步）⇒ 末行被 textView 自己裁掉。
            // 修法：内容完整却出现 tailCut 时，强制重算固有尺寸并排队布局，让末行回到可见区。
            // （只在"内容完整"时触发 ⇒ 不会与正常的"流式期还没长完"混淆。）
            // [Fix 2026-09-14 第二版·按排版结果直接定高（社区配套做法）]
            // 真机签名：`glyphs == storageLen`（120/120、173/173）⇒ **全部字形都已排好**，
            // 但 `visEnd` 恰好少一行（两次都是少 17 个字形），而 `tvFrameH == tvContentH`、`clipped=0`。
            // ⇒ **尾部那一行被排到了 textView 自己的 `contentSize/bounds` 之外**（textView 高度落后一行）
            // ⇒ 排完不画；而 cell 高度来自另一条路径（正确）⇒ 那个位置留下空白。
            // 标准解法（同资料）：**不要信 `contentSize`，直接用排版结果（`usedRect + inset`）定高**。
            // ⚠️ [2026-09-14 撤销 FIX3/FIX4] 这里曾用 `usedRect` 直接改写 textView 的 frame、并把
            // 同一测量值写进该行高度条目。**那是错的，已撤销**，真机后果：
            //   · 条件写成"只增不减"（`usedH > frame.height`）⇒ **跨 cell 复用时代代累积**，
            //     textView 被撑到 495pt 而当前内容只需 28pt（真机 `tvFrameH=495.1 / tvContentH=28.0
            //     / cellH=32.0 / clipped=1`），把高度体系搞乱；
            //   · 在**诊断探针里**改几何，本身就是"打补丁"而不是"算准"。
            // 结论：这块几何必须由**布局路径**（cell 的高度提交处）统一驱动，不能在探针里各改各的。
            // 保留的两处修复是**有证据支持**的：① 关 `allowsNonContiguousLayout`（字形全排好，
            // `glyphs == storageLen` 实证）；② 终态收敛（终态签名全绿实证）。
            guard forceLog || bad else { return }
            // [Diag] 不依赖时机的**裁剪**判据：textView 的 frame 底边是否超出 cell 内容区底边。
            // 这比 `visEnd`（依赖 textView.bounds，会受"布局还没跑"的时机影响）可靠得多：
            // 若 `clipped=1` ⇒ 末行**确实**被 cell 裁掉（真病灶）；
            // 若 `clipped=0` 而 `visEnd` 仍小 ⇒ 只是我量早了（测量假象，不该再当病灶修）。
            var geomInfo = "clipped=n/a"
            if let cell = cellRef {
                geomInfo = "clipped=\(clippedNow ? 1 : 0)"
            }
            // [Obs 2026-09-13] `cellShort=1` 且**内容已定型**（storage 完整）⇒ 该行的实测高度条目
            // 陈旧（内容长了约一行、条目没跟着更新），末行被 cell 裁掉 =「少一行字」。
            // ⚠️ 此处**只观测、不改几何**：曾在探针里调用 `clearCachedHeight()` /
            // `invalidateHeight(at:)` / `invalidateLayout()`，那是"在诊断探针里改几何"（历史事故：
            // 跨 cell 复用代代累积，textView 被撑到 495pt）—— 已删，几何只能由布局路径统一驱动。
            if cellTooShort, !storageBehind, let cell = cellRef,
               let cv = cell.superview as? UICollectionView,
               let ip = cv.indexPath(for: cell) {
                AppLogger.shared.warning(
                    "[TruncL-FIX2] cellShort 观测（不改几何）blk=\(blkSnap) idx=\(ip.item) cellH=\(String(format: "%.1f", cellH)) contentH=\(String(format: "%.1f", contentH))",
                    category: "RenderProbe")
            }
            AppLogger.shared.warning(
                "[TruncL]\(bad ? " ⚠BAD" : "") blk=\(blkSnap) storageLen=\(storageLenAfterAssign) attrLen=\(attrLenSnap) mdCnt=\(mdCntSnap) tvContentH=\(String(format: "%.1f", contentH)) cellH=\(String(format: "%.1f", cellH)) path=\(pathSnap) streaming=\(streamSnap ? 1 : 0) glyphs=\(total) visEnd=\(visEnd) tailCut=\(tailCut ? 1 : 0) storageBehind=\(storageBehind ? 1 : 0) cellShort=\(cellTooShort ? 1 : 0) \(geomInfo)",
                category: "RenderProbe")
        }
        let storage = textView.textStorage
        let storageLen = storage.length
        if storageLen>0 {
            storage.enumerateAttribute(.attachment,
                                       in: NSRange(location: 0,length: storageLen),
                                       options: []) { value,range,_ in
                if let table = value as? TableAttachment,table.needsLayoutInvalidation {
                    textView.layoutManager.invalidateLayout(forCharacterRange: range,actualCharacterRange: nil)
                    table.needsLayoutInvalidation = false
                }
            }
        }

        if fastPathTaken {
            textView.setNeedsLayout()
        } else if (cachedContent != nil || cachedAttributedString != nil) && textView.textContainer.size.width>1 {
            let containerSize = textView.textContainer.size
            let visibleRect: CGRect
            if textView.bounds.width>1,textView.bounds.height>1 {
                visibleRect = CGRect(x: 0,y: 0,width: containerSize.width,height: textView.bounds.height+800)
            } else {
                visibleRect = CGRect(x: 0,y: 0,width: containerSize.width,height: 1200)
            }
            let visibleGlyphRange = textView.layoutManager.glyphRange(forBoundingRect: visibleRect,
                                                                     in: textView.textContainer)
            if visibleGlyphRange.length>0 {
                textView.layoutManager.ensureLayout(forGlyphRange: visibleGlyphRange)
            } else {
                textView.setNeedsLayout()
            }
        } else {
            textView.setNeedsLayout()
        }
        textView.invalidateIntrinsicContentSize()
        textView.setNeedsDisplay()
        textView.invalidateCellSizeIfChanged()

        let attachStart = CFAbsoluteTimeGetCurrent()
        // refreshAttachViews enumeration. If a new attachment did appear
        let skipAttachUpdate = fastPathTaken && newAttachInTail == 0
        if skipAttachUpdate {
        } else if textView.textContainer.size.width>1 {
            textView.refreshAttachViews()
        } else {
            DispatchQueue.main.async { [weak textView] in
                guard let textView,textView.window != nil else { return }
                textView.refreshAttachViews()
                textView.invalidateIntrinsicContentSize()
                textView.setNeedsDisplay()
                textView.setNeedsLayout()
                textView.invalidateCellSizeIfChanged()
            }
        }
        _ = (CFAbsoluteTimeGetCurrent()-attachStart)*1000
        let updateElapsed = (CFAbsoluteTimeGetCurrent()-updateStart)*1000

        #if DEBUG
        let msgIdShort = messageId?.uuidString.prefix(8) ?? "—"
        if updateElapsed >= 300 {
            Self.watchdogProbe.warning("[WatchdogProbe][upd] slow updateUIView elapsed=\(String(format: "%.1f", updateElapsed))ms attrLen=\(textView.attributedText?.length ?? 0) markdownLen=\(markdown.count) msgId=\(msgIdShort)")
        }
        Self.recordUpdateUIView(elapsedMs: updateElapsed,attrLen: textView.attributedText?.length ?? 0,msgId: messageId)
        #endif

        if textView.textContainer.size.height<CGFloat.greatestFiniteMagnitude {
            textView.textContainer.size.height = CGFloat.greatestFiniteMagnitude
        }
    }

    private static let nsOriginalFontKey = NSAttributedString.Key("NSOriginalFont")

    ///
    /// A genuine font/size change still breaks the match.
    private static func prefixesEqualIgnoringFontSubstitution(
        _ newPrefix: NSAttributedString,
        _ oldPrefix: NSAttributedString
    ) -> Bool {
        guard newPrefix.length == oldPrefix.length else { return false }
        guard (newPrefix.string as NSString).isEqual(oldPrefix.string) else { return false }
        let fontKey = NSAttributedString.Key.font
        let full = NSRange(location: 0,length: newPrefix.length)
        var equal = true
        newPrefix.enumerateAttributes(in: full,options: []) { aN,range,stop in
            let aO = oldPrefix.attributes(at: range.location,effectiveRange: nil)
            let fontN = aN[fontKey] as? UIFont
            let fontO = aO[fontKey] as? UIFont
            let originalO = aO[nsOriginalFontKey] as? UIFont
            let fontsOK = (fontN == fontO) || (fontN != nil && fontN == originalO)
            if !fontsOK { equal = false; stop.pointee = true; return }
            var nN = aN; nN.removeValue(forKey: fontKey); nN.removeValue(forKey: nsOriginalFontKey)
            var nO = aO; nO.removeValue(forKey: fontKey); nO.removeValue(forKey: nsOriginalFontKey)
            if !(nN as NSDictionary).isEqual(to: nO) {
                equal = false
                stop.pointee = true
            }
        }
        return equal
    }

    private static func collectImageNodes(from block: BlockNode) -> [String] {
        var results: [String] = []
        func walkInlineNodes(_ inlines: [InlineNode]) {
            for inline in inlines {
                switch inline {
                case .image(let src,_):
                    results.append(src)
                case .emphasis(let ch),.strong(let ch),.strikethrough(let ch),.link(_,let ch):
                    walkInlineNodes(ch)
                default: break
                }
            }
        }
        func walkBlockNodes(_ blocks: [BlockNode]) {
            for b in blocks {
                switch b {
                case .paragraph(let inlines),.heading(_,let inlines):
                    walkInlineNodes(inlines)
                case .blockquote(let children):
                    walkBlockNodes(children)
                case .bulletedList(_,let items):
                    for item in items { walkBlockNodes(item.children) }
                case .numberedList(_,_,let items):
                    for item in items { walkBlockNodes(item.children) }
                case .taskList(_,let items):
                    for item in items { walkBlockNodes(item.children) }
                default: break
                }
            }
        }
        walkBlockNodes([block])
        return results
    }

    ///
    /// 沿 superview 链上溯找承载本视图的 `SelfSizingCell`（找不到返回 nil）。
    /// [Single height source] 让 `sizeThatFits` 读到 cell 已提交的正文高度 —— 那条链必然经过
    /// cell（SwiftUI 内容挂在 `SelfSizingCell.contentView` 子树内），故上溯即可命中。
    private func enclosingSelfSizingCell(of view: UIView) -> SelfSizingCell? {
        var cur: UIView? = view.superview
        while let v = cur {
            if let cell = v as? SelfSizingCell { return cell }
            cur = v.superview
        }
        return nil
    }

    static func ctFramesetterHeight(for attrStr: NSAttributedString,width: CGFloat) -> CGFloat {        guard attrStr.length>0,width>0 else { return 0 }
        let framesetter = CTFramesetterCreateWithAttributedString(attrStr)
        let constraint = CGSize(width: width,height: .greatestFiniteMagnitude)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0,length: 0),// 0 length = whole string
            nil,
            constraint,
            nil
        )
        return ceil(size.height)
    }

    @available(iOS 16.0,*)
    func sizeThatFits(_ proposal: ProposedViewSize,uiView: MarkdownTextView,context: Context) -> CGSize? {
        // [2026-09-12 测量宽度同源修复] SwiftUI 会在**不同的 pass** 里以不同宽度询问本视图：
        // ① 布局 pass：cell 宽 402（边界宽）；② 内容 pass：370（= 402 − 2×16 块内边距）；
        // ③ **理想尺寸 pass：宽度未指定**（`.fixedSize(vertical: true)` 会拿这次答案当高度钉死），
        //    此时 `bounds.width == 0`，视图自身无从得知内容宽 → 旧代码退回**屏幕宽 402**，
        //    按 402 排版行数偏少 → 高度偏矮（1699 vs 真实 1711.3）→ 永久裁尾。
        // 解析优先级（越靠前越可信）：
        //   ① 宿主显式传入的真实内容宽（cell 宽 − 块内边距，聊天列表唯一正确来源）；
        //   ② **宿主本次给出的明确宽度**（proposal）——必须优先于「视图当前宽度」：
        //      用户气泡走 MarkdownSurface（contentWidth 为 nil），其 proposal 是气泡内容宽
        //      （~314），而视图当前 bounds/container 可能是复用遗留的较宽值（402）。
        //      若用后者，19 个字会排成 1 行 → 气泡从 2 行塌成 1 行（真机 IMG_4695/4697 实证：
        //      `branch=smooth h=48.0` 与 `branch=seed h=67.7` 反复交替）。
        //   ③ 视图当前 bounds 宽（仅当宿主未指定宽度 = 理想尺寸 pass 时，作为最佳已知真值）；
        //   ④ textContainer 宽；⑤ 屏幕宽（最后兜底，仅全新视图 + 未指定宽度时发生）。
        let rawProposal = proposal.width
        let resolvedContentWidth = contentWidth
        let width: CGFloat
        if let cw = resolvedContentWidth, cw > 1 {
            width = cw
        } else if let rawProposal, rawProposal > 1 {
            width = rawProposal
        } else if uiView.bounds.width > 1 {
            width = uiView.bounds.width
        } else if uiView.textContainer.size.width > 1 {
            width = uiView.textContainer.size.width
        } else {
            width = UIScreen.main.bounds.width
        }
        // 统一渲染/测量缓存的 key（渲染分支与测量分支共用同一 key，条目互通）
        let renderCacheKey = MarkdownRenderCache.key(for: markdown, fontSize: FontSettings.shared.scaledMessage(16.5))
        // [2026-09-13 重构·语义拆分] 原先一个 `bindingLen` 兼任两职：
        //   ① **缓存代际键**（与 `cachedSizeFingerprint` 比较）—— 需要**内容指纹**（等长改写必须判"变了"）；
        //   ② **长度代理**（`bindingLen == storageLen` 的存储一致性检查）—— 需要**真实长度**。
        // 一个变量两个语义正是本轮重构要消掉的坏味道，故拆成两个变量，各只承担一件事。
        let bindingLen = (markdown as NSString).length
        let bindingFingerprint = ContentFingerprint.of(markdown)
        let storageLen = uiView.textStorage.length

        let coord = context.coordinator
        coord.sizeThatFitsCallCount &+= 1
        let callIdx = coord.sizeThatFitsCallCount
        let t0 = CFAbsoluteTimeGetCurrent()

        let widthKey = Int(width.rounded())
        // [Single height source] cell 已按**同一内容 + 同一宽度**提交过正文高度 ⇒ 作为**下限**
        // （不是直接返回）。宿主（SwiftUI hosting）就是拿本函数的返回值去写 textView 的 frame。
        // 为什么取下限：直接返回把正确性押在"实际装饰恰好等于 `assistantBlockVerticalChrome`"上 ——
        // 实际装饰更大时高度会**每轮累加、无界跑飞**（跨 cell 累积 495pt 的事故形状）。
        // 取下限则**恒有界**（上界 = 真实测量高），同时仍保证"正文 view 永不比 cell 已经给它的
        // 空间矮" ⇒ 尾部不再掉出可见范围。
        // 必须放在**所有缓存判定之前**：否则缓存先返回它自己算的值，下限失效。
        // 三道校验缺一不可：① 内容指纹一致（cell 复用后旧值绝不能被当成新内容的高度）；
        // ② 宽度一致（高度与宽度都相关）；③ 正文视图**当前**的 markdown 与本次测量一致
        //（防"cell 已提交新内容、uiView 还挂着旧内容"时张冠李戴）。
        let committedFloor: CGFloat = {
            guard let cell = enclosingSelfSizingCell(of: uiView),
                  cell.committedTextHeight > 1,
                  cell.committedFingerprint == bindingFingerprint,
                  abs(cell.committedTextWidth - width) < 0.5,
                  ContentFingerprint.of(uiView.rawMarkdown) == bindingFingerprint else { return 0 }
            return cell.committedTextHeight
        }()
        @inline(__always) func floored(_ h: CGFloat) -> CGSize { CGSize(width: width,height: max(h,committedFloor)) }
        if bindingFingerprint == coord.cachedSizeFingerprint,
           let cachedHeight = coord.cachedSizes[widthKey] {
            coord.sizeThatFitsCacheHitCount &+= 1
            if callIdx%50 == 0 {
            }
            return floored(cachedHeight)
        }

        // Near-width cache hit for FULLY
        if bindingFingerprint == coord.cachedSizeFingerprint,
           bindingLen == storageLen,
           !coord.cachedSizes.isEmpty {
            var nearestHeight: CGFloat?
            var nearestDelta = Int.max
            for (bucket,h) in coord.cachedSizes {
                let delta = abs(bucket-widthKey)
                if delta <= 2,delta<nearestDelta {
                    nearestDelta = delta
                    nearestHeight = h
                }
            }
            if let nearestHeight {
                coord.sizeThatFitsCacheHitCount &+= 1
                coord.cachedSizes[widthKey] = nearestHeight
                if coord.cachedSizes.count>4,let firstKey = coord.cachedSizes.keys.first {
                    coord.cachedSizes.removeValue(forKey: firstKey)
                }
                return floored(nearestHeight)
            }
        }

        //
        let useMeasureTextView = bindingLen != storageLen

        if bindingFingerprint != coord.cachedSizeFingerprint {
            coord.cachedSizes.removeAll(keepingCapacity: true)
            coord.cachedSizeFingerprint = bindingFingerprint
        }

        // recorded in `MiniClaw-2026-05-13-084827.ips` (depth=9 recursion at
        let measuringTextView: MarkdownTextView
        if useMeasureTextView {
            // from `MessageListModel.cacheAttributedString(for:)` which uses
            let preHasTable: Bool = {
                guard let pre = cachedAttributedString,pre.length>0 else { return false }
                var found = false
                pre.enumerateAttribute(.attachment,in: NSRange(location: 0,length: pre.length),options: []) { value,_,stop in
                    if value is TableAttachment { found = true; stop.pointee = true }
                }
                return found
            }()
            let pending: NSAttributedString
            // [高度投毒修复 2026-09-10] 本次测量输入是否为落后快照（见下方节流分支）。
            var measuredFromStaleSnapshot = false
            if let pre = cachedAttributedString,!preHasTable {
                pending = pre
            } else {
                //
                // Skip the split once the message has finished streaming: a message
                // whose final row never gets a trailing `\n` must still be rendered
                // as a real table after stream-end.
                // [2026-09-08] 终态信号改为**宿主显式传入的 isStreaming**（旧实现用
                // `cachedAttributedString != nil || cachedContent != nil` 反推，而
                // cachedAttributedString 又只能由终态回写产生 → 自依赖死循环：缓存
                // 缺失时永远判为流式，回写永不触发）。保留旧条件作兼容兜底（旧缓存
                // 已存在的块同样视为终态，行为不变）。
                let _isFinalisedSTF = !isStreaming
                    || cachedAttributedString != nil || cachedContent != nil
                let split = _isFinalisedSTF
                    ? (prefix: markdown, plainSuffix: "")
                    : splitStreamingTableTail(markdown)
                let preparedPrefix = prepareMarkdownForRender(split.prefix)
                // 统一渲染缓存查找：key=markdown 源文+字号。**不加 _isFinalisedSTF 门**——
                // key 内容敏感（流式中内容变 → key 变 → 自然 miss），历史块复用时
                // cachedAttributedString 为 nil 也不该跳过缓存（真机日志：62-144ms
                // hosting 测量 × 每块 = 流式期间滑动掉帧主因）。
                if let memo = MarkdownRenderCache.shared.cachedAttributed(for: renderCacheKey) {
                    pending = memo
                } else {
                // [T-perf 2026-09-08] 流式渲染节流：距上次全量渲染 <节流窗时直接复用
                // 上次结果（显示滞后 ≤节流窗，下个 token 到达自然追上）。全量渲染是
                // O(当前长度)——长消息后期单次 0.5-1.1s（真机 SizeFit #32=1112ms），
                // 每 token 都渲染 = 主线程饱和 = 思考/流式期间没法滑动。
                if _isFinalisedSTF == false,
                   let prev = coord.lastStreamPending,
                   CACurrentMediaTime()-coord.lastStreamRenderAt < Coordinator.streamThrottleWindow {
                    pending = prev
                    // [高度投毒修复 2026-09-10] 节流复用的旧快照可能**落后于当前
                    // markdown**（下个 token 已到、渲染还没追上）。此时 renderCacheKey
                    // 是**新内容**的 key，用旧快照测出的矮高度一旦写入，就会以新内容
                    // 的 key 永久命中（:1051/:1088 直接 return，不再重测）→ 文字全在、
                    // 高度没长 → 上滑回看尾部行被裁（两天「块错位/丢字」的根因）。
                    // 快照落后时置位，下方所有缓存写入全部跳过；返回值照旧（显示
                    // 滞后 ≤节流窗是节流的既有语义，下个 chunk 自然追平）。
                    measuredFromStaleSnapshot = coord.lastStreamPendingSourceLen < markdown.count
                } else {
                let blocks = MarkdownContent(preparedPrefix).blocks
                coord.renderer.messageId = messageId
                coord.renderer.blockId = blockId
                let rendered = autoreleasepool { coord.renderer.render(blocks: blocks) }
                if split.plainSuffix.isEmpty {
                    pending = rendered
                } else {
                    let mut = NSMutableAttributedString(attributedString: rendered)
                    let suffixAttrs: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: FontSettings.shared.scaledMessage(16.5)),
                        .foregroundColor: UIColor.label,
                    ]
                    mut.append(NSAttributedString(string: split.plainSuffix,attributes: suffixAttrs))
                    pending = mut
                }
                if _isFinalisedSTF == false {
                    coord.lastStreamPending = pending
                    coord.lastStreamRenderAt = CACurrentMediaTime()
                }
                // block 级缓存写回（供 precalc 精确种子）：统一缓存在测量分支写入。
                if _isFinalisedSTF, split.plainSuffix.isEmpty {
                    // 第二参数必须是**本次渲染输入**的内容指纹：回调方以它当缓存指纹，
                    // 保证指纹与 pending 同源（见 onRendered 声明处注释）。
                    onRendered?(pending, ContentFingerprint.of(markdown))
                }
            }
            }
            }
            if !pending.hasAnyAttachment {
                // FINALIZED content takes
                // MarkdownTextView measure matches the final render
                let finalizedSTF = cachedAttributedString != nil || cachedContent != nil
                let h: CGFloat
                // [T-perf 2026-09-08] 统一缓存 heights 命中：免 TextKit 全量重排
                // （50-100ms/次，cell 每次复用重复付费 → 上滑掉帧主因）。
                // **不加 finalizedSTF 门**：key 内容敏感（内容变 → key 变 → 自然
                // miss），历史块复用（cachedAttributedString=nil）也必须命中——
                // 真机日志：62-144ms hosting 测量 × 每块 = 流式期间滑动掉帧主因。
                // store 保留 finalized 门（流式中间态不污染缓存）。
                if finalizedSTF {
                    MarkdownRenderCache.shared.store(attributed: pending, key: renderCacheKey)
                }
                if let cachedH = MarkdownRenderCache.shared.cachedHeight(for: renderCacheKey, width: widthKey) {
                    h = cachedH
                // [2026-09-12 裁尾修复·CT 不得参与已完结块] 原条件只有 `finalizedSTF`：
                // 当块的 cachedAttributedString/cachedContent 均为 nil（新 cell 实例 +
                // 块缓存尚未回写）时 finalizedSTF == false → 落到下面的 CT 分支
                // （ctFramesetterHeight + inset）。CT 与渲染引擎在同一内容/同一宽度下
                // **矮 12.3pt**（真机实证 CT 1699 vs 屏上 TextKit 1712），而该值会被
                // `.fixedSize(vertical: true)` 当理想高度钉死 → cell 1703 而非 1716
                // → 尾部半行被裁，并经 recordMeasuredHeight 污染布局 memo（此后
                // configureCell→seed 一直播 1703）。⇒ **已完结块必须走同源 TextKit**；
                // CT 只保留给真正还在流式的块（高度是瞬态，流终有 settle 重测）。
                } else if (finalizedSTF || !isStreaming),pending.length <= 8000,
                   let mtv = coord.measureTextView as? MarkdownTextView {
                    // [T-perf 2026-09-08] 绕过 UITextView.attributedText setter——它
                    // 会重置 selection/scroll/内部 canvas 等全部 UI 状态（真机实测
                    // 单次 1.2s），测量只需要 TextKit 排版：直接驱动 textStorage +
                    // 手动设 textContainer 宽（widthTracksTextView=false 的离屏 mtv）。
                    mtv.textContainer.size = CGSize(width: width,height: .greatestFiniteMagnitude)
                    mtv.textStorage.setAttributedString(pending)
                    h = ceil(mtv.sizeThatFits(CGSize(width: width,height: .greatestFiniteMagnitude)).height)
                    if !measuredFromStaleSnapshot {
                        MarkdownRenderCache.shared.store(height: h, key: renderCacheKey, width: widthKey)
                    }
                } else {
                    let textHeight = Self.ctFramesetterHeight(for: pending,width: width)
                    let inset = uiView.textContainerInset.top+uiView.textContainerInset.bottom
                    h = textHeight+inset
                    if !measuredFromStaleSnapshot {
                        MarkdownRenderCache.shared.store(height: h, key: renderCacheKey, width: widthKey)
                    }
                }
                if !measuredFromStaleSnapshot {
                    // [高度投毒修复] 落后快照测出的高度一律不入任何缓存——否则短高度
                    // 挂在完整内容的 key/指纹下，回看时 :902/:1051 永久命中矮高度。
                    coord.cachedSizes[widthKey] = h
                    coord.cachedSizeFingerprint = bindingFingerprint
                }
                let _renderW = uiView.bounds.width
                if _renderW <= 0 || abs(width-_renderW)<0.5 {
                    uiView.lastComputedHeight = h
                }
                return floored(h)
            }
            // [T-perf 2026-09-08 缓存合并] 含表格/附件块的测量高度迁移至统一缓存
            // MarkdownRenderCache.heights（key=renderCacheKey+width，与无附件块/
            // 预填充/种子循环同一体系——此前独立的 heightMemo 已删除）。命中则
            // 跳过 `mtv.attributedText = pending` 的全量重排（755-811ms/次）。
            // 高度在函数尾部拿到后回写（fallbackMemoKey）。
            let mtv = coord.measureTextView as? MarkdownTextView ?? coord.measureTextView as! MarkdownTextView
            if let cachedH = MarkdownRenderCache.shared.cachedHeight(for: renderCacheKey, width: widthKey) {
                measuringTextView = mtv
                return floored(cachedH)
            }
            mtv.attributedText = pending
            measuringTextView = mtv
        } else {
            measuringTextView = uiView

            let liveStorage = uiView.textStorage
            if liveStorage.length>0 {
                if !liveStorage.hasAnyAttachment {
                    // Same real-engine
                    // offscreen MarkdownTextView (matches the render
                    let finalizedCommitted = cachedAttributedString != nil || cachedContent != nil
                    // [T-perf 2026-09-08 缓存合并] 进程级高度查找迁入统一缓存
                    //（key=renderCacheKey+width，与渲染分支/预填充/种子循环同体系）。
                    // 命中则直接跳过 `mtv.attributedText = liveStorage` 的全量重排。
                    let h: CGFloat
                    if finalizedCommitted {
                        // [2026-09-08 修复] 存**深拷贝**：liveStorage 是屏幕上 UITextView
                        // 的 NSTextStorage（可变子类）——直接缓存会 ① cell 复用时旧 key
                        // 的内容被就地改写（串味）② 强引用保活 UITextView/layoutManager/
                        // 附件子视图（1024 条上限形同虚设）。与渲染分支一致存不可变副本。
                        MarkdownRenderCache.shared.store(
                            attributed: NSAttributedString(attributedString: liveStorage),
                            key: renderCacheKey)
                    }
                    if let cachedH = MarkdownRenderCache.shared.cachedHeight(for: renderCacheKey, width: widthKey) {
                        h = cachedH
                    } else if (finalizedCommitted || !isStreaming),liveStorage.length <= 8000,
                       let mtv = coord.measureTextView as? MarkdownTextView {
                        mtv.attributedText = liveStorage
                        h = ceil(mtv.sizeThatFits(CGSize(width: width,height: .greatestFiniteMagnitude)).height)
                        MarkdownRenderCache.shared.store(height: h, key: renderCacheKey, width: widthKey)
                    } else {
                        let textHeight = Self.ctFramesetterHeight(for: liveStorage,width: width)
                        let inset = uiView.textContainerInset.top+uiView.textContainerInset.bottom
                        h = textHeight+inset
                        MarkdownRenderCache.shared.store(height: h, key: renderCacheKey, width: widthKey)
                    }
                    coord.cachedSizes[widthKey] = h
                    if coord.cachedSizes.count>12,let firstKey = coord.cachedSizes.keys.first {
                        coord.cachedSizes.removeValue(forKey: firstKey)
                    }
                    coord.cachedSizeFingerprint = bindingFingerprint
                    let renderW = uiView.bounds.width
                    if renderW <= 0 || abs(width-renderW)<0.5 {
                        uiView.lastComputedHeight = h
                    }
                    // [STF 诊断 2026-09-12] 只读探针（live-storage 分支）已随收尾清理移除。
                    let totalMs = (CFAbsoluteTimeGetCurrent()-t0)*1000
                    coord.sizeThatFitsTotalMs += totalMs
                    #if DEBUG
                    Self.recordSTF(elapsedMs: totalMs,msgId: messageId,attrLen: bindingLen)
                    #endif
                    return floored(h)
                }
            }
        }

        //
        let tc = measuringTextView.textContainer
        let oldWidth = tc.size.width
        let renderW = measuringTextView.bounds.width
        let isRenderWidth = renderW>0 && abs(width-renderW)<0.5
        let widthChanged = abs(width-oldWidth)>0.5
        if widthChanged && (isRenderWidth || renderW <= 0 || useMeasureTextView) {
            tc.size = CGSize(width: width,height: .greatestFiniteMagnitude)
        }

        let tSize = CFAbsoluteTimeGetCurrent()
        let size = measuringTextView.sizeThatFits(CGSize(width: width,height: .greatestFiniteMagnitude))
        let sizeMs = (CFAbsoluteTimeGetCurrent()-tSize)*1000

        if tc.size.height<CGFloat.greatestFiniteMagnitude {
            tc.size.height = CGFloat.greatestFiniteMagnitude
        }

        // Keep lastComputedHeight in sync so invalidateCellSizeIfChanged()
        //
        if isRenderWidth || renderW <= 0 {
            uiView.lastComputedHeight = size.height
        }

        // Cache the new result by width bucket. [T-perf 2026-09-08] Cap 4 → 12:
        // SwiftUI 布局每 pass 以 402（边界宽）/370（内容宽）两个宽度交替询问，
        // 4 桶时两宽度互相淘汰 → 每次 MISS 都走 mtv.attributedText = liveStorage
        // 的 TextKit 全量重排（50-100ms/次，上滑掉帧主因）。12 桶让两组宽度共存。
        coord.cachedSizes[widthKey] = size.height
        if coord.cachedSizes.count>12 {
            if let firstKey = coord.cachedSizes.keys.first {
                coord.cachedSizes.removeValue(forKey: firstKey)
            }
        }


        let totalMs = (CFAbsoluteTimeGetCurrent()-t0)*1000
        coord.sizeThatFitsTotalMs += totalMs

        if totalMs >= 50 || callIdx%100 == 0 {
            let widthDelta = Int((width-oldWidth).rounded())
            let level: String
            if totalMs >= 200 { level = "🔥🔥" }
            else if totalMs >= 50 { level = "🔥" }
            else { level = "" }
            Self.stfLogger.info("[SizeFit] #\(callIdx) MISS\(level) w=\(widthKey) (Δ\(widthDelta)) len=\(bindingLen) wChg=\(widthChanged ? 1 : 0) stf=\(String(format: "%.1f", sizeMs))ms total=\(String(format: "%.1f", totalMs))ms buckets=\(coord.cachedSizes.count) cumulative=\(String(format: "%.0f", coord.sizeThatFitsTotalMs))ms hits=\(coord.sizeThatFitsCacheHitCount)/\(callIdx)")
        }

        if bindingLen >= 10_000 && totalMs >= 100 {
            Self.stfLogger.warning("[SizeFit] ⚠️ LONG-TEXT SLOW len=\(bindingLen) totalMs=\(String(format: "%.1f", totalMs)) — repeated calls of this size can trigger 0x8BADF00D")
        }

        #if DEBUG
        Self.recordSTF(elapsedMs: totalMs,msgId: messageId,attrLen: bindingLen)
        #endif


        // [T-perf 2026-09-08 缓存合并] 附件块高度回写统一缓存（渲染分支已
        // store(attributed) → entry 存在 → 本写入生效；流式期 entry 不存在 → no-op）。
        MarkdownRenderCache.shared.store(height: size.height, key: renderCacheKey, width: widthKey)

        return floored(size.height)
    }

    private static let stfLogger = AppLogger(category: "MarkdownSTF")
    #if DEBUG
    fileprivate static let watchdogProbe = AppLogger(category: "ChatList.Watchdog")
    #endif

    #if DEBUG

    private static var stfWindowTotalMs: Double = 0
    private static var stfWindowCallCount: Int = 0
    private static var updWindowTotalMs: Double = 0
    private static var updWindowCallCount: Int = 0
    private static var distinctMsgIds: Set<UUID> = []
    private static var observerInstalled = false
    private static let windowAlarmThresholdMs: Double = 2000
    private static var alarmAlreadyFiredThisHop = false

    fileprivate static func recordSTF(elapsedMs: Double,msgId: UUID?,attrLen: Int) {
        installWindowObserverIfNeeded()
        stfWindowTotalMs += elapsedMs
        stfWindowCallCount += 1
        if let msgId { distinctMsgIds.insert(msgId) }
        checkWindowAlarm(trigger: "stf", lastLen: attrLen, lastMsgId: msgId)
    }

    fileprivate static func recordUpdateUIView(elapsedMs: Double,attrLen: Int,msgId: UUID?) {
        installWindowObserverIfNeeded()
        updWindowTotalMs += elapsedMs
        updWindowCallCount += 1
        if let msgId { distinctMsgIds.insert(msgId) }
        checkWindowAlarm(trigger: "upd", lastLen: attrLen, lastMsgId: msgId)
    }

    private static func checkWindowAlarm(trigger: String,lastLen: Int,lastMsgId: UUID?) {
        let total = stfWindowTotalMs+updWindowTotalMs
        guard total >= windowAlarmThresholdMs,!alarmAlreadyFiredThisHop else { return }
        alarmAlreadyFiredThisHop = true
        let msgIdShort = lastMsgId?.uuidString.prefix(8) ?? "—"
        watchdogProbe.warning("[WatchdogProbe][window] 🚨 cumulative=\(String(format: "%.0f", total))ms (stf=\(String(format: "%.0f", stfWindowTotalMs)) upd=\(String(format: "%.0f", updWindowTotalMs))) sttCalls=\(stfWindowCallCount) updCalls=\(updWindowCallCount) distinctMsgs=\(distinctMsgIds.count) trigger=\(trigger) lastMsgId=\(msgIdShort) lastLen=\(lastLen) — main runloop is heading toward 0x8BADF00D (10s watchdog)")
    }

    private static func installWindowObserverIfNeeded() {
        guard !observerInstalled else { return }
        observerInstalled = true
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue,
            true,0
        ) { _,_ in
            let total = stfWindowTotalMs+updWindowTotalMs
            if total >= 500 {
                watchdogProbe.info("[WatchdogProbe][hop] cumulative=\(String(format: "%.0f", total))ms stf=\(String(format: "%.0f", stfWindowTotalMs)) upd=\(String(format: "%.0f", updWindowTotalMs)) stfCalls=\(stfWindowCallCount) updCalls=\(updWindowCallCount) distinctMsgs=\(distinctMsgIds.count)")
            }
            stfWindowTotalMs = 0
            stfWindowCallCount = 0
            updWindowTotalMs = 0
            updWindowCallCount = 0
            distinctMsgIds.removeAll(keepingCapacity: true)
            alarmAlreadyFiredThisHop = false
        }
        if let observer {
            CFRunLoopAddObserver(CFRunLoopGetMain(),observer,.commonModes)
        }
    }
    #endif

    final class Coordinator: NSObject,UITextViewDelegate {
        /// 上一次 `updateUIView` 看到的流式态；`nil` = 尚未见过。
        /// 用途：下一次更新时判定「流是否**刚刚**结束」—— 那是终态收敛的唯一可靠触发点
        /// （`isStreaming` true→false 是入参变化，必然带来一次 `updateUIView`）。
        var lastWasStreaming: Bool?
        var lastMarkdown: String = ""
        /// [StaleRender 限流] 上一次打印"拒绝更短的旧快照"的时间（1s 节流，防流式期刷屏）。
        var lastStaleLogAt: CFTimeInterval = 0
        var lastRenderedContentHash: Int? = nil
        var pendingMarkdown: String? = nil
        private var replayDeferredRender: (() -> Void)?

        func deferRender(_ markdown: String,replay: @escaping () -> Void) {
            pendingMarkdown = markdown
            replayDeferredRender = replay
        }

        private nonisolated(unsafe) var foregroundObserver: NSObjectProtocol?
        private nonisolated(unsafe) var resignActiveObserver: NSObjectProtocol?
        var inactiveEnteredAt: Date?

        override init() {
            super.init()
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.inactiveEnteredAt = nil
                self?.applyDeferredRenderNow()
            }
            resignActiveObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.inactiveEnteredAt = Date()
            }
        }

        private func applyDeferredRenderNow() {
            guard UIApplication.shared.applicationState == .active else { return }
            guard pendingMarkdown != nil,let replay = replayDeferredRender else { return }
            pendingMarkdown = nil
            replayDeferredRender = nil
            replay()
        }

        deinit {
            if let foregroundObserver {
                NotificationCenter.default.removeObserver(foregroundObserver)
            }
            if let resignActiveObserver {
                NotificationCenter.default.removeObserver(resignActiveObserver)
            }
        }
        var lastFontSize: CGFloat = FontSettings.shared.scaledMessage(16.5)
        var openURL: OpenURLAction?
        var cachedSizes: [Int: CGFloat] = [:]
        /// [2026-09-13 指纹统一] 原为 `cachedSizeMarkdownCount`（只比 NSString 长度）。
        /// 等长改写会被判"未变" ⇒ sizeThatFits 直接返回陈旧高度（尾部被裁）。改用 `ContentFingerprint`。
        var cachedSizeFingerprint: Int = 0
        // [T-perf 2026-09-08] 流式渲染节流状态（见渲染分支注释）：节流窗内的
        // sizeThatFits/updateUIView 直接复用上次渲染结果，把流式渲染频率锁到 ~4 次/秒。
        var lastStreamPending: NSAttributedString? = nil
        var lastStreamRenderAt: CFTimeInterval = 0
        /// [尾包修复 2026-09-10] 上面这份节流快照所对应的**渲染输入长度**（markdown.count）。
        /// 判定「显示所依据的快照是否已落后于当前内容」——只有落后的快照才需要追赶。
        var lastStreamPendingSourceLen: Int = 0
        /// [尾包修复 2026-09-10 真机实证] 节流复用旧快照的那一次 updateUIView 会把
        /// `lastMarkdown` 记成**最新内容**，于是内容停止增长后（回复结束）后续 updateUIView
        /// 全被早退守卫拦下 → storage 永久停在缺尾的旧快照上（表现：AI 回复结尾少一截，
        /// 滑动离开/重进会话才恢复，因为那时才换到新 textView 重新全量渲染）。
        /// 置位 = 当前 storage 与内容不一致：早退守卫必须放行，追赶渲染必须跳过节流。
        var streamSnapshotStale = false
        private var streamCatchUpScheduled = false

        /// [尾包修复 2026-09-10] 追赶渲染：本条 updateUIView 显示的是落后快照时排一次
        /// 「出窗即全量渲染」。必须显式排期——内容停止增长后不会再有带新 markdown 的
        /// SwiftUI 更新，否则尾包永远落不了地。延迟取节流窗剩余时间，保证追赶那次
        /// 真正走全量。后台不渲染（与 deferRender 同口径）且**保留脏标记**，
        /// 回前台由 applyDeferredRenderNow 的那次 replay 顺带追平。
        func scheduleStreamCatchUp(replay: @escaping () -> Void) {
            guard !streamCatchUpScheduled else { return }
            streamCatchUpScheduled = true
            let remaining = max(0,Self.streamThrottleWindow - (CACurrentMediaTime() - lastStreamRenderAt)) + 0.02
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                guard let self else { return }
                self.streamCatchUpScheduled = false
                guard UIApplication.shared.applicationState == .active else { return }
                replay()
            }
        }

        /// 流式渲染/测量统一节流窗（唐唐定 2026-09-10：250ms → 150ms）。
        /// 全库节流判定与追赶排期必须引用本常量，禁止散落字面量。
        static let streamThrottleWindow: CFTimeInterval = 0.15
        var lastRenderedWidth: CGFloat = -1
        /// [FadeLeak] 尾部透明残留扫描的节流时间戳（early-return 分支，2s/次）。
        var lastFadeResidueScanAt: CFTimeInterval = 0
        /// 当前渲染的内容身份（blockId 优先，缺省
        /// messageId）。换块判定用：cell 复用/块重配把同一 textView 更新为另一块
        /// 的内容时必须 cancelAll（见 updateUIView 内注释）。
        var lastContentId: UUID?
        var sizeThatFitsCallCount: Int = 0
        var sizeThatFitsCacheHitCount: Int = 0
        var sizeThatFitsTotalMs: Double = 0
        ///
        var renderer = MarkdownNSRenderer(baseFontSize: FontSettings.shared.scaledMessage(16.5))

        weak var fadeTextView: MarkdownTextView?

        lazy var fadeAnimator: TextFadeAnimator = TextFadeAnimator { [weak self] in
            self?.fadeTextView?.setNeedsDisplay()
        }

        /// `MiniClaw-2026-05-13-084827.ips`: it rebuilds attachment subviews
        ///
        fileprivate lazy var measureTextView: UITextView = {
            let tv = MarkdownTextView()
            tv.isScrollEnabled = false
            // [Fix 2026-09-14] 同 `MarkdownTextView`：关掉 TextKit 非连续布局，
            // 否则离屏测量用的这个栈也会"只排版部分文本"⇒ 高度偏小 / 尾部不绘制。
            tv.layoutManager.allowsNonContiguousLayout = false
            tv.isEditable = false
            tv.isSelectable = false
            // [ClipFix 2026-05-16] Match the live MarkdownTextView's
            tv.textContainerInset = UIEdgeInsets(top: 4,left: 0,bottom: 4,right: 0)
            tv.textContainer.lineFragmentPadding = 0
            tv.backgroundColor = .clear
            return tv
        }()

        @available(iOS 17.0,*)
        func textView(_ textView: UITextView,primaryActionFor textItem: UITextItem,defaultAction: UIAction) -> UIAction? {
            if case .link(let url) = textItem.content {
                return UIAction { [weak self] _ in
                    if let openURL = self?.openURL {
                        openURL(url)
                    } else {
                        UIApplication.shared.open(url)
                    }
                }
            }
            if #available(iOS 19,*) {
            } else if case .textAttachment(let attachment) = textItem.content,
                      attachment is TableAttachment {
                return UIAction { _ in }
            }
            return defaultAction
        }

        @available(iOS 17.0,*)
        func textView(_ textView: UITextView,menuConfigurationFor textItem: UITextItem,defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
            switch textItem.content {
            case .link(let url):
                let copyAction = UIAction(title: String(localized: "Copy Link"), image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = url.absoluteString
                }
                let openAction = UIAction(title: String(localized: "Open in Safari"), image: UIImage(systemName: "safari")) { _ in
                    UIApplication.shared.open(url)
                }
                let menu = UIMenu(children: [copyAction,openAction])
                return UITextItem.MenuConfiguration(preview: nil,menu: menu)
            case .textAttachment(let attachment):
                if #available(iOS 19,*) {
                } else if let tableAttach = attachment as? TableAttachment {
                    let copyTableAction = UIAction(
                        title: String(localized: "Copy Table"),
                        image: UIImage(systemName: "tablecells")
                    ) { _ in
                        UIPasteboard.general.string = tableAttach.plainText()
                    }
                    return UITextItem.MenuConfiguration(preview: nil,menu: UIMenu(children: [copyTableAction]))
                }
                guard let imageAttach = attachment as? ImageAttachment,
                      let image = imageAttach.loadedImage else {
                    return UITextItem.MenuConfiguration(preview: nil,menu: UIMenu(children: []))
                }
                let copyAction = UIAction(title: String(localized: "Copy Image"), image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.image = image
                }
                let saveAction = UIAction(title: String(localized: "Save to Camera Roll"), image: UIImage(systemName: "square.and.arrow.down")) { _ in
                    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                        guard status == .authorized || status == .limited else { return }
                        PHPhotoLibrary.shared().performChanges {
                            PHAssetChangeRequest.creationRequestForAsset(from: image)
                        }
                    }
                }
                let menu = UIMenu(children: [copyAction,saveAction])
                return UITextItem.MenuConfiguration(preview: nil,menu: menu)
            @unknown default:
                return nil
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            (textView as? MarkdownTextView)?.refreshSelectionState()
        }

        func textView(_ textView: UITextView,shouldInteractWith URL: URL,in characterRange: NSRange,interaction: UITextItemInteraction) -> Bool {
            if interaction == .presentActions {
                let alert = UIAlertController(title: URL.absoluteString,message: nil,preferredStyle: .actionSheet)
                alert.addAction(UIAlertAction(title: String(localized: "Copy Link"), style: .default) { _ in
                    UIPasteboard.general.string = URL.absoluteString
                })
                alert.addAction(UIAlertAction(title: String(localized: "Open in Safari"), style: .default) { _ in
                    UIApplication.shared.open(URL)
                })
                alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let root = scene.windows.first?.rootViewController {
                    var presenter = root
                    while let presented = presenter.presentedViewController { presenter = presented }
                    if let popover = alert.popoverPresentationController {
                        popover.sourceView = textView
                        let glyphRange = textView.layoutManager.glyphRange(forCharacterRange: characterRange,actualCharacterRange: nil)
                        popover.sourceRect = textView.layoutManager.boundingRect(forGlyphRange: glyphRange,in: textView.textContainer)
                    }
                    presenter.present(alert,animated: true)
                }
                return false
            }
            if let openURL {
                openURL(URL)
            } else {
                UIApplication.shared.open(URL)
            }
            return false
        }
    }
}
