import MiniClawKit
import SwiftUI
import UIKit
import Foundation
import Combine
import AVFoundation
import Combine
import CoreText
import Photos
import SwiftUI
import UIKit

/// 附件实例可变测量状态的互斥锁。
///
/// 主线程（cell / TextKit 排版）与后台高度预排版（`MessageCollectionCoordinator+Snapshot`
/// 的 `Task.detached` 会跑一套独立 TextKit 栈）会并发调用**同一批** attachment 实例的
/// `attachmentBounds`，而这些实例上缓存了布局结果与已加载位图。无锁并发读写会撕裂
/// 引用计数 / 数组缓冲（EXC_BAD_ACCESS），故这些字段的读写一律经本锁。
/// **只保护字段存取，不覆盖计算过程**（计算在锁外完成后再存）。
private final class AttachmentStateLock: @unchecked Sendable {
    private let lock = NSLock()
    func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

private final class ImageTapGesture: UITapGestureRecognizer {
    var attachedImage: UIImage?
    var sourceURL: String?
    var messageId: UUID?

    @objc func handleTap() {
        if let messageId,let sourceURL {
            // 2026-08-12 治本:图片点击同时进入系统预览通道(宿主监听
            // .miniClawOpenURLRequested → QLPreviewController)。source 归一为
            // miniclaw:// 文件语义(图片/PDF/音视频统一系统预览)。
            let canonical = ImageAttachment.canonicalizeMarkdownImageSource(sourceURL)
            if let url = URL(string: canonical), url.scheme == "miniclaw" {
                NotificationCenter.default.post(name: .miniClawOpenURLRequested, object: url)
            }
            return
        }
        guard let image = attachedImage else { return }
        guard let presenter = self.view?.nearestViewController() else { return }
        let scrollView = self.view?.enclosingScrollView()
        let savedOffset = scrollView?.contentOffset
        let preview = ScrollRestoringDismissWrapper(scrollView: scrollView,savedOffset: savedOffset) {
            ImagePreviewView(image: image)
        }
        let hosting = UIHostingController(rootView: preview)
        hosting.modalPresentationStyle = .overFullScreen
        hosting.modalTransitionStyle = .crossDissolve
        presenter.present(hosting,animated: true)
    }
}

/// 聊天内容里**内联媒体（图片/视频缩略图）的显示高度上限** —— 唯一常量（2026-09-13）。
///
/// 规则：**不超过则按原比例正常显示；超过则等比缩放（同时缩宽）**。点开看原图不受此限
/// （预览走的是画廊/原图路径，不经 `attachmentBounds`）。
///
/// ⚠️ 为什么必须是一个常量、而不是各写一遍：
/// 这个值决定"块有多高"，而**同一件事有 6 处实现** —— 图片的 `attachmentBounds` 两条分支、
/// 图片实际承载视图 `makeImageView`、视频的 `attachmentBounds` 与 `makeThumbnailView`、
/// 以及高度**估算器** `estimateMarkdownImageHeight`。
/// 只改其中一部分就会出现**帧高 ≠ 绘制内容**：
///   · 只改 `attachmentBounds` 不改 `makeImageView` ⇒ 视图比帧高，底部被 clipsToBounds 裁掉；
///   · 只改渲染不改估算 ⇒ 估算偏高，而手势期只拒绝收缩 ⇒ **拖动期空白**（本项目反复吃过这个亏）。
/// 此前这 6 处都写作「屏幕高度的一半」（他机器上约 655pt，等于没限高），
/// 所以 AI 生成的竖图会占掉大半屏。
enum InlineMediaMetrics {
    /// 内联媒体显示高度上限（pt）。要调松紧只改这一个值。
    static let maxHeight: CGFloat = 360
}

final class MathAttachment: NSTextAttachment {
    let latex: String
    let isBlock: Bool
    let theme: MarkdownTheme
    private(set) var renderedImage: UIImage?
    private(set) var renderedSize: CGSize = .zero
    private var didAttemptRender = false
    private(set) var renderFailed = false
    var onLoad: (() -> Void)?

    init(latex: String,isBlock: Bool,theme: MarkdownTheme) {
        self.latex = latex
        self.isBlock = isBlock
        self.theme = theme
        super.init(data: nil,ofType: nil)
        self.image = Self.transparentImage
    }

    @available(*,unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static let transparentImage: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 1,height: 1)).image { _ in }
    }()

    private static let inlinePlaceholderHeight: CGFloat = 20
    private static let blockPlaceholderHeight: CGFloat = 44

    override func attachmentBounds(for textContainer: NSTextContainer?,proposedLineFragment lineFrag: CGRect,glyphPosition position: CGPoint,characterIndex charIndex: Int) -> CGRect {
        if let img = renderedImage {
            let imgW = min(img.size.width,lineFrag.width)
            let imgH = img.size.height
            if isBlock {
                return CGRect(x: 0,y: 0,width: lineFrag.width,height: imgH)
            } else {
                // Center the formula vertically on the text baseline.
                // y offset = -(imgH - capHeight) / 2 positions the image so its
                // vertical center aligns roughly with the cap-height center.
                let baseFont = theme.baseFont
                let yOffset = -(imgH-baseFont.capHeight)/2
                return CGRect(x: 0,y: yOffset,width: imgW,height: imgH)
            }
        }
        if renderFailed {
            let fallbackFont = UIFont.monospacedSystemFont(ofSize: theme.baseFontSize*0.85,weight: .regular)
            if isBlock {
                let constraintSize = CGSize(width: lineFrag.width,height: .greatestFiniteMagnitude)
                let textHeight = (latex as NSString).boundingRect(with: constraintSize,options: [.usesLineFragmentOrigin],attributes: [.font: fallbackFont],context: nil).height
                return CGRect(x: 0,y: 0,width: lineFrag.width,height: max(ceil(textHeight),Self.blockPlaceholderHeight))
            } else {
                // Measure the actual fallback
                let textSize = (latex as NSString).size(withAttributes: [.font: fallbackFont])
                let w = min(ceil(textSize.width)+4,lineFrag.width)
                let h = max(ceil(textSize.height),Self.inlinePlaceholderHeight)
                let baseFont = theme.baseFont
                let yOffset = -(h-baseFont.capHeight)/2
                return CGRect(x: 0,y: yOffset,width: w,height: h)
            }
        }
        if isBlock {
            return CGRect(x: 0,y: 0,width: lineFrag.width,height: Self.blockPlaceholderHeight)
        }
        return CGRect(x: 0,y: 0,width: 40,height: Self.inlinePlaceholderHeight)
    }

    func beginRenderingIfNeeded() {
        MathAttachment.beginCount &+= 1
        if MathAttachment.beginCount <= 3 || MathAttachment.beginCount%50 == 0 {
            AppLogger.shared.info("[MathSched] beginRenderingIfNeeded #\(MathAttachment.beginCount) rendered=\(renderedImage != nil) attempted=\(didAttemptRender) isBlock=\(isBlock) latex=\(latex.prefix(30))", category: "MathSched")
        }
        guard renderedImage == nil,!didAttemptRender else { return }
        didAttemptRender = true
        MathRenderScheduler.shared.enqueue(self)
    }

    nonisolated(unsafe) static var beginCount: Int = 0

    func performRender() {
        if let result = SwiftMathRenderer.render(latex: latex,displayMode: isBlock,fontSize: theme.baseFontSize) {
            applyResult(result)
        } else if let fallback = SwiftMathRenderer.renderFallback(latex: latex,displayMode: isBlock,fontSize: theme.baseFontSize) {
            applyResult(fallback)
        } else {
            renderFailed = true
        }
        onLoad?()
    }

    private func applyResult(_ result: SwiftMathRenderResult) {
        renderedImage = result.image
        renderedSize = result.size
        if inlineDrawable {
            self.image = result.image
        }
    }

    /// dedicated UIImageView overlay built in `refreshAttachViews`.
    var inlineDrawable: Bool = false

    @MainActor
    func makeView(width: CGFloat) -> UIView {
        if renderedImage == nil && !didAttemptRender {
            beginRenderingIfNeeded()
        }

        if let img = renderedImage {
            let imgW = img.size.width
            let imgH = img.size.height
            let imgView = UIImageView(image: img)
            imgView.contentMode = .scaleAspectFit
            if isBlock {
                let clampedW = min(imgW,width)
                let container = UIView(frame: CGRect(x: 0,y: 0,width: width,height: imgH))
                imgView.frame = CGRect(x: (width-clampedW)/2,y: 0,width: clampedW,height: imgH)
                container.addSubview(imgView)
                return container
            } else {
                imgView.frame = CGRect(x: 0,y: 0,width: imgW,height: imgH)
                return imgView
            }
        }
        let label = UILabel()
        label.text = latex
        label.font = .monospacedSystemFont(ofSize: theme.baseFontSize*0.85,weight: .regular)
        label.textColor = theme.secondaryLabelColor
        label.numberOfLines = 0
        if isBlock {
            label.textAlignment = .center
            let fittingSize = label.sizeThatFits(CGSize(width: width,height: .greatestFiniteMagnitude))
            let height = max(ceil(fittingSize.height),Self.blockPlaceholderHeight)
            label.frame = CGRect(x: 0,y: 0,width: width,height: height)
        } else {
            label.sizeToFit()
            label.frame = CGRect(x: 0,y: 0,width: min(label.frame.width,width),height: max(label.frame.height,Self.inlinePlaceholderHeight))
        }
        return label
    }
}

final class TableScrollView: UIScrollView,UIScrollViewDelegate {
    var borderColorProvider: ((UITraitCollection) -> CGColor)?

    /// One-shot callback fired when a
    /// deceleration settled). Armed by refreshAttachViews when a streaming
    var onInteractionEnded: (() -> Void)?

    /// Reports every USER-driven offset
    var onUserScroll: ((CGPoint) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
    }

    @available(*,unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if isTracking || isDragging || isDecelerating {
            onUserScroll?(contentOffset)
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView,willDecelerate decelerate: Bool) {
        if !decelerate { notifyInteractionEnded() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        notifyInteractionEnded()
    }

    private func notifyInteractionEnded() {
        guard let callback = onInteractionEnded else { return }
        onInteractionEnded = nil
        callback()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyBorderColorNow()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyBorderColorNow()
    }

    func applyBorderColorNow() {
        guard let provider = borderColorProvider else { return }
        layer.borderColor = provider(traitCollection)
    }
}

let miniClawInlineCodeBackgroundColor = UIColor { traits in
    traits.userInterfaceStyle == .dark
        ? UIColor(red: 0x3A/255.0,green: 0x3A/255.0,blue: 0x3C/255.0,alpha: 1)
        : .systemGray6
}

/// Mirrors the `.miniClawChat` MarkdownUI theme using UIKit types.

final class NativeMediaImageCache {
    nonisolated(unsafe) static let shared = NativeMediaImageCache()
    let cache = NSCache<NSString,UIImage>()
    /// image to clipsToBounds when the late `invalidateCellSizeIfChanged` grow
    ///
    private static let defaultsKey = "MiniClawImageSizes_v1"
    private var sizes: [String: CGSize]
    private let sizesLock = NSLock()
    private init() {
        cache.countLimit = 50
        var loaded: [String: CGSize] = [:]
        if let raw = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String] {
            for (k,v) in raw {
                let parts = v.split(separator: "x")
                if parts.count == 2,
                   let w = Double(parts[0]),
                   let h = Double(parts[1]) {
                    loaded[k] = CGSize(width: w,height: h)
                }
            }
        }
        self.sizes = loaded
    }

    func image(for key: String) -> UIImage? { cache.object(forKey: key as NSString) }
    func set(_ image: UIImage,for key: String) { cache.setObject(image,forKey: key as NSString) }

    // MARK: - Negative (failure) cache
    //
    // 28 MiniClawImage + 19 AttachHotPath events on a single 115ms landing frame,
    private var failedSources: [String: CFAbsoluteTime] = [:]
    private let failedLock = NSLock()
    private let failureTTL: CFAbsoluteTime = 60

    func isRecentlyFailed(_ src: String) -> Bool {
        failedLock.lock(); defer { failedLock.unlock() }
        guard let t = failedSources[src] else { return false }
        if CFAbsoluteTimeGetCurrent()-t>failureTTL {
            failedSources.removeValue(forKey: src) // expired — allow a fresh attempt
            return false
        }
        return true
    }

    func recordFailure(_ src: String) {
        failedLock.lock(); failedSources[src] = CFAbsoluteTimeGetCurrent(); failedLock.unlock()
    }

    func clearFailure(_ src: String) {
        failedLock.lock(); failedSources.removeValue(forKey: src); failedLock.unlock()
    }

    func size(forSource src: String) -> CGSize? {
        sizesLock.lock(); defer { sizesLock.unlock() }
        return sizes[src]
    }
    func recordSize(_ size: CGSize,forSource src: String) {
        sizesLock.lock()
        if sizes[src] == size {
            sizesLock.unlock()
            return
        }
        sizes[src] = size
        let snapshot = sizes
        sizesLock.unlock()
        let encoded: [String: String] = snapshot.mapValues { "\($0.width)x\($0.height)" }
        UserDefaults.standard.set(encoded,forKey: Self.defaultsKey)
    }
}

final class AudioAttachment: NSTextAttachment {
    let source: String
    let theme: MarkdownTheme
    private var resolvedURL: URL?
    private var isResolved = false

    static let attachmentHeight: CGFloat = 70

    init(source: String,theme: MarkdownTheme) {
        self.source = source
        self.theme = theme
        super.init(data: nil,ofType: nil)
        self.image = Self.transparentImage
        resolveURL()
    }

