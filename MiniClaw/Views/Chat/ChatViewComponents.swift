import Foundation
import SwiftUI
import MiniClawKit
import UIKit
import QuickLook
import AVKit

struct FullscreenImageItem: Identifiable, Equatable {
    let url: URL
    var id: String { url.absoluteString }
}

/// 2026-08-12:长按菜单通知监听(「添加到输入框」/「从这里重跑」)。
/// 独立 modifier 承载——直接挂 ChatView body 会触发 type-check 超时。
struct ChatMenuListeners: ViewModifier {
    let onAppend: (String) -> Void
    let onRerun: (UUID) -> Void

    func body(content: Content) -> some View {
        content
            // 通知名字符串与 Kit(AssistantBlockView.swift) 的
            // chatInputAppendRequested / rerunFromToolBlock 常量同值;
            // Kit 常量是 internal,宿主无法引用,这里用字面量构造同名通知。
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("chatInputAppendRequested"))) { note in
                guard let text = note.userInfo?["text"] as? String else {
                    // 运行时打点(2026-08-13):通知到达但 userInfo 缺失 text。
                    AppLogger.shared.warn("ChatMenuListeners: 收到 chatInputAppendRequested 但 userInfo 无 text", category: "ChatInputInject")
                    return
                }
                // 运行时打点(2026-08-13):宿主收到「添加到输入框」通知。
                onAppend(text)
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("rerunFromToolBlock"))) { note in
                guard let blockId = note.userInfo?["blockId"] as? UUID else { return }
                onRerun(blockId)
            }
    }
}

/// 系统共享面板(UIActivityViewController)——「分享」按钮接入的系统自带共享功能。
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// 可缩放图片视图(UIScrollView + UIImageView):
/// - 双指捏合放大(pinch zoom)
/// - 双击恢复适合屏幕尺寸(已放大时);双击放大 2x(适合屏幕尺寸时)
struct PreviewZoomableImageView: UIViewRepresentable {
    let image: UIImage
    /// 缩放状态变化回调:zoomScale > 1 时 true(用于关闭下滑关闭手势)。
    var onZoomChange: ((Bool) -> Void)? = nil

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.decelerationRate = .fast
        scrollView.bouncesZoom = true

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.onZoomChange = onZoomChange
        return coordinator
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        var onZoomChange: ((Bool) -> Void)?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            onZoomChange?(scrollView.zoomScale > 1.0)
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                // 双击恢复适合屏幕尺寸
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let rect = PreviewZoomableImageView.zoomRect(forScale: 2.0,
                                                      center: gesture.location(in: gesture.view),
                                                      in: scrollView)
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }

    private static func zoomRect(forScale scale: CGFloat, center: CGPoint, in scrollView: UIScrollView) -> CGRect {
        var rect = CGRect.zero
        rect.size.width = scrollView.frame.size.width / scale
        rect.size.height = scrollView.frame.size.height / scale
        rect.origin.x = center.x - rect.size.width / 2
        rect.origin.y = center.y - rect.size.height / 2
        return rect
    }
}


/// 上下文占用圆环：随实时占用比例变色，中心显示占用百分比数字（无 % 符号）。
/// 变色档位与「真正的压缩触发点」严格同源——红色起点 = 引擎分档策略的 compactThreshold，
/// 所以圆环变红那一刻就是引擎会压缩历史的那一刻（大窗口模型阈值可能是 88% 而非 80%）。
/// 点击进入 词元 用量详情。放置于会话页右上角菜单左侧。
struct ContextRingIndicator: View {
    let ratio: Double
    /// 当前模型/端点未配置上下文窗口时为 true，显示「∞ 无限制」而非误导性的假 0。
    var unlimited: Bool = false
    /// 压缩触发点在环上的位置（0...1）。红色从此处开始，黄色为其前 20% 区间。
    var thresholdRatio: Double = 0.8
    /// 占用是否来自服务商真实 prompt_tokens（false = 本地估算，数字用次级色）。
    var measured: Bool = true

    private var color: Color {
        let r = min(1, max(0, ratio))
        let danger = min(0.99, max(0.1, thresholdRatio))
        let warn = danger * 0.8
        if r < warn { return .green }
        if r < danger { return .yellow }
        return .red
    }

    var body: some View {
        ZStack {
            // 圆底与右上角选项按钮同色（secondarySystemBackground），视觉上成为一组按钮。
            Circle()
                .fill(Color(.secondarySystemBackground))
            Circle()
                .stroke(Color(.tertiarySystemBackground), lineWidth: 2.5)
            if unlimited {
                // 无限制：画一段灰色弧线表示「未设上限」，而不是 0%。
                Circle()
                    .trim(from: 0, to: 0.85)
                    .stroke(Color(.tertiaryLabel), lineWidth: 2.5)
                    .rotationEffect(.degrees(-90))
            } else {
                // 压缩触发点刻度：一小段灰线标出「到这里就会压缩」。
                Circle()
                    .trim(from: CGFloat(min(0.99, max(0.1, thresholdRatio))),
                          to: CGFloat(min(1.0, max(0.1, thresholdRatio) + 0.012)))
                    .stroke(Color(.tertiaryLabel), lineWidth: 4)
                    .rotationEffect(.degrees(-90))
                Circle()
                    .trim(from: 0, to: CGFloat(min(1, max(0, ratio))))
                    .stroke(color, lineWidth: 2.5)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.35), value: ratio)
            }
            // 只显示占用百分比数字（居中、粗体），不再叠加缓存闪电等附加信息。
            Text(unlimited ? "∞" : "\(Int(min(1, max(0, ratio)) * 100))")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(measured ? .primary : .secondary)
        }
        .frame(width: 27, height: 27)
        .contentShape(Circle())
        .accessibilityLabel(unlimited ? L10n.l("unlimited_context_window") : L10n.l("context_usage_format") + String(format: "%d%%", Int(ratio * 100)))
    }
}

// MARK: - 排队消息虚线气泡

/// 排队中的用户消息气泡：右对齐、虚线边框，右侧带删除按钮，持续展示直到被处理或删除。
struct PendingMessageBubble: View {
    let text: String
    var onSend: () -> Void
    var onDelete: () -> Void

    private let accent = Color(red: 0.098, green: 0.549, blue: 0.996)

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            // 左：发送按钮（停止当前生成并立即处理这条）；中：虚线气泡；右：删除按钮。
            // 三者同层、垂直居中对齐；删除按钮只相对气泡居中，不随下方「排队中」文字下移。
            HStack(alignment: .center, spacing: 8) {
                Button(action: onSend) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(accent)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Text(text)
                    .foregroundStyle(accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(
                                accent.opacity(0.75),
                                style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                            )
                    )

                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 3) {
                Image(systemName: "hourglass")
                    .font(.system(size: 9))
                Text(L10n.l("queued_tap_the_left_button_to_stop_and_send_immediately"))
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

// MARK: - 未接入模型提示横幅（2026-08-09 抽为独立视图，供消息列表 banner cell 使用）

struct ModelWarningBannerView: View {
    let onConfigure: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)
                Text(L10n.l("no_model_connected"))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
            }

            Text(L10n.l("connect_a_model_first_to_start_chatting_go_to_providers_add_one_and_fill_in_the_api_key"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onConfigure) {
                HStack(spacing: 6) {
                    Text(L10n.l("go_to_configure_models"))
                        .fontWeight(.medium)
                    Image(systemName: "arrow.up.right.square")
                }
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(.orange)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

