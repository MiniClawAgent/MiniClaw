import SwiftUI

struct SlashCommandItem: Identifiable {
    let id: String           // 唯一标识，如 "clear"、"memory"
    let icon: String         // SF Symbol 名称
    let title: String        // 命令名（如 "clear"、"memory"）
    let subtitle: String     // 说明文字
    let kind: SlashCommandKind
    /// 思考档位选择器数据（仅 /thinking 使用）：当前选中等级 + 可选档位列表。
    /// 非空时菜单渲染为 pill 选择器而非 toggle/disabled。
    var thinkingLevel: String?

    enum SlashCommandKind {
        /// 立即执行的动作（如 /clear、/compact）
        case action
        /// 插入文本前缀到输入框（如 /search → "/search "）
        case insertText(String)
        /// 用户技能：点击后在输入框填入 "/技能名 "，发送时一次性注入该技能让 智能体直接使用。
        case skill(String)
        /// 带开关的切换项（如 /memory）
        case toggle(Bool)
        /// 禁用态（显示原因文字，如 /thinking 在不支持时）
        case disabled(String)
        /// 思考档位选择器（/thinking 在支持思考模型上展示强度 pills）
        case thinkingPicker(selectedLevel: String?, levels: [(id: String, label: String)])
    }
}

// MARK: - 斜杠命令覆盖层

/// 输入 "/" 时在输入框上方弹出的 inline 命令列表。
/// 样式照抄参考 App：深色圆角卡片 + 每行 图标/命令名/说明，支持过滤与开关。
struct SlashCommandOverlay: View {
    let filter: String
    var onSelect: (SlashCommandItem) -> Void

    /// 所有可用命令（由 ChatInputBar 固定定义；toggle 状态由外部传入）。
    let commands: [SlashCommandItem]

    init(filter: String, commands: [SlashCommandItem]? = nil, onSelect: @escaping (SlashCommandItem) -> Void) {
        self.filter = filter
        self.onSelect = onSelect
        // 默认命令集：若外部未传入则使用内置列表（toggle 占位符会在 ChatView 侧替换为真实状态）。
        self.commands = commands ?? Self.defaultCommands
    }

    /// 内置默认命令（toggle 状态占位，实际值由 ChatView 注入）。
    static let defaultCommands: [SlashCommandItem] = [
        SlashCommandItem(id: "clear", icon: "trash", title: "/clear", subtitle: "Clear all messages in this session", kind: .action),
        SlashCommandItem(id: "compact", icon: "arrow.up.arrow.down", title: "/compact", subtitle: "Compress conversation history into summary", kind: .action),
        SlashCommandItem(id: "memory", icon: "brain", title: "/memory", subtitle: "Writes off — tap to toggle", kind: .toggle(false)),
        SlashCommandItem(id: "thinking", icon: "wand.and.sparkles", title: "/thinking", subtitle: L10n.l("current_model_not_supported"), kind: .disabled(L10n.l("current_model_not_supported"))),
        SlashCommandItem(id: "search", icon: "globe", title: "/search", subtitle: L10n.l("web_search"), kind: .insertText("/search ")),
        SlashCommandItem(id: "image", icon: "photo", title: "/image", subtitle: L10n.l("image_generation"), kind: .insertText("/image ")),
        SlashCommandItem(id: "analyze", icon: "doc.text", title: "/analyze", subtitle: L10n.l("file_analysis"), kind: .insertText("/analyze ")),
        SlashCommandItem(id: "exec", icon: "terminal", title: "/exec", subtitle: L10n.l("run_command"), kind: .insertText("/exec ")),
    ]

