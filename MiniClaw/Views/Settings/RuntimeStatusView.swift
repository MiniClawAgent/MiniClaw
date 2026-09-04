import SwiftUI

// MARK: - Rootfs 管理

/// 设置中的 Rootfs 管理页，按四分类组织：
/// ① 运行状态（安装状态 ✓/✗、大小、路径）
/// ② 浏览文件（进入 rootfs 根目录）
/// ③ 镜像源（Alpine APK：探测 + 切换，P3 落地）
/// ④ 操作（重置 Rootfs：卸载并重装）
struct RuntimeStatusView: View {
    @State private var snapshot: RuntimeStatusSnapshot?
    @State private var showFileManager = false
    @State private var showReinstallConfirm = false
    @State private var showRestartNotice = false
    @State private var reinstallPending = false
    /// 镜像源当前选择（kind.rawValue → 源 id）。用显式状态而非直接读 UserDefaults：
    /// UserDefaults 非响应式，切源后返回本页不会自动重算，行尾仍显示旧源（已修）。
    @State private var mirrorSelection: [String: String] = [:]

    var body: some View {
        List {
            if let s = snapshot {
                // 分类一：运行状态
                Section(String(localized: "running_status")) {
                    HStack {
                        Text(String(localized: "installation_status"))
                        Spacer()
                        if s.rootfsDeployed {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text(String(localized: "installed"))
                            }
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                                Text(String(localized: "not_installed"))
                            }
                        }
                    }
                    if let p = s.rootfsPath {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "path")).font(.subheadline).foregroundStyle(.secondary)
                            Text(p)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                    }
                    if let sz = s.rootfsSizeBytes {
                        HStack {
                            Text(String(localized: "size"))
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(sz), countStyle: .file))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // 分类二：浏览文件
                Section(String(localized: "browse_files")) {
                    Button {
                        showFileManager = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                            Text(String(localized: "go_to_rootfs_root_directory"))
                        }
                    }
                }

                // 分类三：镜像源（Alpine APK / Python Pip / Node.js npm，各自进详情页切换）
                Section {
                    ForEach(MirrorKind.allCases) { kind in
                        NavigationLink {
                            MirrorDetailView(kind: kind)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: kind.icon)
                                Text(kind.displayName)
                                Spacer()
                                Text(currentMirrorName(kind))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text(String(localized: "mirror_source"))
                } footer: {
                    Text(String(localized: "switch_alpine_apk_python_pip_node_js_npm_mirrors_to_fix_install_failures_caused_by_slow_or_unstable_direct_connections"))
                        .font(.caption2)
                }

                // 分类四：操作
                Section {
                    if reinstallPending {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                                .foregroundStyle(.orange)
                                .font(.system(size: 15, weight: .semibold))
                            Text(String(localized: "reset_scheduled_will_complete_automatically_after_restarting_the_app"))
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                        }
                        .padding(.vertical, 2)
                        Button(role: .cancel) {
                            RootfsMaintenance.cancelReinstall()
                            reinstallPending = false
                            Task { await refresh() }
                        } label: {
                            Text(String(localized: "cancel_reset")).frame(maxWidth: .infinity)
                        }
                    } else {
                        Button(role: .destructive) {
                            showReinstallConfirm = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "trash")
                                Text(String(localized: "reset_rootfs_uninstall_and_reinstall"))
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                } header: {
                    Text(String(localized: "action_menu"))
                } footer: {
                    if !reinstallPending {
                        Text(String(localized: "restore_the_container_to_the_factory_alpine_image_this_clears_all_installed_software_and_changes_inside_the_container_and_automatically_redeploys_on_the_next_app_launch_terminal_state_will_sync_automatically_after_the_reset"))
                            .font(.caption2)
                    }
                }
            } else {
                Section {
                    HStack {
                        Spacer()
                        ProgressView(String(localized: "reading_rootfs_status"))
                        Spacer()
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .listStyle(.insetGrouped)
        .navigationTitle(String(localized: "rootfs_management"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .refreshable { await refresh() }
        .sheet(isPresented: $showFileManager) {
            #if ISH_ENABLED
            RootfsManagerView()
            #else
            EmptyStateView(label: String(localized: "rootfs_management"), systemImage: "exclamationmark.triangle",
                         description: String(localized: "the_current_build_does_not_include_ish"))
            #endif
        }
        .alert(String(localized: "confirm_reset_rootfs"), isPresented: $showReinstallConfirm) {
            Button(String(localized: "cancel"), role: .cancel) {}
            Button(String(localized: "reset"), role: .destructive) {
                RootfsMaintenance.requestReinstall()
                reinstallPending = true
                showRestartNotice = true
            }
        } message: {
            Text(String(localized: "this_operation_will_erase_all_installed_software_and_changes_inside_the_container_restoring_the_factory_alpine_image_it_cannot_be_undone_and_will_run_on_the_next_app_launch"))
        }
        .alert(String(localized: "reset_scheduled"), isPresented: $showRestartNotice) {
            Button(String(localized: "got_it"), role: .cancel) {}
        } message: {
            Text(String(localized: "please_fully_quit_the_app_swipe_it_away_from_the_background_and_reopen_it_the_reinstall_will_complete_automatically_on_next_launch_and_the_terminal_state_will_sync_automatically"))
        }
    }

    private func refresh() async {
        snapshot = await gatherRuntimeStatus(performLiveProbe: false)
        reinstallPending = RootfsMaintenance.isReinstallPending
        refreshMirrorSelection()
    }

    /// 从持久化重新读取三类镜像源的当前选择（每次出现本页时调用，
    /// 保证从详情页切源返回后行尾显示的是最新值）。
    private func refreshMirrorSelection() {
        var dict: [String: String] = [:]
        for kind in MirrorKind.allCases {
            dict[kind.rawValue] = MirrorManager.current(for: kind).id
        }
        mirrorSelection = dict
    }

    /// 行尾显示的当前源名称（由 mirrorSelection 状态派生）。
    private func currentMirrorName(_ kind: MirrorKind) -> String {
        let id = mirrorSelection[kind.rawValue] ?? MirrorManager.current(for: kind).id
        return kind.mirrors.first { $0.id == id }?.name ?? kind.mirrors.last!.name
    }
}

// MARK: - 镜像源详情页（Alpine APK / Python Pip / Node.js npm 共用）

/// 单个包管理器的镜像源管理页：
/// 顶部显示当前源；「测试延迟」一键探测全部候选源；列表点击即切换；行尾显示延迟 ms。
struct MirrorDetailView: View {
    let kind: MirrorKind

    @State private var probing = false
    @State private var probeResults: [String: Int]
    /// 当前选中源 id（显式状态，切换后 checkmark/顶部立即刷新，不依赖消息副效应）。
    @State private var currentID: String
    @State private var message: String?
    @State private var messageIsSuccess = false

    init(kind: MirrorKind) {
        self.kind = kind
        // @State 初始化不能引用 self.kind，用自定义 init 注入。
        _probeResults = State(initialValue: MirrorManager.lastProbe(for: kind))
        _currentID = State(initialValue: MirrorManager.current(for: kind).id)
    }
    var body: some View {
        List {
            // 顶部：当前源
            Section {
                HStack(spacing: 6) {
                    Image(systemName: kind.icon)
                    Text(String(localized: "current_mirror"))
                    Spacer()
                    Text(currentName)
                        .foregroundStyle(.secondary)
                }
                // 当前源完整地址
                Text(kind.displayURL(for: MirrorManager.current(for: kind)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            // 一键测试延迟
            Section {
                Button {
                    Task { await runProbe() }
                } label: {
                    HStack(spacing: 6) {
                        if probing {
                            ProgressView().controlSize(.small)
                            Text(String(localized: "testing_latency"))
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                            Text(String(localized: "test_latency_of_all_mirrors"))
                        }
                    }
                }
                .disabled(probing)
            } footer: {
                if let message {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(messageIsSuccess ? Color.green : Color.orange)
                }
            }

            // 可用源列表：点击直接切换，行尾显示延迟 ms
            Section(String(localized: "available_mirrors")) {
                ForEach(kind.mirrors) { entry in
                    Button {
                        apply(entry)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: currentID == entry.id
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(currentID == entry.id
                                                 ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                // 源地址（apk 拼 /alpine/，与列表口径一致）
                                Text(kind.displayURL(for: entry))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(latencyText(for: entry))
                                .font(.caption)
                                .foregroundStyle(latencyColor(for: entry))
                        }
                    }
                    .disabled(probing)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .navigationTitle(kind.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 行尾延迟标注：可达显示 ms；失败(-1)显示「超时」；未探测过显示「未测试」。
    private func latencyText(for entry: MirrorEntry) -> String {
        guard let ms = probeResults[entry.id] else { return String(localized: "not_tested") }
        return ms < 0 ? String(localized: "timeout") : "\(ms)ms"
    }

    private func latencyColor(for entry: MirrorEntry) -> Color {
        guard let ms = probeResults[entry.id] else { return .secondary }
        if ms < 0 { return .red }
        if ms < 300 { return .green }
        if ms < 1000 { return .orange }
        return .red
    }

    /// 当前选中源名称（由 currentID 派生）。
    private var currentName: String {
        kind.mirrors.first { $0.id == currentID }?.name ?? String(localized: "not_selected")
    }

    /// 一键探测全部候选源，结果按延迟升序持久化。
    private func runProbe() async {
        probing = true
        message = nil
        defer { probing = false }
        let results = await MirrorManager.probe(kind)
        probeResults = MirrorManager.lastProbe(for: kind)
        if results.isEmpty {
            messageIsSuccess = false
            message = String(localized: "all_mirrors_are_unreachable_check_your_network_and_try_again")
        } else if let fastest = results.first {
            messageIsSuccess = true
            message = String(format: String(localized: "test_complete_fastest_is_ms"), fastest.entry.name, "\(fastest.latencyMs)")
        }
    }

    /// 点击切换：写入配置并持久化。
    private func apply(_ entry: MirrorEntry) {
        do {
            try MirrorManager.apply(kind, id: entry.id)
            currentID = entry.id
            messageIsSuccess = true
            message = String(format: String(localized: "applied"), entry.name)
        } catch {
            messageIsSuccess = false
            message = String(format: String(localized: "failed_to_apply"), error.localizedDescription)
        }
    }
}