    @available(*,unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static let transparentImage: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 1,height: 1)).image { _ in }
    }()

    private func resolveURL() {
        let cleanSource: String
        if let url = URL(string: source),var components = URLComponents(url: url,resolvingAgainstBaseURL: false) {
            components.queryItems = nil
            cleanSource = components.url?.absoluteString ?? source
        } else {
            cleanSource = source
        }
        if let url = URL(string: cleanSource), url.scheme == "miniclaw" {
            resolvedURL = resolveMiniClawFileURLForNativeText(url: url)
        } else if let url = URL(string: cleanSource) {
            resolvedURL = url
        }
        isResolved = true
    }

    override func attachmentBounds(for textContainer: NSTextContainer?,proposedLineFragment lineFrag: CGRect,glyphPosition position: CGPoint,characterIndex charIndex: Int) -> CGRect {
        let width = lineFrag.width
        return CGRect(x: 0,y: 0,width: width,height: Self.attachmentHeight)
    }

    @MainActor
    func makeView(width: CGFloat) -> UIView {
        let maxW = width
        let h = Self.attachmentHeight

        let container = UIView(frame: CGRect(x: 0,y: 0,width: width,height: h))
        container.backgroundColor = .clear

        let bg = UIView(frame: CGRect(x: 0,y: 0,width: maxW,height: h))
        bg.backgroundColor = .secondarySystemBackground
        bg.layer.cornerRadius = 10
        bg.clipsToBounds = true
        container.addSubview(bg)

        let rawFilename = source.components(separatedBy: "/").last ?? source
        let filename = rawFilename.components(separatedBy: "?").first ?? rawFilename

        let waveIcon = UIImageView(image: UIImage(systemName: "waveform"))
        waveIcon.tintColor = .secondaryLabel
        waveIcon.frame = CGRect(x: 10,y: 8,width: 14,height: 14)
        bg.addSubview(waveIcon)

        let nameLabel = UILabel()
        nameLabel.text = filename
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.textColor = .secondaryLabel
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.frame = CGRect(x: 28,y: 8,width: maxW-62,height: 16)
        bg.addSubview(nameLabel)

        let iconConfig = UIImage.SymbolConfiguration(pointSize: 22,weight: .regular)
        let playBtn = UIButton(type: .system)
        playBtn.setImage(UIImage(systemName: "play.circle.fill", withConfiguration: iconConfig), for: .normal)
        playBtn.tintColor = .systemOrange
        playBtn.frame = CGRect(x: 10,y: 30,width: 30,height: 30)
        bg.addSubview(playBtn)

        let slider = UISlider()
        slider.minimumTrackTintColor = .systemOrange
        slider.frame = CGRect(x: 46,y: 34,width: maxW-100,height: 22)
        slider.value = 0
        bg.addSubview(slider)

        let durLabel = UILabel()
        durLabel.text = "--:--"
        durLabel.font = .monospacedDigitSystemFont(ofSize: 11,weight: .regular)
        durLabel.textColor = .secondaryLabel
        durLabel.textAlignment = .right
        durLabel.frame = CGRect(x: maxW-50,y: 36,width: 40,height: 16)
        bg.addSubview(durLabel)

        let expandBtn = UIButton(type: .system)
        let expandConfig = UIImage.SymbolConfiguration(pointSize: 11,weight: .medium)
        expandBtn.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right", withConfiguration: expandConfig), for: .normal)
        expandBtn.tintColor = .secondaryLabel
        expandBtn.frame = CGRect(x: maxW-28,y: 6,width: 22,height: 22)
        bg.addSubview(expandBtn)

        let controller = InlineAudioController(fileURL: resolvedURL,playButton: playBtn,slider: slider,durationLabel: durLabel)
        objc_setAssociatedObject(bg,&InlineAudioController.associatedKey,controller,.OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let expandTap = AudioTapGesture(target: nil,action: nil)
        expandTap.fileURL = resolvedURL
        expandTap.addTarget(expandTap,action: #selector(AudioTapGesture.handleTap))
        expandBtn.addTarget(expandTap,action: #selector(AudioTapGesture.handleTap),for: .touchUpInside)
        objc_setAssociatedObject(expandBtn,&AudioTapGesture.expandTapKey,expandTap,.OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let tapTarget = UIView(frame: CGRect(x: 0,y: 0,width: maxW,height: 26))
        tapTarget.backgroundColor = .clear
        tapTarget.isUserInteractionEnabled = true
        bg.addSubview(tapTarget)
        let audioTap = AudioTapGesture(target: nil,action: nil)
        audioTap.fileURL = resolvedURL
        audioTap.addTarget(audioTap,action: #selector(AudioTapGesture.handleTap))
        tapTarget.addGestureRecognizer(audioTap)

        return container
    }
}

final class VideoAttachment: NSTextAttachment {
    let source: String
    let theme: MarkdownTheme
    /// 附件实例可变状态的互斥锁（见 `AttachmentStateLock`）。
    private let stateLock = AttachmentStateLock()
    private var thumbnailStorage: UIImage?
    /// 读加锁：后台 `attachmentBounds` 与主线程的加载回调会并发访问本属性。
    var thumbnail: UIImage? { stateLock.withLock { thumbnailStorage } }
    private func setThumbnail(_ image: UIImage?) { stateLock.withLock { thumbnailStorage = image } }
    private var isLoading = false
    private var resolvedURL: URL?
    var onLoad: (() -> Void)?

    init(source: String,theme: MarkdownTheme) {
        self.source = source
        self.theme = theme
        super.init(data: nil,ofType: nil)
        self.image = Self.transparentImage
    }

    @available(*,unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static let transparentImage: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 1,height: 1)).image { _ in }
    }()

    private static let placeholderHeight: CGFloat = 200

    override func attachmentBounds(for textContainer: NSTextContainer?,proposedLineFragment lineFrag: CGRect,glyphPosition position: CGPoint,characterIndex charIndex: Int) -> CGRect {
        let width = min(lineFrag.width,400)
        if let thumb = thumbnail {
            let aspect = thumb.size.height/max(thumb.size.width,1)
            let h = min(width*aspect,InlineMediaMetrics.maxHeight)
            return CGRect(x: 0,y: 0,width: lineFrag.width,height: h+24)
        }
        return CGRect(x: 0,y: 0,width: lineFrag.width,height: Self.placeholderHeight)
    }

    @MainActor
    func beginLoadingIfNeeded() {
        guard thumbnail == nil,!isLoading else { return }
        isLoading = true

        let src = source
        Task { @MainActor [weak self] in
            guard let self else { return }
            var fileURL: URL?
            if let url = URL(string: src),url.scheme == "miniclaw" {
                fileURL = resolveMiniClawFileURLForNativeText(url: url)
            } else if let url = URL(string: src) {
                fileURL = url
            }
            guard let fileURL else {
                self.isLoading = false
                return
            }
            let cacheKey = fileURL.path
            if let cached = NativeMediaImageCache.shared.image(for: "thumb:"+cacheKey) {
                self.setThumbnail(cached)
                self.resolvedURL = fileURL
                self.isLoading = false
                self.onLoad?()
                NotificationCenter.default.post(name: .miniClawAttachmentSizeChanged,object: src)
                return
            }
            let asset = AVAsset(url: fileURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 400,height: 400)
            var thumb: UIImage?
            do {
                let (cgImage,_) = try await generator.image(at: .zero)
                thumb = UIImage(cgImage: cgImage)
            } catch {
                // 抽帧失败：回落占位
            }
            if let thumb {
                NativeMediaImageCache.shared.set(thumb,for: "thumb:"+cacheKey)
            }
            self.setThumbnail(thumb)
            self.resolvedURL = fileURL
            self.isLoading = false
            self.onLoad?()
            if thumb != nil {
                NotificationCenter.default.post(name: .miniClawAttachmentSizeChanged,object: src)
            }
        }
    }

    @MainActor
    func makeView(width: CGFloat) -> UIView {
        let maxW = min(width,400)
        if let thumb = thumbnail {
            return makeThumbnailView(thumb,maxWidth: maxW,totalWidth: width)
        } else {
            return makePlaceholderView(maxWidth: maxW,totalWidth: width)
        }
    }

    private func makeThumbnailView(_ thumb: UIImage,maxWidth: CGFloat,totalWidth: CGFloat) -> UIView {
        let aspect = thumb.size.height/max(thumb.size.width,1)
        let h = min(maxWidth*aspect,InlineMediaMetrics.maxHeight)

        let container = UIView(frame: CGRect(x: 0,y: 0,width: totalWidth,height: h+24))
        container.backgroundColor = .clear

        let thumbView = UIImageView(image: thumb)
        thumbView.contentMode = .scaleAspectFill
        thumbView.frame = CGRect(x: 0,y: 0,width: maxWidth,height: h)
        thumbView.layer.cornerRadius = 8
        thumbView.clipsToBounds = true
        container.addSubview(thumbView)

        let overlay = UIView(frame: thumbView.frame)
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.3)
        overlay.layer.cornerRadius = 8
        overlay.clipsToBounds = true
        container.addSubview(overlay)

        let iconConfig = UIImage.SymbolConfiguration(pointSize: 44,weight: .regular)
        let playIcon = UIImageView(image: UIImage(systemName: "play.circle.fill", withConfiguration: iconConfig))
        playIcon.tintColor = .white.withAlphaComponent(0.9)
        playIcon.sizeToFit()
        playIcon.center = CGPoint(x: maxWidth/2,y: h/2)
        container.addSubview(playIcon)

        let filename = source.components(separatedBy: "/").last ?? source
        let filmIconCfg = UIImage.SymbolConfiguration(pointSize: 10,weight: .regular)
        let filmIcon = UIImageView(image: UIImage(systemName: "film", withConfiguration: filmIconCfg))
        filmIcon.tintColor = .secondaryLabel
        filmIcon.frame = CGRect(x: 0,y: h+6,width: 14,height: 12)
        container.addSubview(filmIcon)

        let label = UILabel()
        label.text = filename
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabel
        label.lineBreakMode = .byTruncatingMiddle
        label.frame = CGRect(x: 18,y: h+4,width: maxWidth-18,height: 16)
        container.addSubview(label)

        container.isUserInteractionEnabled = true
        let tap = VideoTapGesture(target: nil,action: nil)
        tap.fileURL = resolvedURL
        tap.addTarget(tap,action: #selector(VideoTapGesture.handleTap))
        container.addGestureRecognizer(tap)

        return container
    }

    private func makePlaceholderView(maxWidth: CGFloat,totalWidth: CGFloat) -> UIView {
        let h = Self.placeholderHeight
        let container = UIView(frame: CGRect(x: 0,y: 0,width: totalWidth,height: h))

        let bg = UIView(frame: CGRect(x: 0,y: 0,width: maxWidth,height: h))
        bg.backgroundColor = .secondarySystemBackground
        bg.layer.cornerRadius = 8
        bg.clipsToBounds = true
        container.addSubview(bg)

        let iconConfig = UIImage.SymbolConfiguration(pointSize: 44,weight: .regular)
        let icon = UIImageView(image: UIImage(systemName: "play.circle.fill", withConfiguration: iconConfig))
        icon.tintColor = .tertiaryLabel
        icon.sizeToFit()
        icon.center = CGPoint(x: bg.bounds.midX,y: bg.bounds.midY-12)
        bg.addSubview(icon)

        let filename = source.components(separatedBy: "/").last ?? source
        let label = UILabel()
        label.text = filename
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.frame = CGRect(x: 8,y: icon.frame.maxY+8,width: bg.bounds.width-16,height: 16)
        bg.addSubview(label)

        return container
    }
}

func downsampleImageData(_ data: Data,maxPixelSize: CGFloat = 2048) -> UIImage? {
    let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
    guard let source = CGImageSourceCreateWithData(data as CFData,opts as CFDictionary) else { return nil }
    let downsampleOpts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source,0,downsampleOpts as CFDictionary) else {
        return UIImage(data: data)
    }
    return UIImage(cgImage: cg)
}

final class FileAttachment: NSTextAttachment {
    let fileName: String
    let source: String
    let theme: MarkdownTheme

    init(fileName: String, source: String, theme: MarkdownTheme) {
        self.fileName = fileName
        self.source = source
        self.theme = theme
        super.init(data: nil, ofType: nil)
    }
    @available(*,unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static let height: CGFloat = 40

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect, glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        let font = UIFont.systemFont(ofSize: 13)
        let nameW = ceil((fileName as NSString).size(withAttributes: [.font: font]).width)
        let w = min(12 + 20 + 6 + nameW + 12, lineFrag.width)
        // y:0 与其他附件(音频/视频)一致——用 y:-4 会让卡片向上偏 4pt,
        // 行底露出背景(深色模式即下方黑边)。
        return CGRect(x: 0, y: 0, width: w, height: Self.height)
    }

    @MainActor
    func makeView(width: CGFloat) -> UIView {
        // 灰底圆角卡片(四角都圆)。renderFileAttach 已显式 lineSpacing=0,行高=卡片高(40),
        // container/bg 与 attachmentBounds 高度一致,圆角四角完整落在行内,无露黑。
        let container = UIView(frame: CGRect(x: 0, y: 0, width: width, height: Self.height))
        container.backgroundColor = .clear

        let bg = UIView(frame: container.bounds)
        bg.backgroundColor = UIColor.secondarySystemBackground
        bg.layer.cornerRadius = 8
        bg.clipsToBounds = true
        container.addSubview(bg)

        let icon = UIImageView(image: UIImage(systemName: "doc.fill"))
        icon.tintColor = UIColor.secondaryLabel
        icon.contentMode = .scaleAspectFit
        icon.frame = CGRect(x: 12, y: (Self.height - 20) / 2, width: 20, height: 20)
        bg.addSubview(icon)

        let label = UILabel(frame: CGRect(x: 38, y: 0, width: max(0, width - 46), height: Self.height))
        label.font = UIFont.systemFont(ofSize: 13)
        label.textColor = UIColor.label
        label.text = fileName
        label.lineBreakMode = .byTruncatingTail
        bg.addSubview(label)

        container.isUserInteractionEnabled = true
        container.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
        return container
    }

    @objc private func handleTap() {
        if let url = URL(string: source) {
            NotificationCenter.default.post(name: .miniClawOpenURLRequested, object: url)
        }
    }
}

final class ImageAttachment: NSTextAttachment {
    let source: String
    let theme: MarkdownTheme
    var messageId: UUID?
    var loadedFingerprint: String?
    /// `refreshAttachViews` rebuilds the `UIImageView` instead of
    var needsViewRebuild: Bool = false
    /// 附件实例可变状态的互斥锁（见 `AttachmentStateLock`）。
    private let stateLock = AttachmentStateLock()
    private var loadedImageStorage: UIImage?
    /// 读加锁：后台 `attachmentBounds` 与主线程的加载回调会并发访问；
    /// 无锁并发读写 `UIImage?` 会撕裂引用计数（EXC_BAD_ACCESS）。
    var loadedImage: UIImage? { stateLock.withLock { loadedImageStorage } }
    private func setLoadedImage(_ image: UIImage?) { stateLock.withLock { loadedImageStorage = image } }
    /// Resolved file URL for lazy re-downsampling (no raw Data in memory).
    private var resolvedFileURL: URL?
    /// The maxPixelSize used for the current loadedImage (0 = initial full load).
    private var downsampledAtPixelSize: CGFloat = 0
    /// 降采样请求：由 nonisolated 的 attachmentBounds 记录，主 actor 侧消费。
    nonisolated(unsafe) private var desiredDownsamplePixels: CGFloat?
    private var isLoading = false
    /// Set when a miniclaw:// file was not found; allows retry on next render.
    private var fileNotFound = false
    private var retriesRemaining = 15
    var onLoad: (() -> Void)?

    fileprivate var attachmentBoundsCallCount: Int = 0
    fileprivate var makeViewCallCount: Int = 0

    init(source: String,theme: MarkdownTheme,messageId: UUID? = nil) {
        self.source = source
        self.theme = theme
        self.messageId = messageId
        super.init(data: nil,ofType: nil)
        self.image = Self.transparentImage
        AppLogger.shared.info("[IMG][CTOR] src=\(Self.shortSrc(source)) ptr=\(ObjectIdentifier(self).hashValue & 0xFFFFFF)", category: "ChatList.Attach")
    }

    static func shortSrc(_ s: String) -> String {
        let max = 60
        return s.count <= max ? s : "…"+String(s.suffix(max-1))
    }

    /// a URL scheme (`http`, `https`, `miniclaw`, `file`, …) are returned
    /// 文件型 `miniclaw://` host(磁盘布局 = 会话目录 `<sid>/<host>/<path>`,
    /// 与 `miniclaw://` 完全一致)。导航深链(settings/open_terminal/session/new/task)
    /// 不在此列,保持原样交给深链路由。internal:MiniClawOpenURLHandler 同用。
    static let fileHosts: Set<String> = [
        "browser", "workspace", "attachments", "shared", "offloads", "memory", "rules", "skills"
    ]

    /// `./foo.png`, `subdir/bar.jpg`) become `miniclaw://workspace/<path>`
    static func canonicalizeMarkdownImageSource(_ src: String) -> String {
        if let colon = src.firstIndex(of: ":") {
            let maybeScheme = src[src.startIndex..<colon]
            if !maybeScheme.isEmpty && maybeScheme.allSatisfy({ $0.isLetter }) {
                // Exception: a miniclaw:// source the
                // encoded URLs (encodeRawMiniClawURL decodes-then-encodes per segment).
                if src.hasPrefix("miniclaw://"), URL(string: src) == nil,
                   let fixed = encodeRawMiniClawURL(src) {
                    return fixed.absoluteString
                }
                // [2026-08-12 治本] miniclaw://<host>/<path> 文件型链接归一为 miniclaw://:
                // 系统提示与 BrowserController 产物输出 miniclaw://browser/...,而本加载
                // 管线只认 miniclaw://——不归一就落入 file 兜底分支(Data(contentsOf:) 对非
                // file URL 抛错),图片永远显示"大矩形+文件名"占位符。
                if src.hasPrefix("miniclaw://"), let url = URL(string: src),
                   let host = url.host, Self.fileHosts.contains(host) {
                    return "miniclaw://" + String(src.dropFirst("miniclaw://".count))
                }
                return src
            }
        }
        var trimmed = src
        while trimmed.hasPrefix("./") { trimmed.removeFirst(2) }
        while trimmed.hasPrefix("/") { trimmed.removeFirst() }
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        let encoded = segments.map { seg -> String in
            String(seg).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(seg)
        }.joined(separator: "/")
        return "miniclaw://workspace/\(encoded)"
    }

    func invalidateLoadedImage() {
        setLoadedImage(nil)
        loadedFingerprint = nil
        downsampledAtPixelSize = 0
        resolvedFileURL = nil
        fileNotFound = false
        retriesRemaining = 15
        needsViewRebuild = true
    }

    @available(*,unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static let transparentImage: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 1,height: 1)).image { _ in }
    }()

    private static let placeholderHeight: CGFloat = 200
    private static let maxImageWidth: CGFloat = 400
    /// Breathing room reserved on EVERY side of the
    private static let imageShadowInset: CGFloat = 6

    override func attachmentBounds(for textContainer: NSTextContainer?,proposedLineFragment lineFrag: CGRect,glyphPosition position: CGPoint,characterIndex charIndex: Int) -> CGRect {
        // flows through cell self-sizing. Without quantization the downstream
        // `targetPixels` can toggle across the `downsampledAtPixelSize !=` guard
        // and re-schedule downsample on every call, which mutates loadedImage
        // and forces TextKit to re-typeset. Bucket is visually imperceptible.
        let rawWidth = lineFrag.width
        let width = (rawWidth/4.0).rounded()*4.0
        // 计数在锁内自增：本方法会被主线程排版与后台预排版并发调用。
        let cnt = stateLock.withLock { attachmentBoundsCallCount &+= 1; return attachmentBoundsCallCount }
        // [2026-09-14 降噪] 原为 `cnt <= 5 || cnt%50 == 0` —— 但计数是**逐附件对象**的，
        // 而一次会话会新建上百个附件对象（`[IMG][MAKEVIEW]` 实测 266 次/天）⇒ 全天 584 行，
        // 报的却只是"该附件的宽度桶/是否已解码"，首次即定型。
        // 改为**每个附件只留首次一行**：几何分桶是否异常这一唯一诊断价值仍在，
        // 定位交给 `[IMG][MAKEVIEW]`（每次 makeView）与 `[IMG][BOUNDS][DOWNSAMPLE-FIRE]`（罕见且高价值）。
        if cnt == 1 {
            AppLogger.shared.info("[IMG][BOUNDS] first src=\(Self.shortSrc(self.source)) ptr=\(ObjectIdentifier(self).hashValue & 0xFFFFFF) rawW=\(String(format: "%.1f", rawWidth)) bucketW=\(String(format: "%.0f", width)) hasImg=\(self.loadedImage != nil) sampledAt=\(Int(self.downsampledAtPixelSize))", category: "ChatList.Attach")
        }

        if let img = loadedImage {
            // Inset the displayed image by
            let boxWidth = min(min(width,img.size.width+Self.imageShadowInset*2),Self.maxImageWidth)
            var imgWidth = max(boxWidth-Self.imageShadowInset*2,40)
            let aspect = img.size.height/max(img.size.width,1)
            let maxH = InlineMediaMetrics.maxHeight
            var h = imgWidth*aspect
            // 2026-08-12 治本:限高时必须等比缩宽保持原比例——否则 box 比例≠图片
            // 比例,scaleAspectFit 在 box 内 letterbox 居中 + 露出黑底(黑边)。
            if h > maxH {
                h = maxH
                imgWidth = h/aspect
            }

            // Re-downsample if the loaded image is much larger than needed.
            // Target: 2x the actual display width for retina crispness.
            // Re-reads from disk (not memory) to avoid holding raw Data in RAM.
            // Guards:
            // - imgWidth >= maxImageWidth * 0.8: only downsample when layout width
            // is close to the final display width. TextKit may call attachmentBounds
            // with a very small lineFrag during intermediate layout passes; if we
            // downsample then, loadedImage is permanently replaced with a tiny
            // thumbnail (e.g. 112×200) and never recovers.
            // - targetPixels >= 600: absolute minimum to avoid destroying image quality.
            // - targetPixels is bucketed to 50pt so sub-point lineFrag jitter
            // cannot flip the `downsampledAtPixelSize != targetPixels` guard
            // and re-kick downsample on every attachmentBounds call.
            let rawTargetPixels = imgWidth*2
            let targetPixels = (rawTargetPixels/50.0).rounded()*50.0
            if imgWidth >= Self.maxImageWidth*0.8,
               targetPixels >= 600,
               img.size.width>targetPixels*1.5,
               downsampledAtPixelSize != targetPixels {
                AppLogger.shared.info("[IMG][BOUNDS][DOWNSAMPLE-FIRE] src=\(Self.shortSrc(self.source)) ptr=\(ObjectIdentifier(self).hashValue & 0xFFFFFF) targetPx=\(Int(targetPixels)) prevPx=\(Int(self.downsampledAtPixelSize)) imgW=\(Int(img.size.width)) bucketW=\(String(format: "%.0f", width))", category: "ChatList.Attach")
                downsampledAtPixelSize = targetPixels
                // 降采样请求记入非隔离标记位，由 beginLoadingIfNeeded（主 actor）消费；
                // nonisolated 的 TextKit 回调内不创建捕获 self 的任务。
                desiredDownsamplePixels = targetPixels
            }

            return CGRect(x: 0,y: 0,width: imgWidth+Self.imageShadowInset*2,
                          height: h+Self.imageShadowInset*2)
        }
        // 1. First updateUIView creates a fresh ImageAttachment (cacheCount=0)
        // 2. SwiftUI sizeThatFits → attachmentBounds → placeholder 200pt
        // 3. Cell self-sizes to 276pt (placeholder + surrounding text)
        // 4. Async image load completes, attachmentBounds now returns 280pt
        // 5. invalidateCellSizeIfChanged fires prev=271→new=358 delta=+87
        // 6. That late grow is sometimes lost (deferSelfSizing rejects it,
        // SwiftUI's UIHostingConfiguration.systemLayoutSizeFitting still
        // caches 276pt from step 3, etc.)
        // 7. Cell stays at 276pt; the UITextView inside grows to 358pt and
        // gets clipped by the cell's clipsToBounds — image bottom cut
        // off and the trailing prose after the image disappears.
        let canonicalSrc = Self.canonicalizeMarkdownImageSource(source)
        if let knownSize = NativeMediaImageCache.shared.size(forSource: canonicalSrc) {
            // Same inset geometry as the loaded path.
            let boxWidth = min(min(width,knownSize.width+Self.imageShadowInset*2),Self.maxImageWidth)
            var imgWidth = max(boxWidth-Self.imageShadowInset*2,40)
            let aspect = knownSize.height/max(knownSize.width,1)
            let maxH = InlineMediaMetrics.maxHeight
            var h = imgWidth*aspect
            // 2026-08-12 治本:限高等比缩宽保持原比例(同 loaded 路径)。
            if h > maxH {
                h = maxH
                imgWidth = h/aspect
            }
            return CGRect(x: 0,y: 0,width: imgWidth+Self.imageShadowInset*2,
                          height: h+Self.imageShadowInset*2)
        }
        let placeholderWidth = min(width,Self.maxImageWidth)
        return CGRect(x: 0,y: 0,width: placeholderWidth,height: Self.placeholderHeight)
    }

    @MainActor
    func beginLoadingIfNeeded() {
        guard loadedImage == nil,!isLoading else {
            imgLogger.info("[MiniClawImage][Load] skip src=\(self.source) alreadyLoaded=\(self.loadedImage != nil) isLoading=\(self.isLoading)")
            return
        }
        fileNotFound = false
        guard retriesRemaining>0 else {
            imgLogger.warning("[MiniClawImage][Load] no retries left src=\(self.source)")
            return
        }
        retriesRemaining -= 1
        isLoading = true
        // Canonicalize scheme-less / relative sources to miniclaw://workspace/…
        let canonicalSrc = Self.canonicalizeMarkdownImageSource(source)
        if canonicalSrc != source {
            imgLogger.info("[MiniClawImage][Load] canonicalized src=\(self.source) → \(canonicalSrc)")
        }
        let parsedURL = URL(string: canonicalSrc)
        imgLogger.info("[MiniClawImage][Load] START src=\(canonicalSrc) scheme=\(parsedURL?.scheme ?? "nil") host=\(parsedURL?.host ?? "nil") path=\(parsedURL?.path ?? "nil") ext=\(parsedURL?.pathExtension ?? "nil") retriesRemaining=\(self.retriesRemaining)")

        // Fingerprint-keyed cache so an in-place rewrite of the same
        // miniclaw:// path produces a different key and falls through to
        // a fresh decode.
        let fpKey = miniClawMediaCacheKey(for: canonicalSrc)
        if let cached = NativeMediaImageCache.shared.image(for: fpKey) {
            imgLogger.info("[MiniClawImage][Load] MEMORY CACHE HIT src=\(canonicalSrc) size=\(cached.size.width)x\(cached.size.height)")
            setLoadedImage(cached)
            loadedFingerprint = fpKey
            isLoading = false
            onLoad?()
            // Memory-cache hit still grows the cell: placeholder bounds →
            // image bounds at the recorded size. Cell needs to re-measure.
            NotificationCenter.default.post(name: .miniClawAttachmentSizeChanged,object: canonicalSrc)
            return
        }
        imgLogger.info("[MiniClawImage][Load] MEMORY CACHE MISS src=\(canonicalSrc) — will load from disk/network")

        let src = canonicalSrc
        // 消费降采样请求（由 nonisolated 的 attachmentBounds 记录）：主 actor 上发起，
        // 读盘与解码走非隔离纯函数在后台执行；结果只更新本实例的位图，
        // **不写回共享缓存**（缓存须保留全分辨率，供其它实例复用）。
        if let targetPx = desiredDownsamplePixels {
            desiredDownsamplePixels = nil
            let urlForResample = resolvedFileURL
            Task { @MainActor [weak self] in
                guard let urlForResample else { return }
                let box = await downsampleImageFile(at: urlForResample,maxPixelSize: targetPx)
                guard let self,let resized = box.value else { return }
                self.setLoadedImage(resized)
            }
        }
        let isMiniClawURL = URL(string: src).map { $0.scheme == "miniclaw" } ?? false
        // For remote (non-miniclaw) URLs that
        // recycle — render the placeholder and bail. miniclaw:// is exempt: those
        if !isMiniClawURL,NativeMediaImageCache.shared.isRecentlyFailed(src) {
            imgLogger.info("[MiniClawImage][Load] SUPPRESSED (recent failure within TTL) src=\(src)")
            isLoading = false
            fileNotFound = true
            return
        }
        imgLogger.info("[MiniClawImage][Load] dispatching async load src=\(src) isMiniClawURL=\(isMiniClawURL)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            var fileURL: URL?
            let img: UIImage?
            if let url = URL(string: src), url.scheme == "miniclaw" {
                imgLogger.info("[MiniClawImage][Load] resolving miniclaw:// URL src=\(src) host=\(url.host ?? "nil") path=\(url.path)")
                if let resolved = resolveMiniClawFileURLForNativeText(url: url) {
                    imgLogger.info("[MiniClawImage][Load] miniclaw:// resolved to localPath=\(resolved.path)")
                    fileURL = resolved
                    if let data = await Task.detached { try? Data(contentsOf: resolved) }.value {
                        imgLogger.info("[MiniClawImage][Load] read \(data.count) bytes from localPath=\(resolved.path)")
                        let downsampled = await Task.detached { downsampleImageData(data) }.value
                        if let downsampled {
                            imgLogger.info("[MiniClawImage][Load] downsample OK src=\(src) resultSize=\(downsampled.size.width)x\(downsampled.size.height)")
                        } else {
                            imgLogger.error("[MiniClawImage][Load] downsample FAILED src=\(src) dataSize=\(data.count)")
                        }
                        img = downsampled
                    } else {
                        imgLogger.error("[MiniClawImage][Load] Data(contentsOf:) FAILED localPath=\(resolved.path)")
                        img = nil
                    }
                } else {
                    imgLogger.warning("[MiniClawImage][Load] resolveMiniClawFileURLForNativeText returned nil src=\(src)")
                    img = nil
                }
            } else if let url = URL(string: src), url.scheme == "http" || url.scheme == "https" {
                imgLogger.info("[MiniClawImage][Load] fetching HTTP(S) url=\(src)")
                if let data = await Task.detached { try? Data(contentsOf: url) }.value {
                    // HTTP images: no local file URL for re-downsample (network-only)
                    imgLogger.info("[MiniClawImage][Load] HTTP fetched \(data.count) bytes src=\(src)")
                    img = await Task.detached { downsampleImageData(data) }.value
                } else {
                    imgLogger.warning("[MiniClawImage][Load] HTTP fetch FAILED src=\(src)")
                    img = nil
                }
            } else if let url = URL(string: src) {
                imgLogger.info("[MiniClawImage][Load] trying file/relative URL scheme=\(url.scheme ?? "nil") path=\(url.path)")
                fileURL = url
                if let data = await Task.detached { try? Data(contentsOf: url) }.value {
                    imgLogger.info("[MiniClawImage][Load] file loaded \(data.count) bytes src=\(src)")
                    img = await Task.detached { downsampleImageData(data) }.value
                } else {
                    imgLogger.warning("[MiniClawImage][Load] file load FAILED src=\(src)")
                    img = nil
                }
            } else {
                imgLogger.error("[MiniClawImage][Load] cannot parse URL src=\(src)")
                img = nil
            }

            let postLoadKey = miniClawMediaCacheKey(for: src)
            if let img {
                imgLogger.info("[MiniClawImage][Load] SUCCESS src=\(src) finalSize=\(img.size.width)x\(img.size.height) — caching in memory")
                NativeMediaImageCache.shared.set(img,for: postLoadKey)
                NativeMediaImageCache.shared.recordSize(img.size,forSource: src)
                // A previously-failed URL
                if !isMiniClawURL { NativeMediaImageCache.shared.clearFailure(src) }
            } else {
                imgLogger.warning("[MiniClawImage][Load] FAILED src=\(src) — no image produced")
                // Negative-cache remote
                // miniclaw:// is exempt — its not-yet-written-file case is handled
                if !isMiniClawURL { NativeMediaImageCache.shared.recordFailure(src) }
            }

            await MainActor.run {
                self.setLoadedImage(img)
                self.loadedFingerprint = img != nil ? postLoadKey : nil
                self.resolvedFileURL = fileURL
                self.isLoading = false
                if img == nil && isMiniClawURL && self.retriesRemaining>0 {
                    imgLogger.info("[MiniClawImage][Load] RETRY scheduled src=\(src) retriesRemaining=\(self.retriesRemaining)")
                    self.fileNotFound = true
                    DispatchQueue.main.asyncAfter(deadline: .now()+1.0) { [weak self] in
                        guard let self,self.fileNotFound else { return }
                        self.beginLoadingIfNeeded()
                    }
                } else {
                    if img == nil && isMiniClawURL {
                        imgLogger.error("[MiniClawImage][Load] GAVE UP src=\(src) — all retries exhausted")
                    }
                    self.onLoad?()
                    if img != nil {
                        // Cell-side height re-measure after async image load.
                        // Mirrors the fix in VideoAttachment — without this,
                        // the cell stays at the 200pt placeholder height
                        // until an unrelated event triggers a reconfigure.
                        NotificationCenter.default.post(name: .miniClawAttachmentSizeChanged,object: src)
                    }
                }
            }
        }
    }

    @MainActor
    func makeView(width: CGFloat) -> UIView {
        makeViewCallCount &+= 1
        // refreshAttachViews reuse path.
        AppLogger.shared.info("[IMG][MAKEVIEW] #\(self.makeViewCallCount) src=\(Self.shortSrc(self.source)) ptr=\(ObjectIdentifier(self).hashValue & 0xFFFFFF) hasImg=\(self.loadedImage != nil) width=\(String(format: "%.0f", width))", category: "ChatList.Attach")
        if let img = loadedImage {
            // [2026-09-14 降噪] 原有 `rendering LOADED image …`（全天 236 行），
            // 与**紧邻上方**的 `[IMG][MAKEVIEW] #N … hasImg=1 width=…` 完全同义 ⇒ 删除。
            return makeImageView(img,width: width)
        } else {
            // [2026-09-13 A 方案·本地图同步出首帧] 数据就在本机磁盘（真机日志实证
            // `[Load] read N bytes from localPath=…`），走异步必然**先画占位符、再换真图**
            // ⇒ 肉眼「像从占位符变成实际图片」（真机实录 `rendering PLACEHOLDER` →
            // `rendering LOADED image`）。这里对**本地来源**同步解码并直接出首帧；
            // http(s) 不在此列（可能长耗时，仍走原异步路径）。
            if let img = syncLoadLocalImageIfPossible() {
                return makeImageView(img,width: width)
            }
            imgLogger.info("[MiniClawImage][MakeView] rendering PLACEHOLDER src=\(self.source) containerWidth=\(width) fileNotFound=\(self.fileNotFound) retriesRemaining=\(self.retriesRemaining)")
            return makePlaceholderView(width: width)
        }
    }

    /// [2026-09-13 A 方案] 仅对**本地**来源（`miniclaw://` 且已解析到磁盘文件）做同步首帧。
    /// 返回 nil = 无法同步（远程 / 文件缺失 / 解码失败），交由既有异步路径与占位符兜底。
    @MainActor
    private func syncLoadLocalImageIfPossible() -> UIImage? {
        guard let u = URL(string: source), u.scheme == "miniclaw",
              let fileURL = resolveMiniClawFileURLForNativeText(url: u),
              let data = try? Data(contentsOf: fileURL),
              let img = downsampleImageData(data)
        else { return nil }
        NativeMediaImageCache.shared.set(img,for: miniClawMediaCacheKey(for: source))
        NativeMediaImageCache.shared.recordSize(img.size,forSource: source)
        setLoadedImage(img)
        resolvedFileURL = fileURL
        imgLogger.info("[MiniClawImage][MakeView] SYNC-LOCAL 首帧直出 src=\(source) size=\(img.size.width)x\(img.size.height) — 不经占位符")
        return img
    }

    private func makeImageView(_ img: UIImage,width: CGFloat) -> UIView {
        // Mirror attachmentBounds' inset geometry:
        let boxWidth = min(min(width,img.size.width+Self.imageShadowInset*2),Self.maxImageWidth)
        var imgWidth = max(boxWidth-Self.imageShadowInset*2,40)
        let aspect = img.size.height/max(img.size.width,1)
        let maxH = InlineMediaMetrics.maxHeight
        var h = imgWidth*aspect
        // 2026-08-12 治本:限高等比缩宽保持原比例(同 attachmentBounds 路径)。
        if h > maxH {
            h = maxH
            imgWidth = h/aspect
        }
        // [2026-09-14 降噪] 原有 `[MakeView] layout src=… displayWidth=… displayHeight=…`（全天 254 行）：
        // 每次按宽度重算等比缩放都打一行，属**推导过程**而非结论；结论性几何由
        // `[IMG][BOUNDS] first`（每个附件一行）与 `[IMG][MAKEVIEW]`（每次 makeView）覆盖到。

        let shadowInset: CGFloat = Self.imageShadowInset
        let container = UIView(frame: CGRect(x: 0,y: 0,width: imgWidth+shadowInset*2,height: h+shadowInset*2))
        container.backgroundColor = .clear
        container.clipsToBounds = false

        let shadowView = UIView(frame: CGRect(x: shadowInset,y: shadowInset,width: imgWidth,height: h))
        shadowView.backgroundColor = .clear
        shadowView.layer.shadowColor = UIColor.black.cgColor
        shadowView.layer.shadowOpacity = 0.15
        shadowView.layer.shadowRadius = 4
        shadowView.layer.shadowOffset = CGSize(width: 0,height: 2)
        shadowView.layer.shadowPath = UIBezierPath(roundedRect: CGRect(x: 0,y: 0,width: imgWidth,height: h),cornerRadius: 8).cgPath

        // Image view — clipped to rounded corners; clear background so the
        // image renders at original aspect ratio without letterbox bars.
        // (2026-08-12 治本:原 .black 背景在比例不匹配时露出黑边;现 box 已等比,
        // .clear 彻底无黑边,透明/白底图片也正常。)
        let imageView = UIImageView(image: img)
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .clear
        imageView.frame = shadowView.bounds
        imageView.layer.cornerRadius = 8
        imageView.clipsToBounds = true
        imageView.isUserInteractionEnabled = true

        let tap = ImageTapGesture(target: nil,action: nil)
        tap.attachedImage = img
        tap.sourceURL = source
        tap.messageId = messageId
        tap.addTarget(tap,action: #selector(ImageTapGesture.handleTap))
        imageView.addGestureRecognizer(tap)

        shadowView.addSubview(imageView)
        container.addSubview(shadowView)
        return container
    }

    private func makePlaceholderView(width: CGFloat) -> UIView {
        let h = Self.placeholderHeight
        let container = UIView(frame: CGRect(x: 0,y: 0,width: width,height: h))

        let bg = UIView(frame: CGRect(x: 0,y: 0,width: min(width,400),height: h))
        bg.backgroundColor = .secondarySystemBackground
        bg.layer.cornerRadius = 8
        bg.clipsToBounds = true
        container.addSubview(bg)

        let iconConfig = UIImage.SymbolConfiguration(pointSize: 32,weight: .light)
        let icon = UIImageView(image: UIImage(systemName: "photo", withConfiguration: iconConfig))
        icon.tintColor = .tertiaryLabel
        icon.sizeToFit()
        icon.center = CGPoint(x: bg.bounds.midX,y: bg.bounds.midY-12)
        bg.addSubview(icon)

        let filename = source.components(separatedBy: "/").last ?? source
        let label = UILabel()
        label.text = filename
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.frame = CGRect(x: 8,y: icon.frame.maxY+8,width: bg.bounds.width-16,height: 16)
        bg.addSubview(label)

        return container
    }
}

