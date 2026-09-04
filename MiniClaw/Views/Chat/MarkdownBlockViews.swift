@preconcurrency import SwiftUI
import AVKit
import PDFKit

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

    /// 代码块配色固定跟随系统外观（2026-09-05 移除 codeBlockTheme 设置项）。
    /// auto = 亮色黑底绿字 / 深色 15% 白底浅绿字（原灰底单色）。
    private var codeBackground: Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.15, alpha: 1) : .black })
    }
    private var codeForeground: Color {
        Color(UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(red: 0.55, green: 0.95, blue: 0.55, alpha: 1)
            : .systemGreen })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header（开源参考实现对齐：无语言标签，仅右上角复制按钮）
            HStack {
                Spacer()

                Button(action: copyCode) {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        Text(isCopied ? String(localized: "copied") : String(localized: "copy_action"))
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
        let rawType = MarkdownParser.classifyMediaType(fileURL.absoluteString) ?? .file
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

// MARK: - 容器宽度上报

/// MarkdownContentView 容器宽度（供图片等固定限宽内容自适应，防右侧溢出被气泡裁剪）。
struct MarkdownContainerWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

