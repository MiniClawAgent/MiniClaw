import SwiftUI

struct SessionRowView: View {
    /// 观察会话对象(2026-08-12 修复)：AI 生成标题/改图标/updatedAt 是成员对象原地改值,
    /// 不触发首页数组 willSet——行必须订阅对象本身才能实时刷新标题。
    @ObservedObject var session: ChatSession
    /// 搜索关键字（非空时高亮命中，并在命中消息内容时显示匹配片段）
    var highlight: String = ""
    /// 是否处于多选模式（决定左侧图标区替换为勾选圆）
    var selectionMode: Bool = false
    /// 当前会话是否已被选中
    var isSelected: Bool = false
    /// 任务是否「未完成（暂停/中断、可续跑）」：驱动图标外圈橙色边框徽标。
    var isIncomplete: Bool = false
    /// 草稿刷新令牌（2026-08-13）：首页监听 pendingDraftDidChange 后递增并传入，
    /// 使 hasDraft 即时重算——异步落盘的草稿删除完成后笔图标立即消失，不再残留。
    var draftRefreshID: Int = 0

    var body: some View {
        // 引用草稿刷新令牌：参数变化强制本行重算 hasDraft（读时计算）。
        let _ = draftRefreshID
        // 显示标题：默认占位标题（"新会话"）走 i18n（存量数据为中文默认值，显示层兜底本地化）。
        let displayTitle = (session.title == "NewChat") ? L10n.l("new_chat_title") : session.title
        HStack(spacing: 12) {
            leadingView

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    (highlight.isEmpty
                        ? Text(displayTitle)
                        : highlightedText(displayTitle, keyword: highlight))
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    Spacer()

                    Text(session.updatedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    if hasDraft {
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    // 搜索时直接在这一行高亮命中文字（优先展示命中的那条消息内容）
                    (highlight.isEmpty
                        ? Text(displayContent)
                        : highlightedText(displayContent, keyword: highlight))
                        // 2026-08-09 字体适配：14pt 基准随系统动态字体缩放（原硬编码 14 不跟随）
                        .font(.system(size: UIFontMetrics.default.scaledValue(for: 14)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)

                    messageCountBadge
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        )
    }

    /// 多选模式时左侧图标区替换为圆形勾选框；否则沿用原会话图标。
    @ViewBuilder
    private var leadingView: some View {
        if selectionMode {
            ZStack {
                Circle()
                    .fill(isSelected ? Color(red: 0.098, green: 0.549, blue: 0.996) : Color.clear)
                    .frame(width: 42, height: 42)
                    .overlay(
                        Circle()
                            .stroke(isSelected ? Color.clear : Color.secondary.opacity(0.5), lineWidth: 1.5)
                    )
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .accessibilityHidden(true)
        } else {
            sessionIcon
        }
    }

    private var sessionIcon: some View {
        // 优先使用 智能体生成的图标配色（与会话主题匹配、已持久化故重进不乱跳）；
        // 配色解析兼容 hex / rgb() / hsl()（任意空白与 #），并拒绝纯黑/纯白（深/浅背景均不可见）。
        // 智能体未提供、或给了黑/白/非法色时，按会话 ID 确定性落「多样兜底调色板」（而非千篇一律的蓝）。
        let accent = session.iconColor
            .flatMap { sanitizeSessionIconColor($0) }
            .flatMap { Color(hex: $0) } ?? Self.fallbackSessionIconColor(for: session.id)
        let symbol = SessionRowView.validSymbol(session.iconName)
        return Circle()
            .fill(accent.opacity(0.2))
            .frame(width: 42, height: 42)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .overlay {
                // 转圈只负责绘制，不参与布局尺寸计算；运行/空闲时头像占位始终为 42×42，
                // 避免 48×48 外圈把运行中的整排内容向右推 3pt。
                // 优先级：未完成（暂停/中断、可续跑）> 进行中。两者互斥显示。
                // 橙色静态环与 RotatingRing 同尺寸（48×48、lineWidth 2.5），仅颜色/动效不同，
                // 表示该会话「上次回复未跑完、可继续」。
                // 2026-08-12 治本:session.status == .paused 直接显示橙环,与检查点双保险
                // (重启后检查点存在但 reload 未触发时,首页也能正确显示暂停态而非转圈)。
                if isIncomplete || session.status == .paused {
                    Circle()
                        .stroke(Color.orange, lineWidth: 2.5)
                        .frame(width: 48, height: 48)
                } else if isActive {
                    RotatingRing(color: accent)
                }
            }
            .accessibilityHidden(true)
    }

    /// 多样兜底调色板：智能体未提供配色、或给的是黑/白/非法色时，按会话 ID 确定性取色，
    /// 让不同会话尽量落到不同颜色（而非千篇一律的蓝）。均为中高饱和、作 0.2 透明底色或
    /// 整色前景符号在浅色背景上都够明显的颜色。
    private static let iconColorPalette: [Color] = [
        Color(hex: "#FA5252")!, Color(hex: "#FD7E14")!, Color(hex: "#FAB005")!,
        Color(hex: "#94D82D")!, Color(hex: "#51CF66")!, Color(hex: "#20C997")!,
        Color(hex: "#22B8CF")!, Color(hex: "#339AF0")!, Color(hex: "#5C7CFA")!,
        Color(hex: "#7950F2")!, Color(hex: "#BE4BDB")!, Color(hex: "#F06595")!,
    ]

    /// 按会话 ID 确定性取兜底色（保证可复现、同一会话始终同色，且不同会话尽量分散）。
    private static func fallbackSessionIconColor(for id: UUID) -> Color {
        // ⚠️ 不可用 String.hashValue——Swift 的 hashValue 每次进程启动随机化种子，
        // 同一字符串每次启动结果都不同（唐唐反馈：兜底色每次打开 App 重排）。
        // 改用 UUID 的稳定 16 字节（id.uuid）做多项式哈希，跨启动确定性一致。
        var sum = 0
        withUnsafeBytes(of: id.uuid) { raw in
            for byte in raw { sum = (sum &* 31 &+ Int(byte)) }
        }
        let idx = abs(sum) % iconColorPalette.count
        return iconColorPalette[idx]
    }

    private var isActive: Bool {
        session.status == .running || session.status == .retrying
    }

    /// 该会话是否存在尚未发送的草稿（由 ChatView 落盘的 PendingMessageStore 草稿文件判断）。
    /// 存在时会在标题下方的 智能体回复区前显示一个橙色编辑图标，提示用户还在编辑。
    private var hasDraft: Bool {
        (PendingMessageStore.shared.loadDraft(for: session.id) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
    }

    private var messageCountBadge: some View {
        let count = session.messages.count
        return Text("\(count)")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .frame(minWidth: 20, minHeight: 20)
            .padding(.horizontal, count >= 10 ? 5 : 0)
            .background(Color.secondary.opacity(0.12))
            .clipShape(Capsule())
            .accessibilityLabel(String(format: L10n.l("messages"), NSNumber(value: count)))
    }

    /// SwiftData 关系数组不保证顺序，因此显式筛选并按 createdAt 取最后一条 智能体回复。
    /// 正文优先取 `previewText`（最终轮答复，2026-08 起落库）——避免工具循环场景下
    /// 显示整轮拼接 content 开头的过程叙述（「第一轮循环的中间回复」）；旧数据无 previewText
    /// 时回退 `content`。取到正文后再剥掉开头的思考包裹块（个别思考模型把 thinking 直接吐进
    /// content 字段），保证片段始终「从回复的正文开始显示」。
    private var lastAssistantContent: String {
        guard let last = session.messages
            .filter({ $0.role == .assistant })
            .max(by: {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            })
        else { return L10n.l("no_agent_reply_yet") }

        let preferred = last.previewText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body = !preferred.isEmpty
            ? preferred
            : last.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return L10n.l("no_agent_reply_yet") }
        return Self.stripLeadingThinking(body)
    }

    /// 剥掉正文开头的思考包裹块：`<think>…</think>`、`<thinking>…</thinking>`、
    /// `【思考】…【/思考】`、`【深度思考】…`（常不带闭标签）等。仅匹配已知标记，
    /// 正文干净时不误删；剥到只剩思考（无正文）时回退占位文案。
    private static func stripLeadingThinking(_ text: String) -> String {
        var result = text
        // 反复剥开头的成对/不成对思考标记，直到开头不再是思考块。
        while true {
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("<think>") {
                if let end = trimmed.range(of: "</think>") {
                    result = String(trimmed[end.upperBound...]); continue
                }
                return L10n.l("no_agent_reply_yet")
            }
            if trimmed.hasPrefix("<thinking>") {
                if let end = trimmed.range(of: "</thinking>") {
                    result = String(trimmed[end.upperBound...]); continue
                }
                return L10n.l("no_agent_reply_yet")
            }
            if trimmed.hasPrefix("【思考】") {
                if let end = trimmed.range(of: "【/思考】") {
                    result = String(trimmed[end.upperBound...]); continue
                }
                return L10n.l("no_agent_reply_yet")
            }
            if trimmed.hasPrefix("【深度思考】") {
                // 该标记常不带闭标签：直接去掉标记前缀，剩下的若仅为思考残留则清空。
                let rest = String(trimmed.dropFirst("【深度思考】".count))
                if rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return L10n.l("no_agent_reply_yet")
                }
                result = rest
                continue
            }
            break
        }
        let final = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return final.isEmpty ? L10n.l("no_agent_reply_yet") : final
    }

    /// 搜索时该行小字展示的内容：优先取「第一个命中关键字的消息」内容并就地高亮；
    /// 否则回退到最新的 智能体回复。避免再单独开一行片段。
    private var displayContent: String {
        guard !highlight.isEmpty else { return lastAssistantContent }
        let matched = session.messages
            .first(where: { $0.content.localizedCaseInsensitiveContains(highlight) })?
            .content
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let matched, !matched.isEmpty {
            return matched
        }
        return lastAssistantContent
    }

    /// 校验 SF Symbol 名称是否有效；无效（或 macOS 无 UIKit）时回退默认图标，避免渲染空白/崩溃。
    static func validSymbol(_ name: String) -> String {
        #if canImport(UIKit)
        return UIImage(systemName: name) != nil ? name : ChatSession.defaultIcon
        #else
        return name
        #endif
    }

    private struct RotatingRing: View {
        let color: Color
        @State private var rotation: Double = 0

        var body: some View {
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: 48, height: 48)
                .rotationEffect(.degrees(rotation))
                .onAppear {
                    withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                        rotation = 360
                    }
                }
        }
    }

    // MARK: - 搜索高亮

    /// 将 text 中(不区分大小写)命中 keyword 的部分高亮（主色 + 浅色底），其余原样。
    private func highlightedText(_ text: String, keyword: String) -> Text {
        guard !keyword.isEmpty else { return Text(text) }
        var result = AttributedString()
        var remaining = Substring(text)
        while let range = remaining.range(of: keyword, options: .caseInsensitive) {
            if range.lowerBound > remaining.startIndex {
                result.append(AttributedString(String(remaining[..<range.lowerBound])))
            }
            var match = AttributedString(String(remaining[range]))
            match.foregroundColor = Color.accentColor
            match.backgroundColor = Color.accentColor.opacity(0.15)
            result.append(match)
            remaining = remaining[range.upperBound...]
        }
        if !remaining.isEmpty {
            result.append(AttributedString(String(remaining)))
        }
        return Text(result)
    }
}

// MARK: - 十六进制颜色解析（会话图标配色）

extension Color {
    /// 从十六进制字符串构造颜色，支持 #RGB / #RRGGBB / #RRGGBBAA。
    /// 非法格式返回 nil（调用方据此回退默认配色）。
    init?(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        var rgb: UInt64 = 0
        guard Scanner(string: h).scanHexInt64(&rgb) else { return nil }
        switch h.count {
        case 6:
            self.init(.sRGB,
                      red: Double((rgb & 0xFF0000) >> 16) / 255,
                      green: Double((rgb & 0x00FF00) >> 8) / 255,
                      blue: Double(rgb & 0x0000FF) / 255,
                      opacity: 1)
        case 3:
            let r = Double((rgb & 0xF00) >> 8) / 15
            let g = Double((rgb & 0x0F0) >> 4) / 15
            let b = Double(rgb & 0x00F) / 15
            self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
        case 8:
            self.init(.sRGB,
                      red: Double((rgb & 0xFF000000) >> 24) / 255,
                      green: Double((rgb & 0x00FF0000) >> 16) / 255,
                      blue: Double((rgb & 0x0000FF00) >> 8) / 255,
                      opacity: Double(rgb & 0x000000FF) / 255)
        default:
            return nil
        }
    }
}

// MARK: - 会话图标配色清理与解析

/// 校验并清理会话图标配色：先归一化为标准十六进制（兼容 hex / rgb() / hsl() / 带空格 / 带 #），
/// 再拒绝接近纯黑 / 纯白的不可见色。合法彩色返回规范十六进制；否则返回 nil（调用方据此走多样兜底调色板）。
///
/// 设计意图：允许 智能体选取除黑白以外的任何颜色；当 智能体给的是黑 / 白或非法串时不强落单一蓝，
/// 而是交回「按会话 ID 取色的兜底调色板」，从而每个会话尽量不同色。
func sanitizeSessionIconColor(_ raw: String) -> String? {
    guard let hex = normalizeSessionIconColor(raw) else { return nil }
    guard let (r, g, b) = rgbComponents(from: hex) else { return nil }
    // 接近纯黑（各通道均 ≤ 0.04 ≈ #0A0A0A）或接近纯白（各通道均 ≥ 0.96 ≈ #F5F5F5）
    // 在深 / 浅背景下都会不可见，拒绝使用。
    let nearBlack = r <= 0.04 && g <= 0.04 && b <= 0.04
    let nearWhite = r >= 0.96 && g >= 0.96 && b >= 0.96
    guard !nearBlack, !nearWhite else { return nil }
    return hex
}

/// 将任意颜色字符串归一化为标准六位十六进制（#RRGGBB）。依次尝试：
/// 1. 十六进制：#RGB / #RRGGBB / #RRGGBBAA（忽略 alpha）/ 带或不带 # / 前后空白
/// 2. 函数式 rgb() / rgba()（0–255 或 0–1 均可）
/// 3. 函数式 hsl() / hsla()（h 取度数，s/l 可为百分号或小数）
/// 全部失败返回 nil。
func normalizeSessionIconColor(_ raw: String) -> String? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return nil }
    if let hex = parseHexColor(s) { return hex }
    if let hex = parseRGBColor(s) { return hex }
    if let hex = parseHSLColor(s) { return hex }
    return nil
}