///
/// and let `ChatView` resolve the message → full gallery item list.

final class TableAttachment: NSTextAttachment {
    private(set) var alignments: [RawTableColumnAlignment]
    private(set) var rows: [RawTableRow]
    let theme: MarkdownTheme
    var onOpenURL: ((URL) -> Void)?

    static let linkDataDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()
    /// refreshAttachViews path that the existing rendered TableScrollView
    var needsViewRebuild: Bool = false
    var needsLayoutInvalidation: Bool = false

    ///
    /// This is PERSISTENT, not one-shot:
    var preservedScrollOffset: CGPoint?

    static func tableScrollView(in wrapper: UIView) -> TableScrollView? {
        if let direct = wrapper as? TableScrollView { return direct }
        return wrapper.subviews.compactMap { $0 as? TableScrollView }.first
    }

    /// `invalidateCellSizeIfChanged` includes the sum of all TableAttachments'
    private(set) var contentGeneration: UInt64 = 0

    init(alignments: [RawTableColumnAlignment],rows: [RawTableRow],theme: MarkdownTheme) {
        self.alignments = alignments
        self.rows = rows
        self.theme = theme
        super.init(data: nil,ofType: nil)
        self.image = Self.transparentImage
    }

    @available(*,unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// keeps the MarkdownView fast-path's prefix `isEqual` check
    func update(alignments: [RawTableColumnAlignment],rows: [RawTableRow]) {
        // No-op when the content is
        if alignments == self.alignments && rows == self.rows { return }
        //
        let oldRowCount = self.rows.count
        let oldColCount = self.alignments.count
        self.alignments = alignments
        self.rows = rows
        let structureChanged = rows.count != oldRowCount || alignments.count != oldColCount

        // Check whether the cached column widths
        let colCount = alignments.count
        var currentMax = [Int](repeating: 0,count: colCount)
        for row in rows {
            for (ci,cell) in row.cells.enumerated() where ci<colCount {
                currentMax[ci] = max(currentMax[ci],cell.content.plainText.count)
            }
        }
        let contentGrew: Bool
        if cachedLayout == nil {
            contentGrew = false
        } else if currentMax.count != cachedMaxCharPerCol.count {
            contentGrew = true
        } else {
            contentGrew = zip(currentMax,cachedMaxCharPerCol).contains { $0>$1 }
        }
        if structureChanged || contentGrew {
            self.cachedLayout = nil
        }
        self.needsViewRebuild = true
        self.needsLayoutInvalidation = structureChanged || contentGrew
        self.contentGeneration &+= 1
    }

    func plainText() -> String {
        let colCount = alignments.count
        return rows.map { row in
            row.cells.prefix(colCount).map { $0.content.plainText }.joined(separator: "\t")
        }.joined(separator: "\n")
        // Strip flanking-fix spacers (see
        // plainTextWithTabs) so table copies stay clean too.
        .replacingOccurrences(of: "\u{200B}", with: "")
        .replacingOccurrences(of: "\u{200A}", with: "")
    }

    private static let transparentImage: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 1,height: 1)).image { _ in }
    }()

    static let verticalMargin: CGFloat = 0
    static let minRowHeight: CGFloat = 36
    static let cellPaddingH: CGFloat = 16
    static let cellPaddingV: CGFloat = 8

    nonisolated(unsafe) static var narrowestRealWidth: CGFloat = 380

    /// 附件实例可变状态的互斥锁：主线程排版与后台高度预排版会并发调用同一实例的
    /// `attachmentBounds`，而布局缓存两边都会读写。
    private let stateLock = AttachmentStateLock()
    private var cachedLayoutStorage: TableLayout?
    /// 读加锁（后台 `attachmentBounds` 与主线程的 `updateContent` 会并发访问）。
    var cachedLayout: TableLayout? {
        get { stateLock.withLock { cachedLayoutStorage } }
        set { stateLock.withLock { cachedLayoutStorage = newValue } }
    }
    private var cachedMaxCharPerColStorage: [Int] = []
    private var cachedMaxCharPerCol: [Int] {
        get { stateLock.withLock { cachedMaxCharPerColStorage } }
        set { stateLock.withLock { cachedMaxCharPerColStorage = newValue } }
    }

    // MARK: - Process-wide layout cache
    //
    // jank, confirmed via [Decel]+[AttachBounds] device logs).
    //
    private struct LayoutCacheKey: Hashable {
        let contentSig: Int
        let widthBucket: Int // width snapped to 4pt to fold typesetter probe jitter
    }
    nonisolated(unsafe) private static var sharedLayoutCache: [LayoutCacheKey: TableLayout] = [:]
    nonisolated(unsafe) private static var sharedLayoutLRU: [LayoutCacheKey] = []
    private static let sharedLayoutCacheCap = 256
    nonisolated(unsafe) private static var sharedLayoutHits: Int = 0
    nonisolated(unsafe) private static var sharedLayoutMisses: Int = 0
    nonisolated(unsafe) private static var sharedLayoutLastFlush: CFAbsoluteTime = 0

    private var layoutContentSignature: Int {
        var h = Hasher()
        h.combine(alignments)
        h.combine(theme.baseFontSize)
        for row in rows {
            for cell in row.cells { h.combine(cell.content.plainText) }
            h.combine(0x1E) // row separator so cell regrouping changes the hash
        }
        return h.finalize()
    }

    func invalidateCachedLayoutForWidthChange() {
        cachedLayout = nil
        needsViewRebuild = true
        needsLayoutInvalidation = true
        contentGeneration &+= 1
    }

    struct TableLayout {
        let width: CGFloat
        let columnWidths: [CGFloat]
        let rowHeights: [CGFloat]
        let tableWidth: CGFloat
        var totalHeight: CGFloat { rowHeights.reduce(0,+)+2 }
    }

    func computeLayout(for width: CGFloat,persist: Bool = true) -> TableLayout {
        if let cached = cachedLayout,cached.width == width {
            return cached
        }

        //
        if let cached = cachedLayout,!cached.columnWidths.isEmpty {
            let canonical = cached.width
            let relDelta = abs(canonical-width)/max(canonical,1)
            if relDelta<0.25 {
                return TableLayout(
                    width: width,
                    columnWidths: cached.columnWidths,
                    rowHeights: cached.rowHeights,
                    tableWidth: cached.tableWidth
                )
            }
        }

        // Per-instance cachedLayout missed
        let sharedKey = Self.LayoutCacheKey(contentSig: layoutContentSignature,widthBucket: Int((width/4).rounded()))
        if let shared = Self.cachedSharedLayout(sharedKey) {
            Self.flushSharedLayoutStatsIfNeeded()
            let reused = TableLayout(width: width,columnWidths: shared.columnWidths,rowHeights: shared.rowHeights,tableWidth: shared.tableWidth)
            if persist {
                cachedLayout = reused
                Self.touchSharedLayoutLRU(sharedKey)
            }
            return reused
        }

        let colCount = alignments.count
        var columnWidths = [CGFloat](repeating: 80,count: colCount)

        for (rowIdx,row) in rows.enumerated() {
            for (colIdx,cell) in row.cells.enumerated() where colIdx<colCount {
                let text = cell.content.plainText
                let font: UIFont = rowIdx == 0
                    ? .systemFont(ofSize: theme.baseFontSize,weight: .semibold)
                    : .systemFont(ofSize: theme.baseFontSize)
                let size = (text as NSString).size(withAttributes: [.font: font])
                let requested = ceil(size.width)+Self.cellPaddingH*2+12
                columnWidths[colIdx] = min(width*5,max(columnWidths[colIdx],requested))
            }
        }

        let contentWidth = columnWidths.reduce(0,+)
        let tableWidth = max(contentWidth,width)
        if tableWidth>contentWidth,colCount>0 {
            columnWidths[colCount-1] += tableWidth-contentWidth
        }

        var rowHeights = [CGFloat](repeating: Self.minRowHeight,count: rows.count)
        for (rowIdx,row) in rows.enumerated() {
            for (colIdx,cell) in row.cells.enumerated() where colIdx<colCount {
                let font: UIFont = rowIdx == 0
                    ? .systemFont(ofSize: theme.baseFontSize,weight: .semibold)
                    : .systemFont(ofSize: theme.baseFontSize)
                let cellWidth = columnWidths[colIdx]-Self.cellPaddingH*2
                let attrStr = renderCellInlinesNow(cell.content,baseFont: font)
                let boundingRect = attrStr.boundingRect(
                    with: CGSize(width: cellWidth,height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin,.usesFontLeading],
                    context: nil
                )
                let needed = ceil(boundingRect.height)+Self.cellPaddingV*2
                rowHeights[rowIdx] = max(rowHeights[rowIdx],needed)
            }
        }

        let layout = TableLayout(width: width,columnWidths: columnWidths,rowHeights: rowHeights,tableWidth: tableWidth)
        if persist {
            cachedLayout = layout
            var maxChars = [Int](repeating: 0,count: colCount)
            for row in rows {
                for (ci,cell) in row.cells.enumerated() where ci<colCount {
                    maxChars[ci] = max(maxChars[ci],cell.content.plainText.count)
                }
            }
            cachedMaxCharPerCol = maxChars
            // Populate the process-wide cache
            Self.storeSharedLayout(layout,key: sharedKey)
        }
        Self.flushSharedLayoutStatsIfNeeded()
        return layout
    }

    // MARK: - Shared layout cache helpers

    /// 进程级表格布局缓存的互斥锁。
    /// 主线程（cell 排版）与后台（快照高度预排版使用的独立 TextKit 栈）都会经
    /// `attachmentBounds → computeLayout` 读写下面两个静态容器；无锁并发写
    /// Dictionary/Array 会造成 COW 缓冲撕裂（EXC_BAD_ACCESS）。**布局计算过程不持锁**。
    private static let sharedLayoutLock = NSLock()

    /// 加锁读取缓存条目（是否 touch LRU 由调用方决定）。
    /// 更新并读取进程级最窄实测宽度（跨线程共享，故读写同锁；传 nil 表示只读）。
    private static func updateNarrowestRealWidth(_ width: CGFloat?) -> CGFloat {
        sharedLayoutLock.lock(); defer { sharedLayoutLock.unlock() }
        if let width,narrowestRealWidth>width { narrowestRealWidth = width }
        return narrowestRealWidth
    }

    private static func cachedSharedLayout(_ key: LayoutCacheKey) -> TableLayout? {
        sharedLayoutLock.lock(); defer { sharedLayoutLock.unlock() }
        guard let hit = sharedLayoutCache[key] else { sharedLayoutMisses &+= 1; return nil }
        sharedLayoutHits &+= 1
        return hit
    }

    private static func touchSharedLayoutLRU(_ key: LayoutCacheKey) {
        sharedLayoutLock.lock(); defer { sharedLayoutLock.unlock() }
        touchSharedLayoutLRULocked(key)
    }

    /// 无锁版 LRU 更新：调用方必须已持有 `sharedLayoutLock`。
    private static func touchSharedLayoutLRULocked(_ key: LayoutCacheKey) {
        if let pos = sharedLayoutLRU.firstIndex(of: key) { sharedLayoutLRU.remove(at: pos) }
        sharedLayoutLRU.append(key)
    }

    private static func storeSharedLayout(_ layout: TableLayout,key: LayoutCacheKey) {
        sharedLayoutLock.lock(); defer { sharedLayoutLock.unlock() }
        sharedLayoutCache[key] = layout
        touchSharedLayoutLRULocked(key)
        while sharedLayoutLRU.count>sharedLayoutCacheCap,let oldest = sharedLayoutLRU.first {
            sharedLayoutLRU.removeFirst()
            sharedLayoutCache.removeValue(forKey: oldest)
        }
    }

    /// 1Hz hit/miss summary so we can confirm
    private static func flushSharedLayoutStatsIfNeeded() {
        #if DEBUG
        let now = CACurrentMediaTime()
        // 统计量与被计数的容器同锁保护：无锁读 `sharedLayoutCache.count`
        // 会与另一线程的写入竞争。快照后立刻出锁，日志在锁外打。
        sharedLayoutLock.lock()
        guard now-sharedLayoutLastFlush>1.0,(sharedLayoutHits+sharedLayoutMisses)>0 else {
            sharedLayoutLock.unlock(); return
        }
        let hits = sharedLayoutHits,misses = sharedLayoutMisses,size = sharedLayoutCache.count
        sharedLayoutHits = 0
        sharedLayoutMisses = 0
        sharedLayoutLastFlush = now
        sharedLayoutLock.unlock()
        AppLogger.shared.info("[SharedLayoutCache] last1s hits=\(hits) misses=\(misses) size=\(size)/\(sharedLayoutCacheCap)", category: "AttachBoundsHot")
        #endif
    }

    override func attachmentBounds(for textContainer: NSTextContainer?,proposedLineFragment lineFrag: CGRect,glyphPosition position: CGPoint,characterIndex charIndex: Int) -> CGRect {
        // the full line fragment width. Also snap to 1pt grid so tiny floating-
        let usableWidth = floor(lineFrag.width)-1
        guard usableWidth>0 else {
            return CGRect(x: 0,y: 0,width: lineFrag.width,height: Self.minRowHeight)
        }
        // and `refreshAttachViews`. Clamp to 32_768pt and don't persist
        let isOversizedProbe = lineFrag.width >= 100_000
        let clampedWidth = isOversizedProbe ? min(usableWidth,32_768) : usableWidth
        // 1. the real textContainer width — valid even during a probe (only the
        // proposed lineFragment is synthesized to 10M, the container keeps its
        // true width). This is the crucial first-appearance source: on the
        // VERY first probe there is no cached layout yet, and the previous
        // fallback (clampedWidth=32_768) still collapsed wrapping → one row
        // short → the persistent "missing a row" the user still saw.
        // 2. the last real (non-probe) width we measured (cachedLayout).
        // 3. a conservative bubble-width cap as a last resort.
        let containerRealWidth: CGFloat? = {
            guard let w = textContainer?.size.width,w>0,w<100_000 else { return nil }
            return floor(w)-1
        }()
        let lastRealWidth = cachedLayout.map { $0.width }.flatMap { $0<100_000 ? $0 : nil }
        // 进程级最窄实测宽度跨线程共享，读写走同锁（本体不再直接暴露）。
        let narrowestRealWidth = Self.updateNarrowestRealWidth(
            isOversizedProbe || usableWidth<=0 ? nil : usableWidth
        )
        let heightWidth = isOversizedProbe
            ? (containerRealWidth ?? lastRealWidth ?? narrowestRealWidth)
            : clampedWidth
        // "[AttachBounds] tables=6 calls=180 totalMs=850" — 6 tables ×
        let t0 = CACurrentMediaTime()
        let _diagCacheHit = (cachedLayout?.width == heightWidth)
        let layout = computeLayout(for: heightWidth,persist: !isOversizedProbe)
        let elapsed = CACurrentMediaTime()-t0
        Self.attachBoundsHotPath_record(elapsed: elapsed,cacheHit: _diagCacheHit,rows: rows.count,cols: alignments.count)
        let height = layout.totalHeight+Self.verticalMargin*2
        let returnWidth = isOversizedProbe ? clampedWidth : usableWidth
        return CGRect(x: 0,y: 0,width: returnWidth,height: height)
    }

    /// 诊断计数器的互斥锁：`attachmentBounds` 会被主线程与后台预排版并发调用，
    /// 无锁读改写会造成丢失更新。
    private static let hotPathLock = NSLock()
    nonisolated(unsafe) private static var hotCallCount: Int = 0
    nonisolated(unsafe) private static var hotTotalMs: Double = 0
    nonisolated(unsafe) private static var hotLastFlush: CFAbsoluteTime = 0
    nonisolated(unsafe) private static var hotCacheHits: Int = 0
    nonisolated(unsafe) private static var hotCacheMisses: Int = 0
    nonisolated(unsafe) private static var hotMaxMs: Double = 0
    nonisolated(unsafe) private static var hotSlowEmittedThisSec: Int = 0
    static func attachBoundsHotPath_record(elapsed: CFTimeInterval,cacheHit: Bool = false,rows: Int = 0,cols: Int = 0) {
        let ms = elapsed*1000
        var slowLine: String?
        var flushLine: String?
        hotPathLock.lock()
        hotCallCount &+= 1
        hotTotalMs += ms
        if ms>hotMaxMs { hotMaxMs = ms }
        if cacheHit { hotCacheHits &+= 1 } else { hotCacheMisses &+= 1 }
        if ms >= 5 && hotSlowEmittedThisSec<8 {
            hotSlowEmittedThisSec &+= 1
            slowLine = "[TEMP-DIAG][AttachBoundsSlow] ms=\(String(format: "%.2f", ms)) cacheHit=\(cacheHit) rows=\(rows) cols=\(cols)"
        }
        let now = CFAbsoluteTimeGetCurrent()
        if now-hotLastFlush >= 1.0,hotCallCount>0 {
            // [2026-09-11 降噪] 只在**真慢**（1s 内累计 ≥30ms）时输出汇总行。
            // 原条件 `hotCallCount >= 20 ||` 让常态（totalMs=0.0）也每秒刷一条，
            // 属 HangFix 排查期插桩的遗留噪音——表格附件性能问题已解，保留阈值触发即可。
            if hotTotalMs >= 30 {
                flushLine = "[HangFix][AttachBounds] TableAttachment.attachmentBounds calls=\(hotCallCount) totalMs=\(String(format: "%.1f", hotTotalMs)) avg=\(String(format: "%.2f", hotTotalMs / Double(hotCallCount)))ms max=\(String(format: "%.2f", hotMaxMs))ms hit=\(hotCacheHits) miss=\(hotCacheMisses) in last \(String(format: "%.1f", now - hotLastFlush))s"
            }
            hotCallCount = 0
            hotTotalMs = 0
            hotMaxMs = 0
            hotCacheHits = 0
            hotCacheMisses = 0
            hotSlowEmittedThisSec = 0
            hotLastFlush = now
        }
        hotPathLock.unlock()
        // 日志在锁外写（落盘 IO 不应持锁）。
        if let slowLine {
            LoggingManager.shared.writeRawLine(category: "AttachBoundsHot",level: "WARN",message: slowLine)
        }
        if let flushLine {
            LoggingManager.shared.writeRawLine(category: "AttachBoundsHot",level: "WARN",message: flushLine)
            LoggingManager.shared.flush()
        }
    }

    private func renderCellInlinesNow(_ inlines: [InlineNode],baseFont: UIFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for node in inlines {
            result.append(renderCellInlineNow(node,font: baseFont))
        }
        return result
    }

    private func renderCellInlineNow(_ node: InlineNode,font: UIFont) -> NSAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [.font: font,.foregroundColor: UIColor.label]
        switch node {
        case .text(let text):
            return NSAttributedString(string: text,attributes: attrs)
        case .softBreak:
            return NSAttributedString(string: " ", attributes: attrs)
        case .lineBreak:
            return NSAttributedString(string: "\n", attributes: attrs)
        case .code(let code):
            var codeAttrs = attrs
            codeAttrs[.font] = theme.inlineCodeFont
            codeAttrs[.foregroundColor] = theme.inlineCodeColor
            // Mark inline code with BOTH the
            // - Link cells -> TableCellTextView, now backed by a
            // MiniClawLayoutManager whose fillBackgroundRectArray draws the
            // same rounded rect as body inline code (theme.inlineCodeCornerRadius=5).
            // - Link-inert cells -> TableCellLabel, which has no layout
            // manager; it strips `.backgroundColor` (to avoid the square
            // fill) and paints the rounded background itself in drawText.
            // Both resolve miniClawInlineCodeBackgroundColor at draw time and
            codeAttrs[.inlineCodeBackground] = true
            codeAttrs[.backgroundColor] = miniClawInlineCodeBackgroundColor
            return NSAttributedString(string: code,attributes: codeAttrs)
        case .html(let h):
            return NSAttributedString(string: h,attributes: attrs)
        case .emphasis(let children):
            let italicFont = font.withTraits(.traitItalic)
            return renderCellInlinesNow(children,baseFont: italicFont)
        case .strong(let children):
            let descriptor = font.fontDescriptor.addingAttributes([
                .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.bold]
            ])
            let boldFont = UIFont(descriptor: descriptor,size: font.pointSize)
            return renderCellInlinesNow(children,baseFont: boldFont)
        case .strikethrough(let children):
            let result = NSMutableAttributedString(attributedString: renderCellInlinesNow(children,baseFont: font))
            result.addAttribute(.strikethroughStyle,value: NSUnderlineStyle.single.rawValue,range: NSRange(location: 0,length: result.length))
            return result
        case .link(let destination,let children):
            let result = NSMutableAttributedString(attributedString: renderCellInlinesNow(children,baseFont: font))
            let range = NSRange(location: 0,length: result.length)
            if let url = URL(string: destination) {
                result.addAttribute(.link,value: url,range: range)
            }
            result.addAttribute(.foregroundColor,value: theme.linkColor,range: range)
            result.addAttribute(.underlineStyle,value: NSUnderlineStyle.single.rawValue,range: range)
            return result
        case .image(_,let children):
            return renderCellInlinesNow(children,baseFont: font)
        case .inlineMath(let latex):
            let attach = MathAttachment(latex: latex,isBlock: false,theme: theme)
            attach.inlineDrawable = true
            let result = NSMutableAttributedString(attachment: attach)
            result.addAttribute(.font,value: font,range: NSRange(location: 0,length: result.length))
            return result
        }
    }

    private static func collectMathAttachments(in attrStr: NSAttributedString) -> [MathAttachment] {
        var out: [MathAttachment] = []
        attrStr.enumerateAttribute(.attachment,
                                   in: NSRange(location: 0,length: attrStr.length),
                                   options: []) { value,_,_ in
            if let math = value as? MathAttachment { out.append(math) }
        }
        return out
    }

    private static func wireMathAttachments(_ attachments: [MathAttachment],
                                            cellWidth: CGFloat,
                                            rowHeight: CGFloat,
                                            attrStr: NSAttributedString,
                                            refresh: @escaping @MainActor () -> Void) {
        guard !attachments.isEmpty else { return }
        final class RefreshState: @unchecked Sendable { var pending: Bool = false }
        let state = RefreshState()
        for attachment in attachments {
            attachment.onLoad = {
                guard !state.pending else { return }
                state.pending = true
                Task { @MainActor [state] in
                    state.pending = false
                    refresh()
                }
            }
            attachment.beginRenderingIfNeeded()
        }
    }

    private static func containsLinks(_ inlines: [InlineNode]) -> Bool {
        for node in inlines {
            switch node {
            case .link: return true
            case .emphasis(let ch),.strong(let ch),.strikethrough(let ch),.image(_,let ch):
                if containsLinks(ch) { return true }
            default: break
            }
        }
        return false
    }

    @MainActor
    func makeView(width: CGFloat) -> UIView {
        let wrapper = UIView()
        wrapper.backgroundColor = .clear

        let scrollView = TableScrollView()
        scrollView.borderColorProvider = { [theme] traits in
            theme.tableBorderColor.resolvedColor(with: traits).cgColor
        }
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.alwaysBounceVertical = false
        scrollView.isScrollEnabled = true

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 0

        let layout = computeLayout(for: width)
        let colCount = alignments.count
        let columnWidths = layout.columnWidths
        let rowHeights = layout.rowHeights
        let tableWidth = layout.tableWidth

        let copyTable: () -> Void = { [weak self] in
            guard let self else { return }
            UIPasteboard.general.string = self.plainText()
            // Confirm the copy succeeded.
            MiniClawToast.show(String(localized: "Table copied"))
        }

        // Render the FULL table (all rows/cols, not
        let tableBg = UIColor.systemBackground
        let tableBorder = theme.tableBorderColor
        let copyTableImage: () -> Void = { [weak stack] in
            guard let stack,stack.bounds.width>0,stack.bounds.height>0 else { return }

            // Clear any active text selection first so
            func clearSelections(_ view: UIView) {
                if let tv = view as? UITextView {
                    tv.selectedTextRange = nil
                    tv.resignFirstResponder()
                }
                view.subviews.forEach(clearSelections)
            }
            clearSelections(stack)
            stack.layoutIfNeeded()

            let bounds = stack.bounds
            let bg = tableBg.resolvedColor(with: stack.traitCollection)
            let border = tableBorder.resolvedColor(with: stack.traitCollection)
            let fmt = UIGraphicsImageRendererFormat.default()
            fmt.opaque = true
            let renderer = UIGraphicsImageRenderer(bounds: bounds,format: fmt)
            let image = renderer.image { ctx in
                bg.setFill()
                ctx.fill(bounds)
                stack.layer.render(in: ctx.cgContext)
                let path = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.25,dy: 0.25),cornerRadius: 8)
                border.setStroke()
                path.lineWidth = 0.5
                path.stroke()
            }
            UIPasteboard.general.image = image
            // Confirm the image copy succeeded.
            MiniClawToast.show(String(localized: "Table image copied"))
        }

        var yOffset: CGFloat = 0
        for (rowIdx,row) in rows.enumerated() {
            let rowHeight = rowHeights[rowIdx]
            let rowView = UIView()
            rowView.translatesAutoresizingMaskIntoConstraints = false

            var x: CGFloat = 0
            for (colIdx,cell) in row.cells.enumerated() where colIdx<colCount {
                let cellContentWidth = columnWidths[colIdx]-Self.cellPaddingH*2
                let cellFrame = CGRect(x: x+Self.cellPaddingH,y: 0,width: cellContentWidth,height: rowHeight)

                let alignment: NSTextAlignment
                switch alignments[colIdx] {
                case .center: alignment = .center
                case .right: alignment = .right
                default: alignment = .left
                }

                let baseFont: UIFont = rowIdx == 0
                    ? .systemFont(ofSize: theme.baseFontSize,weight: .semibold)
                    : .systemFont(ofSize: theme.baseFontSize)

                let attrStr = NSMutableAttributedString(attributedString: renderCellInlinesNow(cell.content,baseFont: baseFont))
                let paraStyle = NSMutableParagraphStyle()
                paraStyle.alignment = alignment
                attrStr.addAttribute(.paragraphStyle,value: paraStyle,range: NSRange(location: 0,length: attrStr.length))

                var hasLinks = Self.containsLinks(cell.content)
                if !hasLinks {
                    attrStr.enumerateAttribute(.link,
                                                in: NSRange(location: 0,length: attrStr.length),
                                                options: []) { value,_,stop in
                        if value != nil { hasLinks = true; stop.pointee = true }
                    }
                }
                if !hasLinks,let detector = Self.linkDataDetector {
                    let plain = attrStr.string
                    let fullRange = NSRange(location: 0,length: (plain as NSString).length)
                    let matches = detector.matches(in: plain,options: [],range: fullRange)
                    for m in matches {
                        guard let url = m.url else { continue }
                        if attrStr.attribute(.link,at: m.range.location,effectiveRange: nil) != nil {
                            continue
                        }
                        attrStr.addAttribute(.link,value: url,range: m.range)
                        attrStr.addAttribute(.foregroundColor,value: theme.linkColor,range: m.range)
                        attrStr.addAttribute(.underlineStyle,value: NSUnderlineStyle.single.rawValue,range: m.range)
                        hasLinks = true
                    }
                }

                let mathAttachments = Self.collectMathAttachments(in: attrStr)

                if hasLinks {
                    let tv = TableCellTextView()
                    tv.isEditable = false
                    tv.isScrollEnabled = false
                    tv.backgroundColor = .clear
                    tv.textContainerInset = .zero
                    tv.textContainer.lineFragmentPadding = 0
                    tv.linkTextAttributes = [
                        .foregroundColor: theme.linkColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                    ]
                    tv.attributedText = attrStr

                    if let onOpenURL {
                        tv.onOpenURL = onOpenURL
                    }

                    tv.frame = cellFrame
                    let textSize = tv.sizeThatFits(CGSize(width: cellFrame.width,height: .greatestFiniteMagnitude))
                    tv.frame.origin.y = (rowHeight-textSize.height)/2
                    rowView.addSubview(tv)

                    Self.wireMathAttachments(mathAttachments,cellWidth: cellFrame.width,rowHeight: rowHeight,attrStr: attrStr) { @MainActor [weak tv] in
                        guard let tv else { return }
                        tv.attributedText = attrStr
                        let ts = tv.sizeThatFits(CGSize(width: cellFrame.width,height: .greatestFiniteMagnitude))
                        tv.frame.origin.y = (rowHeight-ts.height)/2
                    }
                } else {
                    let label = TableCellLabel()
                    label.backgroundColor = .clear
                    label.numberOfLines = 0
                    label.attributedText = attrStr
                    label.selectableAttributedText = attrStr
                    label.copyTableAction = copyTable
                    label.copyTableImageAction = copyTableImage
                    label.frame = cellFrame
                    let textSize = label.sizeThatFits(CGSize(width: cellFrame.width,height: .greatestFiniteMagnitude))
                    label.frame.size.height = textSize.height
                    label.frame.origin.y = (rowHeight-textSize.height)/2
                    rowView.addSubview(label)

                    Self.wireMathAttachments(mathAttachments,cellWidth: cellFrame.width,rowHeight: rowHeight,attrStr: attrStr) { @MainActor [weak label] in
                        guard let label else { return }
                        label.attributedText = attrStr
                        label.selectableAttributedText = attrStr
                        let ts = label.sizeThatFits(CGSize(width: cellFrame.width,height: .greatestFiniteMagnitude))
                        label.frame.size.height = ts.height
                        label.frame.origin.y = (rowHeight-ts.height)/2
                        label.setNeedsDisplay()
                    }
                }

                if colIdx<colCount-1 {
                    let sep = UIView()
                    sep.backgroundColor = theme.tableBorderColor
                    sep.frame = CGRect(x: x+columnWidths[colIdx]-0.25,y: 0,width: 0.5,height: rowHeight)
                    rowView.addSubview(sep)
                }
                x += columnWidths[colIdx]
            }

            if rowIdx<rows.count-1 {
                let hSep = UIView()
                hSep.backgroundColor = theme.tableBorderColor
                hSep.frame = CGRect(x: 0,y: rowHeight-0.25,width: tableWidth,height: 0.5)
                rowView.addSubview(hSep)
            }

            rowView.frame = CGRect(x: 0,y: yOffset,width: tableWidth,height: rowHeight)
            stack.addArrangedSubview(rowView)
            NSLayoutConstraint.activate([
                rowView.heightAnchor.constraint(equalToConstant: rowHeight),
                rowView.widthAnchor.constraint(equalToConstant: tableWidth),
            ])
            yOffset += rowHeight
        }

        let stackHeight = rowHeights.reduce(0,+)
        stack.frame = CGRect(x: 0,y: 0,width: tableWidth,height: stackHeight)
        scrollView.addSubview(stack)
        scrollView.contentSize = CGSize(width: tableWidth,height: stackHeight)
        scrollView.frame = CGRect(x: 0,y: Self.verticalMargin,width: width,height: stackHeight)

        scrollView.layer.cornerRadius = 8
        scrollView.layer.borderWidth = 0.5
        scrollView.applyBorderColorNow()
        scrollView.clipsToBounds = true

        wrapper.addSubview(scrollView)
        wrapper.frame = CGRect(x: 0,y: 0,width: width,height: stackHeight+Self.verticalMargin*2)

        // Keep the attachment's persistent
        scrollView.onUserScroll = { [weak self] offset in
            self?.preservedScrollOffset = offset
        }
        if let saved = preservedScrollOffset,saved.x>0 {
            let applyClamped = { [weak scrollView] in
                guard let scrollView else { return }
                let maxX = max(0,scrollView.contentSize.width-scrollView.bounds.width)
                let x = min(max(0,saved.x),maxX)
                scrollView.contentOffset = CGPoint(x: x,y: 0)
            }
            applyClamped()
            DispatchQueue.main.async(execute: applyClamped)
        }

        return wrapper
    }

}

