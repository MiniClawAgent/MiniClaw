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
            URLQueryItem(name: "agent", value: "小组件任务")
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
                .containerBackground(.fill.tertiary, for: .widget)
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
                    Text("新建对话").font(.caption)
                }
                Spacer(minLength: 0)
            }
            .widgetURL(WidgetDeepLink.newChat)
        default:
            mediumBody
                .containerBackground(.fill.tertiary, for: .widget)
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
            Text("新建对话")
                .font(.system(size: 14, weight: .semibold))
            Text("点按直接开始一段新会话")
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
                Text("快捷入口")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Link(destination: WidgetDeepLink.newChat) {
                    ActionTile(icon: "plus.bubble.fill", title: "新建对话", tint: .blue)
                }
                Link(destination: WidgetDeepLink.terminal) {
                    ActionTile(icon: "terminal.fill", title: "终端", tint: .green)
                }
                Link(destination: WidgetDeepLink.settings) {
                    ActionTile(icon: "gearshape.fill", title: "设置", tint: .orange)
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
        .configurationDisplayName("MiniClaw 快捷入口")
        .description("一步进入新对话、终端或设置。")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

// MARK: - 一键派任务小组件（可配置 prompt）

/// 长按小组件「编辑」即可填写常用指令；点按把它作为任务直接派给智能体。
struct QuickTaskConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "一键任务"
    static let description = IntentDescription("配置一句常用指令，点按小组件即可直接派发给 MiniClaw 执行。")

    @Parameter(title: "标题", default: "一键任务")
    var label: String

    @Parameter(title: "指令内容", default: "总结我今天的待办并给出优先级建议")
    var prompt: String

    @Parameter(title: "图标", default: .bolt)
    var symbol: QuickTaskSymbol
}

/// 可选图标（AppEnum 才能出现在小组件配置面板里）。
enum QuickTaskSymbol: String, AppEnum {
    case bolt, checklist, doc, brain, terminal

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "图标")
    static let caseDisplayRepresentations: [QuickTaskSymbol: DisplayRepresentation] = [
        .bolt: "闪电",
        .checklist: "清单",
        .doc: "文稿",
        .brain: "思考",
        .terminal: "终端"
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

private struct QuickTaskEntry: TimelineEntry {
    let date: Date
    let label: String
    let prompt: String
    let symbol: String
}

private struct QuickTaskProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuickTaskEntry {
        QuickTaskEntry(date: Date(), label: "一键任务", prompt: "", symbol: "bolt.fill")
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
                    Text(entry.prompt.isEmpty ? "长按编辑，填入常用指令" : entry.prompt)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(family == .systemSmall ? 4 : 2)
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        Image(systemName: "paperplane.fill").font(.system(size: 10))
                        Text("点按派发").font(.system(size: 10, weight: .medium))
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

struct MiniClawQuickTaskWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "MiniClawQuickTask",
            intent: QuickTaskConfigurationIntent.self,
            provider: QuickTaskProvider()
        ) { entry in
            QuickTaskView(entry: entry)
        }
        .configurationDisplayName("MiniClaw 一键任务")
        .description("把一句常用指令固定到桌面，点按直接派给智能体执行。")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}