    /// 按过滤关键词筛选命令：匹配命令名或副标题。
    private var filteredCommands: [SlashCommandItem] {
        guard !filter.isEmpty else { return commands }
        return commands.filter { cmd in
            cmd.title.lowercased().contains(filter) ||
            cmd.subtitle.lowercased().contains(filter)
        }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(filteredCommands) { cmd in
                    slashCommandRow(cmd)
                }
                if filteredCommands.isEmpty {
                    Text(L10n.l("no_matching_command"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
        }
        // 默认只显示约 3.5 行高度，超出部分可上下滑动选择。
        .frame(maxHeight: 190)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }

    /// 单行命令项：图标 + 命令名 + 说明（右侧可选开关/禁用标记/思考档位选择器）。
    @ViewBuilder
    private func slashCommandRow(_ cmd: SlashCommandItem) -> some View {
        // 思考档位选择器：特殊布局——左侧可切换开/关，右侧 pill 独立点选档位
        if case .thinkingPicker(let selected, let levels) = cmd.kind {
            thinkingPickerRow(icon: cmd.icon, title: cmd.title, subtitle: cmd.subtitle,
                              selectedLevel: selected, levels: levels, cmd: cmd)
        } else {
            // 普通行：整个区域可点击
            Button(action: { onSelect(cmd) }) {
                commandRowContent(cmd)
            }
            .buttonStyle(.plain)
            .disabled(isDisabled(cmd))
        }
    }

    /// 思考档位选择器行：左侧标题区（点击切换开/关）+ 右侧 pill 档位条。
    @ViewBuilder
    private func thinkingPickerRow(icon: String, title: String, subtitle: String,
                                    selectedLevel: String?, levels: [(id: String, label: String)],
                                    cmd: SlashCommandItem) -> some View {
        // selectedLevel 三态：nil=模型默认（思考模型默认开启）、"off"=关闭、具体档位=开启到该档。
        let isActive = selectedLevel != "off"
        // 模型默认（nil）时显示 low 档：支持深度思考的模型一般都有 low 档，
        // 与「关→开」切换动作一致（开 = low），保证默认档永远落在模型支持的档位内。
        let effectiveSelection = selectedLevel ?? (isActive ? "low" : nil)

        HStack(spacing: 12) {
            // 左侧：图标 + 标题（点击切换开/关）
            Button(action: {
                if effectiveSelection != nil && effectiveSelection != "off" {
                    // 当前开（含模型默认 nil）：关闭 → 传 "off"
                    onSelect(SlashCommandItem(
                        id: cmd.id, icon: cmd.icon, title: cmd.title,
                        subtitle: cmd.subtitle, kind: cmd.kind, thinkingLevel: "off"
                    ))
                } else {
                    // 当前关：开启 → 默认 low 档（支持思考的模型一般都有 low 档）
                    onSelect(SlashCommandItem(
                        id: cmd.id, icon: cmd.icon, title: cmd.title,
                        subtitle: cmd.subtitle, kind: cmd.kind, thinkingLevel: "low"
                    ))
                }
            }) {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isActive ? Color.accentColor : .secondary)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(isActive ? Color.accentColor : .primary)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(isActive ? Color.accentColor.opacity(0.7) : .secondary)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // 右侧：一体式档位切换器（整体圆角容器，点击段切换档位，选中段高亮，段间分隔线）
            HStack(spacing: 0) {
                ForEach(Array(levels.enumerated()), id: \.element.id) { index, level in
                    let isSelected = effectiveSelection == level.id
                    Button(action: {
                        onSelect(SlashCommandItem(
                            id: cmd.id, icon: cmd.icon, title: cmd.title,
                            subtitle: cmd.subtitle, kind: cmd.kind, thinkingLevel: level.id
                        ))
                    }) {
                        Text(level.label)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(isActive && isSelected ? .white : (isActive ? Color.accentColor : .secondary))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isActive && isSelected ? Color.accentColor : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    if index < levels.count - 1 {
                        Divider()
                            .frame(height: 14)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isActive ? Color.accentColor.opacity(0.4) : Color(.separator), lineWidth: 0.5)
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// 普通命令行的内容（图标 + 文字 + 右侧标记）。
    private func commandRowContent(_ cmd: SlashCommandItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: cmd.icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isDisabled(cmd) ? .gray : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(cmd.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isDisabled(cmd) ? .gray : .primary)
                Text(cmd.subtitle)
                    .font(.caption)
                    .foregroundStyle(isDisabled(cmd) ? .gray.opacity(0.7) : .secondary)
                    .lineLimit(1)
            }

            Spacer()

            if case .toggle(let isOn) = cmd.kind {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isOn ? Color.accentColor : Color(.tertiaryLabel))
            } else if isDisabled(cmd) {
                Image(systemName: "circle.slash")
                    .font(.system(size: 14))
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// 判断命令是否为禁用态。
    private func isDisabled(_ cmd: SlashCommandItem) -> Bool {
        if case .disabled = cmd.kind { return true }
        return false
    }
}