final class TableCellTextView: UITextView,UITextViewDelegate {
    var onOpenURL: ((URL) -> Void)?
    var onResignFirstResponder: (() -> Void)?
    var copyTableAction: (() -> Void)?
    /// Closure that copies the full table as a PNG image.
    var copyTableImageAction: (() -> Void)?

    override init(frame: CGRect,textContainer: NSTextContainer?) {
        super.init(frame: frame,textContainer: textContainer)
        self.delegate = self
    }

    /// TextKit1 stack backed by a
    /// MiniClawLayoutManager so inline-code spans (marked with
    convenience init() {
        let textStorage = NSTextStorage()
        let layoutManager = MiniClawLayoutManager()
        let textContainer = NSTextContainer()
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        self.init(frame: .zero,textContainer: textContainer)
    }

    @available(*,unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // iOS 16 ONLY: drop the system
    // attachments. Same rationale as MarkdownTextView.addInteraction;
    override func addInteraction(_ interaction: any UIInteraction) {
        if #unavailable(iOS 17.0),interaction is UIContextMenuInteraction {
            return
        }
        super.addInteraction(interaction)
    }

    override func becomeFirstResponder() -> Bool {
        let cv = findCollectionView()
        cv?.offsetLocked = true
        let result = super.becomeFirstResponder()
        cv?.offsetLocked = false
        return result
    }

