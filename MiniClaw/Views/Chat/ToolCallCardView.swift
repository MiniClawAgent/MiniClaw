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
        // 历史会话里的工具名可能是旧的连字符写法（apple-open 等），统一规范化后再匹配。
        let name = event.name.replacingOccurrences(of: "-", with: "_")
        let args = event.arguments
        let activity = extractJSONField(args, field: "activity")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let activity, !activity.isEmpty {
            return (toolSymbol(for: name), activity)
        }
        switch name {
        case "file-read":
            if args.contains("path") {
                let path = extractJSONField(args, field: "path") ?? ""
                let filename = URL(fileURLWithPath: path).lastPathComponent
                return ("doc.text", filename.isEmpty ? String(localized: "read_file") : String(format: String(localized: "read"), filename))
            }
            return ("doc.text", String(localized: "read_file"))
        case "file-write":
            if args.contains("path") {
                let path = extractJSONField(args, field: "path") ?? ""
                let filename = URL(fileURLWithPath: path).lastPathComponent
                return ("square.and.pencil", filename.isEmpty ? String(localized: "write_file") : String(format: String(localized: "write_to"), filename))
            }
            return ("square.and.pencil", String(localized: "write_file"))
        case "file-edit": return ("pencil.and.outline", String(localized: "edit_file"))
        case "browser", "miniclaw_browser-use":
            if let activity, !activity.isEmpty {
                return ("globe", activity)
            }
            let action = extractJSONField(args, field: "action")
            let url = extractJSONField(args, field: "url") ?? extractJSONField(args, field: "params.url")
            let selector = extractJSONField(args, field: "selector") ?? extractJSONField(args, field: "params.selector")
            switch action {
            case "navigate", "new_tab":
                let host = url.flatMap { URL(string: $0)?.host } ?? url ?? String(localized: "web_page")
                return ("globe", String(format: String(localized: "open_format"), host))
            case "screenshot": return ("camera.viewfinder", String(localized: "capture_current_page"))
            case "get_text": return ("doc.plaintext", selector.map { String(format: String(localized: "read_content"), $0) } ?? String(localized: "read_web_page_content"))
            case "get_readable": return ("text.book.closed", String(localized: "read_page_body"))
            case "get_page_info": return ("info.circle", String(localized: "view_page_info"))
            case "get_backbone": return ("point.3.connected.trianglepath.dotted", String(localized: "analyze_page_structure"))
            case "click": return ("hand.tap", selector.map { String(format: String(localized: "tap"), $0) } ?? String(localized: "tap_web_element"))
            case "type": return ("keyboard", String(localized: "type_in_web_page"))
            case "scroll": return ("scroll", String(localized: "browse_page_content"))
            case "scroll_and_collect": return ("arrow.down.doc", String(localized: "collect_page_list"))
            case "find_elements": return ("scope", String(localized: "find_web_elements"))
            case "fetch": return ("arrow.down.circle", String(localized: "download_web_resources"))
            case "list_tabs": return ("rectangle.on.rectangle", String(localized: "view_browser_tabs"))
            case "close_tab": return ("xmark.square", String(localized: "close_browser_tab"))
            case "wait_for_dom_stable": return ("hourglass", String(localized: "waiting_for_page_to_load"))
            default: return ("globe", String(localized: "process_web_content"))
            }
        case "shell-execute": return ("terminal", String(localized: "run_command"))
        case "memory-write": return ("brain.head.profile", String(localized: "write_to_memory"))
        case "memory-get": return ("magnifyingglass", String(localized: "search_memory"))
        case "apple-image": return ("photo", String(localized: "apple-image"))
        case "apple-vision": return ("viewfinder", String(localized: "apple-vision"))
        case "apple-calendar": return ("calendar", String(localized: "calendar_actions"))
        case "apple-reminders": return ("checklist", String(localized: "reminders"))
        case "apple-speak": return ("speaker.wave.2", String(localized: "read_aloud"))
        case "apple-speech": return ("mic", String(localized: "speech_recognition"))
        case "apple-contacts": return ("person.crop.circle", String(localized: "contacts_actions"))
        case "apple-media": return ("music.note", String(localized: "media_playback"))
        case "apple-clipboard": return ("doc.on.clipboard", String(localized: "clipboard_actions"))
        case "apple-device": return ("iphone", String(localized: "device_info"))
        case "apple-nlp": return ("text.alignleft", String(localized: "text_analysis"))
        case "apple-open": return ("arrow.up.forward.app", String(localized: "open_link"))
        case "open-in-safari": return ("safari", String(localized: "open-in-safari"))
        case "apple-notification": return ("bell", String(localized: "send_notification"))
        case "apple-location": return ("location", String(localized: "location_services"))
        case "apple-maps": return ("map", String(localized: "map_search"))
        case "miniclaw-config": return ("gearshape", String(localized: "configuration_management"))
        case "sessions-cli": return ("bubble.left.and.bubble.right", String(localized: "session_management"))
        case "miniclaw-debug": return ("ladybug", String(localized: "debug_info"))
        case "miniclaw-plugin": return ("puzzlepiece.extension", String(localized: "plugin_management"))
        default: return ("wrench.and.screwdriver", name.replacingOccurrences(of: "_", with: " "))
        }
    }

    private func toolSymbol(for name: String) -> String {
        switch name {
        case "file-read": return "doc.text"
        case "file-write": return "square.and.pencil"
        case "file-edit": return "pencil.and.outline"
        case "browser", "miniclaw_browser-use": return "globe"
        case "shell-execute": return "terminal"
        case "memory-write": return "brain.head.profile"
        case "memory-get": return "magnifyingglass"
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
        case "miniclaw-config": return "gearshape"
        case "sessions-cli": return ("bubble.left.and.bubble.right")
        case "miniclaw-debug": return "ladybug"
        case "miniclaw-plugin": return "puzzlepiece.extension"
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
                        Text(String(localized: "stopped"))
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
                            Text(String(localized: "downloaded"))
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
        // 2026-09-02 唐唐拍板：与主会话工具指示器统一——固定矩形圆角 12
        // （主会话 AssistantBlockView 同款；原折叠态 Capsule 半圆废弃）。
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
        .fixedSize(horizontal: !isExpanded, vertical: true)
    }
}

// MARK: - 用户附件缩略图

/// 单个附件单元格：图片显示本地缩略图（点按全屏），非图片显示文件卡片。
