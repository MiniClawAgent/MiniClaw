// TextFadeAnimator.swift
// MiniClaw
//
// Word-by-word fade-in animation for streaming Markdown output.
//
// When the renderer appends new tokens to a message's textStorage via the
// `[AttachHotPath]` append-only fast path in MarkdownView, instead
// of the new glyphs popping in instantly we fade each word from alpha 0 → 1
// with a small per-word stagger, producing a "ripple" reveal.
//
// Design constraints (see /tmp/task_word_fade_animation.md):
// - Display-layer only. Does NOT touch MiniClawMarkdownParser / AST /
// MarkdownNSRenderer. We mutate the live NSTextStorage's `.foregroundColor`
// attribute and rely on TextKit 1's behaviour that a foregroundColor change
// does NOT invalidate layout (no `ensureLayout` reflow) — only a redraw.
// - O(new words), never O(full text). Only the appended NSRange is scanned.
// - A single CADisplayLink drives ALL in-flight words; it stops itself once
// every word has settled, so an idle (non-streaming) view costs nothing.
//
// This file deliberately owns no parsing or rendering logic; it is a pure
// per-word alpha scheduler over an existing NSTextStorage.

import UIKit

/// NSTextStorage. Lives on the MarkdownView Coordinator; one
@MainActor
final class TextFadeAnimator {

    private static let wordFadeDuration: CFTimeInterval = 0.45

    private static let maxAnimatedWords = 160

    private static let staggerWindow: CFTimeInterval = 0.10

    private static func stagger(forWordCount count: Int) -> CFTimeInterval {
        guard count>0 else { return 0 }
        return staggerWindow/CFTimeInterval(count)
    }

    private struct FadeWord {
        let range: NSRange
        let startTime: CFTimeInterval
        let duration: CFTimeInterval
        let originalColor: UIColor
    }

    private weak var storage: NSTextStorage?
    private let requestRedraw: () -> Void

    private var words: [FadeWord] = []
    nonisolated(unsafe) private var displayLink: CADisplayLink?
    /// [FadeLeak] 我们**亲手压暗过**的 (range, 原色) 记录（保留最近 maxRetainedSeeds 条）。
    /// 自愈只允许还原这些记录——绝不做「凡 alpha<1 一律拉满」的全范围扫描：正文里
    /// `.secondaryLabel`（引用块）与其它半透明色本就 alpha<1，一刀切会把它们刷成不透明
    /// 黑（真机日志 IDLE-RESIDUE HEALED 最低alpha=0.61 即此痕迹）。记录式自愈同时保证
    /// 只碰自己写过 alpha 的字，不误伤任何外来颜色；保留历史记录是为了「用户回到该
    /// cell 时」仍能核对（第二道保险，见 healResidueIfNeeded）。
    private var batchSeeds: [(range: NSRange,color: UIColor)] = []
    private static let maxRetainedSeeds = 512
    /// 供残留自愈解析动态色用（由持有方传入 textView；resolvedColor 需要 traitCollection）。
    weak var traitProvider: UITraitEnvironment?
    private var resolvedTraits: UITraitCollection? {
        traitProvider?.traitCollection
    }

    /// alpha mutation. The owner should call `textView.setNeedsDisplay()`.
    init(requestRedraw: @escaping () -> Void) {
        self.requestRedraw = requestRedraw
    }

    deinit {
        // (nonisolated(unsafe): deinit 非隔离上下文访问,仅失效操作,线程安全)
        displayLink?.invalidate()
    }

    ///
    func scheduleAnimation(for range: NSRange,in targetStorage: NSTextStorage) {
        guard range.length>0 else { return }
        let storageLen = targetStorage.length
        guard range.location >= 0,range.location<storageLen else { return }
        let safeRange = NSRange(
            location: range.location,
            length: min(range.length,storageLen-range.location)
        )
        guard safeRange.length>0 else { return }

        self.storage = targetStorage

        let nsString = targetStorage.string as NSString
        let wordRanges = Self.revealUnits(in: nsString,within: safeRange,cap: Self.maxAnimatedWords)

        guard !wordRanges.isEmpty,wordRanges.count <= Self.maxAnimatedWords else { return }

        let now = CACurrentMediaTime()
        let step = Self.stagger(forWordCount: wordRanges.count)
        let baseStart = now

        targetStorage.beginEditing()
        for (i,wr) in wordRanges.enumerated() {
            let original = currentForegroundColor(at: wr.location,in: targetStorage)
            let start = baseStart+CFTimeInterval(i)*step
            words.append(FadeWord(
                range: wr,
                startTime: start,
                duration: Self.wordFadeDuration,
                originalColor: original
            ))
            batchSeeds.append((range: wr,color: original))
            targetStorage.addAttribute(
                .foregroundColor,
                value: original.withAlphaComponent(0),
                range: wr
            )
        }
        targetStorage.endEditing()

        requestRedraw()
        if batchSeeds.count > Self.maxRetainedSeeds {
            batchSeeds.removeFirst(batchSeeds.count-Self.maxRetainedSeeds)
        }
        startDisplayLinkIfNeeded()
    }

