import SwiftUI

// MARK: - 后台设置（从「权限与后台」进入）

struct BackgroundSettingsView: View {
    @State private var background: BackgroundSettings = SettingsStore.shared.settings.background
    /// 订阅运行时状态，显示「Agent状态：活跃 / 空闲」。
    @ObservedObject private var runtime = AgentRuntimeStatus.shared

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(L10n.l("agent_status"))
                    Spacer()
                    Text(runtime.isAgentActive ? L10n.l("active") : L10n.l("idle_status"))
                        .foregroundStyle(runtime.isAgentActive ? .green : .secondary)
                }
            } header: {
                Text(L10n.l("status"))
            } footer: {
                Text(L10n.l("coarse_location_keeps_the_app_running_in_the_background_it_is_enabled_only_when_background_run_is_on_and_permission_is_granted"))
            }

            Section {
                Toggle(L10n.l("background_run"), isOn: $background.backgroundRun)
                Toggle(L10n.l("live_activity"), isOn: $background.liveActivity)
                Toggle(L10n.l("picture_in_picture"), isOn: $background.pictureInPicture)
            } header: {
                Text(L10n.l("background"))
            } footer: {
                Text(L10n.l("when_background_run_is_on_live_island_live_activity_shows_task_progress_live_activity_controls_rendering_on_the_island_and_lock_screen_picture_in_picture_shows_the_running_task_icon_title_progress_as_a_persistent_pip_window_after_you_leave_the_chat_page"))
            }
        }
        .navigationTitle(L10n.l("background"))
        .navigationBarTitleDisplayMode(.inline)
        // iOS16 兼容:闭包显式带参,强制匹配 onChange(of:) 单参重载(iOS17 新增无参 action 重载会优先选中)。
        .onChange(of: background) { _ in saveBackground() }
    }

    private func saveBackground() {
        SettingsStore.shared.set(background, domain: .background, summary: L10n.l("edit_background_settings"))
    }
}
