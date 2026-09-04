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
                Toggle(String(localized: "icloud_sync"), isOn: $iCloudEnabled)
                    .onChange(of: iCloudEnabled) { newValue in
                        SettingsStore.shared.update(domain: .sync, summary: String(localized: "modify_sync_settings")) { (config: inout SyncConfig) in
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
                    Toggle(String(localized: "auto_sync"), isOn: $autoSync)
                }
            } footer: {
                Text(String(localized: "when_enabled_session_data_configuration_and_skills_will_sync_across_devices_via_icloud"))
            }

            if iCloudEnabled {
                // 账号状态
                if !accountStatus.isEmpty {
                    Section(String(localized: "account_status")) {
                        HStack {
                            Text(String(localized: "icloud_account"))
                            Spacer()
                            Text(accountStatus)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // 同步内容
                Section(String(localized: "sync_contents")) {
                    SyncContentRow(icon: "bubble.left.and.bubble.right.fill", title: String(localized: "chat_history"))
                    SyncContentRow(icon: "server.rack", title: String(localized: "provider_config"))
                    SyncContentRow(icon: "square.stack.3d.up.fill", title: String(localized: "model_group"))
                    SyncContentRow(icon: "puzzlepiece.extension.fill", title: String(localized: "skills"))
                    SyncContentRow(icon: "key.fill", title: String(localized: "env_vars"))
                    SyncContentRow(icon: "cat.fill", title: String(localized: "sync_soul"))
                    SyncContentRow(icon: "brain.fill", title: String(localized: "memory"))
                }

                // 同步状态
                Section(String(localized: "sync_status")) {
                    HStack {
                        Text(String(localized: "last_synced"))
                        Spacer()
                        if let date = lastSyncDate {
                            Text(date, style: .relative)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(String(localized: "not_yet_synced"))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if totalSent > 0 || totalReceived > 0 {
                        HStack {
                            Text(String(localized: "sent"))
                            Spacer()
                            Text(String(format: String(localized: "records"), "\(totalSent)"))
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text(String(localized: "received"))
                            Spacer()
                            Text(String(format: String(localized: "records"), "\(totalReceived)"))
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
                            Text(isSyncing ? String(localized: "syncing") : String(localized: "sync_now"))
                        }
                    }
                    .disabled(isSyncing)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .navigationTitle(String(localized: "sync"))
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
        accountStatus = String(localized: "icloud_sync_disabled")
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
