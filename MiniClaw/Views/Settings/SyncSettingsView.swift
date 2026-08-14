import SwiftUI

// MARK: - Sync Settings

struct SyncSettingsView: View {
    @State private var iCloudEnabled: Bool = false
    @State private var autoSync: Bool = true
    @State private var lastSyncDate: Date?
    @State private var isSyncing: Bool = false
    @State private var accountStatus: String = ""
    @State private var totalSent: Int = 0
    @State private var totalReceived: Int = 0

    var body: some View {
        List {
            Section {
                Toggle(L10n.l("icloud_sync"), isOn: $iCloudEnabled)
                    .onChange(of: iCloudEnabled) { newValue in
                        SettingsStore.shared.update(domain: .sync, summary: L10n.l("modify_sync_settings")) { (config: inout SyncConfig) in
                            config.iCloudEnabled = newValue
                        }
                        if newValue {
                            checkAccountStatus()
                            SyncBootstrap.startIfNeeded()
                        } else {
                            SyncCore.shared.stop()
                        }
                    }
                if iCloudEnabled {
                    Toggle(L10n.l("auto_sync"), isOn: $autoSync)
                }
            } footer: {
                Text(L10n.l("when_enabled_session_data_configuration_and_skills_will_sync_across_devices_via_icloud"))
            }

            if iCloudEnabled {
                // 账号状态
                if !accountStatus.isEmpty {
                    Section(L10n.l("account_status")) {
                        HStack {
                            Text(L10n.l("icloud_account"))
                            Spacer()
                            Text(accountStatus)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // 同步内容
                Section(L10n.l("sync_contents")) {
                    SyncContentRow(icon: "bubble.left.and.bubble.right.fill", title: L10n.l("chat_history"))
                    SyncContentRow(icon: "server.rack", title: L10n.l("provider_config"))
                    SyncContentRow(icon: "square.stack.3d.up.fill", title: L10n.l("model_group"))
                    SyncContentRow(icon: "puzzlepiece.extension.fill", title: L10n.l("skills"))
                    SyncContentRow(icon: "key.fill", title: L10n.l("env_vars"))
                    SyncContentRow(icon: "cat.fill", title: L10n.l("sync_soul"))
                    SyncContentRow(icon: "brain.fill", title: L10n.l("memory"))
                }

                // 同步状态
                Section(L10n.l("sync_status")) {
                    HStack {
                        Text(L10n.l("last_synced"))
                        Spacer()
                        if let date = lastSyncDate {
                            Text(date, style: .relative)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(L10n.l("not_yet_synced"))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if totalSent > 0 || totalReceived > 0 {
                        HStack {
                            Text(L10n.l("sent"))
                            Spacer()
                            Text(String(format: L10n.l("records"), "\(totalSent)"))
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text(L10n.l("received"))
                            Spacer()
                            Text(String(format: L10n.l("records"), "\(totalReceived)"))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        Task { await performSync() }
                    } label: {
                        HStack {
                            if isSyncing {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                            Text(isSyncing ? L10n.l("syncing") : L10n.l("sync_now"))
                        }
                    }
                    .disabled(isSyncing)
                }
            }
        }
        .navigationTitle(L10n.l("sync"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let config = SettingsStore.shared.settings.sync
            iCloudEnabled = config.iCloudEnabled
            autoSync = config.autoSync
            lastSyncDate = config.lastSyncDate
            if iCloudEnabled { checkAccountStatus() }
        }
    }

    private func checkAccountStatus() {
        // CloudKit transport 当前不可用（entitlements 已移除，2026-08-03）。
        // 后续重做 iCloud 同步时恢复此检查。
        accountStatus = "iCloud 同步已禁用"
    }

    private func performSync() async {
        isSyncing = true
        defer { isSyncing = false }

        SyncCore.shared.markDirty(recordType: "ProviderConfigV2", recordId: "provider-config")
        SyncCore.shared.markDirty(recordType: "SoulV2", recordId: "soul")
        await SyncCore.shared.sendNow()
        await SyncCore.shared.fetchFromAllTransports()

        lastSyncDate = Date()
        totalSent = SyncCore.shared.totalSent
        totalReceived = SyncCore.shared.totalReceived
    }
}

/// 同步内容条目行
private struct SyncContentRow: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(.cyan, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(title)
                .font(.subheadline)
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        }
    }
}