    override func resignFirstResponder() -> Bool {
        let cv = findCollectionView()
        cv?.offsetLocked = true
        let result = super.resignFirstResponder()
        cv?.offsetLocked = false
        onResignFirstResponder?()
        return result
    }

    override func canPerformAction(_ action: Selector,withSender sender: Any?) -> Bool {
        if action == #selector(copyTable) { return copyTableAction != nil }
        if action == #selector(copyTableImage) { return copyTableImageAction != nil }
        if action == #selector(addSelectionToChatInput(_:)) {
            return selectedRange.length>0
        }
        if action == #selector(readSelectedAloud) { return selectedRange.length>0 }
        if action == #selector(readAllAloud) { return !text.isEmpty }
        let blocked: Set<String> = ["paste:", "cut:", "delete:", "_addShortcut:",
                                     "_speak:", "_accessibilitySpeak:"]
        let actionName = NSStringFromSelector(action)
        if actionName.contains("speak") || actionName.contains("Speak") { return false }
        if blocked.contains(actionName) { return false }
        // guard in MarkdownTextView.canPerformAction.
        if actionName.localizedCaseInsensitiveContains("image") {
            return false
        }
        return super.canPerformAction(action,withSender: sender)
    }

    @objc func copyTable() {
        copyTableAction?()
    }

    @objc func copyTableImage() {
        copyTableImageAction?()
    }

    @objc func readSelectedAloud() {
        guard selectedRange.length>0,
              let range = Range(selectedRange,in: text) else { return }
        VoiceOutputPlayer.shared.stopAll()
        Self.activateReadAloudState()
        VoiceOutputPlayer.shared.enqueueSegmented(String(text[range]),sessionId: VoiceOutputPlayer.manualOwnerId)
    }

    @objc func readAllAloud() {
        VoiceOutputPlayer.shared.stopAll()
        Self.activateReadAloudState()
        VoiceOutputPlayer.shared.enqueueSegmented(text,sessionId: VoiceOutputPlayer.manualOwnerId)
    }

    /// Menu-triggered read-aloud bypasses MessageListModel's reply-TTS flow, so
    static func activateReadAloudState() {
        let state = VoiceOutputState.shared
        if !state.isEnabled { state.isEnabled = true } // didSet persists to prefs
        if state.isMuted { state.isMuted = false }
        if let vm = state.activeController as? MessageListModel {
            vm.isReadingAloud = true
            vm.speechPaused = false
            vm.syncSpeechStateToGlobal(registerActive: true)
        } else {
            state.syncState(reading: true,paused: false,
                            speed: VoiceOutputPreferences.speedMultiplier)
        }
    }

    /// Same as MarkdownTextView.addSelectionToChatInput — posts a
    /// ChatView listens and routes to `MessageListModel.appendToInputText`.
    @objc func addSelectionToChatInput(_ sender: Any?) {
        guard selectedRange.length>0,
              let range = Range(selectedRange,in: text) else { return }
        let snippet = String(text[range])
        NotificationCenter.default.post(
            name: .chatInputAppendRequested,
            object: nil,
            userInfo: ["text": snippet]
        )
        resignFirstResponder()
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        // Add to Chat Input →  Copy Table →  Copy Table Image
        // copy actions after it.
        var children: [UICommand] = []
        if selectedRange.length>0 {
            children.append(
                UICommand(
                    title: String(localized: "Add to Chat Input"),
                    image: UIImage(systemName: "text.insert"),
                    action: #selector(addSelectionToChatInput(_:))
                )
            )
        }
        if copyTableAction != nil {
            children.append(
                UICommand(
                    title: String(localized: "Copy Table"),
                    image: UIImage(systemName: "tablecells"),
                    action: #selector(copyTable)
                )
            )
            // Offer copying the whole table as an image.
            if copyTableImageAction != nil {
                children.append(
                    UICommand(
                        title: String(localized: "Copy Table Image"),
                        image: UIImage(systemName: "tablecells.badge.ellipsis"),
                        action: #selector(copyTableImage)
                    )
                )
            }
        }
        if selectedRange.length>0 {
            children.append(
                UICommand(
                    title: String(localized: "Read Selected Aloud"),
                    image: UIImage(systemName: "speaker.wave.2"),
                    action: #selector(readSelectedAloud)
                )
            )
        }
        children.append(
            UICommand(
                title: String(localized: "Read All Aloud"),
                image: UIImage(systemName: "play.circle"),
                action: #selector(readAllAloud)
            )
        )
        builder.remove(menu: .speech)
        let menu = UIMenu(title: "", options: .displayInline, children: children)
        builder.insertSibling(menu,afterMenu: .standardEdit)
    }

    func textView(_ textView: UITextView,shouldInteractWith URL: URL,in characterRange: NSRange,interaction: UITextItemInteraction) -> Bool {
        if interaction == .invokeDefaultAction,let onOpenURL {
            onOpenURL(URL)
            return false
        }
        return true
    }
}

