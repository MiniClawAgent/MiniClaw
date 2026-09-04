import SwiftUI

// MARK: - Shared Folder Settings

struct SharedFolderSettingsView: View {
    @State private var sharedFolders: [String] = [
        "/var/MiniClaw/shared/projects",
        "/var/MiniClaw/shared/datasets",
    ]

    var body: some View {
        List {
            Section(String(localized: "shared_folders")) {
                ForEach(sharedFolders, id: \.self) { folder in
                    HStack {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.cyan)
                        Text(folder)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .onDelete { indexSet in
                    sharedFolders.remove(atOffsets: indexSet)
                }

                Button(action: {}) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text(String(localized: "add_shared_folder"))
                    }
                }
            }

            Section {
                Text(String(localized: "files_in_the_shared_folder_persist_across_sessions_both_the_agent_and_shell_can_read_and_write_them"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .navigationTitle(String(localized: "shared_folders"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
