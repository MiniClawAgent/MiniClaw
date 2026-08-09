import SwiftUI

struct EnvVarsSettingsView: View {
    @State private var envVars: [EnvVariable] = []
    @State private var isPrivacyMode: Bool = true
    @State private var showAddVar: Bool = false
    @State private var newKey: String = ""
    @State private var newValue: String = ""
    @State private var newIsSecret: Bool = true

    var body: some View {
        List {
            Section {
                Toggle(L10n.tr("隐私模式"), isOn: $isPrivacyMode)
                    .onChange(of: isPrivacyMode) { newValue in
                        SettingsStore.shared.setEnvvarsPrivacyMode(newValue)
                    }
                Text(L10n.tr("开启后，Shell 输出中的环境变量值将被掩码遮蔽。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.tr("环境变量")) {
                ForEach(envVars) { v in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v.key)
                                .font(.system(.body, design: .monospaced))
                            if v.isSecret {
                                Label(L10n.tr("加密存储，不可回读"), systemImage: "lock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(v.isSecret ? "••••••••" : v.value)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { indexSet in
                    envVars.remove(atOffsets: indexSet)
                    persist()
                }

                Button(action: { showAddVar = true }) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text(L10n.tr("添加环境变量"))
                    }
                }
            }
        }
        .navigationTitle(L10n.tr("环境变量"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddVar) {
            NavigationStack {
                Form {
                    TextField(L10n.tr("变量名"), text: $newKey)
                    TextField(L10n.tr("变量值"), text: $newValue)
                    Toggle(L10n.tr("加密存储"), isOn: $newIsSecret)
                }
                .navigationTitle(L10n.tr("添加变量"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.tr("取消")) { showAddVar = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.tr("添加")) { addVar() }
                    }
                }
            }
        }
        .onAppear {
            envVars = SettingsStore.shared.settings.envvars
            isPrivacyMode = SettingsStore.shared.settings.envvarsPrivacyMode
        }
    }

    private func persist() {
        SettingsStore.shared.set(envVars, domain: .envvars, summary: L10n.tr("更新环境变量"))
    }

    private func addVar() {
        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { showAddVar = false; return }
        envVars.append(EnvVariable(key: key, value: newValue, isSecret: newIsSecret))
        newKey = ""
        newValue = ""
        newIsSecret = true
        showAddVar = false
        persist()
    }
}