private final class InlineAudioController: NSObject,@unchecked Sendable {
    nonisolated(unsafe) static var associatedKey: UInt8 = 0

    let fileURL: URL?
    private weak var playButton: UIButton?
    private weak var slider: UISlider?
    private weak var durationLabel: UILabel?
    private var cancellables = Set<AnyCancellable>()

    init(fileURL: URL?,playButton: UIButton,slider: UISlider,durationLabel: UILabel) {
        self.fileURL = fileURL
        self.playButton = playButton
        self.slider = slider
        self.durationLabel = durationLabel
        super.init()

        playButton.addTarget(self,action: #selector(togglePlayPause),for: .touchUpInside)
        slider.addTarget(self,action: #selector(sliderChanged),for: .valueChanged)

        // MessageListModel.triggerAutoPlayAudio() which only fires once at the end
        if let fileURL {
            Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
                guard let p = try? AVAudioPlayer(contentsOf: fileURL) else { return }
                p.prepareToPlay()
                let dur = p.duration
                await MainActor.run {
                    slider.maximumValue = Float(dur)
                    durationLabel.text = Self.formatTime(dur)
                }
            }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let gp = GlobalAudioPlayer.shared
            let iconConfig = UIImage.SymbolConfiguration(pointSize: 22,weight: .regular)

            gp.$isPlaying.combineLatest(gp.$activeFileURL)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] playing,activeURL in
                    guard let self,let url = self.fileURL else { return }
                    let isActive = activeURL == url
                    let icon = isActive && playing ? "pause.circle.fill" : "play.circle.fill"
                    self.playButton?.setImage(UIImage(systemName: icon,withConfiguration: iconConfig),for: .normal)
                }
                .store(in: &self.cancellables)

            gp.$currentTime.combineLatest(gp.$activeFileURL)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] time,activeURL in
                    guard let self,let url = self.fileURL else { return }
                    if activeURL == url {
                        self.slider?.value = Float(time)
                    }
                }
                .store(in: &self.cancellables)

            gp.$duration.combineLatest(gp.$activeFileURL)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] dur,activeURL in
                    guard let self,let url = self.fileURL else { return }
                    if activeURL == url {
                        self.slider?.maximumValue = Float(dur)
                        self.durationLabel?.text = Self.formatTime(dur)
                    }
                }
                .store(in: &self.cancellables)
        }
    }

    @MainActor @objc private func togglePlayPause() {
        guard let url = fileURL else { return }
        let gp = GlobalAudioPlayer.shared
        if gp.isActive(url: url) {
            gp.togglePlayPause()
        } else {
            gp.play(url: url)
        }
    }

    @MainActor @objc private func sliderChanged() {
        guard let url = fileURL,let slider else { return }
        let gp = GlobalAudioPlayer.shared
        if gp.isActive(url: url) {
            gp.seek(to: TimeInterval(slider.value))
        }
    }

    static func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t)/60
        let s = Int(t)%60
        return String(format: "%d:%02d", m, s)
    }
}

