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
                    Text(L10n.tr("Agent状态"))
                    Spacer()
                    Text(runtime.isAgentActive ? L10n.tr("活跃") : L10n.tr("空闲"))
                        .foregroundStyle(runtime.isAgentActive ? .green : .secondary)
                }
            } header: {
                Text(L10n.tr("状态"))
            } footer: {
                Text(L10n.tr("模糊定位用于在后台保持 App 运行，仅当「后台运行」开启且已授权时启用。"))
            }

            Section {
                Toggle(L10n.tr("后台运行"), isOn: $background.backgroundRun)
                Toggle(L10n.tr("实时活动"), isOn: $background.liveActivity)
                Toggle(L10n.tr("画中画"), isOn: $background.pictureInPicture)
            } header: {
                Text(L10n.tr("后台"))
            } footer: {
                Text(L10n.tr("「后台运行」开启后，运用灵动岛 / 实时活动显示任务进度；「实时活动」控制是否在灵动岛与锁屏渲染；「画中画」开启后，退出会话页即以画中画常驻显示运行中的任务（图标 / 会话标题 / 执行进度）。"))
            }
        }
        .navigationTitle(L10n.tr("后台"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: background) { saveBackground() }
    }

    private func saveBackground() {
        SettingsStore.shared.set(background, domain: .background, summary: L10n.tr("修改后台设置"))
    }
}
