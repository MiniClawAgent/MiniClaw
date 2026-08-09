import WidgetKit
import SwiftUI

struct MiniClawWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MiniClawLiveActivityAttributes.self) { context in
            // 锁屏 / 通知长览展示（见下方 LockScreenActivityView）
            let sessionURL = URL(string: "miniclaw://session/\(context.attributes.sessionID)") ?? URL(string: "miniclaw://")!
            Link(destination: sessionURL) {
                LockScreenActivityView(context: context)
            }
        } dynamicIsland: { context in
            // 灵动岛展开布局：
            //  - 顶部一行：leading = 🌟AI名，trailing = 状态图标
            //  - 下方 .bottom（全宽区域）：第二排[图标+标题……时间]、第三排[执行信息]
            //    .bottom 是系统唯一的全宽可延展区，多行内容放这里才不会因 .leading 窄区被圆角裁切。
            DynamicIsland {
                let sessionURL = URL(string: "miniclaw://session/\(context.attributes.sessionID)") ?? URL(string: "miniclaw://")!

                DynamicIslandExpandedRegion(.leading) {
                    Link(destination: sessionURL) {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11))
                            Text(context.attributes.aiName)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                        }
                        .foregroundColor(.white)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Link(destination: sessionURL) {
                        StatusIconView(status: context.state.status, phase: context.state.phase, monochrome: true)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    Link(destination: sessionURL) {
                        VStack(alignment: .leading, spacing: 5) {
                            // 第二排：会话图标 + 标题（左）…… 时间（右，靠右对齐）
                            HStack(spacing: 4) {
                                Image(systemName: context.state.sessionIcon)
                                    .font(.system(size: 13))
                                Text(context.state.sessionTitle)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 6)
                                Text(context.state.timeText)
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.7))
                                    .lineLimit(1)
                            }
                            // 第三排：任务执行信息（整行左对齐，全宽不遮挡）
                            Text(context.state.progressText)
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.8))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.sessionIcon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
            } compactTrailing: {
                StatusIconView(status: context.state.status, phase: context.state.phase, monochrome: true)
                    .foregroundColor(.white)
            } minimal: {
                Image(systemName: context.state.sessionIcon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
            }
            .contentMargins(.horizontal, 20, for: .expanded)
        }
    }
}

/// 实时活动状态图标：所有状态统一固定尺寸容器。
private struct StatusIconView: View {
    let status: String
    let phase: String
    let monochrome: Bool

    private let iconSize: CGFloat = 16

    private var resolved: String {
        if !status.isEmpty { return status }
        switch phase {
        case "完成": return "completed"
        case "失败": return "failed"
        default: return "running"
        }
    }

    var body: some View {
        switch resolved {
        case "completed":
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: iconSize))
                .foregroundStyle(monochrome ? Color.white : Color.green)
        case "failed":
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: iconSize))
                .foregroundStyle(monochrome ? Color.white : Color.red)
        case "paused":
            Image(systemName: "pause.circle.fill")
                .font(.system(size: iconSize))
                .foregroundStyle(monochrome ? Color.white : Color(red: 0.098, green: 0.549, blue: 0.996))
        case "stopped":
            Image(systemName: "stop.circle.fill")
                .font(.system(size: iconSize))
                .foregroundStyle(monochrome ? Color.white : Color.orange)
        case "interrupted":
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: iconSize))
                .foregroundStyle(monochrome ? Color.white : Color.red)
        default:
            // 运行中：与「完成」同容器尺寸的黄色圆点（2026-08-08 用户定：替代小菊花，
            // 与主会话「回复中」黄点同色系；Widget 内动画受系统节流，静态显示）。
            Circle()
                .fill(Color.yellow)
                .frame(width: iconSize * 0.5, height: iconSize * 0.5)
                .frame(width: iconSize, height: iconSize)
        }
    }
}

/// 锁屏长览视图（三行单行布局，AI名与「图标+标题」带胶囊背景）
private struct LockScreenActivityView: View {
    let context: ActivityViewContext<MiniClawLiveActivityAttributes>
    @Environment(\.colorScheme) private var colorScheme

    private var background: Color {
        colorScheme == .dark
        ? Color.black.opacity(0.85)
        : Color.white.opacity(0.92)
    }
    private var primaryText: Color {
        colorScheme == .dark ? .white : .black
    }
    private var secondaryText: Color {
        colorScheme == .dark
        ? Color.white.opacity(0.72)
        : Color.black.opacity(0.62)
    }
    /// 胶囊底色：随外观取主色淡透明，保证对比度且不抢内容。
    private var pillTint: Color {
        primaryText.opacity(0.12)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 第一排：✨AI 名字（胶囊背景）+ 状态图标
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                    Text(context.attributes.aiName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundColor(primaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(pillTint))
                Spacer()
                StatusIconView(status: context.state.status, phase: context.state.phase, monochrome: false)
            }

            // 第二排：会话图标 + 会话标题（胶囊背景）…… 时间（右）
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: context.state.sessionIcon)
                        .font(.system(size: 13))
                        .foregroundColor(colorScheme == .dark ? .white : .accentColor)
                    Text(context.state.sessionTitle)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .foregroundColor(primaryText)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(pillTint))
                Spacer(minLength: 6)
                Text(context.state.timeText)
                    .font(.caption2)
                    .foregroundColor(secondaryText)
                    .lineLimit(1)
            }

            // 第三排：任务执行信息（无 token 速度）
            HStack(alignment: .center, spacing: 6) {
                Text(context.state.progressText)
                    .font(.footnote)
                    .foregroundColor(secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }
        }
        .padding(12)
        .activityBackgroundTint(background)
        .activitySystemActionForegroundColor(primaryText)
    }
}

@main
struct MiniClawWidgetBundle: WidgetBundle {
    var body: some Widget {
        MiniClawWidgetLiveActivity()
        MiniClawQuickActionsWidget()
        MiniClawQuickTaskWidget()
    }
}