private func parseHexColor(_ s: String) -> String? {
    let h = s.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
    var v: UInt64 = 0
    guard Scanner(string: h).scanHexInt64(&v) else { return nil }
    switch h.count {
    case 3:
        let r = (v & 0xF00) >> 8, g = (v & 0x0F0) >> 4, b = v & 0x00F
        return String(format: "#%02X%02X%02X", Int(r) * 17, Int(g) * 17, Int(b) * 17)
    case 6:
        return String(format: "#%06X", UInt32(v))
    case 8:
        let r = (v & 0xFF000000) >> 24
        let g = (v & 0x00FF0000) >> 16
        let b = (v & 0x0000FF00) >> 8
        return String(format: "#%02X%02X%02X", Int(r), Int(g), Int(b))
    default:
        return nil
    }
}

private func parseRGBColor(_ s: String) -> String? {
    let pattern = #"rgba?\(\s*([\d.]+)\s*[, ]\s*([\d.]+)\s*[, ]\s*([\d.]+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
          let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
          let rR = Range(m.range(at: 1), in: s),
          let gR = Range(m.range(at: 2), in: s),
          let bR = Range(m.range(at: 3), in: s),
          let r = Double(s[rR]), let g = Double(s[gR]), let b = Double(s[bR])
    else { return nil }
    // 任一通道 > 1 视为 0–255 区间，否则视为 0–1 小数。
    let scale = (r > 1 || g > 1 || b > 1) ? 255.0 : 1.0
    return clampHex(r / scale, g / scale, b / scale)
}

