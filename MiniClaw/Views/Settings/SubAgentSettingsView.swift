import SwiftUI

/// 子代理控制（设置 → 智能体 → 子代理）：
/// 总开关 / 最大并发（1-4）/ 思考档位（参考 reasonix subagent_effort 思路）。
/// 关闭后引擎不注入 dispatch_subagent 工具，且引导段明确告知模型「子代理已被用户关闭」。
struct SubAgentSettingsView: View {
    @State private var subagent: SubAgentSettings = SettingsStore.shared.settings.subagent

    private let thinkingOptions: [(id: String, label: String)] = [
        ("follow", L10n.tr("跟随主模型")),
        ("off", L10n.tr("关闭思考")),
        ("low", L10n.tr("低")),
        ("high", L10n.tr("高"))
    ]

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $subagent.enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.tr("启用子代理"))
                        Text(L10n.tr("关闭后智能体不再派发子代理，并被告知该能力已被用户关闭"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.orange)
                .onChange(of: subagent.enabled) { _, newValue in
                    SettingsStore.shared.update(domain: .subagent, summary: L10n.tr("修改子代理开关")) { (s: inout SubAgentSettings) in
                        s.enabled = newValue
                    }
                }
            } footer: {
                Text(L10n.tr("子代理用于并行/隔离处理复杂任务（调研、写作、规划等），可显著提升多步骤任务的完成质量。"))
            }

            Section {
                Stepper(value: $subagent.maxConcurrent, in: 1...4, label: {
                    HStack {
                        Text(L10n.tr("最大并发"))
                        Spacer()
                        Text("\(subagent.maxConcurrent)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                })
                .disabled(!subagent.enabled)
                .onChange(of: subagent.maxConcurrent) { _, newValue in
                    SettingsStore.shared.update(domain: .subagent, summary: L10n.tr("修改子代理最大并发")) { (s: inout SubAgentSettings) in
                        s.maxConcurrent = newValue
                    }
                }
            } header: {
                Text(L10n.tr("运行限制"))
            } footer: {
                Text(L10n.tr("同时运行（含嵌套层级累计）的子代理数量上限，最大 4。"))
            }

            Section {
                Picker(L10n.tr("思考档位"), selection: $subagent.thinking) {
                    ForEach(thinkingOptions, id: \.id) { opt in
                        Text(opt.label).tag(opt.id)
                    }
                }
                .disabled(!subagent.enabled)
                .onChange(of: subagent.thinking) { _, newValue in
                    SettingsStore.shared.update(domain: .subagent, summary: L10n.tr("修改子代理思考档位")) { (s: inout SubAgentSettings) in
                        s.thinking = newValue
                    }
                }
            } header: {
                Text(L10n.tr("思考控制"))
            } footer: {
                Text(L10n.tr("「跟随主模型」= 不强制，按模型默认思考；「关闭思考」= 子代理快速直接作答，省 token 但质量下降。"))
            }
        }
        .navigationTitle(L10n.tr("子代理"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // 设置可能经审计回滚/其他路径刷新，进入页面时重新同步，避免显示陈旧值。
            subagent = SettingsStore.shared.settings.subagent
        }
    }
}