final class ThematicBreakAttachment: NSTextAttachment {
    let theme: MarkdownTheme

    init(theme: MarkdownTheme) {
        self.theme = theme
        super.init(data: nil,ofType: nil)
        self.image = Self.transparentImage
    }

    @available(*,unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static let transparentImage: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 1,height: 1)).image { _ in }
    }()

    static let verticalMargin: CGFloat = 0

    override func attachmentBounds(for textContainer: NSTextContainer?,proposedLineFragment lineFrag: CGRect,glyphPosition position: CGPoint,characterIndex charIndex: Int) -> CGRect {
        CGRect(x: 0,y: 0,width: lineFrag.width,height: 1+Self.verticalMargin*2)
    }

    @MainActor
    func makeView(width: CGFloat) -> UIView {
        let totalHeight = 1+Self.verticalMargin*2
        let container = UIView(frame: CGRect(x: 0,y: 0,width: width,height: totalHeight))
        let line = UIView(frame: CGRect(x: 0,y: Self.verticalMargin,width: width,height: 1))
        line.backgroundColor = theme.secondaryLabelColor.withAlphaComponent(0.3)
        container.addSubview(line)
        return container
    }
}

let nativeImageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "svg"]
final class CodeBlockAttachment: NSTextAttachment {
    var code: String
    let language: String?
    let theme: MarkdownTheme
    let quoteDepth: Int
    var blockIndex: Int = 0

