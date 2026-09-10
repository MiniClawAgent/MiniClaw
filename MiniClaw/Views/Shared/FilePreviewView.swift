import SwiftUI
import AVKit
import PDFKit

// MARK: - Media Type

/// 文件媒体类型：文件预览 / 分享入口共用。
enum MediaType { case image, video, audio, code, pdf, office, html, file }

extension MediaType {
    /// 扩展名判定（**单一事实来源**）：文件预览入口共用，避免多处扩展名列表漂移。
    /// 先剥离查询参数 / fragment 再取扩展名（URL 可能带 ?x=1 等后缀）；
    /// nil = 未识别的通用文件（epub/zip 等按文件卡片处理，不再误判为图片）。
    nonisolated static func classify(url urlString: String) -> MediaType? {
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
}

// MARK: - File Preview (code / PDF / Office)

/// 统一文件预览容器（文件管理器 / 会话内文件卡片共用入口）。
/// 按类型分派到统一查看器，所有类型共用：sheet 下滑关闭 + 导航栏文件名 + 右上角分享按钮。
/// 类型判定与文件预览共用同一来源（MediaType.classify(url:)），不再各自维护清单。
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
        let rawType = MediaType.classify(url: fileURL.absoluteString) ?? .file
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
                Text(String(localized: "file_too_large_truncated_for_preview"))
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
            Text(String(localized: "content_preview_is_not_supported_for_this_type_use_the_share_button_in_the_top_right_to_export"))
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
