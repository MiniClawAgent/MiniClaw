import SwiftUI

struct ToolCallCardView: View {
    let event: ToolCallEvent
    /// 受控展开状态（2026-08-09 与思考块同机制，按工具调用 id 索引）。
    let isExpanded: Bool
    var onToggle: (() -> Void)? = nil

    private var downloadTracker: DownloadProgressTracker { .shared }

    private var isPending: Bool { event.resultText.isEmpty && !event.wasInterrupted }

    /// 是否为本卡片专属的下载进度显示
    private var isMyDownload: Bool {
        guard event.name == "browser" || event.name == "miniclaw-browser-use" else { return false }
        // 仅「fetch」action 才是下载
        return event.arguments.contains("\"fetch\"")
    }

    /// 正在下载中（本卡片是当前执行下载的工具）
    private var isDownloading: Bool {
        isPending && isMyDownload && downloadTracker.isActive
    }

    /// 下载已完成（从持久化的 event 数据判定，重启不丢失）
    private var isDownloadDone: Bool {
        isMyDownload && !isPending && event.success && !event.wasInterrupted
    }

    /// pill 背景色
    private var pillBackground: some View {
        Group {
            if isDownloading {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Color(.systemGray5)
                        Color(red: 0.098, green: 0.549, blue: 0.996).opacity(0.15)
                            .frame(width: geo.size.width * downloadTracker.progress)
                    }
                }
            } else if isDownloadDone {
                Color.green.opacity(0.12)
            } else {
                Color(.systemGray6)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isDownloading)
    }

    private var stateColor: Color {
        if event.wasInterrupted { return .orange }
        if isPending { return .secondary }
        return event.success ? .green : .red
    }

    private var formattedDuration: String {
        guard let duration = event.duration else { return "--" }
        if duration < 0.1 { return "<0.1s" }
        return String(format: "%.1fs", duration)
    }

    /// SF Symbols 图标 + 可读描述
    private func toolDisplayInfo() -> (symbol: String, label: String) {
        let name = event.name
        let args = event.arguments
        let activity = extractJSONField(args, field: "activity")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let activity, !activity.isEmpty {
            return (toolSymbol(for: name), activity)
        }
        switch name {
        case "file_read":
            if args.contains("path") {
                let path = extractJSONField(args, field: "path") ?? ""
                let filename = URL(fileURLWithPath: path).lastPathComponent
                return ("doc.text", filename.isEmpty ? L10n.l("read_file") : String(format: L10n.l("read"), filename))
            }
            return ("doc.text", L10n.l("read_file"))
        case "file_write":
            if args.contains("path") {
                let path = extractJSONField(args, field: "path") ?? ""
                let filename = URL(fileURLWithPath: path).lastPathComponent
                return ("square.and.pencil", filename.isEmpty ? L10n.l("write_file") : String(format: L10n.l("write_to"), filename))
            }
            return ("square.and.pencil", L10n.l("write_file"))
        case "file_edit": return ("pencil.and.outline", L10n.l("edit_file"))
        case "browser", "miniclaw-browser-use":
            if let activity, !activity.isEmpty {
                return ("globe", activity)
            }
            let action = extractJSONField(args, field: "action")
            let url = extractJSONField(args, field: "url") ?? extractJSONField(args, field: "params.url")
            let selector = extractJSONField(args, field: "selector") ?? extractJSONField(args, field: "params.selector")
            switch action {
            case "navigate", "new_tab":
                let host = url.flatMap { URL(string: $0)?.host } ?? url ?? L10n.l("web_page")
                return ("globe", String(format: L10n.l("open_format"), host))
            case "screenshot": return ("camera.viewfinder", L10n.l("capture_current_page"))
            case "get_text": return ("doc.plaintext", selector.map { String(format: L10n.l("read_content"), $0) } ?? L10n.l("read_web_page_content"))
            case "get_readable": return ("text.book.closed", L10n.l("read_page_body"))
            case "get_page_info": return ("info.circle", L10n.l("view_page_info"))
            case "get_backbone": return ("point.3.connected.trianglepath.dotted", L10n.l("analyze_page_structure"))
            case "click": return ("hand.tap", selector.map { String(format: L10n.l("tap"), $0) } ?? L10n.l("tap_web_element"))
            case "type": return ("keyboard", L10n.l("type_in_web_page"))
            case "scroll": return ("scroll", L10n.l("browse_page_content"))
            case "scroll_and_collect": return ("arrow.down.doc", L10n.l("collect_page_list"))
            case "find_elements": return ("scope", L10n.l("find_web_elements"))
            case "fetch": return ("arrow.down.circle", L10n.l("download_web_resources"))
            case "list_tabs": return ("rectangle.on.rectangle", L10n.l("view_browser_tabs"))
            case "close_tab": return ("xmark.square", L10n.l("close_browser_tab"))
            case "wait_for_dom_stable": return ("hourglass", L10n.l("waiting_for_page_to_load"))
            default: return ("globe", L10n.l("process_web_content"))
            }
        case "shell_execute": return ("terminal", L10n.l("run_command"))
        case "memory_write": return ("brain.head.profile", L10n.l("write_to_memory"))
        case "memory_get": return ("magnifyingglass", L10n.l("search_memory"))
        case "apple-image": return ("photo", L10n.l("apple_image"))
        case "apple-vision": return ("viewfinder", L10n.l("apple_vision"))
        case "apple-calendar": return ("calendar", L10n.l("calendar_actions"))
        case "apple-reminders": return ("checklist", L10n.l("reminders"))
        case "apple-speak": return ("speaker.wave.2", L10n.l("read_aloud"))
        case "apple-speech": return ("mic", L10n.l("speech_recognition"))
        case "apple-contacts": return ("person.crop.circle", L10n.l("contacts_actions"))
        case "apple-media": return ("music.note", L10n.l("media_playback"))
        case "apple-clipboard": return ("doc.on.clipboard", L10n.l("clipboard_actions"))
        case "apple-device": return ("iphone", L10n.l("device_info"))
        case "apple-nlp": return ("text.alignleft", L10n.l("text_analysis"))
        case "apple-open": return ("arrow.up.forward.app", L10n.l("open_link"))
        case "open-in-safari": return ("safari", L10n.l("open_in_safari"))
        case "apple-notification": return ("bell", L10n.l("send_notification"))
        case "apple-location": return ("location", L10n.l("location_services"))
        case "apple-maps": return ("map", L10n.l("map_search"))
        case "miniclaw_config": return ("gearshape", L10n.l("configuration_management"))
        case "sessions_cli": return ("bubble.left.and.bubble.right", L10n.l("session_management"))
        case "miniclaw-debug": return ("ladybug", L10n.l("debug_info"))
        default: return ("wrench.and.screwdriver", name.replacingOccurrences(of: "_", with: " "))
        }
    }

    private func toolSymbol(for name: String) -> String {
        switch name {
        case "file_read": return "doc.text"
        case "file_write": return "square.and.pencil"
        case "file_edit": return "pencil.and.outline"
        case "browser", "miniclaw-browser-use": return "globe"
        case "shell_execute": return "terminal"
        case "memory_write": return "brain.head.profile"
        case "memory_get": return "magnifyingglass"
        case "apple-image": return "photo"
        case "apple-vision": return "viewfinder"
        case "apple-calendar": return "calendar"
        case "apple-reminders": return "checklist"
        case "apple-speak": return "speaker.wave.2"
        case "apple-speech": return "mic"
        case "apple-contacts": return "person.crop.circle"
        case "apple-media": return "music.note"
        case "apple-clipboard": return "doc.on.clipboard"
        case "apple-device": return "iphone"
        case "apple-nlp": return "text.alignleft"
        case "apple-open": return "arrow.up.forward.app"
        case "open-in-safari": return "safari"
        case "apple-notification": return "bell"
        case "apple-location": return "location"
        case "apple-maps": return "map"
        case "miniclaw_config": return "gearshape"
        case "sessions_cli": return ("bubble.left.and.bubble.right")
        case "miniclaw-debug": return "ladybug"
        default: return "wrench.and.screwdriver"
        }
    }

    private func extractJSONField(_ json: String, field: String) -> String? {
        let pattern = "\"\(field)\"\\s*:\\s*\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: json, range: NSRange(json.startIndex..., in: json)),
              let range = Range(match.range(at: 1), in: json) else { return nil }
        return String(json[range])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Pill 主体行
            Button(action: { onToggle?() }) {
                HStack(spacing: 6) {
                    let info = toolDisplayInfo()
                    Image(systemName: event.wasInterrupted ? "stop.circle.fill" : info.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(stateColor)
                    Text(info.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if event.wasInterrupted {
                        Text(L10n.l("stopped"))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.orange)
                    } else if isPending {
                        if isDownloading {
                            Text("\(Int(downloadTracker.progress * 100))%")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color(red: 0.098, green: 0.549, blue: 0.996))
                        } else {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                        }
                    } else if isDownloadDone {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.green)
                            Text(L10n.l("downloaded"))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.green)
                        }
                    } else {
                        Text(formattedDuration)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(stateColor)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
            }
            .buttonStyle(.plain)

            // 展开详情
            if isExpanded {
                Divider()
                    .padding(.horizontal, 12)
                VStack(alignment: .leading, spacing: 4) {
                    if !event.arguments.isEmpty {
                        Text(event.arguments)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(5)
                    }
                    if !event.resultText.isEmpty {
                        Text(event.resultText)
                            .font(.caption2)
                            .foregroundStyle(event.success ? Color.secondary : Color.red)
                            .textSelection(.enabled)
                            .lineLimit(8)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .background(pillBackground)
        // 开源参考实现对齐(2026-08-09):折叠态 Capsule(高36)、展开态圆角 18
        .clipShape(isExpanded ? AnyShape(RoundedRectangle(cornerRadius: 18)) : AnyShape(Capsule()))
        .overlay(
            (isExpanded ? AnyShape(RoundedRectangle(cornerRadius: 18)) : AnyShape(Capsule()))
                .stroke(Color(.separator), lineWidth: 0.5)
        )
        .fixedSize(horizontal: !isExpanded, vertical: true)
    }
}

// MARK: - 用户附件缩略图

/// 单个附件单元格：图片显示本地缩略图（点按全屏），非图片显示文件卡片。