    /// [FadeLeak] 残留自愈：逐条核对**我们亲手压暗过的**记录，当前 alpha 仍低于原色
    /// alpha = 压暗未还原，原样写回记录的原色。写回**原色**而不是「拉满 alpha」——
    /// 正文的 `.secondaryLabel`（引用块）等本来就 alpha<1，一刀切会刷成不透明黑。
    /// 越界记录跳过：字符已被内容替换（与 STALE-DROP 同源），由替换方写下正确颜色。
    /// 调用点：动画收尾帧 / cancelAll / MarkdownView 的「内容未变且非流式」早退分支。
    private func healBatchResidue() {
        guard let storage,let traits = resolvedTraits,!batchSeeds.isEmpty else { return }
        let len = storage.length
        guard len > 0 else { return }
        var healed = 0
        storage.beginEditing()
        for seed in batchSeeds {
            guard seed.range.length>0,
                  seed.range.location+seed.range.length <= len else { continue }
            let current = currentForegroundColor(at: seed.range.location,in: storage)
            guard Self.alpha(of: current,traits: traits)+0.01
                < Self.alpha(of: seed.color,traits: traits) else { continue }
            storage.addAttribute(.foregroundColor,value: seed.color,range: seed.range)
            healed += seed.range.length
        }
        storage.endEditing()
        if healed > 0 {
            requestRedraw()
            AppLogger.shared.warning(
                "[FadeLeak] HEALED-BATCH \(healed)字符压暗未还原已写回原色——透明残留自愈", category: "FadeLeak")
        }
    }

    /// 第二道保险（由宿主在「内容未变、非流式」时按 2s 节流调用）：
    /// ① 记录式精确核对（batchSeeds）；② 纯透明扫描兜底（见 sweepTransparentResidue）。
    func healResidueIfNeeded() {
        healBatchResidue()
        sweepTransparentResidue()
    }

    /// [2026-09-11 终态兜底] alpha < 0.01 的前景色**必为** fade 逃逸残留——seed 后
    /// 动画器销毁（cell 复用/catch-up 重渲）或记录被 maxRetainedSeeds 淘汰时，
    /// 记录式自愈覆盖不到，字符以透明态占位（真机截图：「有行高但没有内容填充」）。
    /// 正式正文没有全透明色（合法半透明如 secondaryLabel=0.6 远离阈值）→ 还原安全：
    /// 保留原 RGB、alpha 拉满。动画进行中跳过（避免把渐隐中间态刷成终态）。
    private func sweepTransparentResidue() {
        guard words.isEmpty,let storage,let traits = resolvedTraits else { return }
        let len = storage.length
        guard len > 0 else { return }
        var fixes: [(NSRange, UIColor)] = []
        storage.enumerateAttribute(.foregroundColor,in: NSRange(location: 0,length: len),options: []) { value,range,_ in
            guard let color = value as? UIColor else { return }
            let resolved = color.resolvedColor(with: traits)
            var a: CGFloat = 0,r: CGFloat = 0,g: CGFloat = 0,b: CGFloat = 0,w: CGFloat = 0
            if resolved.getRed(&r,green: &g,blue: &b,alpha: &a) {
                if a < 0.01 { fixes.append((range, UIColor(red: r,green: g,blue: b,alpha: 1))) }
            } else if resolved.getWhite(&w,alpha: &a) {
                if a < 0.01 { fixes.append((range, UIColor(white: w,alpha: 1))) }
            }
        }
        guard !fixes.isEmpty else { return }
        let healedChars = fixes.reduce(0) { $0 + $1.0.length }
        storage.beginEditing()
        for (range,color) in fixes {
            storage.addAttribute(.foregroundColor,value: color,range: range)
        }
        storage.endEditing()
        requestRedraw()
        AppLogger.shared.warning(
            "[FadeLeak] SWEEP-TRANSPARENT \(healedChars)字符 alpha<0.01 已拉满 — 逃逸 seed 兜底", category: "FadeLeak")
    }

    private static func alpha(of color: UIColor,traits: UITraitCollection) -> CGFloat {
        let resolved = color.resolvedColor(with: traits)
        var a: CGFloat = 0
        var r: CGFloat = 0,g: CGFloat = 0,b: CGFloat = 0
        if resolved.getRed(&r,green: &g,blue: &b,alpha: &a) { return a }
        var w: CGFloat = 0
        if resolved.getWhite(&w,alpha: &a) { return a }
        return 1
    }