    var leftInset: CGFloat { CGFloat(quoteDepth)*13 }

    init(code: String,language: String?,theme: MarkdownTheme,quoteDepth: Int = 0) {
        self.code = code
        self.language = language
        self.theme = theme
        self.quoteDepth = quoteDepth
        super.init(data: nil,ofType: nil)
        self.image = Self.transparentImage
    }

    @available(*,unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static let transparentImage: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 1,height: 1)).image { _ in }
    }()

    static let topMargin: CGFloat = 6
    static let bottomMargin: CGFloat = 4

    /// Associated-object key retaining the iOS 16 copy-tap gesture target
    nonisolated(unsafe) static var copyTapHandlerKey: UInt8 = 0

    /// Target object for the iOS 16 fallback tap gesture on the copy button —
    final class CodeCopyTapHandler: NSObject,@unchecked Sendable {
        private let perform: () -> Void
        init(perform: @escaping () -> Void) { self.perform = perform }
        @objc func handleTap() { perform() }
    }

    /// 附件实例可变状态的互斥锁（见 `AttachmentStateLock`）。
    private let stateLock = AttachmentStateLock()
    private var cachedContentHeight: (hash: Int,height: CGFloat)?

    /// 代码块测量容器的宽度：`.byClipping` 下代码不换行，高度与宽度无关，
    /// 给一个足够大的**有限**值即可（`NSLayoutManager` 不接受"无限宽"）。
    private static let measurementWidth: CGFloat = 100_000

    private func measureCodeBlockHeight() -> CGFloat {
        let codeHash = code.hashValue
        if let cached = stateLock.withLock({ cachedContentHeight }),cached.hash == codeHash {
            return cached.height
        }
        let codeStyle = NSMutableParagraphStyle()
        codeStyle.lineSpacing = 4
        codeStyle.lineBreakMode = .byClipping
        let attrStr = NSAttributedString(string: code,attributes: [
            .font: theme.codeBlockFont,
            .paragraphStyle: codeStyle,
        ])
        // 纯 TextKit 栈测量（原实现创建 `UITextView` 并 layout）。本方法由
        // `attachmentBounds` 调用，而 `attachmentBounds` 也会被后台高度预排版
        // （`MessageCollectionCoordinator+Snapshot` 的 `Task.detached`）触发——
        // UIKit 视图不可在非主线程创建，故改为不依赖任何视图的纯排版计算。
        let storage = NSTextStorage(attributedString: attrStr)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: Self.measurementWidth,height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byClipping
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        let h = ceil(layoutManager.usedRect(for: container).height)
        stateLock.withLock { cachedContentHeight = (hash: codeHash,height: h) }
        return h
    }

    override func attachmentBounds(for textContainer: NSTextContainer?,proposedLineFragment lineFrag: CGRect,glyphPosition position: CGPoint,characterIndex charIndex: Int) -> CGRect {
        let width = lineFrag.width
        let topOffset: CGFloat = (language != nil && !language!.isEmpty) ? 28 : 12
        let contentHeight = measureCodeBlockHeight()
        let bottomPadding: CGFloat = 12
        let maxCodeHeight: CGFloat = 400-topOffset-bottomPadding
        let scrollHeight = min(contentHeight,maxCodeHeight)
        let totalHeight = topOffset+scrollHeight+bottomPadding
        let height = totalHeight+Self.topMargin+Self.bottomMargin
        return CGRect(x: 0,y: 0,width: width,height: height)
    }

    @MainActor
    func makeView(width: CGFloat) -> UIView {
        let wrapper = UIView()
        wrapper.backgroundColor = .clear

        let inset = leftInset
        let contentWidth = width-inset

        let container = UIView()
        container.backgroundColor = theme.codeBlockBackground
        container.layer.cornerRadius = theme.codeBlockCornerRadius
        container.clipsToBounds = true

        var topOffset: CGFloat = 12

        if let language,!language.isEmpty {
            let langLabel = UILabel()
            langLabel.text = language.lowercased()
            langLabel.font = .systemFont(ofSize: 11,weight: .medium)
            langLabel.textColor = .white.withAlphaComponent(0.4)
            langLabel.frame = CGRect(x: 12,y: 8,width: contentWidth-60,height: 16)
            container.addSubview(langLabel)
            topOffset = 28
        }

        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.alwaysBounceHorizontal = true
        scrollView.alwaysBounceVertical = true
        scrollView.clipsToBounds = true

        let codeTextView = UITextView()
        codeTextView.isEditable = false
        codeTextView.isSelectable = true
        codeTextView.isScrollEnabled = false // scrollView handles scrolling
        codeTextView.backgroundColor = .clear
        codeTextView.textContainerInset = UIEdgeInsets(top: 0,left: 8,bottom: 0,right: 8)
        codeTextView.textContainer.lineFragmentPadding = 0
        codeTextView.textContainer.lineBreakMode = .byClipping

        let codeStyle = NSMutableParagraphStyle()
        codeStyle.lineSpacing = 4
        codeStyle.lineBreakMode = .byClipping
        let codeAttr = NSAttributedString(string: code,attributes: [
            .font: theme.codeBlockFont,
            .foregroundColor: theme.codeBlockTextColor,
            .paragraphStyle: codeStyle,
        ])
        codeTextView.attributedText = codeAttr

        let fitting = codeTextView.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude,height: CGFloat.greatestFiniteMagnitude))
        let contentHeight = fitting.height
        let fittingWidth = fitting.width
        codeTextView.frame = CGRect(x: 0,y: 0,width: fittingWidth,height: contentHeight)

        let maxCodeHeight: CGFloat = 400-topOffset-12
        let scrollHeight = min(contentHeight,maxCodeHeight)
        let bottomPadding: CGFloat = 12
        scrollView.frame = CGRect(x: 0,y: topOffset,width: contentWidth,height: scrollHeight+bottomPadding)
        scrollView.contentInset = UIEdgeInsets(top: 0,left: 0,bottom: bottomPadding,right: 0)
        scrollView.scrollIndicatorInsets = .zero
        scrollView.addSubview(codeTextView)
        scrollView.contentSize = CGSize(width: fittingWidth,height: contentHeight)

        let bottomY = scrollView.contentSize.height-scrollView.bounds.height
        if bottomY>0 {
            scrollView.contentOffset = CGPoint(x: 0,y: bottomY)
        }

        container.addSubview(scrollView)

        let totalHeight = topOffset+scrollHeight+bottomPadding
        container.frame = CGRect(x: inset,y: 0,width: contentWidth,height: totalHeight)

        let iconConfig = UIImage.SymbolConfiguration(pointSize: 9,weight: .medium)
        let copyButton = UIButton(type: .system)
        copyButton.setImage(UIImage(systemName: "doc.on.doc", withConfiguration: iconConfig), for: .normal)
        copyButton.tintColor = .white.withAlphaComponent(0.5)
        copyButton.frame = CGRect(x: contentWidth-44,y: 0,width: 44,height: 44)
        let performCopy: () -> Void = { [weak codeTextView,weak copyButton] in
            // content, even after updateExistingAttachView replaced the attributed text.
            UIPasteboard.general.string = codeTextView?.text
            copyButton?.setImage(UIImage(systemName: "checkmark", withConfiguration: iconConfig), for: .normal)
            copyButton?.tintColor = .systemGreen
            DispatchQueue.main.asyncAfter(deadline: .now()+1.5) {
                copyButton?.setImage(UIImage(systemName: "doc.on.doc", withConfiguration: iconConfig), for: .normal)
                copyButton?.tintColor = .white.withAlphaComponent(0.5)
            }
        }
        copyButton.addAction(UIAction { @Sendable _ in performCopy() },for: .touchUpInside)
        // iOS 16 ONLY: also bind an
        // independent tap gesture on the button. On iOS 16 the UIControl
        // .touchUpInside event stopped firing for this button (regressed
        // between TF26 and TF28; exact toucher unidentified — the host text
        // view's gesture/interaction graph cancels the control's touches).
        // A UITapGestureRecognizer attached to the button itself recognizes
        // through the gesture system rather than the control-event path, so
        // it survives the cancellation. Gated to <17: iOS 17+ button works,
        // and double-binding there would just be dead weight.
        if #unavailable(iOS 17.0) {
            let tapHandler = CodeCopyTapHandler(perform: performCopy)
            let tap = UITapGestureRecognizer(target: tapHandler,action: #selector(CodeCopyTapHandler.handleTap))
            tap.cancelsTouchesInView = false
            copyButton.addGestureRecognizer(tap)
            objc_setAssociatedObject(copyButton,&Self.copyTapHandlerKey,tapHandler,.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        container.addSubview(copyButton)

        container.frame.origin.y = Self.topMargin
        wrapper.addSubview(container)
        wrapper.frame = CGRect(x: 0,y: 0,width: width,height: totalHeight+Self.topMargin+Self.bottomMargin)

        return wrapper
    }

    func updateExistingAttachView(_ wrapper: UIView) {
        guard let container = wrapper.subviews.first else { return }
        guard let scrollView = container.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView else { return }
        guard let codeTextView = scrollView.subviews.first(where: { $0 is UITextView }) as? UITextView else { return }

        let codeStyle = NSMutableParagraphStyle()
        codeStyle.lineSpacing = 4
        codeStyle.lineBreakMode = .byClipping
        let codeAttr = NSAttributedString(string: code,attributes: [
            .font: theme.codeBlockFont,
            .foregroundColor: theme.codeBlockTextColor,
            .paragraphStyle: codeStyle,
        ])
        codeTextView.attributedText = codeAttr

        let fitting = codeTextView.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude,height: CGFloat.greatestFiniteMagnitude))
        codeTextView.frame.size = fitting
        scrollView.contentSize = fitting

        let topOffset: CGFloat = (language != nil && !language!.isEmpty) ? 28 : 12
        let maxCodeHeight: CGFloat = 400-topOffset-12
        let scrollHeight = min(fitting.height,maxCodeHeight)
        let bottomPadding: CGFloat = 12
        let newScrollFrame = CGRect(x: 0,y: topOffset,width: container.frame.width,height: scrollHeight+bottomPadding)
        let totalHeight = topOffset+scrollHeight+bottomPadding

        let heightGrew = totalHeight>container.frame.size.height+0.5
        wrapper.frame.size.height = totalHeight+Self.topMargin+Self.bottomMargin
        let applyChildFrames = {
            scrollView.frame = newScrollFrame
            container.frame.size.height = totalHeight
        }
        if heightGrew {
            UIView.animate(withDuration: 0.20,
                           delay: 0,
                           options: [.curveEaseOut,.allowUserInteraction,.beginFromCurrentState],
                           animations: applyChildFrames)
        } else {
            applyChildFrames()
        }

        let bottomY = scrollView.contentSize.height-scrollView.bounds.height
        if bottomY>0 {
            scrollView.contentOffset = CGPoint(x: scrollView.contentOffset.x,y: bottomY)
        }
    }
}

/// 跨隔离传递 `UIImage` 的装箱：`UIImage` 非 Sendable，但此处由后台任务独占构造、
/// 单侧交给主 actor 使用，不共享可变状态。
private struct SendableImageBox: @unchecked Sendable {
    let value: UIImage?
}

/// 读盘并按目标像素降采样（非隔离纯计算，由主 actor 侧 await 调用，在协作线程池执行）。
private func downsampleImageFile(at url: URL?,maxPixelSize: CGFloat) async -> SendableImageBox {
    guard let url,let data = try? Data(contentsOf: url) else { return SendableImageBox(value: nil) }
    return SendableImageBox(value: downsampleImageData(data,maxPixelSize: maxPixelSize))
}
