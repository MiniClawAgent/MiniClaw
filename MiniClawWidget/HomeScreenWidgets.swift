import AppIntents
import SwiftUI
import WidgetKit

// MARK: - 深链

/// 小组件可用的深链（全部由主 App `MiniClawApp.handleDeepLink` 已实现的路由消费）。
/// 刻意**不使用 App Group**：个人开发者团队（免费签名）无法申请 App Groups 能力，
/// 一旦加上 entitlement 会直接导致真机自动签名失败。因此小组件只做「入口」，不读主 App 数据。
enum WidgetDeepLink {
    static let newChat = URL(string: "miniclaw://new")!
    static let terminal = URL(string: "miniclaw://open_terminal")!
    static let settings = URL(string: "miniclaw://settings")!

    /// 一键派任务：`miniclaw://task?prompt=<urlencoded>`（P1-4 深链派任务链路）。
    static func task(prompt: String) -> URL {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return newChat }
        var comps = URLComponents()
        comps.scheme = "miniclaw"
        comps.host = "task"
        comps.queryItems = [
            URLQueryItem(name: "prompt", value: trimmed),
            URLQueryItem(name: "agent", value: String(localized: "widget_task_agent"))
        ]
        return comps.url ?? newChat
    }
}

// MARK: - 快捷入口小组件

private struct QuickActionsEntry: TimelineEntry {
    let date: Date
}

private struct QuickActionsProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickActionsEntry { QuickActionsEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (QuickActionsEntry) -> Void) {
        completion(QuickActionsEntry(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickActionsEntry>) -> Void) {
        // 纯静态入口，无需刷新节奏。
        completion(Timeline(entries: [QuickActionsEntry(date: Date())], policy: .never))
    }
}

/// 单个入口按钮（medium 尺寸下每个都是独立 Link，可分别点击）。
private struct ActionTile: View {
    let icon: String
    let title: String
    let tint: Color

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.opacity(0.18))
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(tint)
            }
            .frame(width: 44, height: 44)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct QuickActionsView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuickActionsEntry

    var body: some View {
        switch family {
        case .systemSmall:
            smallBody
                // iOS16 兼容:containerBackground 是 iOS17 API,16 下用系统默认背景。
                .modifier(WidgetBackgroundCompat())
                .widgetURL(WidgetDeepLink.newChat)
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .medium))
            }
            .widgetURL(WidgetDeepLink.newChat)
        case .accessoryRectangular:
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                VStack(alignment: .leading, spacing: 1) {
                    Text("MiniClaw").font(.headline)
                    Text("new_chat").font(.caption)
                }
                Spacer(minLength: 0)
            }
            .widgetURL(WidgetDeepLink.newChat)
        default:
            mediumBody
                // iOS16 兼容:containerBackground 是 iOS17 API,16 下用系统默认背景。
                .modifier(WidgetBackgroundCompat())
        }
    }

    private var smallBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("MiniClaw")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            Image(systemName: "plus.bubble.fill")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.tint)
            Text("new_chat")
                .font(.system(size: 14, weight: .semibold))
            Text("widget_new_chat_hint")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var mediumBody: some View {
        VStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("MiniClaw")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Text("quick_actions")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Link(destination: WidgetDeepLink.newChat) {
                    ActionTile(icon: "plus.bubble.fill", title: String(localized: "new_chat"), tint: .blue)
                }
                Link(destination: WidgetDeepLink.terminal) {
                    ActionTile(icon: "terminal.fill", title: String(localized: "terminal"), tint: .green)
                }
                Link(destination: WidgetDeepLink.settings) {
                    ActionTile(icon: "gearshape.fill", title: String(localized: "settings"), tint: .orange)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct MiniClawQuickActionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MiniClawQuickActions", provider: QuickActionsProvider()) { entry in
            QuickActionsView(entry: entry)
        }
        .configurationDisplayName("widget_quick_actions_name")
        .description("widget_quick_actions_desc")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

// MARK: - 一键派任务小组件（可配置 prompt）

/// 长按小组件「编辑」即可填写常用指令；点按把它作为任务直接派给智能体。
@available(iOS 17.0, *)
struct QuickTaskConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "quick_task"
    static let description = IntentDescription("quick_task_config_desc")

    @Parameter(title: "label_title", default: "一键任务")
    var label: String

    @Parameter(title: "prompt_title", default: "总结我今天的待办并给出优先级建议")
    var prompt: String

    @Parameter(title: "symbol_title", default: .bolt)
    var symbol: QuickTaskSymbol
}

