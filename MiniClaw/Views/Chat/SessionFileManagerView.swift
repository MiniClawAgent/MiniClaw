import SwiftUI
import UIKit

// MARK: - 会话文件管理
//
// 浏览「当前会话」隔离命名空间内的文件（宿主
// Documents/MiniClaw-Sessions/<uuid>/ 下的
// workspace / attachments / browser / offloads），
// 以及所有会话共享的顶层目录（mounts / skills / memory / shared）。
// 根目录与子目录统一使用同一种行样式（彩色图标 + 文件名，.insetGrouped 列表），
// 进入任意子目录后交给 UnifiedFileBrowser 渲染。

// MARK: 会话文件管理器（入口）

struct SessionFileManagerView: View {
    let sessionID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var path: [FileBrowserLocation] = []

    var body: some View {
        NavigationStack(path: $path) {
            SessionFileManagerRootView(sessionID: sessionID, path: $path)
                .navigationTitle(String(localized: "session_files"))
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: FileBrowserLocation.self) { loc in
                    UnifiedFileBrowser(location: loc, path: $path)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(String(localized: "done")) { dismiss() }
                    }
                }
        }
    }
}

// MARK: 文件管理器根目录（本会话隔离目录 + 所有会话共享目录）
//
// 视觉与 UnifiedFileBrowser 完全一致：`.insetGrouped` 列表、彩色文件夹图标、
// 长按弹出上下文菜单（复制路径 / 删除）。点击进入子目录后由 UnifiedFileBrowser 接管。

struct SessionFileManagerRootView: View {
    let sessionID: UUID
    @Binding var path: [FileBrowserLocation]

    @State private var deleteTarget: FileBrowserLocation?
    @State private var toast: String?

    /// 会话页「共享文件夹」仅展示这 4 个目录，其余为内部配置对用户隐藏。
    private static let visibleSharedDirNames: [String] = ["mounts", "skills", "memory", "shared"]

    /// 当前会话的宿主根目录。
    private var sessionBaseURL: URL {
        SessionManager.shared.sessionHostDirectory(id: sessionID)
    }

    /// 本会话隔离目录（固定 4 个会话专属子目录）。
    private var sessionDirLocations: [FileBrowserLocation] {
        ["workspace", "attachments", "browser", "offloads"].map {
            FileBrowserLocation(
                mode: .session,
                directoryURL: sessionBaseURL.appendingPathComponent($0),
                displayGuestPath: nil,
                sessionID: sessionID
            )
        }
    }

    /// 所有会话共享的顶层目录（白名单过滤）。
    private var sharedDirLocations: [FileBrowserLocation] {
        let root = FileSystemManager.shared.miniClawRoot
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let present = Set(urls.map { $0.lastPathComponent })
        return Self.visibleSharedDirNames
            .filter { present.contains($0) }
            .map {
                FileBrowserLocation(
                    mode: .session,
                    directoryURL: root.appendingPathComponent($0),
                    displayGuestPath: nil,
                    sessionID: nil
                )
            }
    }

    var body: some View {
        List {
            Section {
                pathBar
            } header: {
                Text(String(localized: "current_path_agent_accessible"))
            }
            Section {
                ForEach(sessionDirLocations, id: \.id) { loc in
                    dirRow(loc)
                }
            } header: { Text(String(localized: "this_session")) } footer: { Text(String(localized: "visible_only_in_the_current_session_isolated_from_other_sessions")) }
            Section {
                ForEach(sharedDirLocations, id: \.id) { loc in
                    dirRow(loc)
                }
            } header: { Text(String(localized: "shared_folders")) } footer: { Text(String(localized: "shared_across_all_sessions_changes_affect_the_global_scope_e_g_skills_mounts_memory")) }
        }
        .listStyle(.insetGrouped)
        .alert(Text(String(localized: "confirm_deletion")), isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button(String(localized: "delete_action"), role: .destructive) { confirmDelete() }
            Button(String(localized: "cancel"), role: .cancel) { deleteTarget = nil }
        } message: {
            if let t = deleteTarget {
                Text(String(format: String(localized: "delete_folder"), t.directoryURL.lastPathComponent) + String(localized: "and_all_its_contents_this_action_cannot_be_undone"))
            }
        }
        .overlay(alignment: .bottom) { toastView }
    }

    // MARK: - 统一行样式（与 UnifiedFileBrowser 一致）

    @ViewBuilder
    private func dirRow(_ loc: FileBrowserLocation) -> some View {
        let name = loc.directoryURL.lastPathComponent
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 22))
                .foregroundStyle(.yellow)
                .frame(width: 28, height: 28)

            Text(name)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            path.append(loc)
        }
        .contextMenu {
            Button {
                copyPath(for: loc)
            } label: {
                Label(String(localized: "copy_path"), systemImage: "doc.on.clipboard")
            }
            Button(role: .destructive) {
                deleteTarget = loc
            } label: {
                Label(String(localized: "delete_action"), systemImage: "trash")
            }
        }
    }

    // MARK: - 路径栏

    private var pathBar: some View {
        let p = aiAccessibleGuestPath(for: sessionBaseURL)
        return Text(p)
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(nil)
            .onLongPressGesture {
                UIPasteboard.general.string = p
            }
    }

    // MARK: - 操作

    private func copyPath(for loc: FileBrowserLocation) {
        let p = aiAccessibleGuestPath(for: loc.directoryURL)
        UIPasteboard.general.string = p
        showToast(String(format: String(localized: "path_copied"), p))
    }

    private func confirmDelete() {
        guard let t = deleteTarget else { return }
        do {
            try FileManager.default.removeItem(at: t.directoryURL)
            deleteTarget = nil
        } catch {
            deleteTarget = nil
            showToast(String(format: String(localized: "delete_failed"), error.localizedDescription))
        }
    }

    private func showToast(_ msg: String) {
        toast = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if toast == msg { toast = nil }
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let t = toast {
            Text(t)
                .font(.caption)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.black.opacity(0.8), in: Capsule())
                .padding(.bottom, 48)
                .transition(.opacity)
        }
    }
}
