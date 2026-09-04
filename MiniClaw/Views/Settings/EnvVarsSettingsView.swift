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
                Toggle(String(localized: "privacy_mode"), isOn: $isPrivacyMode)
                    .onChange(of: isPrivacyMode) { newValue in
                        SettingsStore.shared.setEnvvarsPrivacyMode(newValue)
                    }
                Text(String(localized: "when_enabled_environment_variable_values_in_shell_output_will_be_masked"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "environment_variables")) {
                ForEach(envVars) { v in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v.key)
                                .font(.system(.body, design: .monospaced))
                            if v.isSecret {
                                Label(String(localized: "encrypted_storage_cannot_be_read_back"), systemImage: "lock.fill")
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
                        Text(String(localized: "add_environment_variable"))
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .navigationTitle(String(localized: "environment_variables"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddVar) {
            NavigationStack {
                Form {
                    TextField(String(localized: "variable_name"), text: $newKey)
                    TextField(String(localized: "variable_value"), text: $newValue)
                    Toggle(String(localized: "encrypted_storage"), isOn: $newIsSecret)
                }
                .scrollContentBackground(.hidden)
                .background(ThemeBackground(slot: .settings))
                .navigationTitle(String(localized: "add_variable"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "cancel")) { showAddVar = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "add")) { addVar() }
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
        SettingsStore.shared.set(envVars, domain: .envvars, summary: String(localized: "update_environment_variables"))
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