    func cancelAll() {
        stopDisplayLink()
        var skipped = 0
        if let storage,!words.isEmpty {
            let len = storage.length
            storage.beginEditing()
            for w in words where w.range.location+w.range.length <= len {
                storage.addAttribute(.foregroundColor,value: w.originalColor,range: w.range)
            }
            skipped = words.filter { $0.range.location+$0.range.length > len }.count
            storage.endEditing()
            requestRedraw()
        }
        words.removeAll(keepingCapacity: true)
        // [FadeLeak] 取消 ≠ 已还原：越界 word 按 range 恢复不了，用批次记录做精确兜底。
        healBatchResidue()
        if skipped>0 {
            AppLogger.shared.warning(
                "[FadeLeak] CANCEL-SKIP \(skipped)个 word 越界（storageLen 已变）— 交给批次自愈兜底", category: "FadeLeak")
        }
    }

    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil,!words.isEmpty else { return }
        let link = CADisplayLink(target: self,selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30,maximum: 120,preferred: 60)
        link.add(to: .main,forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        guard let storage else {
            stopDisplayLink()
            words.removeAll(keepingCapacity: true)
            return
        }
        let now = CACurrentMediaTime()
        let storageLen = storage.length

        var completed: [Int] = []
        var staleDropped = 0
        var staleSample = ""
        storage.beginEditing()
        for (i,w) in words.enumerated() {
            // [FadeLeak] range 越界 = storage 在动画期间被别处改写（流式回退/换块/表格
            // 尾重新切分）。该 word seed 过 alpha0，但字符本身已不存在——按 range 无从
            // 恢复，也不需要（位置上是新内容自己的颜色）。同位置真残留由批次自愈兜底。
            // 只**聚合**计数：逐条打印会刷屏（真机单帧 20+ 条，把真问题淹掉）。
            guard w.range.location+w.range.length <= storageLen else {
                staleDropped += 1
                if staleSample.isEmpty { staleSample = "\(w.range)" }
                completed.append(i)
                continue
            }
            let elapsed = now-w.startTime
            if elapsed <= 0 {
                continue // not started yet (still inside its stagger delay)
            }
            let t = min(1,elapsed/w.duration)
            let eased = Self.easeOutCubic(t)
            let color = w.originalColor.withAlphaComponent(CGFloat(eased))
            storage.addAttribute(.foregroundColor,value: color,range: w.range)
            if t >= 1 {
                storage.addAttribute(.foregroundColor,value: w.originalColor,range: w.range)
                completed.append(i)
            }
        }
        storage.endEditing()

        if staleDropped>0 {
            // [2026-09-11 降噪] 这是**正常容错路径**（越界 word 的字符已被新内容替换、
            // 位置上是新内容自己的颜色，无需恢复）→ info：不镜像控制台，避免流式回退时
            // 每帧刷屏；落盘保留聚合计数供复盘（单帧已聚合，不逐条）。
            AppLogger.shared.info(
                "[FadeLeak] STALE-DROP \(staleDropped)个 word 越界（storageLen=\(storageLen) 首个=\(staleSample)）— 内容已被替换，无需恢复", category: "FadeLeak")
        }

        if !completed.isEmpty {
            for i in completed.reversed() {
                words.remove(at: i)
            }
        }

        requestRedraw()

        if words.isEmpty {
            // [FadeLeak] 全部 word 结算完毕 → 对整批记录做残留自愈（见 healBatchResidue）。
            healBatchResidue()
            stopDisplayLink()
        }
    }

    private static func easeOutCubic(_ t: CFTimeInterval) -> CFTimeInterval {
        let inv = 1-t
        return 1-inv*inv*inv
    }

    private static func revealUnits(in string: NSString,within range: NSRange,cap: Int) -> [NSRange] {
        var units: [NSRange] = []
        var overflow = false
        let appendGap = { (start: Int,end: Int) in
            if end>start { units.append(NSRange(location: start,length: end-start)) }
        }
        string.enumerateSubstrings(in: range,options: [.byWords,.localized,.substringNotRequired]) { _,wordRange,_,stop in
            let gapStart = units.last.map { NSMaxRange($0) } ?? range.location
            appendGap(gapStart,wordRange.location)
            units.append(wordRange)
            if units.count>cap { overflow = true; stop.pointee = true }
        }
        if overflow { return [] }
        let tailStart = units.last.map { NSMaxRange($0) } ?? range.location
        appendGap(tailStart,NSMaxRange(range))
        if units.count>cap { return [] }
        return units
    }

    private func currentForegroundColor(at location: Int,in storage: NSTextStorage) -> UIColor {
        guard location >= 0,location<storage.length else { return .label }
        if let c = storage.attribute(.foregroundColor,at: location,effectiveRange: nil) as? UIColor {
            return c
        }
        return .label
    }
}