private func parseHSLColor(_ s: String) -> String? {
    let pattern = #"hsla?\(\s*([\d.]+)\s*[, ]\s*([\d.]+)\s*%?\s*[, ]\s*([\d.]+)\s*%?"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
          let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
          let hR = Range(m.range(at: 1), in: s),
          let sR = Range(m.range(at: 2), in: s),
          let lR = Range(m.range(at: 3), in: s),
          let h = Double(s[hR]), let ss = Double(s[sR]), let l = Double(s[lR])
    else { return nil }
    // s/l 可能以「80%」或「0.8」出现：> 1 视为百分数。
    let sNorm = ss > 1 ? ss / 100 : ss
    let lNorm = l > 1 ? l / 100 : l
    return hslToHex(h: h, s: sNorm, l: lNorm)
}

private func clampHex(_ r: Double, _ g: Double, _ b: Double) -> String {
    func c(_ v: Double) -> Int { max(0, min(255, Int(round(v * 255)))) }
    return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
}

/// HSL（h: 度数 0–360，s/l: 0–1）→ 标准十六进制。
private func hslToHex(h: Double, s: Double, l: Double) -> String {
    let c = (1 - abs(2 * l - 1)) * s
    let hp = h.truncatingRemainder(dividingBy: 360) / 60
    let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
    let (r1, g1, b1): (Double, Double, Double)
    switch hp {
    case 0..<1:  (r1, g1, b1) = (c, x, 0)
    case 1..<2:  (r1, g1, b1) = (x, c, 0)
    case 2..<3:  (r1, g1, b1) = (0, c, x)
    case 3..<4:  (r1, g1, b1) = (0, x, c)
    case 4..<5:  (r1, g1, b1) = (x, 0, c)
    default:     (r1, g1, b1) = (c, 0, x)
    }
    let m = l - c / 2
    return clampHex(r1 + m, g1 + m, b1 + m)
}

/// 解析十六进制颜色为 sRGB 分量（0...1）。支持 #RGB / #RRGGBB / #RRGGBBAA（忽略 alpha）。
private func rgbComponents(from hex: String) -> (Double, Double, Double)? {
    let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
    var rgb: UInt64 = 0
    guard Scanner(string: h).scanHexInt64(&rgb) else { return nil }
    switch h.count {
    case 3:
        return (Double((rgb & 0xF00) >> 8) / 15,
                Double((rgb & 0x0F0) >> 4) / 15,
                Double(rgb & 0x00F) / 15)
    case 6:
        return (Double((rgb & 0xFF0000) >> 16) / 255,
                Double((rgb & 0x00FF00) >> 8) / 255,
                Double(rgb & 0x0000FF) / 255)
    case 8:
        return (Double((rgb & 0xFF000000) >> 24) / 255,
                Double((rgb & 0x00FF0000) >> 16) / 255,
                Double((rgb & 0x0000FF00) >> 8) / 255)
    default:
        return nil
    }
}

