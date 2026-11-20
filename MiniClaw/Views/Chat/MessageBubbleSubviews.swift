import SwiftUI
import MiniClawKit

struct AttachmentCell: View {
    let path: String
    let onImageTap: ((URL) -> Void)?
    /// 所属会话 ID：把「attachments/<name>」相对路径解析为当前会话目录真实文件。
    let sessionID: UUID?

    private static let imageExts: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff"
    ]

    /// [2026-09-11 审计修复] 缩略图降采样缓存：body 每次求值都在主线程全尺寸解码
    /// （12MP 照片单次 ~100-300ms + 40-90MB 位图），滚动/流式刷新反复触发 → 掉帧 +
    /// 内存峰值。改为 ImageIO 缩略图（目标 400px ≈ 200pt@2x）+ 按 path 进程级缓存。
    private static let thumbCache = NSCache<NSString, UIImage>()

    private static func downsampledThumbnail(at path: String) -> UIImage? {
        if let cached = thumbCache.object(forKey: path as NSString) { return cached }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 400,
        ]
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let ui = UIImage(cgImage: cg)
        thumbCache.setObject(ui, forKey: path as NSString)
        return ui
    }

    private var isImage: Bool {
        AttachmentCell.imageExts.contains((path as NSString).pathExtension.lowercased())
    }

    /// 解析附件真实 URL：
    /// - 绝对路径且文件存在 → 直接使用（兼容旧数据 / 智能体落盘的绝对路径）；
    /// - 相对路径「attachments/<name>」→ 经当前会话目录解析（活动 Documents 路径，避免容器 UUID 变化失效）；
    /// - 都不命中 → 回退原路径，交由 UIImage 判定。
    private var resolvedURL: URL {
        if FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let sid = sessionID {
            let candidate = SessionFileRouter.shared.sessionHostDirectory(for: sid)
                .appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return URL(fileURLWithPath: path)
    }

    var body: some View {
        let url = resolvedURL
        if isImage, let ui = Self.downsampledThumbnail(at: url.path) {
            // 等比缩小：用紧贴图片真实宽高比的紧框（而非 200x200 letterbox），
            // 这样图片才会真正靠右、且圆角作用于图片本身而非透明外框。
            let cgW = max(ui.size.width, 1)
            let cgH = max(ui.size.height, 1)
            let ratio = min(200 / cgW, 200 / cgH)
            let w = cgW * ratio
            let h = cgH * ratio
            Image(uiImage: ui)
                .resizable()
                .frame(width: w, height: h)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
                .onTapGesture { onImageTap?(url) }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "doc.fill")
                    .foregroundStyle(.secondary)
                Text(url.lastPathComponent)
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
            }
            .padding(8)
            .frame(width: 110, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// 智能体消息底部状态行（已完成/已停止/已中断/回复中/已暂停 + 任务耗时）。
/// 数据全部来自落盘消息字段（块级拆分后独立渲染，非流式消息专用路径）。
struct AssistantStatusRow: View {
    let wasStopped: Bool
    let wasInterrupted: Bool
    let taskElapsedSeconds: Double?
    let isStreaming: Bool
    let isPaused: Bool
    /// 流式呼吸点（消息级路径传入；块级路径恒 false 不显示流式态）
    var replyDotDimmed: Bool = false
    /// 智能体名（开源参考实现 TypingIndicator 文案用）
    var agentName: String = "MiniClaw"

    @State private var dotDimmed = false
    /// 三点弹跳（开源参考实现对齐：easeInOut 0.4s 错峰 0.15s，offset -3↔1）

    var body: some View {
        // 反色外阴影（2026-09-07 全局强制）：状态行与图标浮在可换背景上
        // （背景图主题下看不清），与正文同款光晕塔，见 LegibleTextShadow。
        statusContent.legibleTextShadow()
    }

    @ViewBuilder
    private var statusContent: some View {
        if isPaused {
            HStack(spacing: 5) {
                Image(systemName: "pause.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color(red: 0.098, green: 0.549, blue: 0.996))
                Text(String(localized: "paused"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        } else if isStreaming {
            // 2026-09-05 TopFlow定稿：与主会话统一——黄色圆内绿色呼吸点 +「回复中」。
            HStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(Color.yellow)
                        .frame(width: 10, height: 10)
                    Circle()
                        .fill(Color.green)
                        .frame(width: 4, height: 4)
                        .opacity(replyDotDimmed ? 0.2 : 1)
                }
                Text(String(localized: "replying"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        } else if wasStopped {
            HStack(spacing: 5) {
                Image(systemName: "stop.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text(String(localized: "stopped"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                elapsedSuffix
            }
            .padding(.top, 2)
        } else if wasInterrupted {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Text(String(localized: "interrupted"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                elapsedSuffix
            }
            .padding(.top, 2)
        } else {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text(String(localized: "completed"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                elapsedSuffix
            }
            .padding(.top, 2)
        }
    }

    /// 任务总耗时后缀：23s / 12m23s / 1h2m3s（断点恢复/旧消息无字段不显示）。
    @ViewBuilder
    private var elapsedSuffix: some View {
        if let et = Self.elapsedText(taskElapsedSeconds) {
            Text(" · \(et)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private static func elapsedText(_ seconds: Double?) -> String? {
        guard let s = seconds, s >= 1 else { return nil }
        let t = Int(s.rounded())
        let h = t / 3600
        let m = (t % 3600) / 60
        let sec = t % 60
        if h > 0 { return "\(h)h\(m)m\(sec)s" }
        if m > 0 { return "\(m)m\(sec)s" }
        return "\(sec)s"
    }
}

