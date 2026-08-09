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
                Section(L10n.tr("运行状态")) {
                    HStack {
                        Text(L10n.tr("安装状态"))
                        Spacer()
                        if s.rootfsDeployed {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text(L10n.tr("已安装"))
                            }
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                                Text(L10n.tr("未安装"))
                            }
                        }
                    }
                    if let p = s.rootfsPath {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.tr("路径")).font(.subheadline).foregroundStyle(.secondary)
                            Text(p)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                    }
                    if let sz = s.rootfsSizeBytes {
                        HStack {
                            Text(L10n.tr("大小"))
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(sz), countStyle: .file))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // 分类二：浏览文件
                Section(L10n.tr("浏览文件")) {
                    Button {
                        showFileManager = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                            Text(L10n.tr("进入 Rootfs 根目录"))
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
                    Text(L10n.tr("镜像源"))
                } footer: {
                    Text(L10n.tr("切换 Alpine APK / Python Pip / Node.js npm 软件源，解决国内直连慢/不稳导致的安装失败。"))
                        .font(.caption2)
                }

                // 分类四：操作
                Section {
                    if reinstallPending {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                                .foregroundStyle(.orange)
                                .font(.system(size: 15, weight: .semibold))
                            Text(L10n.tr("已排定重置，重启 App 后自动完成"))
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                        }
                        .padding(.vertical, 2)
                        Button(role: .cancel) {
                            RootfsMaintenance.cancelReinstall()
                            reinstallPending = false
                            Task { await refresh() }
                        } label: {
                            Text(L10n.tr("取消重置")).frame(maxWidth: .infinity)
                        }
                    } else {
                        Button(role: .destructive) {
                            showReinstallConfirm = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "trash")
                                Text(L10n.tr("重置 Rootfs（卸载并重装）"))
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                } header: {
                    Text(L10n.tr("操作"))
                } footer: {
                    if !reinstallPending {
                        Text(L10n.tr("将容器恢复到出厂 Alpine 镜像：清除容器内所有已安装软件与改动，并在下次启动 App 时自动重新部署。重置完成后终端状态会自动同步。"))
                            .font(.caption2)
                    }
                }
            } else {
                Section {
                    HStack {
                        Spacer()
                        ProgressView(L10n.tr("正在读取 Rootfs 状态…"))
                        Spacer()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.tr("Rootfs 管理"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .refreshable { await refresh() }
        .sheet(isPresented: $showFileManager) {
            #if ISH_ENABLED
            RootfsManagerView()
            #else
            ContentUnavailableView {
                Label(L10n.tr("Rootfs 管理"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(L10n.tr("当前构建未集成 iSH。"))
            }
            #endif
        }
        .alert(L10n.tr("确认重置 Rootfs？"), isPresented: $showReinstallConfirm) {
            Button(L10n.tr("取消"), role: .cancel) {}
            Button(L10n.tr("重置"), role: .destructive) {
                RootfsMaintenance.requestReinstall()
                reinstallPending = true
                showRestartNotice = true
            }
        } message: {
            Text(L10n.tr("此操作将清除容器内所有已安装软件与改动，恢复出厂 Alpine 镜像，且不可撤销。将在下次启动 App 时执行。"))
        }
        .alert(L10n.tr("已排定重置"), isPresented: $showRestartNotice) {
            Button(L10n.tr("知道了"), role: .cancel) {}
        } message: {
            Text(L10n.tr("请完全退出（从后台划掉）并重新打开 App，重装将在下次启动时自动完成，终端状态会自动同步。"))
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
                    Text(L10n.tr("当前源"))
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
                            Text(L10n.tr("正在测试延迟…"))
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                            Text(L10n.tr("测试所有源延迟"))
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
            Section(L10n.tr("可用源")) {
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
        .navigationTitle(kind.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 行尾延迟标注：可达显示 ms；失败(-1)显示「超时」；未探测过显示「未测试」。
    private func latencyText(for entry: MirrorEntry) -> String {
        guard let ms = probeResults[entry.id] else { return L10n.tr("未测试") }
        return ms < 0 ? L10n.tr("超时") : "\(ms)ms"
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
        kind.mirrors.first { $0.id == currentID }?.name ?? L10n.tr("未选择")
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
            message = L10n.tr("全部镜像源均不可达，请检查网络后重试。")
        } else if let fastest = results.first {
            messageIsSuccess = true
            message = String(format: L10n.tr("测试完成：最快为 %@（%@ms）"), fastest.entry.name, "\(fastest.latencyMs)")
        }
    }

    /// 点击切换：写入配置并持久化。
    private func apply(_ entry: MirrorEntry) {
        do {
            try MirrorManager.apply(kind, id: entry.id)
            currentID = entry.id
            messageIsSuccess = true
            message = String(format: L10n.tr("已应用 %@"), entry.name)
        } catch {
            messageIsSuccess = false
            message = String(format: L10n.tr("应用失败：%@"), error.localizedDescription)
        }
    }
}