/// 可选图标（AppEnum 才能出现在小组件配置面板里）。
@available(iOS 17.0, *)
enum QuickTaskSymbol: String, AppEnum {
    case bolt, checklist, doc, brain, terminal

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "symbol_title")
    static let caseDisplayRepresentations: [QuickTaskSymbol: DisplayRepresentation] = [
        .bolt: "symbol_bolt",
        .checklist: "symbol_checklist",
        .doc: "symbol_doc",
        .brain: "symbol_brain",
        .terminal: "symbol_terminal"
    ]

    var systemName: String {
        switch self {
        case .bolt: return "bolt.fill"
        case .checklist: return "checklist"
        case .doc: return "doc.text.fill"
        case .brain: return "brain.head.profile"
        case .terminal: return "terminal.fill"
        }
    }
}

@available(iOS 17.0, *)
private struct QuickTaskEntry: TimelineEntry {
    let date: Date
    let label: String
    let prompt: String
    let symbol: String
}

@available(iOS 17.0, *)
private struct QuickTaskProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuickTaskEntry {
        QuickTaskEntry(date: Date(), label: String(localized: "quick_task"), prompt: "", symbol: "bolt.fill")
    }

    func snapshot(for configuration: QuickTaskConfigurationIntent, in context: Context) async -> QuickTaskEntry {
        entry(for: configuration)
    }

    func timeline(for configuration: QuickTaskConfigurationIntent, in context: Context) async -> Timeline<QuickTaskEntry> {
        Timeline(entries: [entry(for: configuration)], policy: .never)
    }

    private func entry(for c: QuickTaskConfigurationIntent) -> QuickTaskEntry {
        QuickTaskEntry(date: Date(), label: c.label, prompt: c.prompt, symbol: c.symbol.systemName)
    }
}

@available(iOS 17.0, *)
private struct QuickTaskView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuickTaskEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: entry.symbol)
                        .font(.system(size: 18, weight: .medium))
                }
            case .accessoryRectangular:
                HStack(spacing: 6) {
                    Image(systemName: entry.symbol)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.label).font(.headline).lineLimit(1)
                        Text(entry.prompt).font(.caption).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            default:
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: entry.symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.tint)
                        Text(entry.label)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    Text(entry.prompt.isEmpty ? String(localized: "quick_task_edit_hint") : entry.prompt)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(family == .systemSmall ? 4 : 2)
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        Image(systemName: "paperplane.fill").font(.system(size: 10))
                        Text("quick_task_dispatch").font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.tint)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .containerBackground(.fill.tertiary, for: .widget)
            }
        }
        .widgetURL(WidgetDeepLink.task(prompt: entry.prompt))
    }
}

@available(iOS 17.0, *)
struct MiniClawQuickTaskWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "MiniClawQuickTask",
            intent: QuickTaskConfigurationIntent.self,
            provider: QuickTaskProvider()
        ) { entry in
            QuickTaskView(entry: entry)
        }
        .configurationDisplayName("widget_quick_task_name")
        .description("widget_quick_task_desc")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}


/// iOS16 兼容:containerBackground(_:for:) 是 iOS17 API。
/// 16 下保持系统默认 widget 背景(视觉一致,系统提供的标准背景)。
private struct WidgetBackgroundCompat: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.containerBackground(.fill.tertiary, for: .widget)
        } else {
            content
        }
    }
}
