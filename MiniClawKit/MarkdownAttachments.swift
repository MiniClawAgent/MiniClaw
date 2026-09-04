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

private final class ImageTapGesture: UITapGestureRecognizer {
    var attachedImage: UIImage?
    var sourceURL: String?
    var messageId: UUID?

    @objc func handleTap() {
        // Preferred path: route up to SwiftUI so a paged gallery can be shown.
        if let messageId,let sourceURL {
            MarkdownImageTapRouter.postTap(messageId: messageId,sourceURL: sourceURL)
            // 2026-08-12 治本:图片点击同时进入系统预览通道(宿主监听
            // .miniClawOpenURLRequested → QLPreviewController)。source 归一为
            // miniclaw:// 文件语义(图片/PDF/音视频统一系统预览)。
            let canonical = ImageAttachment.canonicalizeMarkdownImageSource(sourceURL)
            if let url = URL(string: canonical), url.scheme == "miniclaw" {
                NotificationCenter.default.post(name: .miniClawOpenURLRequested, object: url)
            }
            return
        }
        // Fallback: no message context — present a single-image fullscreen
        // preview directly, same as before.
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

/// Wraps a fullscreen preview view and restores scroll position on disappear.
final class MathAttachment: NSTextAttachment {
    let latex: String
    let isBlock: Bool
    let theme: MarkdownTheme
    private(set) var renderedImage: UIImage?
    private(set) var renderedSize: CGSize = .zero
    private var didAttemptRender = false
    private var isKaTeXPending = false
    /// Both SwiftMath and KaTeX failed — show raw LaTeX fallback.
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
                // [T-ios-math-inline-fallback-width] Measure the actual fallback
                // text width so the label doesn't overflow. The old hardcoded 40pt
                // caused "G(..." truncation artifacts when the LaTeX string was
                // wider than 40pt.
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

    /// Enqueue this attachment for async rendering. Idempotent — subsequent
    /// calls are no-ops once `didAttemptRender` is set. The actual render work
    /// is batched by `MathRenderScheduler` so a document with hundreds of
    /// formulas doesn't block the main thread. See `performRender()` for the
    /// synchronous render body.
    func beginRenderingIfNeeded() {
        MathAttachment.beginCount &+= 1
        if MathAttachment.beginCount <= 3 || MathAttachment.beginCount%50 == 0 {
            AppLogger(category: "MathSched").info("[MathSched] beginRenderingIfNeeded #\(MathAttachment.beginCount) rendered=\(renderedImage != nil) attempted=\(didAttemptRender) katex=\(isKaTeXPending) isBlock=\(isBlock) latex=\(latex.prefix(30))")
        }
        guard renderedImage == nil,!didAttemptRender,!isKaTeXPending else { return }
        didAttemptRender = true
        MathRenderScheduler.shared.enqueue(self)
    }

    nonisolated(unsafe) static var beginCount: Int = 0

    /// Synchronous render body. Called by `MathRenderScheduler` on the main
    /// thread from inside a yielding batch loop — do not call directly.
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

    /// When true, `performRender` writes the rendered image into
    /// `NSTextAttachment.image` so UILabel / UITextView draw the formula
    /// via TextKit. Main-flow attachments leave this false and rely on a
    /// dedicated UIImageView overlay built in `refreshAttachViews`.
    var inlineDrawable: Bool = false

    func makeView(width: CGFloat) -> UIView {
        // Attempt render if not yet done (e.g. attachment reappeared after recycle)
        if renderedImage == nil && !didAttemptRender && !isKaTeXPending {
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
                // Use actual image size — the passed-in width may be stale from
                // placeholder bounds if SwiftMath rendered synchronously after the
                // layout pass already computed attachment bounds with nil image.
                imgView.frame = CGRect(x: 0,y: 0,width: imgW,height: imgH)
                return imgView
            }
        }
        // Placeholder while KaTeX renders, or final fallback: raw LaTeX
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

// MARK: - Image Attachment

final class TableScrollView: UIScrollView,UIScrollViewDelegate {
    /// Closure called every time the trait collection changes; should
    /// return a CGColor resolved for the supplied trait collection.
    var borderColorProvider: ((UITraitCollection) -> CGColor)?

    /// [T-ios-table-hscroll-stream-interrupt] One-shot callback fired when a
    /// user scroll interaction fully ends (finger lifted with no momentum, or
    /// deceleration settled). Armed by refreshAttachViews when a streaming
    /// rebuild of this table was deferred because the view was mid-gesture;
    /// the callback replays the deferred rebuild. Cleared before invocation
    /// so a later interaction with no pending rebuild fires nothing.
    var onInteractionEnded: (() -> Void)?

    /// [T-ios-table-hscroll-offset-lost] Reports every USER-driven offset
    /// change (finger down or momentum) so the owning TableAttachment can
    /// persist the position across streaming rebuilds. Programmatic
    /// setContentOffset calls (e.g. the makeView restore) don't fire this —
    /// they run with isTracking/isDragging/isDecelerating all false — so a
    /// clamped restore can never overwrite the user's real position.
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
        // The trait collection becomes meaningful only after the view is
        // attached to a window; resolve once at that moment so the border
        // is correct on the very first frame the user sees.
        applyBorderColorNow()
    }

    func applyBorderColorNow() {
        guard let provider = borderColorProvider else { return }
        layer.borderColor = provider(traitCollection)
    }
}

/// Minimal UITextView subclass for table cells with tappable links.
/// Intercepts link taps and routes them through the same openURL handler
/// used by the main markdown text view.
let miniClawInlineCodeBackgroundColor = UIColor { traits in
    traits.userInterfaceStyle == .dark
        ? UIColor(red: 0x3A/255.0,green: 0x3A/255.0,blue: 0x3C/255.0,alpha: 1)
        : .systemGray6
}

/// Mirrors the `.miniClawChat` MarkdownUI theme using UIKit types.
// MARK: - Video Attachment

final class NativeMediaImageCache {
    nonisolated(unsafe) static let shared = NativeMediaImageCache()
    let cache = NSCache<NSString,UIImage>()
    /// Persistent record of image pixel sizes, keyed by canonical source URL.
    /// Used by `ImageAttachment.attachmentBounds` to compute the correct
    /// attachment height *before* the bitmap is loaded, so the cell self-sizes
    /// to the final layout on the very first pass — instead of locking at the
    /// 200pt placeholder, then losing the trailing markdown text below the
    /// image to clipsToBounds when the late `invalidateCellSizeIfChanged` grow
    /// is rejected by SwiftUI's UIHostingConfiguration cache.
    ///
    /// Backed by UserDefaults so cold starts (the symptom case: app killed →
    /// re-entered conversation, or message-list session re-load from disk)
    /// already have the size on the very first attachmentBounds call.
    /// [AttachHang preload-bounds]
    private static let defaultsKey = "MiniClawImageSizes_v1"
    private var sizes: [String: CGSize]
    private let sizesLock = NSLock()
    private init() {
        cache.countLimit = 50
        // Hydrate from UserDefaults. Stored as ["src": "wxh"] (string-encoded
        // so the dictionary serialises cleanly through plist encoding).
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

    // MARK: - [T-ios-failed-image-refetch-storm] Negative (failure) cache
    //
    // A broken HTTP(S) image URL has no per-instance retry budget across cell
    // reuse: scrolling recycles the cell, CACHE-WIPE recreates the
    // ImageAttachment with retriesRemaining reset, so the SAME failing URL
    // re-fetches on every recycle. Each failed fetch fires onLoad → updateAttachment
    // Views → re-render → re-fetch, a main-thread storm that shows up as the
    // residual scroll-deceleration jank on image-heavy sessions (device log:
    // 28 MiniClawImage + 19 AttachHotPath events on a single 115ms landing frame,
    // all the same FAILED url). Record failures process-wide with a short TTL
    // so a recycled cell doesn't re-hit the network; the TTL lets a transient
    // network error recover later (a fresh attempt after the window).
    private var failedSources: [String: CFAbsoluteTime] = [:]
    private let failedLock = NSLock()
    /// How long a failed source stays suppressed before a retry is allowed.
    private let failureTTL: CFAbsoluteTime = 60

    /// True if `src` failed to load within the last `failureTTL` seconds.
    func isRecentlyFailed(_ src: String) -> Bool {
        failedLock.lock(); defer { failedLock.unlock() }
        guard let t = failedSources[src] else { return false }
        if CFAbsoluteTimeGetCurrent()-t>failureTTL {
            failedSources.removeValue(forKey: src)  // expired — allow a fresh attempt
            return false
        }
        return true
    }

    /// Record that `src` failed to produce an image (negative-cache it).
    func recordFailure(_ src: String) {
        failedLock.lock(); failedSources[src] = CFAbsoluteTimeGetCurrent(); failedLock.unlock()
    }

    /// Clear a source's failure record (call on a successful load so a URL that
    /// recovered isn't suppressed by a stale entry).
    func clearFailure(_ src: String) {
        failedLock.lock(); failedSources.removeValue(forKey: src); failedLock.unlock()
    }

    /// Lookup the recorded pixel size for a source URL (canonical form, no
    /// fingerprint suffix). Returns nil if we've never loaded this URL.
    func size(forSource src: String) -> CGSize? {
        sizesLock.lock(); defer { sizesLock.unlock() }
        return sizes[src]
    }
    /// Record a source URL → pixel-size mapping. Call once after a successful
    /// image decode. Persists to UserDefaults so cold starts can use it.
    func recordSize(_ size: CGSize,forSource src: String) {
        sizesLock.lock()
        if sizes[src] == size {
            sizesLock.unlock()
            return
        }
        sizes[src] = size
        let snapshot = sizes
        sizesLock.unlock()
        // Encode and persist outside the lock (UserDefaults can be slow).
        let encoded: [String: String] = snapshot.mapValues { "\($0.width)x\($0.height)" }
        UserDefaults.standard.set(encoded,forKey: Self.defaultsKey)
    }
}

// MARK: - Downsample Helper

/// Downsample image data. maxPixelSize controls the longest edge in pixels.
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
        // Strip query parameters for file URL resolution (they are metadata, not part of the path)
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

        // Waveform icon + filename
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

        // Play button
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 22,weight: .regular)
        let playBtn = UIButton(type: .system)
        playBtn.setImage(UIImage(systemName: "play.circle.fill", withConfiguration: iconConfig), for: .normal)
        playBtn.tintColor = .systemOrange
        playBtn.frame = CGRect(x: 10,y: 30,width: 30,height: 30)
        bg.addSubview(playBtn)

        // Slider
        let slider = UISlider()
        slider.minimumTrackTintColor = .systemOrange
        slider.frame = CGRect(x: 46,y: 34,width: maxW-100,height: 22)
        slider.value = 0
        bg.addSubview(slider)

        // Duration label
        let durLabel = UILabel()
        durLabel.text = "--:--"
        durLabel.font = .monospacedDigitSystemFont(ofSize: 11,weight: .regular)
        durLabel.textColor = .secondaryLabel
        durLabel.textAlignment = .right
        durLabel.frame = CGRect(x: maxW-50,y: 36,width: 40,height: 16)
        bg.addSubview(durLabel)

        // Expand button (top-right)
        let expandBtn = UIButton(type: .system)
        let expandConfig = UIImage.SymbolConfiguration(pointSize: 11,weight: .medium)
        expandBtn.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right", withConfiguration: expandConfig), for: .normal)
        expandBtn.tintColor = .secondaryLabel
        expandBtn.frame = CGRect(x: maxW-28,y: 6,width: 22,height: 22)
        bg.addSubview(expandBtn)

        // Wire up audio playback controller
        let controller = InlineAudioController(fileURL: resolvedURL,playButton: playBtn,slider: slider,durationLabel: durLabel)
        // Keep controller alive by attaching to the view
        objc_setAssociatedObject(bg,&InlineAudioController.associatedKey,controller,.OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        // Expand button action
        let expandTap = AudioTapGesture(target: nil,action: nil)
        expandTap.fileURL = resolvedURL
        expandTap.addTarget(expandTap,action: #selector(AudioTapGesture.handleTap))
        expandBtn.addTarget(expandTap,action: #selector(AudioTapGesture.handleTap),for: .touchUpInside)
        // Keep expandTap alive
        objc_setAssociatedObject(expandBtn,&AudioTapGesture.expandTapKey,expandTap,.OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        // Tap on filename area opens fullscreen audio preview
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

/// Tap gesture to open audio preview sheet.
final class VideoAttachment: NSTextAttachment {
    let source: String
    let theme: MarkdownTheme
    private(set) var thumbnail: UIImage?
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
            let h = min(width*aspect,UIScreen.main.bounds.height/2)
            // +24 for filename label below
            return CGRect(x: 0,y: 0,width: lineFrag.width,height: h+24)
        }
        return CGRect(x: 0,y: 0,width: lineFrag.width,height: Self.placeholderHeight)
    }

    func beginLoadingIfNeeded() {
        guard thumbnail == nil,!isLoading else { return }
        isLoading = true

        let src = source
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var fileURL: URL?
            if let url = URL(string: src), url.scheme == "miniclaw" {
                fileURL = resolveMiniClawFileURLForNativeText(url: url)
            } else if let url = URL(string: src) {
                fileURL = url
            }

            guard let fileURL else {
                await MainActor.run { self.isLoading = false }
                return
            }

            // Check thumbnail cache
            let cacheKey = fileURL.path
            if let cached = NativeMediaImageCache.shared.image(for: "thumb:"+cacheKey) {
                await MainActor.run {
                    self.thumbnail = cached
                    self.resolvedURL = fileURL
                    self.isLoading = false
                    self.onLoad?()
                    // Cell-side height re-measure: attachmentBounds now returns
                    // aspect-fit height instead of the 200pt placeholder, so
                    // the surrounding cell must invalidate its cached height.
                    // Without this, the cell stays at the placeholder height
                    // until some unrelated event (scroll, reconfigure) forces
                    // a re-measure (the "appears half-rendered, then snaps
                    // 10s later" bug).
                    NotificationCenter.default.post(name: .miniClawAttachmentSizeChanged,object: src)
                }
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
                // Fallback: no thumbnail
            }

            if let thumb {
                NativeMediaImageCache.shared.set(thumb, for: "thumb:"+cacheKey)
            }

            await MainActor.run {
                self.thumbnail = thumb
                self.resolvedURL = fileURL
                self.isLoading = false
                self.onLoad?()
                if thumb != nil {
                    NotificationCenter.default.post(name: .miniClawAttachmentSizeChanged,object: src)
                }
            }
        }
    }

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
        let h = min(maxWidth*aspect,UIScreen.main.bounds.height/2)

        let container = UIView(frame: CGRect(x: 0,y: 0,width: totalWidth,height: h+24))
        container.backgroundColor = .clear

        let thumbView = UIImageView(image: thumb)
        thumbView.contentMode = .scaleAspectFill
        thumbView.frame = CGRect(x: 0,y: 0,width: maxWidth,height: h)
        thumbView.layer.cornerRadius = 8
        thumbView.clipsToBounds = true
        container.addSubview(thumbView)

        // Dark overlay
        let overlay = UIView(frame: thumbView.frame)
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.3)
        overlay.layer.cornerRadius = 8
        overlay.clipsToBounds = true
        container.addSubview(overlay)

        // Play icon
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 44,weight: .regular)
        let playIcon = UIImageView(image: UIImage(systemName: "play.circle.fill", withConfiguration: iconConfig))
        playIcon.tintColor = .white.withAlphaComponent(0.9)
        playIcon.sizeToFit()
        playIcon.center = CGPoint(x: maxWidth/2,y: h/2)
        container.addSubview(playIcon)

        // Filename label with film icon
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

        // Tap to play
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
    /// Assistant message this attachment belongs to, for resolving all sibling
    /// images in the same message when the user taps to preview. nil for
    /// contexts that aren't aware of a message (e.g. standalone previews).
    var messageId: UUID?
    /// Fingerprint (size+mtime) of the file that produced `loadedImage`.
    /// When the renderer reuses a cached attachment for the same source
    /// string, it compares this against the current on-disk fingerprint
    /// and clears `loadedImage` if they differ — so in-place rewrites of
    /// the underlying file get picked up on the next render.
    var loadedFingerprint: String?
    /// Set by `invalidateLoadedImage` when the on-disk file changed, so
    /// `refreshAttachViews` rebuilds the `UIImageView` instead of
    /// reusing the previous view (which still holds the stale bitmap in
    /// its `UIImageView.image` property).
    var needsViewRebuild: Bool = false
    private(set) var loadedImage: UIImage?
    /// Resolved file URL for lazy re-downsampling (no raw Data in memory).
    private var resolvedFileURL: URL?
    /// The maxPixelSize used for the current loadedImage (0 = initial full load).
    private var downsampledAtPixelSize: CGFloat = 0
    private var isLoading = false
    /// Set when a miniclaw:// file was not found; allows retry on next render.
    private var fileNotFound = false
    /// Number of file-not-found retries remaining (prevents infinite polling).
    private var retriesRemaining = 15
    /// Callback fired after image loads so the text view can refresh layout.
    var onLoad: (() -> Void)?

    /// [AttachHotPath] Per-instance counters: prove or refute that streaming
    /// re-runs layout / decode for the same image attachment. If these grow
    /// linearly with token count, the attachment is being thrashed.
    fileprivate var attachmentBoundsCallCount: Int = 0
    fileprivate var makeViewCallCount: Int = 0

    init(source: String,theme: MarkdownTheme,messageId: UUID? = nil) {
        self.source = source
        self.theme = theme
        self.messageId = messageId
        super.init(data: nil,ofType: nil)
        self.image = Self.transparentImage
        AppLogger(category: "AttachHotPath").info("[IMG][CTOR] src=\(Self.shortSrc(source)) ptr=\(ObjectIdentifier(self).hashValue & 0xFFFFFF)")
    }

    static func shortSrc(_ s: String) -> String {
        let max = 60
        return s.count <= max ? s : "…"+String(s.suffix(max-1))
    }

    /// Rewrite a markdown image source so relative paths resolve against
    /// the active session's workspace directory. Paths that already carry
    /// a URL scheme (`http`, `https`, `miniclaw`, `file`, …) are returned
    /// unchanged. Bare filenames and relative paths (e.g. `foo.png`,
    /// 文件型 `miniclaw://` host(磁盘布局 = 会话目录 `<sid>/<host>/<path>`,
    /// 与 `miniclaw://` 完全一致)。导航深链(settings/open_terminal/session/new/task)
    /// 不在此列,保持原样交给深链路由。internal:MiniClawOpenURLHandler 同用。
    static let fileHosts: Set<String> = [
        "browser", "workspace", "attachments", "shared", "offloads", "memory", "rules", "skills"
    ]

    /// `./foo.png`, `subdir/bar.jpg`) become `miniclaw://workspace/<path>`
    /// with non-ASCII segments percent-encoded so `URL(string:)` parses
    /// them cleanly.
    static func canonicalizeMarkdownImageSource(_ src: String) -> String {
        // Fast path: if there's any URL scheme, bail out.
        if let colon = src.firstIndex(of: ":") {
            let maybeScheme = src[src.startIndex..<colon]
            // Only accept alphabetic-prefixed schemes (RFC 3986 § 3.1).
            if !maybeScheme.isEmpty && maybeScheme.allSatisfy({ $0.isLetter }) {
                // [T-miniclaw-url-fullwidth-pipe-ios] Exception: a miniclaw:// source the
                // model emitted with raw non-ASCII in the path (e.g. `｜`, CJK) that
                // URL(string:) can't parse. Re-encode the path so the image resolves
                // instead of bailing with a dead source. Idempotent for already-
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
        // Strip leading `./` and any leading slashes.
        var trimmed = src
        while trimmed.hasPrefix("./") { trimmed.removeFirst(2) }
        while trimmed.hasPrefix("/") { trimmed.removeFirst() }
        // Percent-encode each path segment so multi-byte characters
        // (CJK, emoji, spaces) don't break URL parsing.
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        let encoded = segments.map { seg -> String in
            String(seg).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(seg)
        }.joined(separator: "/")
        return "miniclaw://workspace/\(encoded)"
    }

    /// Drop the currently-loaded bitmap so the next `beginLoadingIfNeeded`
    /// re-reads the source from disk. Called by the renderer when the
    /// on-disk fingerprint for this source changes between renders.
    func invalidateLoadedImage() {
        loadedImage = nil
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
    /// Match MarkdownUI's maxWidth: 400 for images
    private static let maxImageWidth: CGFloat = 400
    /// [T-md-image-shadow-clip] Breathing room reserved on EVERY side of the
    /// rendered image inside its attachment box so the drop shadow
    /// (radius 4, y-offset 2) draws fully instead of being clipped by the
    /// text view's clipsToBounds at full-width images. attachmentBounds and
    /// makeImageView MUST use the same value or the cell height drifts.
    private static let imageShadowInset: CGFloat = 6

    override func attachmentBounds(for textContainer: NSTextContainer?,proposedLineFragment lineFrag: CGRect,glyphPosition position: CGPoint,characterIndex charIndex: Int) -> CGRect {
        // Quantize the line-fragment width to a 4pt bucket. TextKit can call
        // attachmentBounds many times per layout pass with widths that differ
        // by sub-point floats (e.g. 329.83333 vs 330.0) as the container width
        // flows through cell self-sizing. Without quantization the downstream
        // `targetPixels` can toggle across the `downsampledAtPixelSize !=` guard
        // and re-schedule downsample on every call, which mutates loadedImage
        // and forces TextKit to re-typeset. Bucket is visually imperceptible.
        let rawWidth = lineFrag.width
        let width = (rawWidth/4.0).rounded()*4.0
        attachmentBoundsCallCount &+= 1
        // [AttachHotPath] Per-call log capped at first 5 + every 50 to avoid log
        // flooding while still proving cadence vs streaming token rate.
        let cnt = attachmentBoundsCallCount
        if cnt <= 5 || cnt%50 == 0 {
            AppLogger(category: "AttachHotPath").info("[IMG][BOUNDS] #\(cnt) src=\(Self.shortSrc(self.source)) ptr=\(ObjectIdentifier(self).hashValue & 0xFFFFFF) rawW=\(String(format: "%.1f", rawWidth)) bucketW=\(String(format: "%.0f", width)) hasImg=\(self.loadedImage != nil) sampledAt=\(Int(self.downsampledAtPixelSize))")
        }

        if let img = loadedImage {
            // [T-md-image-shadow-clip] Inset the displayed image by
            // shadowInset per side so the drop shadow renders INSIDE the
            // attachment box. Previously the image filled the full box width;
            // for full-width images the shadow spilled past the text view's
            // bounds (clipsToBounds=true) and was visibly cut off left/right.
            let boxWidth = min(min(width,img.size.width+Self.imageShadowInset*2),Self.maxImageWidth)
            var imgWidth = max(boxWidth-Self.imageShadowInset*2,40)
            let aspect = img.size.height/max(img.size.width,1)
            let maxH = UIScreen.main.bounds.height/2
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
            //  - imgWidth >= maxImageWidth * 0.8: only downsample when layout width
            //    is close to the final display width. TextKit may call attachmentBounds
            //    with a very small lineFrag during intermediate layout passes; if we
            //    downsample then, loadedImage is permanently replaced with a tiny
            //    thumbnail (e.g. 112×200) and never recovers.
            //  - targetPixels >= 600: absolute minimum to avoid destroying image quality.
            //  - targetPixels is bucketed to 50pt so sub-point lineFrag jitter
            //    cannot flip the `downsampledAtPixelSize != targetPixels` guard
            //    and re-kick downsample on every attachmentBounds call.
            let rawTargetPixels = imgWidth*2
            let targetPixels = (rawTargetPixels/50.0).rounded()*50.0
            if imgWidth >= Self.maxImageWidth*0.8,
               targetPixels >= 600,
               img.size.width>targetPixels*1.5,
               downsampledAtPixelSize != targetPixels {
                AppLogger(category: "AttachHotPath").info("[IMG][BOUNDS][DOWNSAMPLE-FIRE] src=\(Self.shortSrc(self.source)) ptr=\(ObjectIdentifier(self).hashValue & 0xFFFFFF) targetPx=\(Int(targetPixels)) prevPx=\(Int(self.downsampledAtPixelSize)) imgW=\(Int(img.size.width)) bucketW=\(String(format: "%.0f", width))")
                downsampledAtPixelSize = targetPixels
                let fileURL = resolvedFileURL
                Task.detached(priority: .utility) { [weak self] in
                    guard let self else { return }
                    guard let url = fileURL,let data = try? Data(contentsOf: url) else { return }
                    guard let resized = downsampleImageData(data,maxPixelSize: targetPixels) else { return }
                    await MainActor.run {
                        AppLogger(category: "AttachHotPath").info("[IMG][BOUNDS][DOWNSAMPLE-APPLY] src=\(Self.shortSrc(self.source)) ptr=\(ObjectIdentifier(self).hashValue & 0xFFFFFF) newSize=\(Int(resized.size.width))x\(Int(resized.size.height)) — ASSIGNS loadedImage on main, will trigger TextKit re-layout")
                        self.loadedImage = resized
                        // Do NOT write back to NativeMediaImageCache — the shared
                        // cache must keep the full-resolution image so that other
                        // ImageAttachment instances (e.g. after markdown re-parse)
                        // pick up the crisp original, not a downsampled copy.
                    }
                }
            }

            // Return the attachment box as `imgWidth` (already clamped by
            // `maxImageWidth` and the image's own intrinsic width), NOT the
            // raw `width`. TextKit can pass `lineFrag.width = 10_000_000.0`
            // as an "unconstrained" probe during intermediate layout passes;
            // returning that value unchanged gave TextKit an attachment box
            // 10M points wide, which invalidates line-fragment geometry and
            // causes neighbouring passes (at the real container width) to
            // compute a different bounds, feeding a layout loop that can walk
            // past the 5s watchdog budget. [AttachHang fix]
            // Box = image + shadow breathing room on ALL sides (geometry must
            // match makeImageView's container exactly, or the cell height
            // drifts — the historical attachment-clip class of bugs).
            return CGRect(x: 0,y: 0,width: imgWidth+Self.imageShadowInset*2,
                          height: h+Self.imageShadowInset*2)
        }
        // No `loadedImage` yet — but if we've ever loaded this source before
        // we have its pixel size recorded globally. Use that to compute the
        // correct attachment height on the very first layout pass, instead of
        // returning the 200pt placeholder. Without this:
        //   1. First updateUIView creates a fresh ImageAttachment (cacheCount=0)
        //   2. SwiftUI sizeThatFits → attachmentBounds → placeholder 200pt
        //   3. Cell self-sizes to 276pt (placeholder + surrounding text)
        //   4. Async image load completes, attachmentBounds now returns 280pt
        //   5. invalidateCellSizeIfChanged fires prev=271→new=358 delta=+87
        //   6. That late grow is sometimes lost (deferSelfSizing rejects it,
        //      SwiftUI's UIHostingConfiguration.systemLayoutSizeFitting still
        //      caches 276pt from step 3, etc.)
        //   7. Cell stays at 276pt; the UITextView inside grows to 358pt and
        //      gets clipped by the cell's clipsToBounds — image bottom cut
        //      off and the trailing prose after the image disappears.
        // [AttachHang preload-bounds fix]
        let canonicalSrc = Self.canonicalizeMarkdownImageSource(source)
        if let knownSize = NativeMediaImageCache.shared.size(forSource: canonicalSrc) {
            // [T-md-image-shadow-clip] Same inset geometry as the loaded path.
            let boxWidth = min(min(width,knownSize.width+Self.imageShadowInset*2),Self.maxImageWidth)
            var imgWidth = max(boxWidth-Self.imageShadowInset*2,40)
            let aspect = knownSize.height/max(knownSize.width,1)
            let maxH = UIScreen.main.bounds.height/2
            var h = imgWidth*aspect
            // 2026-08-12 治本:限高等比缩宽保持原比例(同 loaded 路径)。
            if h > maxH {
                h = maxH
                imgWidth = h/aspect
            }
            return CGRect(x: 0,y: 0,width: imgWidth+Self.imageShadowInset*2,
                          height: h+Self.imageShadowInset*2)
        }
        // First time we see this source — fall back to placeholder. Same
        // unconstrained-probe guard as the loaded path.
        let placeholderWidth = min(width,Self.maxImageWidth)
        return CGRect(x: 0,y: 0,width: placeholderWidth,height: Self.placeholderHeight)
    }

    func beginLoadingIfNeeded() {
        guard loadedImage == nil,!isLoading else {
            imgLogger.info("[MiniClawImage][Load] skip src=\(self.source) alreadyLoaded=\(self.loadedImage != nil) isLoading=\(self.isLoading)")
            return
        }
        // Reset fileNotFound so we don't spin; it will be set again if still missing.
        fileNotFound = false
        guard retriesRemaining>0 else {
            imgLogger.warning("[MiniClawImage][Load] no retries left src=\(self.source)")
            return
        }
        retriesRemaining -= 1
        isLoading = true
        // Canonicalize scheme-less / relative sources to miniclaw://workspace/…
        // so the rest of the pipeline (cache key, resolve, fingerprint)
        // treats them uniformly. Agents writing plain markdown like
        // `![img](foo.png)` or `![img](subdir/foo.png)` land here.
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
            loadedImage = cached
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
        let isMiniClawURL = URL(string: src).map { $0.scheme == "miniclaw" } ?? false
        // [T-ios-failed-image-refetch-storm] For remote (non-miniclaw) URLs that
        // failed recently, don't re-dispatch a network fetch on every cell
        // recycle — render the placeholder and bail. miniclaw:// is exempt: those
        // are local files that may be written shortly after the markdown
        // references them, so the retriesRemaining-scheduled flow must stay.
        if !isMiniClawURL,NativeMediaImageCache.shared.isRecentlyFailed(src) {
            imgLogger.info("[MiniClawImage][Load] SUPPRESSED (recent failure within TTL) src=\(src)")
            isLoading = false
            fileNotFound = true
            return
        }
        imgLogger.info("[MiniClawImage][Load] dispatching async load src=\(src) isMiniClawURL=\(isMiniClawURL)")
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var fileURL: URL?
            let img: UIImage?
            if let url = URL(string: src), url.scheme == "miniclaw" {
                imgLogger.info("[MiniClawImage][Load] resolving miniclaw:// URL src=\(src) host=\(url.host ?? "nil") path=\(url.path)")
                if let resolved = resolveMiniClawFileURLForNativeText(url: url) {
                    imgLogger.info("[MiniClawImage][Load] miniclaw:// resolved to localPath=\(resolved.path)")
                    fileURL = resolved
                    if let data = try? Data(contentsOf: resolved) {
                        imgLogger.info("[MiniClawImage][Load] read \(data.count) bytes from localPath=\(resolved.path)")
                        let downsampled = downsampleImageData(data)
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
                if let data = try? Data(contentsOf: url) {
                    // HTTP images: no local file URL for re-downsample (network-only)
                    imgLogger.info("[MiniClawImage][Load] HTTP fetched \(data.count) bytes src=\(src)")
                    img = downsampleImageData(data)
                } else {
                    imgLogger.warning("[MiniClawImage][Load] HTTP fetch FAILED src=\(src)")
                    img = nil
                }
            } else if let url = URL(string: src) {
                // file URL or relative
                imgLogger.info("[MiniClawImage][Load] trying file/relative URL scheme=\(url.scheme ?? "nil") path=\(url.path)")
                fileURL = url
                if let data = try? Data(contentsOf: url) {
                    imgLogger.info("[MiniClawImage][Load] file loaded \(data.count) bytes src=\(src)")
                    img = downsampleImageData(data)
                } else {
                    imgLogger.warning("[MiniClawImage][Load] file load FAILED src=\(src)")
                    img = nil
                }
            } else {
                imgLogger.error("[MiniClawImage][Load] cannot parse URL src=\(src)")
                img = nil
            }

            // Recompute the fingerprint post-load in case the file was
            // rewritten between the pre-check at entry and this point.
            let postLoadKey = miniClawMediaCacheKey(for: src)
            if let img {
                imgLogger.info("[MiniClawImage][Load] SUCCESS src=\(src) finalSize=\(img.size.width)x\(img.size.height) — caching in memory")
                NativeMediaImageCache.shared.set(img,for: postLoadKey)
                // Also record the size (keyed by canonical source) so future
                // ImageAttachment instances can compute correct bounds before
                // the bitmap reload finishes. [AttachHang preload-bounds]
                NativeMediaImageCache.shared.recordSize(img.size,forSource: src)
                // [T-ios-failed-image-refetch-storm] A previously-failed URL
                // that now succeeded — clear its negative-cache entry.
                if !isMiniClawURL { NativeMediaImageCache.shared.clearFailure(src) }
            } else {
                imgLogger.warning("[MiniClawImage][Load] FAILED src=\(src) — no image produced")
                // [T-ios-failed-image-refetch-storm] Negative-cache remote
                // failures so cell recycling during scroll doesn't re-fetch the
                // same broken URL every recycle (the image-session decel storm).
                // miniclaw:// is exempt — its not-yet-written-file case is handled
                // by the retriesRemaining-scheduled retry below.
                if !isMiniClawURL { NativeMediaImageCache.shared.recordFailure(src) }
            }

            await MainActor.run {
                self.loadedImage = img
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


    func makeView(width: CGFloat) -> UIView {
        makeViewCallCount &+= 1
        // [AttachHotPath] makeView call counter — the GROUND-TRUTH signal:
        // if this fires more than once per attachment per layout pass, the
        // UIImageView subview is being rebuilt and we have a leak in the
        // refreshAttachViews reuse path.
        AppLogger(category: "AttachHotPath").info("[IMG][MAKEVIEW] #\(self.makeViewCallCount) src=\(Self.shortSrc(self.source)) ptr=\(ObjectIdentifier(self).hashValue & 0xFFFFFF) hasImg=\(self.loadedImage != nil) width=\(String(format: "%.0f", width))")
        if let img = loadedImage {
            imgLogger.info("[MiniClawImage][MakeView] rendering LOADED image src=\(self.source) imgSize=\(img.size.width)x\(img.size.height) containerWidth=\(width)")
            return makeImageView(img,width: width)
        } else {
            imgLogger.info("[MiniClawImage][MakeView] rendering PLACEHOLDER src=\(self.source) containerWidth=\(width) fileNotFound=\(self.fileNotFound) retriesRemaining=\(self.retriesRemaining)")
            return makePlaceholderView(width: width)
        }
    }

    private func makeImageView(_ img: UIImage,width: CGFloat) -> UIView {
        // [T-md-image-shadow-clip] Mirror attachmentBounds' inset geometry:
        // the image is inset by imageShadowInset per side inside the
        // attachment box so the shadow renders fully within the text view's
        // clip bounds (it used to be cut off left/right on full-width images).
        let boxWidth = min(min(width,img.size.width+Self.imageShadowInset*2),Self.maxImageWidth)
        var imgWidth = max(boxWidth-Self.imageShadowInset*2,40)
        let aspect = img.size.height/max(img.size.width,1)
        let maxH = UIScreen.main.bounds.height/2
        var h = imgWidth*aspect
        // 2026-08-12 治本:限高等比缩宽保持原比例(同 attachmentBounds 路径)。
        if h > maxH {
            h = maxH
            imgWidth = h/aspect
        }
        imgLogger.info("[MiniClawImage][MakeView] layout src=\(self.source) displayWidth=\(imgWidth) displayHeight=\(h) aspect=\(aspect) maxImageWidth=\(Self.maxImageWidth)")

        let shadowInset: CGFloat = Self.imageShadowInset
        // Container == the attachment box (image + shadow room on all sides).
        let container = UIView(frame: CGRect(x: 0,y: 0,width: imgWidth+shadowInset*2,height: h+shadowInset*2))
        container.backgroundColor = .clear
        container.clipsToBounds = false

        // Shadow wrapper — positioned at the inset so the shadow's spill stays
        // inside the container/attachment box.
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

/// Tap gesture recognizer that routes a markdown-embedded image tap up to
/// the SwiftUI layer so it can present a paged gallery of **all** inline
/// images in the same assistant message.
///
/// When `messageId` is set, we post a `MarkdownImageTapRouter.tappedNotification`
/// and let `ChatView` resolve the message → full gallery item list.
/// When `messageId` is nil (standalone preview, e.g. a markdown view outside
/// a chat message), we fall back to the legacy single-image fullscreen
/// preview so nothing breaks.
// MARK: - Media Image Cache

final class TableAttachment: NSTextAttachment {
    private(set) var alignments: [RawTableColumnAlignment]
    private(set) var rows: [RawTableRow]
    let theme: MarkdownTheme
    /// Handler for opening URLs from links in table cells.
    var onOpenURL: ((URL) -> Void)?

    /// Shared NSDataDetector used to find bare URLs that the markdown
    /// parser left as `.text` (cmark-gfm autolink misses on CJK / full-
    /// width adjacency). Compiled once — initializer can throw, hence
    /// the `try?`. Reused across every table cell in the app.
    static let linkDataDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()
    /// Set when `update(...)` mutates content in place. Tells the parent
    /// refreshAttachViews path that the existing rendered TableScrollView
    /// needs to be rebuilt to reflect the new rows/alignments. Mirrors
    /// `ImageAttachment.needsViewRebuild`. Reset by the consumer after the
    /// view is recreated.
    var needsViewRebuild: Bool = false
    /// Set when the content/layout changed in place; updateUIView reads this
    /// to invalidate just the attachment's character range in the parent
    /// UITextView's layoutManager (instead of the whole document).
    var needsLayoutInvalidation: Bool = false

    /// Horizontal scroll offset the user last reached on this table,
    /// re-applied inside every freshly-built view so the left/right scroll
    /// position survives streaming redraws. In-memory only (lives on this
    /// attachment, which keeps its object identity across streaming
    /// `update(...)` calls); never persisted.
    ///
    /// [T-ios-table-hscroll-offset-lost] This is PERSISTENT, not one-shot:
    /// the previous consume-once `pendingScrollOffset` + async restore lost
    /// the position whenever the next streaming rebuild fired before the
    /// async restore landed — the capture then read a transient offset of 0,
    /// declined to re-capture, and the restore targeted the already-removed
    /// old view. Now the live TableScrollView pushes every user-driven
    /// offset change here (see `onUserScroll` wiring in `makeView`), and
    /// `makeView` re-applies it synchronously without clearing it.
    var preservedScrollOffset: CGPoint?

    /// Walk a `makeView`-produced wrapper to its inner TableScrollView so the
    /// rebuild path can read/restore `contentOffset`. The wrapper holds exactly
    /// one TableScrollView subview (see `makeView`).
    static func tableScrollView(in wrapper: UIView) -> TableScrollView? {
        if let direct = wrapper as? TableScrollView { return direct }
        return wrapper.subviews.compactMap { $0 as? TableScrollView }.first
    }

    /// Monotonic counter bumped on every `update(...)`. The parent textView's
    /// `invalidateCellSizeIfChanged` includes the sum of all TableAttachments'
    /// generations in its dedup fingerprint — without this, a streaming
    /// table whose rows/cols change but whose surrounding text (and thus
    /// `textStorage.length`) doesn't would be skipped by the
    /// "storageLen+width unchanged → no remeasure" early-exit, leaving the
    /// layout manager with the original (smaller) attachment bounds and
    /// producing the "table renders single-column / extra rows missing"
    /// symptom we hit during the watchdog repro.
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

    /// Replace the table's content while keeping the same NSTextAttachment
    /// object identity. Crucial during streaming markdown: when only the table
    /// grows (e.g. one more cell character per token), preserving identity
    /// keeps the MarkdownView fast-path's prefix `isEqual` check
    /// happy, so we no longer fall back to `ensureLayout` over the entire
    /// message every chunk.
    func update(alignments: [RawTableColumnAlignment],rows: [RawTableRow]) {
        // [T-ios-table-hscroll-stream-interrupt] No-op when the content is
        // identical. The caller's hash-based routing normally sends equal
        // content to the cache-hit path instead of here, but if it ever
        // lands here, setting needsViewRebuild would tear down (and cancel
        // any in-flight horizontal scroll on) an already up-to-date
        // TableScrollView for nothing.
        if alignments == self.alignments && rows == self.rows { return }
        // HangFix(2026-05-14) — During streaming, this method fires on every
        // token chunk while a partial table is on screen. Wiping cachedLayout
        // unconditionally means each subsequent attachmentBounds callback
        // (TextKit1 calls it many times per fillLayoutHole pass) re-runs a
        // full per-cell NSAttributedString.boundingRect measurement. Even
        // a 4-row × 2-col table at small attrLen amplifies into seconds of
        // main-thread time when the typesetter loops on width probing.
        //
        // The previous-pass layout is still visually accurate if no new row
        // arrived (only cell content grew), AND it's still close-enough to
        // accurate even when one row was appended (the typesetter will fix
        // up the final size on the next real layout). We retain it in both
        // cases — the cell will re-measure naturally when `computeLayout`
        // gets called on a different width or when an actual size change
        // forces it. The transient stale height for one frame is invisible
        // versus a 1-2s hang on every streaming chunk.
        let oldRowCount = self.rows.count
        let oldColCount = self.alignments.count
        self.alignments = alignments
        self.rows = rows
        let structureChanged = rows.count != oldRowCount || alignments.count != oldColCount

        // [T-ios-table-streaming-width] Check whether the cached column widths
        // are stale. The HangFix (2026-05-14) only invalidated on row/column
        // COUNT changes, but during streaming a row's content grows from
        // partial to complete (same row count). The cached column widths from
        // the partial content are too narrow → columns wrap / emoji get
        // clipped. We track the max character count per column at cache time;
        // when any column's widest cell grows longer, the cache is stale.
        // This is O(rows × cols) integer comparisons — no hashing, no layout,
        // no measurement — so it stays cheap on every streaming token.
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
        // Always mark for view rebuild so SelectableTableView's row VStack
        // can re-create row subviews with new cell content. Bounds reuse
        // is independent of view rebuild.
        self.needsViewRebuild = true
        // Layout invalidation needed when structure changes (rowHeights array
        // shape) or content grew wider (column widths stale) — even when
        // cachedLayout was already nil, the textView layout manager needs to
        // know the attachment bounds changed.
        self.needsLayoutInvalidation = structureChanged || contentGrew
        self.contentGeneration &+= 1
    }

    /// Tab-separated plain text representation of the table (rows joined by `\n`).
    func plainText() -> String {
        let colCount = alignments.count
        return rows.map { row in
            row.cells.prefix(colCount).map { $0.content.plainText }.joined(separator: "\t")
        }.joined(separator: "\n")
        // [T-md-cjk-emphasis-pairs] Strip flanking-fix spacers (see
        // plainTextWithTabs) so table copies stay clean too.
        .replacingOccurrences(of: "\u{200B}", with: "")
        .replacingOccurrences(of: "\u{200A}", with: "")
    }

    private static let transparentImage: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 1,height: 1)).image { _ in }
    }()

    /// Spacing controlled by RenderedBlock margins; no extra padding inside attachment
    static let verticalMargin: CGFloat = 0
    static let minRowHeight: CGFloat = 36
    static let cellPaddingH: CGFloat = 16
    static let cellPaddingV: CGFloat = 8

    /// Narrowest real (non-probe) attachment width observed process-wide, used as
    /// the height-measurement fallback for a first-appearance probe that races
    /// ahead of any real-width pass. Seeded below any real chat-bubble width so a
    /// probe never returns a height that clips the last table row.
    /// [ios_session_open_last_cell_occluded]
    nonisolated(unsafe) static var narrowestRealWidth: CGFloat = 380

    /// Cached layout computed for a given width, reused by both attachmentBounds and makeView.
    var cachedLayout: TableLayout?
    /// Per-column maximum cell character count at the time `cachedLayout` was
    /// computed. When any column's widest cell grows longer during streaming,
    /// the cached column widths may be too narrow → must recompute. Using
    /// character counts (not a full content hash) keeps the check O(cells)
    /// per token — cheaper than Hasher over all plainText.
    private var cachedMaxCharPerCol: [Int] = []

    // MARK: - [T-ios-attachbounds-cold-cache] Process-wide layout cache
    //
    // `cachedLayout` above is PER-INSTANCE. On scroll deceleration the
    // collection view recycles cells; the per-cell renderer wipes/rebuilds
    // attachments (isNewMessage CACHE-WIPE), so a TableAttachment landing into
    // view at decel-stop often starts with `cachedLayout == nil` and every
    // `attachmentBounds` typesetter probe is a cold miss → a burst of per-cell
    // `boundingRect` measurement on the landing frame (the 100–190ms decel
    // jank, confirmed via [ScrollDecel]+[AttachBoundsHot] device logs).
    //
    // `computeLayout` is a PURE function of (rows, alignments, theme font,
    // bucketed width). Cache its result process-wide keyed by that signature
    // so an identical table — same content, same width — that was measured by
    // ANY earlier cell is reused instantly instead of cold-measured again.
    // LRU-bounded; pure layout values (no view refs) so it's cheap to retain.
    private struct LayoutCacheKey: Hashable {
        let contentSig: Int
        let widthBucket: Int   // width snapped to 4pt to fold typesetter probe jitter
    }
    nonisolated(unsafe) private static var sharedLayoutCache: [LayoutCacheKey: TableLayout] = [:]
    nonisolated(unsafe) private static var sharedLayoutLRU: [LayoutCacheKey] = []
    private static let sharedLayoutCacheCap = 256
    nonisolated(unsafe) private static var sharedLayoutHits: Int = 0
    nonisolated(unsafe) private static var sharedLayoutMisses: Int = 0
    nonisolated(unsafe) private static var sharedLayoutLastFlush: CFAbsoluteTime = 0

    /// Stable content signature for the shared layout cache. Folds the full
    /// cell text + alignments + header-font size (layout depends on all three).
    private var layoutContentSignature: Int {
        var h = Hasher()
        h.combine(alignments)
        h.combine(theme.baseFontSize)
        for row in rows {
            for cell in row.cells { h.combine(cell.content.plainText) }
            h.combine(0x1E)  // row separator so cell regrouping changes the hash
        }
        return h.finalize()
    }

    /// Discard the cached layout so the next `computeLayout` / `attachmentBounds`
    /// recomputes column widths and row heights for whatever width is current.
    /// Called from `layoutSubviews` when the textContainer width changes
    /// (rotation, size-class change) — without it the table reuses the original
    /// portrait-width columns and the visible table frame stays at the old
    /// width on the new orientation.
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

        // HangFix(2026-05-13) — if we already have a cached layout at a
        // *different* width, return the cached totalHeight at the new
        // width. The typesetter explicitly asks for attachment bounds at
        // many slightly different proposed widths during fillLayoutHole;
        // every miss currently runs a full per-cell `NSAttributedString
        // boundingRect` measurement, and a 6-table cell can clock several
        // hundred ms per pass. When fillLayoutHole loops on width probing
        // those passes stack up into the 1+second hang the user sees
        // whenever a table is on screen. Returning the cached height at
        // any width-near-enough satisfies the typesetter cheaply —
        // visually identical because table content didn't change.
        //
        // The only path that *needs* a fresh measurement is when the
        // attachment's data (`rows`/`alignments`) has been mutated, which
        // we handle by setting `cachedLayout = nil` inside `update(...)`.
        if let cached = cachedLayout,!cached.columnWidths.isEmpty {
            // [RotationTableFix] Only reuse the cached column widths when
            // the requested width is "close enough" to the canonical cached
            // width — within 25%. This preserves the HangFix's typesetter-
            // probe optimisation (those probes are within a few points of
            // the real width) while ensuring a real rotation (portrait 397
            // → landscape 899 ≈ 2.2×) recomputes columns. Without this
            // bound, a table cached at portrait width keeps the narrow
            // columns when the bubble expands to landscape, so the table
            // visually stays at the old width even though the cell bubble
            // is now twice as wide.
            let canonical = cached.width
            let relDelta = abs(canonical-width)/max(canonical,1)
            if relDelta<0.25 {
                // Reuse: build a new TableLayout that pretends to be sized for
                // the requested width but shares row heights and column ratios
                // with the cached one. Don't persist — keep the canonical
                // cached version intact.
                return TableLayout(
                    width: width,
                    columnWidths: cached.columnWidths,
                    rowHeights: cached.rowHeights,
                    tableWidth: cached.tableWidth
                )
            }
            // Fall through to a fresh column/row computation below — the
            // cached columns are too narrow/wide for the new requested
            // width (a rotation has happened).
        }

        // [T-ios-attachbounds-cold-cache] Per-instance cachedLayout missed
        // (this is a freshly-built / recycled attachment). Before paying for a
        // full per-cell measurement, try the process-wide cache: an identical
        // table at this width measured by any earlier cell can be reused as-is.
        // computeLayout is a pure function of content+width, so this is safe.
        let sharedKey = Self.LayoutCacheKey(contentSig: layoutContentSignature,widthBucket: Int((width/4).rounded()))
        if let shared = Self.sharedLayoutCache[sharedKey] {
            Self.sharedLayoutHits &+= 1
            Self.flushSharedLayoutStatsIfNeeded()
            // Rebuild a layout at the exact requested width sharing the cached
            // column widths / row heights (width bucket folds ≤4pt jitter).
            let reused = TableLayout(width: width,columnWidths: shared.columnWidths,rowHeights: shared.rowHeights,tableWidth: shared.tableWidth)
            if persist {
                cachedLayout = reused
                Self.touchSharedLayoutLRU(sharedKey)
            }
            return reused
        }
        Self.sharedLayoutMisses &+= 1

        let colCount = alignments.count
        var columnWidths = [CGFloat](repeating: 80,count: colCount)

        // [TableColumnCap] Per-column soft maximum at 500% of available width.
        // Only wrap when a single column requests more than 5× the container
        // — typical tables stay on one line per row even when much wider than
        // the viewport (horizontal scroll handles overflow). Without any cap
        // a stray prose line misclassified as a continuation row could blow
        // the column up to tens of thousands of points. Tighter caps (100%,
        // 200%) caused well-formed tables to wrap and produce uneven row
        // heights — user feedback 2026-05-13.

        // Calculate column widths based on single-line content measurement
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

        // Calculate per-row heights based on text wrapping within column widths
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
            // Snapshot per-column max char counts so `update()` can detect
            // when streaming content grew wider than what was measured here.
            var maxChars = [Int](repeating: 0,count: colCount)
            for row in rows {
                for (ci,cell) in row.cells.enumerated() where ci<colCount {
                    maxChars[ci] = max(maxChars[ci],cell.content.plainText.count)
                }
            }
            cachedMaxCharPerCol = maxChars
            // [T-ios-attachbounds-cold-cache] Populate the process-wide cache
            // (only for real, persisted widths — never the 32_768 probe, which
            // computeLayout never persists) so the NEXT recycled cell showing
            // this same table at this width skips the measurement entirely.
            Self.storeSharedLayout(layout,key: sharedKey)
        }
        Self.flushSharedLayoutStatsIfNeeded()
        return layout
    }

    // MARK: - [T-ios-attachbounds-cold-cache] Shared layout cache helpers

    private static func touchSharedLayoutLRU(_ key: LayoutCacheKey) {
        if let pos = sharedLayoutLRU.firstIndex(of: key) { sharedLayoutLRU.remove(at: pos) }
        sharedLayoutLRU.append(key)
    }

    private static func storeSharedLayout(_ layout: TableLayout,key: LayoutCacheKey) {
        sharedLayoutCache[key] = layout
        touchSharedLayoutLRU(key)
        while sharedLayoutLRU.count>sharedLayoutCacheCap,let oldest = sharedLayoutLRU.first {
            sharedLayoutLRU.removeFirst()
            sharedLayoutCache.removeValue(forKey: oldest)
        }
    }

    /// [T-ios-attachbounds-cold-cache] 1Hz hit/miss summary so we can confirm
    /// the cold-cache storm is gone (high hit ratio during decel) without
    /// per-call log spam. DEBUG-only.
    private static func flushSharedLayoutStatsIfNeeded() {
        #if DEBUG
        let now = CACurrentMediaTime()
        guard now-sharedLayoutLastFlush>1.0,(sharedLayoutHits+sharedLayoutMisses)>0 else { return }
        AppLogger(category: "AttachBoundsHot").info("[SharedLayoutCache] last1s hits=\(sharedLayoutHits) misses=\(sharedLayoutMisses) size=\(sharedLayoutCache.count)/\(sharedLayoutCacheCap)")
        sharedLayoutHits = 0
        sharedLayoutMisses = 0
        sharedLayoutLastFlush = now
        #endif
    }

    override func attachmentBounds(for textContainer: NSTextContainer?,proposedLineFragment lineFrag: CGRect,glyphPosition position: CGPoint,characterIndex charIndex: Int) -> CGRect {
        // Use a slightly reduced width to prevent UIKit NSLayoutManager from
        // entering an infinite _fillLayoutHole loop when the attachment spans
        // the full line fragment width.  Also snap to 1pt grid so tiny floating-
        // point variations between layout passes hit the cached layout.
        let usableWidth = floor(lineFrag.width)-1
        guard usableWidth>0 else {
            return CGRect(x: 0,y: 0,width: lineFrag.width,height: Self.minRowHeight)
        }
        // [TableProbeFix] SwiftUI / UIHostingConfiguration's intrinsic-size
        // probing pass calls `attachmentBounds` with a synthesized lineFrag
        // width of `CGFloat.greatestFiniteMagnitude` (10_000_000pt). If we
        // cache the resulting layout — whose last column has been stretched
        // to fill ~10M points — the typesetter produces a glyph rect of
        // width 9_999_999 for the attachment, which then feeds `makeView`
        // and `refreshAttachViews`. Clamp to 32_768pt and don't persist
        // the probe layout so subsequent real-width measurements aren't
        // poisoned.
        let isOversizedProbe = lineFrag.width >= 100_000
        let clampedWidth = isOversizedProbe ? min(usableWidth,32_768) : usableWidth
        // [TableProbeHeightFix] The HEIGHT we return must reflect how the table
        // wraps at the REAL display width, not at the probe's 32_768pt. At 32_768
        // every column is wide enough that no cell wraps, so totalHeight collapses
        // to the single-line minimum — e.g. a 6-row table that is 238pt at the real
        // 369pt width measures only 218pt under the probe (one row's worth short).
        // SwiftUI's intrinsic-size probe consumes THIS returned height for the
        // cell's self-size, so on first appearance the table cell is laid out one
        // row too short and the bottom row is clipped until a scroll forces a
        // re-measure at the real width. Fix: on a probe, compute the height at a
        // realistic width, NOT the probe's 32_768pt. Width sources, in order:
        //   1. the real textContainer width — valid even during a probe (only the
        //      proposed lineFragment is synthesized to 10M, the container keeps its
        //      true width). This is the crucial first-appearance source: on the
        //      VERY first probe there is no cached layout yet, and the previous
        //      fallback (clampedWidth=32_768) still collapsed wrapping → one row
        //      short → the persistent "missing a row" the user still saw.
        //   2. the last real (non-probe) width we measured (cachedLayout).
        //   3. a conservative bubble-width cap as a last resort.
        // The RETURNED width stays the probe's clampedWidth so SwiftUI's max-width
        // discovery is unaffected. [ios_session_open_last_cell_occluded]
        let containerRealWidth: CGFloat? = {
            guard let w = textContainer?.size.width,w>0,w<100_000 else { return nil }
            return floor(w)-1
        }()
        let lastRealWidth = cachedLayout.map { $0.width }.flatMap { $0<100_000 ? $0 : nil }
        // Remember the narrowest real width this attachment has ever been asked
        // about, across instances — the first non-probe pass records it, and any
        // probe that races AHEAD of that pass (the first-appearance case where
        // cachedLayout is still nil and textContainer reports no usable width)
        // falls back to it. A narrower width can only ADD wrapping (taller table),
        // so erring narrow guarantees we never return a height that is one row too
        // short — at worst the first frame reserves a little extra space, which a
        // later real-width measure trims. The seed (380) is < any real chat bubble
        // width on phone or pad, so it is a safe "never clip" floor.
        // [ios_session_open_last_cell_occluded]
        if !isOversizedProbe,usableWidth>0 {
            Self.narrowestRealWidth = min(Self.narrowestRealWidth,usableWidth)
        }
        let heightWidth = isOversizedProbe
            ? (containerRealWidth ?? lastRealWidth ?? Self.narrowestRealWidth)
            : clampedWidth
        // TEMP(2026-05-13) — count attachmentBounds invocations + elapsed
        // time so a 1Hz hang on a 6-table cell shows up as e.g.
        // "[AttachBoundsHot] tables=6 calls=180 totalMs=850" — 6 tables ×
        // 30 calls/sec × ~4ms each. This pinpoints the typesetter feedback
        // loop: each fillLayoutHole inside `setFrame` re-asks every
        // attachment for its bounds, and our cache only helps when width
        // didn't change.
        let t0 = CACurrentMediaTime()
        // REPRO-DIAG(2026-05-16): record cache hit BEFORE the call (computeLayout
        // mutates cachedLayout on first miss, so we must check first).
        let _diagCacheHit = (cachedLayout?.width == heightWidth)
        // Persist only for genuine real-width measurements (never for a probe,
        // and never when we substituted a different width for height-only use).
        let layout = computeLayout(for: heightWidth,persist: !isOversizedProbe)
        let elapsed = CACurrentMediaTime()-t0
        Self.attachBoundsHotPath_record(elapsed: elapsed,cacheHit: _diagCacheHit,rows: rows.count,cols: alignments.count)
        let height = layout.totalHeight+Self.verticalMargin*2
        let returnWidth = isOversizedProbe ? clampedWidth : usableWidth
        return CGRect(x: 0,y: 0,width: returnWidth,height: height)
    }

    // TEMP(2026-05-13) — bucket per-second invocation counts for
    // attachmentBounds. Flushed when the 1Hz fillLayoutHole loop hits.
    nonisolated(unsafe) private static var hotCallCount: Int = 0
    nonisolated(unsafe) private static var hotTotalMs: Double = 0
    nonisolated(unsafe) private static var hotLastFlush: CFAbsoluteTime = 0
    // REPRO-DIAG(2026-05-16): finer-grained counters — cache hit/miss and
    // max single-call ms so we can tell whether each call is fast (cache hit)
    // or expensive (computeLayout cell measurement on every call).
    nonisolated(unsafe) private static var hotCacheHits: Int = 0
    nonisolated(unsafe) private static var hotCacheMisses: Int = 0
    nonisolated(unsafe) private static var hotMaxMs: Double = 0
    nonisolated(unsafe) private static var hotSlowEmittedThisSec: Int = 0
    static func attachBoundsHotPath_record(elapsed: CFTimeInterval,cacheHit: Bool = false,rows: Int = 0,cols: Int = 0) {
        hotCallCount &+= 1
        let ms = elapsed*1000
        hotTotalMs += ms
        if ms>hotMaxMs { hotMaxMs = ms }
        if cacheHit { hotCacheHits &+= 1 } else { hotCacheMisses &+= 1 }
        // REPRO-DIAG(2026-05-16): single-call slow path — anything ≥5ms is
        // unusual for cache-hit and worth investigating. Cap to 8 events/sec
        // so a true hang storm doesn't flood the log.
        if ms >= 5 && hotSlowEmittedThisSec<8 {
            hotSlowEmittedThisSec &+= 1
            LoggingManager.shared.writeRawLine(
                category: "AttachBoundsHot",
                level: "WARN",
                message: "[TEMP-DIAG][AttachBoundsSlow] ms=\(String(format: "%.2f", ms)) cacheHit=\(cacheHit) rows=\(rows) cols=\(cols)"
            )
        }
        let now = CFAbsoluteTimeGetCurrent()
        if now-hotLastFlush >= 1.0,hotCallCount>0 {
            // Emit when ≥20 calls OR ≥30ms cumulative in the last window.
            if hotCallCount >= 20 || hotTotalMs >= 30 {
                LoggingManager.shared.writeRawLine(
                    category: "AttachBoundsHot",
                    level: "WARN",
                    message: "[HangFix][AttachBoundsHot] TableAttachment.attachmentBounds calls=\(hotCallCount) totalMs=\(String(format: "%.1f", hotTotalMs)) avg=\(String(format: "%.2f", hotTotalMs / Double(hotCallCount)))ms max=\(String(format: "%.2f", hotMaxMs))ms hit=\(hotCacheHits) miss=\(hotCacheMisses) in last \(String(format: "%.1f", now - hotLastFlush))s"
                )
                LoggingManager.shared.flush()
            }
            hotCallCount = 0
            hotTotalMs = 0
            hotMaxMs = 0
            hotCacheHits = 0
            hotCacheMisses = 0
            hotSlowEmittedThisSec = 0
            hotLastFlush = now
        }
    }

    // MARK: - Inline rendering for table cells

    /// Renders an array of InlineNode into an NSAttributedString with proper styling
    /// (bold, italic, links, code, etc.) matching the project's standard link style.
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
            // [T-ios-table-inline-code-rounded] Mark inline code with BOTH the
            // custom `.inlineCodeBackground` flag (drives the rounded painter)
            // and the standard `.backgroundColor` (the rect range the painter
            // keys off). Two cell render paths consume this:
            //   - Link cells -> TableCellTextView, now backed by a
            //     MiniClawLayoutManager whose fillBackgroundRectArray draws the
            //     same rounded rect as body inline code (theme.inlineCodeCornerRadius=5).
            //   - Link-inert cells -> TableCellLabel, which has no layout
            //     manager; it strips `.backgroundColor` (to avoid the square
            //     fill) and paints the rounded background itself in drawText.
            // Both resolve miniClawInlineCodeBackgroundColor at draw time and
            // repaint on trait changes, so light/dark stay correct.
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
            // Render via MathAttachment so the formula appears as an inline
            // image. The attachment starts with a transparent 1×1 image;
            // MathRenderScheduler fills in `NSTextAttachment.image` on the
            // main queue (because `inlineDrawable = true`) and the hosting
            // cell view re-assigns its `attributedText` in `onLoad` so
            // UIKit redraws with the bitmap.
            let attach = MathAttachment(latex: latex,isBlock: false,theme: theme)
            attach.inlineDrawable = true
            let result = NSMutableAttributedString(attachment: attach)
            result.addAttribute(.font,value: font,range: NSRange(location: 0,length: result.length))
            return result
        }
    }

    /// Walks an attributed string and collects every `MathAttachment`
    /// it contains. Used to post-wire async `onLoad` refreshes after the
    /// cell view is created.
    private static func collectMathAttachments(in attrStr: NSAttributedString) -> [MathAttachment] {
        var out: [MathAttachment] = []
        attrStr.enumerateAttribute(.attachment,
                                   in: NSRange(location: 0,length: attrStr.length),
                                   options: []) { value,_,_ in
            if let math = value as? MathAttachment { out.append(math) }
        }
        return out
    }

    /// Kick off async rendering for every math attachment and arrange for
    /// `refresh` to fire once on the main queue after renders complete.
    /// Multiple onLoad callbacks are coalesced via a shared flag so hundreds
    /// of completions only trigger a single `refresh` per runloop tick.
    private static func wireMathAttachments(_ attachments: [MathAttachment],
                                            cellWidth: CGFloat,
                                            rowHeight: CGFloat,
                                            attrStr: NSAttributedString,
                                            refresh: @escaping @MainActor () -> Void) {
        guard !attachments.isEmpty else { return }
        // Box holding a pending-refresh flag shared by all attachments in
        // this cell. Captured by each onLoad closure.
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

    /// Whether an InlineNode tree contains any `.link` nodes.
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

    func makeView(width: CGFloat) -> UIView {
        let wrapper = UIView()
        wrapper.backgroundColor = .clear

        // CALayer.borderColor is a CGColor and CGColor doesn't track dynamic
        // UIColor traits — once we resolve `.cgColor`, it's frozen at the
        // light/dark mode that was active *at resolution time*. When this
        // attachment view is created off-window (typical for the first
        // streaming render of a table), the trait collection is the default
        // (light mode) and resolving `UIColor.label` at 25% alpha gives a
        // near-black border that disappears against the dark message
        // background. Re-entering the session creates the view while the
        // textView is on-window with the right trait collection, which is
        // why the border returns. Use a UIScrollView subclass that
        // re-applies the layer.borderColor in `traitCollectionDidChange`.
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

        // Build a closure that copies the entire table as tab-separated text.
        let copyTable: () -> Void = { [weak self] in
            guard let self else { return }
            UIPasteboard.general.string = self.plainText()
            // [T-toast-feedback] Confirm the copy succeeded.
            MiniClawToast.show(String(localized: "Table copied"))
        }

        // [T-ios-copy-table-image] Render the FULL table (all rows/cols, not
        // just the visible scroll region) to a PNG and put it on the pasteboard.
        // We snapshot the `stack` view — it lays out every row at the real
        // `tableWidth × stackHeight`, so long/wide tables come out complete.
        // Captured weakly to avoid retaining the view tree past its lifetime;
        // a fresh image-renderer draws its layer hierarchy at screen scale over
        // the resolved table background + rounded border.
        // No dedicated table-background in the theme; use the system background
        // so the copied image is legible (adapts to light/dark) behind the
        // cell text, which carries its own foreground colors.
        let tableBg = UIColor.systemBackground
        let tableBorder = theme.tableBorderColor
        let copyTableImage: () -> Void = { [weak stack] in
            guard let stack,stack.bounds.width>0,stack.bounds.height>0 else { return }

            // [T-ios-copy-table-image] Clear any active text selection first so
            // the snapshot doesn't capture the blue selection highlight. The
            // selection lives in a promoted TableCellTextView somewhere under
            // `stack`; walk the subtree, drop its selection, and force a synchronous
            // redraw before rendering.
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
            // Opaque + resolve the bg for the CURRENT light/dark trait so the
            // rounded corners (and any sub-pixel gaps) are filled with the right
            // color instead of leaving transparent corners that show white on a
            // light paste target.
            let bg = tableBg.resolvedColor(with: stack.traitCollection)
            let border = tableBorder.resolvedColor(with: stack.traitCollection)
            let fmt = UIGraphicsImageRendererFormat.default()
            fmt.opaque = true
            let renderer = UIGraphicsImageRenderer(bounds: bounds,format: fmt)
            let image = renderer.image { ctx in
                // Fill the ENTIRE rect (incl. the four corners outside the
                // rounded path) so there are no transparent/white corners.
                bg.setFill()
                ctx.fill(bounds)
                // Draw the table content (rows, cells, separators).
                stack.layer.render(in: ctx.cgContext)
                // Rounded outer border as visual chrome.
                let path = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.25,dy: 0.25),cornerRadius: 8)
                border.setStroke()
                path.lineWidth = 0.5
                path.stroke()
            }
            UIPasteboard.general.image = image
            // [T-toast-feedback] Confirm the image copy succeeded.
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

                // Detect tappable links and ensure they carry an `.link`
                // attribute on the rendered string. cmark-gfm autolink
                // usually upgrades bare URLs to `.link` nodes, but boundary
                // cases (URL adjacent to CJK characters, full-width
                // punctuation, table cell edges) can leave them as `.text`
                // — in which case the AST-based `containsLinks` returns
                // false AND there's no `.link` attribute in attrStr, so we
                // fall through to TableCellLabel (link-inert) and taps die.
                // Run NSDataDetector as a belt-and-suspenders pass to add
                // `.link` attributes for any URL the parser missed, then
                // route the cell to TableCellTextView so taps work.
                // [T-table-cell-link-bug 2026-05-25]
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
                        // Don't clobber an existing `.link` attribute (e.g.
                        // from a `[text](url)` node that happened to match).
                        if attrStr.attribute(.link,at: m.range.location,effectiveRange: nil) != nil {
                            continue
                        }
                        attrStr.addAttribute(.link,value: url,range: m.range)
                        attrStr.addAttribute(.foregroundColor,value: theme.linkColor,range: m.range)
                        attrStr.addAttribute(.underlineStyle,value: NSUnderlineStyle.single.rawValue,range: m.range)
                        hasLinks = true
                    }
                }

                // Collect math attachments so we can re-kick the cell's view
                // when the async SwiftMath render finishes. Without this the
                // cell shows a 1×1 transparent placeholder forever.
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

                // Vertical separator — full height to connect across rows
                if colIdx<colCount-1 {
                    let sep = UIView()
                    sep.backgroundColor = theme.tableBorderColor
                    sep.frame = CGRect(x: x+columnWidths[colIdx]-0.25,y: 0,width: 0.5,height: rowHeight)
                    rowView.addSubview(sep)
                }
                x += columnWidths[colIdx]
            }

            // Horizontal separator between all rows (bottom edge of each row except last)
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

        // Border — borderColor is re-applied by TableScrollView on every
        // traitCollectionDidChange via `borderColorProvider`, so dark-mode
        // hosts always get the right resolved color even when the view was
        // initially created off-window.
        scrollView.layer.cornerRadius = 8
        scrollView.layer.borderWidth = 0.5
        scrollView.applyBorderColorNow()
        scrollView.clipsToBounds = true

        wrapper.addSubview(scrollView)
        wrapper.frame = CGRect(x: 0,y: 0,width: width,height: stackHeight+Self.verticalMargin*2)

        // [T-ios-table-hscroll-offset-lost] Keep the attachment's persistent
        // offset in sync with every user-driven scroll on this view, then
        // restore it into the freshly-built view. Restore SYNCHRONOUSLY —
        // frame and contentSize are already final at this point — so a rapid
        // follow-up streaming rebuild reads the real position instead of a
        // transient 0 (the old consume-once + async-only restore lost the
        // offset exactly that way). The async re-clamp is belt-and-suspenders
        // for hosts that adjust bounds after attach. Never cleared: the next
        // rebuild needs the value again.
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

/// UIScrollView subclass that re-resolves its `layer.borderColor` whenever
/// the active trait collection changes. CGColor values frozen from a
/// dynamic UIColor at view-creation time would otherwise lock in whichever
/// appearance was active when the attachment was first laid out — typically
/// before the view enters the window, so light-mode `UIColor.label`
/// resolves and renders nearly invisible against a dark message background.
// MARK: - Audio Attachment

final class TableCellTextView: UITextView,UITextViewDelegate {
    var onOpenURL: ((URL) -> Void)?
    /// Called when the text view resigns first responder (selection dismissed).
    var onResignFirstResponder: (() -> Void)?
    /// Closure that copies the entire table. Set by TableCellLabel when promoting.
    var copyTableAction: (() -> Void)?
    /// [T-ios-copy-table-image] Closure that copies the full table as a PNG image.
    var copyTableImageAction: (() -> Void)?

    override init(frame: CGRect,textContainer: NSTextContainer?) {
        super.init(frame: frame,textContainer: textContainer)
        self.delegate = self
    }

    /// [T-ios-table-inline-code-rounded] TextKit1 stack backed by a
    /// MiniClawLayoutManager so inline-code spans (marked with
    /// `.inlineCodeBackground`) draw the same rounded background as body
    /// inline code via fillBackgroundRectArray. The default UITextView layout
    /// manager only paints square `.backgroundColor`.
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

    // [T-ios-table-cell-image-menu] iOS 16 ONLY: drop the system
    // UIContextMenuInteraction so a promoted table cell never pops the
    // "Copy Image" / "Save to Camera Roll" preview menu for the cell's inline
    // attachments. Same rationale as MarkdownTextView.addInteraction;
    // iOS 17+ keeps the (handled) system menu.
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

    func findCollectionView() -> NoAnimationCollectionView? {
        var view: UIView? = superview
        while let v = view {
            if let cv = v as? NoAnimationCollectionView { return cv }
            view = v.superview
        }
        return nil
    }

    // MARK: Edit menu — append "Copy Table" + "Add to Chat Input" alongside the standard items.

    override func canPerformAction(_ action: Selector,withSender sender: Any?) -> Bool {
        // Allow our own table commands first — copyTableImage's selector name
        // contains "image", so it must be whitelisted BEFORE the iOS-16 image
        // filter below or it would be swallowed.
        if action == #selector(copyTable) { return copyTableAction != nil }
        if action == #selector(copyTableImage) { return copyTableImageAction != nil }
        if action == #selector(addSelectionToChatInput(_:)) {
            return selectedRange.length>0
        }
        if action == #selector(readSelectedAloud) { return selectedRange.length>0 }
        if action == #selector(readAllAloud) { return !text.isEmpty }
        // Read-only: never offer edit actions. Also block system Speak
        // (we provide our own TTS via VoiceOutputPlayer).
        let blocked: Set<String> = ["paste:", "cut:", "delete:", "_addShortcut:",
                                     "_speak:", "_accessibilitySpeak:"]
        let actionName = NSStringFromSelector(action)
        if actionName.contains("speak") || actionName.contains("Speak") { return false }
        if blocked.contains(actionName) { return false }
        // iOS 16: a table cell that lays out an inline NSTextAttachment with a
        // transparent placeholder image makes UIKit add system "Copy Image" /
        // "Save to Camera Roll" / "Share Image" items — with a black preview,
        // since the placeholder is 1×1 transparent. Copying that is meaningless
        // (the real action is "Copy Table Image"). Filter the system image
        // selectors so only the text/table actions remain. iOS 17+ uses
        // UIEditMenuInteraction and doesn't surface these. Mirrors the same
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
    /// mirror `readReplyFromStart`'s pre-flight here: force the global
    /// read-replies switch ON (runtime state + persisted pref, un-muting if
    /// needed) and push "reading" to the capsule — via the active chat VM when
    /// one is registered, else directly on the global state object.
    static func activateReadAloudState() {
        let state = VoiceOutputState.shared
        if !state.isEnabled { state.isEnabled = true }   // didSet persists to prefs
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
    /// `chatInputAppendRequested` notification with the selected cell text.
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
        // Build ONE inline menu so the order is explicit and stable, then insert
        // it after the system edit menu. Desired order (top→bottom):
        //   Add to Chat Input  →  Copy Table  →  Copy Table Image
        // i.e. the high-frequency "Add to Chat Input" sits first, with the table
        // copy actions after it. [T-ios-copy-table-menu-order]
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
            // [T-ios-copy-table-image] Offer copying the whole table as an image.
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
        // TTS actions — read selected or read all via VoiceOutputPlayer.
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
        // Remove system Speak menu if present.
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

/// Lightweight UILabel used for table cells without links.
/// On long-press the label is swapped out for a UITextView so the user can select text,
/// then swapped back when the selection is dismissed — keeping the steady-state cost
/// at ~1-2 KB instead of ~35 KB per UITextView.
// MARK: - Code Block Attachment

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

        // Pre-load duration for display
        // Note: auto_play is NOT triggered here because InlineAudioController is
        // re-created every time the view renders (including when re-entering a
        // conversation). Auto-play on LLM response is handled by
        // MessageListModel.triggerAutoPlayAudio() which only fires once at the end
        // of streaming.
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

        // Subscribe to global player state on the main actor
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


// MARK: - Thematic Break Attachment

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

    /// Spacing controlled by RenderedBlock margins; no extra padding inside attachment
    static let verticalMargin: CGFloat = 0

    override func attachmentBounds(for textContainer: NSTextContainer?,proposedLineFragment lineFrag: CGRect,glyphPosition position: CGPoint,characterIndex charIndex: Int) -> CGRect {
        CGRect(x: 0,y: 0,width: lineFrag.width,height: 1+Self.verticalMargin*2)
    }

    func makeView(width: CGFloat) -> UIView {
        let totalHeight = 1+Self.verticalMargin*2
        let container = UIView(frame: CGRect(x: 0,y: 0,width: width,height: totalHeight))
        let line = UIView(frame: CGRect(x: 0,y: Self.verticalMargin,width: width,height: 1))
        line.backgroundColor = theme.secondaryLabelColor.withAlphaComponent(0.3)
        container.addSubview(line)
        return container
    }
}

// MARK: - Math Attachment

let nativeImageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "svg"]
final class CodeBlockAttachment: NSTextAttachment {
    var code: String
    let language: String?
    let theme: MarkdownTheme
    let quoteDepth: Int
    /// Sequential index for view reuse across re-renders (set by MarkdownNSRenderer).
    var blockIndex: Int = 0

    /// Left inset for blockquote nesting (matches text indent).
    var leftInset: CGFloat { CGFloat(quoteDepth)*13 }

    init(code: String,language: String?,theme: MarkdownTheme,quoteDepth: Int = 0) {
        self.code = code
        self.language = language
        self.theme = theme
        self.quoteDepth = quoteDepth
        super.init(data: nil,ofType: nil)
        // Provide a transparent image so UIKit doesn't draw a default placeholder
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
    /// for the button's lifetime (see makeView).
    nonisolated(unsafe) static var copyTapHandlerKey: UInt8 = 0

    /// Target object for the iOS 16 fallback tap gesture on the copy button —
    /// UITapGestureRecognizer needs an @objc target/action pair.
    final class CodeCopyTapHandler: NSObject,@unchecked Sendable {
        private let perform: () -> Void
        init(perform: @escaping () -> Void) { self.perform = perform }
        @objc func handleTap() { perform() }
    }

    /// Cached content height from sizeThatFits, keyed by code hash + width.
    private var cachedContentHeight: (hash: Int,height: CGFloat)?

    /// Measure actual code text height using the same approach as makeView.
    private func measureCodeBlockHeight() -> CGFloat {
        let codeHash = code.hashValue
        if let cached = cachedContentHeight,cached.hash == codeHash {
            return cached.height
        }
        let codeStyle = NSMutableParagraphStyle()
        codeStyle.lineSpacing = 4
        codeStyle.lineBreakMode = .byClipping
        let attrStr = NSAttributedString(string: code,attributes: [
            .font: theme.codeBlockFont,
            .paragraphStyle: codeStyle,
        ])
        let tv = UITextView()
        tv.isScrollEnabled = false
        tv.textContainerInset = UIEdgeInsets(top: 0,left: 8,bottom: 0,right: 8)
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.lineBreakMode = .byClipping
        tv.attributedText = attrStr
        let h = tv.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude,height: CGFloat.greatestFiniteMagnitude)).height
        cachedContentHeight = (hash: codeHash,height: h)
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

        // Language label
        if let language,!language.isEmpty {
            let langLabel = UILabel()
            langLabel.text = language.lowercased()
            langLabel.font = .systemFont(ofSize: 11,weight: .medium)
            langLabel.textColor = .white.withAlphaComponent(0.4)
            langLabel.frame = CGRect(x: 12,y: 8,width: contentWidth-60,height: 16)
            container.addSubview(langLabel)
            topOffset = 28
        }

        // Scrollable code area (own the pan gesture here for reliable horizontal scroll)
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

        // Measure content size (unconstrained width)
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

        // Auto-scroll to bottom during streaming
        let bottomY = scrollView.contentSize.height-scrollView.bounds.height
        if bottomY>0 {
            scrollView.contentOffset = CGPoint(x: 0,y: bottomY)
        }

        container.addSubview(scrollView)

        let totalHeight = topOffset+scrollHeight+bottomPadding
        container.frame = CGRect(x: inset,y: 0,width: contentWidth,height: totalHeight)

        // Copy button — 44x44 hit area per Apple HIG, icon stays small visually
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 9,weight: .medium)
        let copyButton = UIButton(type: .system)
        copyButton.setImage(UIImage(systemName: "doc.on.doc", withConfiguration: iconConfig), for: .normal)
        copyButton.tintColor = .white.withAlphaComponent(0.5)
        copyButton.frame = CGRect(x: contentWidth-44,y: 0,width: 44,height: 44)
        let performCopy: () -> Void = { [weak codeTextView,weak copyButton] in
            // Read directly from the UITextView so we always copy the latest
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
        // [T-ios16-codeblock-copy-regression] iOS 16 ONLY: also bind an
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

    /// Update the code text in an existing view created by `makeView(width:)` without recreating.
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

        // Recalculate heights to match attachmentBounds logic
        let topOffset: CGFloat = (language != nil && !language!.isEmpty) ? 28 : 12
        let maxCodeHeight: CGFloat = 400-topOffset-12
        let scrollHeight = min(fitting.height,maxCodeHeight)
        let bottomPadding: CGFloat = 12
        let newScrollFrame = CGRect(x: 0,y: topOffset,width: container.frame.width,height: scrollHeight+bottomPadding)
        let totalHeight = topOffset+scrollHeight+bottomPadding

        // [CodeBlockGrow] Animate the visible code-frame growing taller as more
        // lines stream in, instead of snapping. The wrapper's LOGICAL height is
        // set immediately (synchronously) because the caller reads
        // `view.frame.size.height` right after this returns to lay out the
        // TextKit attachment slot + the enclosing cell — animating that would
        // desync the code frame from the text flow. Only the wrapper's visible
        // children (the rounded background container + its scroll view) animate
        // their height, so the box smoothly extends while layout stays exact.
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

        // Auto-scroll to bottom during streaming
        let bottomY = scrollView.contentSize.height-scrollView.bounds.height
        if bottomY>0 {
            scrollView.contentOffset = CGPoint(x: scrollView.contentOffset.x,y: bottomY)
        }
    }
}

// MARK: - Table Attachment

