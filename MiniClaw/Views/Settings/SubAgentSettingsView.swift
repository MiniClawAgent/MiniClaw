import SwiftUI

/// 子代理控制（设置 → 智能体 → 子代理）：
/// 子代理恒可用（是否派发由智能体依据引导与插件角色自行判断）；
/// 用户可调运行限制（最大并发 1-4）与思考档位（follow/off/low/high）。
struct SubAgentSettingsView: View {
    @State private var subagent: SubAgentSettings = SettingsStore.shared.settings.subagent

    private let thinkingOptions: [(id: String, label: String)] = [
        ("follow", L10n.l("follow_main_model")),
        ("off", L10n.l("thinking_off")),
        ("low", L10n.l("level_low")),
        ("high", L10n.l("high"))
    ]

    var body: some View {
        Form {
            Section {
                Stepper(value: $subagent.maxConcurrent, in: 1...4, label: {
                    HStack {
                        Text(L10n.l("max_concurrency"))
                        Spacer()
                        Text("\(subagent.maxConcurrent)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                })
                .onChange(of: subagent.maxConcurrent) { newValue in
                    SettingsStore.shared.update(domain: .subagent, summary: L10n.l("change_subagent_max_concurrency")) { (s: inout SubAgentSettings) in
                        s.maxConcurrent = newValue
                    }
                }
            } header: {
                Text(L10n.l("runtime_limits"))
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.l("subagents_handle_complex_tasks_in_parallel_isolation_research_writing_planning_etc_and_can_significantly_improve_the_quality_of_multi_step_work"))
                    Text(L10n.l("maximum_number_of_simultaneously_running_subagents_including_nested_levels_up_to_4"))
                }
            }

            Section {
                Picker(L10n.l("thinking_level"), selection: $subagent.thinking) {
                    ForEach(thinkingOptions, id: \.id) { opt in
                        Text(opt.label).tag(opt.id)
                    }
                }
                .onChange(of: subagent.thinking) { newValue in
                    SettingsStore.shared.update(domain: .subagent, summary: L10n.l("change_subagent_thinking_level")) { (s: inout SubAgentSettings) in
                        s.thinking = newValue
                    }
                }
            } header: {
                Text(L10n.l("thinking_control"))
            } footer: {
                Text(L10n.l("follow_main_model_no_override_use_the_model_s_default_thinking_thinking_off_subagents_answer_quickly_and_directly_saving_tokens_at_some_quality_cost"))
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .navigationTitle(L10n.l("subagents"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // 设置可能经审计回滚/其他路径刷新，进入页面时重新同步，避免显示陈旧值。
            subagent = SettingsStore.shared.settings.subagent
        }
    }
}
