import SwiftUI
import UniformTypeIdentifiers

// MARK: - Mount Settings

struct MountSettingsView: View {
    @State private var mounts: [MountPoint] = []
    @State private var showImporter = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if mounts.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.l("no_mounted_folders_yet"))
                            .font(.body)
                            .foregroundStyle(.secondary)
                        Text(L10n.l("tap_add_mount_folder_below_then_choose_a_folder_from_the_files_app"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Section(L10n.l("mounted")) {
                    ForEach(mounts) { mount in
                        mountRow(mount)
                    }
                    .onDelete(perform: deleteMounts)
                }
            }

            Section {
                Button {
                    showImporter = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text(L10n.l("add_mount_folder"))
                    }
                }
            } footer: {
                Text(L10n.l("select_a_folder_via_the_ios_files_app_to_mount_into_miniclaw_read_only_by_default_the_agent_can_read_its_contents_via_var_miniclaw_mounts_name_to_let_the_agent_write_enable_the_allow_write_switch_on_that_mount_writes_are_persisted_to_the_external_folder_so_please_be_careful_mount_info_remains_valid_after_the_app_restarts"))
            }
        }
        .navigationTitle(L10n.l("mounts"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !mounts.isEmpty {
                EditButton()
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert(
            L10n.l("mount_failed"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(L10n.l("ok"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear(perform: reload)
    }

    @ViewBuilder
    private func mountRow(_ mount: MountPoint) -> some View {
        NavigationLink {
            MountDetailView(mount: mount)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(mount.isMounted ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(mount.name)
                            .font(.body)
                        if mount.isWritable {
                            Text(L10n.l("writable"))
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.green.opacity(0.15), in: Capsule())
                                .foregroundStyle(.green)
                        } else {
                            Text(L10n.l("read_only"))
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(mount.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let ext = mount.externalPath {
                        Text(ext)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
            }
        }
    }

    private func reload() {
        mounts = MountStore.shared.list()
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            // 关键：File Provider（云盘/iCloud）文件夹的 startAccessingSecurityScopedResource
            // + bookmarkData 可能阻塞数秒。.fileImporter 回调运行在主线程，若在此同步执行
            // 会触发主线程看门狗（MAIN THREAD BLOCKED）、iSH 终端视图崩溃，并连带使 iSH 内
            // ls 全部无输出。故必须放到后台执行，完成后再回主线程刷新 UI。
            Task.detached(priority: .userInitiated) {
                do {
                    _ = try MountStore.shared.add(url: url)
                    await MainActor.run { reload() }
                } catch {
                    let msg = error.localizedDescription
                    await MainActor.run { errorMessage = msg }
                }
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func deleteMounts(at offsets: IndexSet) {
        for index in offsets {
            MountStore.shared.remove(id: mounts[index].id)
        }
        reload()
    }
}

// MARK: - 挂载详情（从挂载列表点进：顶部名称/路径，权限开关，浏览文件，卸载）

struct MountDetailView: View {
    let mountId: UUID
    @State private var mount: MountPoint
    @State private var showUnmount = false
    @State private var showBrowser = false
    @Environment(\.dismiss) private var dismiss

    init(mount: MountPoint) {
        self.mountId = mount.id
        _mount = State(initialValue: mount)
    }

    var body: some View {
        List {
            // 顶部：沿用列表的显示格式展示名称 + 虚拟路径 + 外部真实路径
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(mount.isMounted ? Color.accentColor : Color.secondary)
                        Text(mount.name)
                            .font(.headline)
                        permissionBadge
                    }
                    Text(mount.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let ext = mount.externalPath {
                        Text(ext)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.vertical, 4)
            }

            // 权限：允许写入（默认开启，点击可禁止）
            Section(L10n.l("permissions")) {
                Toggle(L10n.l("allow_writing"), isOn: Binding(
                    get: { mount.isWritable },
                    set: { setWritable($0) }
                ))
            }

            // 浏览文件：点「打开」以模态方式进入外部文件夹真实内容
            // （与另外两处文件管理器一致用 .sheet 呈现，避免「外层设置导航栈 + 内层 NavigationStack」嵌套导致首次 push 被弹回）
            Section(L10n.l("browse_files")) {
                Button {
                    showBrowser = true
                } label: {
                    Label(L10n.l("open_action"), systemImage: "folder")
                }
            }

            // 卸载
            Section {
                Button(role: .destructive) {
                    showUnmount = true
                } label: {
                    Label(L10n.l("uninstall"), systemImage: "eject.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(L10n.l("mount_details"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(L10n.l("confirm_unmounting_this_folder"), isPresented: $showUnmount) {
            Button(L10n.l("uninstall"), role: .destructive) { performUnmount() }
            Button(L10n.l("cancel"), role: .cancel) { }
    } message: {
        Text(L10n.l("unmount") + mount.name + "」" + L10n.l("the_agent_will_no_longer_be_able_to_access_this_folder_via_the_virtual_path_files_inside_the_external_folder_itself_will_not_be_deleted"))
    }
    .sheet(isPresented: $showBrowser) {
        MountFileBrowserView(mountName: mount.name, subPath: "")
    }
}

    private var permissionBadge: some View {
        Text(mount.isWritable ? L10n.l("writable") : L10n.l("read_only"))
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background((mount.isWritable ? Color.green : Color.secondary).opacity(0.15), in: Capsule())
            .foregroundStyle(mount.isWritable ? Color.green : Color.secondary)
    }

    private func setWritable(_ v: Bool) {
        MountStore.shared.setWritable(id: mountId, v)
        refresh()
    }

    private func refresh() {
        if let updated = MountStore.shared.list().first(where: { $0.id == mountId }) {
            mount = updated
        }
    }

    private func performUnmount() {
        MountStore.shared.remove(id: mountId)
        dismiss()
    }
}

// MARK: - 挂载文件浏览器（浏览外部文件夹真实内容，每项右侧分享按钮）
//
// 统一交给 UnifiedFileBrowser 渲染（信息丰富型行样式一致），挂载模式下每行文件带分享按钮。

struct MountFileBrowserView: View {
    let mountName: String
    var subPath: String = ""
    @State private var path: [FileBrowserLocation] = []

    /// 挂载内的 guest 路径（容器视角）：/var/MiniClaw/mounts/<name>/<subPath>。
    private var rootGuestPath: String {
        let v = "/var/MiniClaw/mounts/\(mountName)/\(subPath)".trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "/" + v
    }

    /// 挂载根目录的真实外部 URL（经 bookmark 解析到外部文件夹）。
    private var rootDirectoryURL: URL? {
        try? FileSystemManager.shared.resolveAgentPath("/var/MiniClaw/mounts/\(mountName)/\(subPath)")
    }

    var body: some View {
        NavigationStack(path: $path) {
            if let url = rootDirectoryURL {
                let rootLoc = FileBrowserLocation(
                    mode: .mount(name: mountName),
                    directoryURL: url,
                    displayGuestPath: rootGuestPath,
                    sessionID: nil
                )
                UnifiedFileBrowser(location: rootLoc, path: $path)
                    .navigationTitle(subPath.isEmpty ? mountName : (subPath as NSString).lastPathComponent)
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationDestination(for: FileBrowserLocation.self) { loc in
                        UnifiedFileBrowser(location: loc, path: $path)
                    }
            } else {
                EmptyStateView(label: L10n.l("mount_unavailable"), systemImage: "tray",
                           description: L10n.l("this_mount_is_currently_inaccessible_the_external_folder_may_have_been_removed_or_its_permission_revoked"))
                .navigationTitle(subPath.isEmpty ? mountName : (subPath as NSString).lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}
