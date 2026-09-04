import SwiftUI

struct ReasoningBlockView: View {
    let text: String
    let isStreaming: Bool
    /// 受控展开状态（2026-08-09 提升到外层：展开状态须进 cell 高度缓存 key，
    /// 否则展开后 cell 高度不更新 → 内容溢出叠加/超出面板）。
    let isExpanded: Bool
    /// 用户是否手动操作过（开源参考实现 thinkingUserToggled）：手动后流式自动
    /// 展开/结束自动折叠全部失效。消息级路径由 MessageBubbleView @State 持有
    /// （cell 复用重建会重置，低风险：仅影响「流式中手动折叠后自动展开」的意图保持）；
    /// 块级路径仅承载非流式消息，无自动逻辑，默认 false。
    var isUserToggled: Bool = false
    var onToggle: (() -> Void)? = nil
    /// 用户手动点击回调（外层在此标记 isUserToggled）
    var onUserToggle: (() -> Void)? = nil

    /// 尾部窗口（开源参考实现 8000 字符，防超长思考渲染卡死 UI）
    private let windowSize = 8000

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                // 展开/折叠即时切换、无动画（2026-08-09：动画化 hosting 内容高度会让
                // flow layout 逐帧重排/塌陷；高度一步到位，由外层触发 cell 重配）。
                onUserToggle?()
                onToggle?()
            } label: {
                // 2026-09-02 唐唐拍板：与主会话 ThinkingBlockView 同款——
                // 图标 wand.and.stars(13 semibold)；去掉 Spacer，折叠态宽度随内容
                // 自适应（不再通栏长条）；字段顺序 图标/标题/字数/菊花/chevron 对齐主会话。
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.blue)
                    Text(String(localized: "deep_thinking_label"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.blue)
                    if !text.isEmpty {
                        Text(charCountText)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.blue.opacity(0.6))
                    }
                    if isStreaming {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.blue)
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.blue.opacity(0.5))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded, !text.isEmpty {
                // 展开内容：内嵌 ScrollView 上限 300pt（开源参考实现），超长只渲染尾部窗口
                let window = windowedText
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if window.isTruncated {
                            Text(String(format: String(localized: "showing_last_k_chars"), window.shownK, window.totalK))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 4)
                        }
                        Text(window.content)
                            .font(.system(size: 13))
                            .foregroundStyle(Color(.tertiaryLabel))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 10)
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .background(Color.blue.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.blue.opacity(0.15), lineWidth: 0.5)
        )
        // 2026-08-10 用户要求:思考块默认折叠、永不自动展开。
        // 仅保留「流式结束自动折叠」(用户手动展开过则尊重用户选择)。
        .onChange(of: isStreaming) { streaming in
            if !streaming, !isUserToggled, isExpanded {
                onToggle?()
            }
        }
        .onAppear {
            // 不再自动展开(用户要求默认折叠)
        }
    }

    private var charCountText: String {
        let c = text.count
        return c > 1000 ? "\(c / 1000)K" : "\(c)"
    }

    /// 尾部 8000 字符窗口；截断起点若落在行中则从下一行开始（避免切断中间行）
    private var windowedText: (content: String, isTruncated: Bool, shownK: Int, totalK: Int) {
        let total = text.count
        guard total > windowSize else { return (text, false, 0, 0) }
        var start = text.index(text.startIndex, offsetBy: total - windowSize)
        if start != text.startIndex {
            let prev = text.index(before: start)
            if text[prev] != "\n", let nl = text[start...].firstIndex(of: "\n") {
                start = text.index(after: nl)
            }
        }
        return (String(text[start...]), true, windowSize / 1000, total / 1000)
    }
}

// MARK: - 工具调用卡片（pill 风格）

/// 统一重试指示器：AI 输出位置显示「自动重试进行中 / 重试失败」。
/// 参考工具指示器骨架（灰底圆角 + 0.5pt 描边），但错误详情区更长（多行完整展示）；
/// 右侧为「立即重试」按钮——点击立即重试（重置 3s 计时），不点击保持自动重试频率。
/// 重试次数耗尽后按钮禁用，指示器保留最终错误。
