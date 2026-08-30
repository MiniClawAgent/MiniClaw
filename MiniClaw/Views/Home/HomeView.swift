import SwiftUI
import UIKit
import Combine

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    /// 订阅界面语言单例：语言切换时 `current` 变化触发本视图重渲染，
    /// 让首页所有 `L10n.tr` 文案（搜索栏、空状态、分组标题、菜单等）以新语言重新求值。
    @ObservedObject private var l10n = L10n.shared
    /// 场景相位：从后台返回前台时主动重载列表（见下方 .onChange），
    /// 避免「切后台再回来列表空白」（@State 在挂起/回收期间被重置的情形）。
    @Environment(\.scenePhase) private var scenePhase
    /// 首页会话列表：不依赖 `@Query` 的自动刷新（在 NavigationStack push/pop 时机下
    /// `@Query` 可能不重新拉取，表现为「发消息/建会话返回首页看不到」）。改为显式
    /// `modelContext.fetch` + 在「上下文保存 / 从聊天返回」时主动重载，列表永远反映真实存储。
    @ObservedObject private var sessionManager = SessionManager.shared
    /// 可见会话（过滤未发言空会话）。基于 sessionManager.sessions 实时派生——置顶等
    /// 成员级变更经 objectWillChange 广播后本视图重算，立即生效（2026-08-13 治本：
    /// 此前 @State 拷贝数组，ChatSession 是 class，成员变更后新旧数组元素引用相同、
    /// 判等不变 → SwiftUI 不重渲染，置顶要等页面刷新才生效）。
    private var sessions: [ChatSession] {
        sessionManager.sessions.filter { !$0.messages.isEmpty }
    }
    /// 首次加载中标记：首帧（.task 的 fetch 完成前）显示加载指示而非「空态」——
    /// 否则冷启动会先闪一下"欢迎使用"空态再突然恢复全部会话（用户误以为数据丢失）。
    /// 仅首次加载置位；后续 reloadSessions（保存/回前台/返回）不影响它。
    @State private var isLoadingSessions = true
    /// 未完成（可续跑）会话集合：检查点为 `paused` / `interrupted` 的会话。
    /// 用于首页图标外圈橙色边框徽标，标记「上次回复中断、可继续」。
    @State private var incompleteSessionIDs: Set<UUID> = []
    /// 草稿刷新令牌（2026-08-13）：草稿 blob 删除/落盘完成广播后递增，
    /// 传入 sessionRow 强制重算笔图标，杜绝「输入框已空但笔图标残留」。
    @State private var draftRefreshToken = 0

    @State private var isSearching: Bool = false
    @State private var searchText: String = ""
    @State private var showBrowserSheet: Bool = false
    /// 顶部标题区点击入口：智能体名 → 灵魂设置；模型名 → 模型管理（与会话页完全一致）。
    @State private var showSoulSettings: Bool = false
    @State private var showModelManagement: Bool = false
    @State private var showTerminal: Bool = false
    @State private var showRootfsManager: Bool = false
    /// Alpine/iSH 运行时是否已启动：控制「终端」菜单项是否可点击（未启动则灰色禁用）。
    @State private var alpineReady: Bool = false
    @FocusState private var searchFocused: Bool

    // 多选 / 长按操作相关状态
    @State private var isSelectionMode: Bool = false
    @State private var selectedSessionIDs: Set<UUID> = []
    @State private var showEditTitle: Bool = false
    @State private var editingSession: ChatSession?
    @State private var editingTitle: String = ""
    /// 会话分享载荷：`.sheet(item:)` 绑定要求值在呈现帧存在（Identifiable），
    /// 从机制上消除「先写 URL 再置开关」同帧竞态导致的首帧白屏。
    private struct SessionSharePayload: Identifiable {
        let id = UUID()
        let urls: [URL]
    }

    @State private var sharePayload: SessionSharePayload?
    @State private var showDeleteConfirm: Bool = false

    private var filteredSessions: [ChatSession] {
        if searchText.isEmpty {
            return sessions
        }
        return sessions.filter { session in
            session.title.localizedCaseInsensitiveContains(searchText) ||
            session.messages.contains { $0.content.localizedCaseInsensitiveContains(searchText) }
        }
    }

    private var groupedSessions: [(group: SessionGroup, sessions: [ChatSession])] {
        var groups: [SessionGroup: [ChatSession]] = [:]
        for s in sessions {
            let g = categorizedGroup(s)
            groups[g, default: []].append(s)
        }
        return SessionGroup.displayOrder.compactMap { g in
            guard let items = groups[g], !items.isEmpty else { return nil }
            return (g, items.sorted { $0.updatedAt > $1.updatedAt })
        }
    }

    private func categorizedGroup(_ session: ChatSession) -> SessionGroup {
        if session.isPinned { return .pinned }
        let calendar = Calendar.current
        let now = Date()
        let day = calendar.startOfDay(for: session.updatedAt)
        let today = calendar.startOfDay(for: now)
        if day == today { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday { return .yesterday }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: today), day > weekAgo { return .thisWeek }
        if let monthAgo = calendar.date(byAdding: .month, value: -1, to: today), day > monthAgo { return .thisMonth }
        return .earlier
    }

    // MARK: - 会话加载（显式重载，规避 @Query 在导航时机下不刷新）
    @MainActor
    private func reloadSessions() {
        // 内存态为唯一可信源（SessionManager.load 启动时全量加载,变更即时落盘）。
        let loaded = SessionManager.shared.sessions
        // sessions 现为 computed（基于 sessionManager.sessions 实时过滤），无需拷贝赋值。
        // 方案B：kill 后状态闭环。把「上次被系统杀死、且本进程已无存活运行时」的检查点
        // 从 running 翻成 interrupted，使「未完成任务」语义准确。
        // 关键守卫：仅当 appState.chatRuntimes 中已无该会话运行时才翻——后台挂起/运行中
        // 导航回首页的会话仍有存活运行时（App 只是被挂起或仍在跑，进程没死），任务其实
        // 在进行，绝不能误标为中断，否则回前台任务在跑、橙环却一直挂着（用户已报的 bug）。
        // recoverIfNeeded 对 running/interrupted 同样自动续跑，故翻状态无副作用；且本调用
        // 幂等（仅 running→interrupted 一次）。
        // 线程治理（2026-08-09）：2×N 次检查点读盘/写盘移后台（AgentTaskStore 内部有
        // 串行队列 + @unchecked Sendable，任意线程安全），主线程只保留 fetch 与一次赋值。
        // Swift 6 并发：detached 闭包不捕获 self（只收值类型参数），回主线程仅赋值 @State。
        let ids = loaded.map(\.id)
        let liveRuntimeIDs = Set(appState.chatRuntimes.keys)
        Task { @MainActor in
            let incomplete = await Task.detached(priority: .userInitiated) {
                for sid in ids where !liveRuntimeIDs.contains(sid) {
                    AgentTaskStore.shared.markInterruptedIfRunning(sessionID: sid)
                }
                // 注入「未完成（可续跑）」会话集合：驱动首页图标橙色边框徽标。
                // 仅检查点为 paused / interrupted 的会话计入（running 视为进行中、不标橙环）。
                // markInterruptedIfRunning 已先把 running→interrupted 落盘，故此处 load 可见最新状态。
                var result = Set<UUID>()
                for sid in ids {
                    if let st = AgentTaskStore.shared.load(sessionID: sid)?.status,
                       st == .paused || st == .interrupted {
                        result.insert(sid)
                    }
                }
                return result
            }.value
            incompleteSessionIDs = incomplete
        }
    }

    var body: some View {
        mainContent
    }

    /// iOS16 适配:body 表达式过长触发类型检查超时,拆为独立子视图。
    private var mainContent: some View {
        ZStack {
            // 背景主题挂载点：无主题时组件内部回退系统背景（视觉与现状一致）。
            ThemeBackground(slot: .home)

            VStack(spacing: 0) {
                // 搜索栏直接嵌在当前列表顶部：保持同一列表格式，仅就地过滤，不切到独立界面。
                // 由右下角浮动搜索按钮（或下拉，已移除）进入，聚焦与键盘由 onChange(isSearching) 处理。
                if isSearching {
                    searchBar
                }

                Group {
                    if isLoadingSessions {
                        loadingView
                    } else if sessions.isEmpty {
                        emptyStateView
                    } else if isSearching && !searchText.isEmpty && filteredSessions.isEmpty {
                        EmptyStateView.search(text: searchText)
                    } else if isSearching {
                        // 搜索中：沿用首页同样的时间分组排序（空文本显示全部，有文本按关键字过滤）
                        groupedListView(searchText.isEmpty ? groupedSessions : filteredGroupedSessions)
                    } else {
                        groupedSessionList
                    }
                }
                .frame(maxHeight: .infinity)
            }

            floatingButtons
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isSelectionMode {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.l("cancel")) { exitSelectionMode() }
                        .fontWeight(.medium)
                }
                ToolbarItem(placement: .principal) {
                    Text("\(selectedSessionIDs.count) " + L10n.l("item_s_selected"))
                        .font(.headline)
                        .fontWeight(.semibold)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selectedSessionIDs.count == sessions.count && !sessions.isEmpty ? L10n.l("deselect_all_action") : L10n.l("select_all_action")) {
                        if selectedSessionIDs.count == sessions.count && !sessions.isEmpty {
                            selectedSessionIDs.removeAll()
                        } else {
                            selectAll()
                        }
                    }
                    .fontWeight(.medium)
                }
            } else {
                ToolbarItem(placement: .topBarLeading) {
                    settingsButton
                }
                ToolbarItem(placement: .principal) {
                    agentTitleView
                }
                ToolbarItem(placement: .topBarTrailing) {
                    optionsMenu
                }
            }
        }
        .onChange(of: isSearching) { searching in
            // 进入搜索：自动聚焦内联输入框；退出：失焦
            searchFocused = searching
        }
        .fullScreenCover(isPresented: $showTerminal) {
            #if ISH_ENABLED
            TerminalView()
            #else
            UnavailablePlaceholder(title: L10n.l("terminal_unavailable"), message: L10n.l("the_current_build_does_not_include_the_ish_runtime"))
            #endif
        }
        .sheet(isPresented: $showRootfsManager) {
            #if ISH_ENABLED
            RootfsManagerView()
            #else
            UnavailablePlaceholder(title: L10n.l("rootfs_management_unavailable"), message: L10n.l("the_current_build_does_not_include_the_ish_runtime"))
            #endif
        }
        .sheet(isPresented: $appState.showSettings) {
            NavigationStack {
                SettingsView()
            }
        }
        .alert(Text(L10n.l("edit_title")), isPresented: $showEditTitle) {
            TextField(L10n.l("title"), text: $editingTitle)
            Button(L10n.l("cancel"), role: .cancel) { editingSession = nil }
            Button(L10n.l("save")) {
                if let session = editingSession {
                    let trimmed = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        session.title = trimmed
                        session.titleIsPlaceholder = false
                    }
                    SessionManager.shared.persist(session)
                    // 标题变更回传：刷新该会话 Live Activity 的标题（若正在运行）。
                    if let sid = editingSession?.id {
                        BackgroundTaskController.shared.agentDidUpdateSession(sessionID: sid.uuidString)
                    }
                }
                editingSession = nil
            }
        } message: {
            Text(L10n.l("enter_a_new_title_for_this_session"))
        }
        .confirmationDialog(
            Text(L10n.l("delete_label_space") + "\(selectedSessionIDs.count)" + L10n.l("conversations")),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.l("delete_action"), role: .destructive) { deleteSelected() }
            Button(L10n.l("cancel"), role: .cancel) {}
        }
        .sheet(item: $sharePayload) { payload in
            ShareSheet(items: payload.urls as [Any])
        }
        .fullScreenCover(isPresented: $showSoulSettings) {
            // 与会话页一致：包 NavigationStack——视图的「关闭/保存」按钮在 toolbar 上，
            // 无导航容器时 toolbar 不渲染，会退不出去。
            NavigationStack {
                SoulSettingsView(dismissAction: { showSoulSettings = false })
            }
        }
        .fullScreenCover(isPresented: $showModelManagement) {
            NavigationStack {
                GroupsSettingsView(dismissAction: { showModelManagement = false })
            }
        }
        .sheet(isPresented: $showBrowserSheet) {
            BrowserView()
        }
        .task {
            // 会话持久层已由 App 启动时加载(SessionManager.load 仅在 MiniClawApp.init 执行一次)。
            // 此处**不再**重复调 load():load 会从 SQLite 重读并整体覆盖内存数组,而 persist
            // 是异步 fire-and-forget——两者无次序保证,会把"运行中、写尚未落库"的会话从列表顶掉
            // (2026-08-12 回归修复)。返回首页只需拷贝内存数组(reloadSessions),内存态才是唯一可信源。
            reloadSessions()
            // 无论加载成败都结束加载态：失败时列表为空，显示空态而非永久转圈。
            isLoadingSessions = false
            // P1-4：冷启动竞态兜底——若 onOpenURL 早于本 configure 触发（尚无法建会话），
            // 此处重试被推迟的深链派任务。
            appState.retryPendingDeepLink()
        }
        .task {
            // 轮询 iSH/Alpine 启动状态，供右上角「终端」菜单项启用/置灰判断。
            // 关键：若尚未 boot，每轮主动补调预热去重试（prewarmBootInBackground
            // 串行于 bootQueue，已成功即秒退、失败会重跑 do_boot），确保杀进程重开后
            // 内核必定被自动拉起，无需用户手动点「运行检测」。
            #if ISH_ENABLED
            while !Task.isCancelled {
                if MiniClawiSHIsBooted() {
                    alpineReady = true
                    break
                }
                LinuxShellRuntime.prewarmBootInBackground()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            #else
            alpineReady = false
            #endif
        }
        // 任意会话持久化（建会话 / 发消息 / 改标题 / 删除等）后主动重载列表，
        // 保证首页始终反映真实存储（iOS16 适配:原 SwiftData/CoreData 通知已随存储层移除,
        // 改为直接订阅 SessionManager 的 @Published sessions)。
        // 会话页切换：返回首页（selectedSession 被清空）时强制重载，双保险；
        // 进入会话页时关闭常驻 PiP（任务完成后的「已完成」悬浮窗，用户回会话查看结果即关闭）。
        .onChange(of: appState.selectedSession?.id) { _ in
            if appState.selectedSession == nil {
                reloadSessions()
            } else {
                TaskPipController.shared.dismissIfShowing()
            }
        }
        // 从后台返回前台时主动重载列表：若 @State 在挂起/被系统回收期间被重置，
        // 回到前台即按真实存储重建，避免「切后台再回来列表变空白」。
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                reloadSessions()
            }
        }
        // 真正订阅 SessionManager(2026-08-12 修复)：此前「改为直接订阅 @Published sessions」
        // 只是注释,列表仅靠生命周期快照刷新——onDisappear 删除空会话/标题写回后首页不刷新
        // (陈旧引用残留)。objectWillChange 覆盖两类变更:数组级(@Published willSet,新增/删除)
        // 与成员级(标题写回处手动 send),统一触发重载。
        .onReceive(SessionManager.shared.objectWillChange) { _ in
            reloadSessions()
        }
        // 2026-08-13 治标：草稿落盘/清空完成广播 → 递增令牌重算各行 hasDraft，
        // 笔图标即时消失（不依赖列表其他刷新信号）。
        .onReceive(NotificationCenter.default.publisher(for: PendingMessageStore.pendingDraftDidChange)) { _ in
            draftRefreshToken += 1
        }
    }

    // MARK: - 加载态

    /// 首次加载会话时显示（冷启动 fetch 完成前）。与「空态」区分：
    /// 空态表示"确实没有会话"，加载态表示"数据还在路上"。
    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text(L10n.l("loading_session"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text(L10n.l("welcome_to_miniclaw"))
                .font(.title2)
                .fontWeight(.semibold)

            Text(L10n.l("tap_the_bottom_left_button_to_start_a_new_session"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button(action: { createNewSession() }) {
                Label(L10n.l("start_new_session"), systemImage: "plus.circle.fill")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
    }

    // MARK: - Session List

    private func sessionList(_ list: [ChatSession]) -> some View {
        List {
            ForEach(list) { session in
                sessionRow(session)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func groupedListView(_ groups: [(group: SessionGroup, sessions: [ChatSession])]) -> some View {
        List {
            ForEach(groups, id: \.group) { item in
                Section {
                    ForEach(item.sessions) { session in
                        sessionRow(session)
                    }
                } header: {
                    Text(L10n.l(item.group.label))
                        .font(.footnote)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var groupedSessionList: some View {
        groupedListView(groupedSessions)
    }

    /// 搜索结果按首页同样的时间分组排序（置顶/今天/昨天/本周/本月/更早），组内按关键字过滤。
    private var filteredGroupedSessions: [(group: SessionGroup, sessions: [ChatSession])] {
        groupedSessions.compactMap { group, items in
            let filtered = items.filter { session in
                session.title.localizedCaseInsensitiveContains(searchText) ||
                session.messages.contains { $0.content.localizedCaseInsensitiveContains(searchText) }
            }
            return filtered.isEmpty ? nil : (group, filtered)
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: ChatSession) -> some View {
        let base = SessionRowView(
            session: session,
            highlight: isSearching ? searchText : "",
            selectionMode: isSelectionMode,
            isSelected: selectedSessionIDs.contains(session.id),
            isIncomplete: incompleteSessionIDs.contains(session.id),
            draftRefreshID: draftRefreshToken
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelectionMode {
                toggleSelection(session)
            } else {
                // 搜索结果点击：记录首个命中关键字的消息，供 ChatView 打开后滚动定位
                appState.scrollToMessageID = firstMatchedMessageID(in: session)
                appState.selectedSession = session
            }
        }

        if isSelectionMode {
            base
        } else {
            base
                .contextMenu { contextMenuContent(for: session) }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deleteSession(session)
                    } label: {
                        Label(L10n.l("delete_action"), systemImage: "trash")
                    }

                    Button {
                        togglePin(session)
                    } label: {
                        Label(session.isPinned ? L10n.l("unpin_action") : L10n.l("pin_action"), systemImage: session.isPinned ? "pin.slash.fill" : "pin.fill")
                    }
                    .tint(.orange)
                }
        }
    }

    /// 长按会话弹出的操作菜单：导出（就地展开 JSON/文本 子菜单）/ 编辑标题 / 选择（进入多选）。
    @ViewBuilder
    private func contextMenuContent(for session: ChatSession) -> some View {
        Menu {
            Button("JSON") { generateExport(sessions: [session], as: .json) }
            Button(L10n.l("text")) { generateExport(sessions: [session], as: .text) }
        } label: {
            Label(L10n.l("export"), systemImage: "square.and.arrow.up")
        }
        Button {
            editingSession = session
            editingTitle = session.title
            showEditTitle = true
        } label: {
            Label(L10n.l("edit_title"), systemImage: "pencil")
        }
        Button {
            enterSelectionMode(preselect: [session.id])
        } label: {
            Label(L10n.l("select"), systemImage: "checkmark.circle")
        }
    }

    /// 返回会话中首个命中关键字的消息 ID（标题命中但内容未命中时返回 nil，由 ChatView 回退到底部）。
    private func firstMatchedMessageID(in session: ChatSession) -> UUID? {
        guard !searchText.isEmpty else { return nil }
        return session.messages.first(where: { $0.content.localizedCaseInsensitiveContains(searchText) })?.id
    }

    // MARK: - Floating Buttons

    private var floatingButtons: some View {
        VStack {
            Spacer()
            HStack(spacing: 16) {
                if !isSelectionMode {
                    // 新会话：非多选模式才显示（多选时仅保留导出 / 删除）
                    circleButton(
                        systemImage: "plus",
                        foreground: .white,
                        fill: Color(red: 0.098, green: 0.549, blue: 0.996),
                        shadow: Color(red: 0.098, green: 0.549, blue: 0.996).opacity(0.4)
                    ) {
                        createNewSession()
                    }
                }

                Spacer()

                if isSelectionMode {
                    // 导出选中会话：就地展开 JSON/文本 菜单（锚定在按钮位置）
                    exportMenuButton
                    // 删除选中会话（红色，强调危险操作）
                    circleButton(
                        systemImage: "trash",
                        foreground: .white,
                        fill: Color(red: 0.937, green: 0.259, blue: 0.235),
                        shadow: Color(red: 0.937, green: 0.259, blue: 0.235).opacity(0.4)
                    ) {
                        showDeleteConfirm = true
                    }
                } else {
                    // 搜索
                    circleButton(
                        systemImage: "magnifyingglass",
                        foreground: .primary,
                        fill: .ultraThinMaterial,
                        shadow: .black.opacity(0.15)
                    ) {
                        isSearching = true
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    /// 统一圆形悬浮按钮外观（与新会话按钮一致：56×56、阴影、白色 SF Symbol）。
    /// 仅外观、不含点击行为，供普通 Button 与 Menu 的 label 共用。
    private func circleShape(
        systemImage: String,
        foreground: Color,
        fill: some ShapeStyle,
        shadow: Color
    ) -> some View {
        Circle()
            .fill(fill)
            .frame(width: 56, height: 56)
            .overlay {
                Image(systemName: systemImage)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(foreground)
            }
            .shadow(color: shadow, radius: 8, y: 4)
    }

    /// 统一圆形悬浮按钮（带点击行为）。
    private func circleButton(
        systemImage: String,
        foreground: Color,
        fill: some ShapeStyle,
        shadow: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            circleShape(systemImage: systemImage, foreground: foreground, fill: fill, shadow: shadow)
        }
    }

    /// 多选模式底部「导出」按钮：用 Menu 锚定在按钮位置，就地展开 JSON / 文本 选项（不再从底部弹窗）。
    private var exportMenuButton: some View {
        Menu {
            Button("JSON") { exportSelectedSessions(as: .json) }
            Button(L10n.l("text")) { exportSelectedSessions(as: .text) }
        } label: {
            circleShape(
                systemImage: "square.and.arrow.up",
                foreground: .white,
                fill: Color(red: 0.098, green: 0.549, blue: 0.996),
                shadow: Color(red: 0.098, green: 0.549, blue: 0.996).opacity(0.4)
            )
        }
    }

    // MARK: - 顶部搜索栏（就地搜索，不切换界面）

    private var searchBar: some View {
        HStack(spacing: 10) {
            // 胶囊形输入框：两端圆形
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                TextField(L10n.l("search_sessions"), text: $searchText)
                    .textFieldStyle(.plain)
                    .submitLabel(.search)
                    .focused($searchFocused)
                // 框内 X：清空输入框（关闭搜索由旁边的「取消」按钮负责）
                Button(action: {
                    searchText = ""
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            // 磨砂玻璃材质（与会话页输入条同款）：主题背景可透出模糊光晕。
            .background(.ultraThinMaterial, in: Capsule())

            // 取消按钮：圆形背景
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    searchText = ""
                    isSearching = false
                }
            }) {
                Text(L10n.l("cancel"))
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    // MARK: - Toolbar Views

    private var settingsButton: some View {
        // 系统格式：label 仅放 SF Symbol，尺寸/点击区/着色由系统统一渲染（唐唐定稿）。
        Button(action: { appState.showSettings = true }) {
            Image(systemName: "gearshape.fill")
        }
    }

    private var agentTitleView: some View {
        VStack(spacing: 1) {
            Text(appState.agentName)
                .font(.headline)
                .fontWeight(.semibold)
                .onTapGesture { showSoulSettings = true }
            Text(appState.currentModelDisplayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .onTapGesture { showModelManagement = true }
        }
    }

    /// 右上角「选项」按钮外观（仅外观，用作 Menu 的 label，点击即在按钮位置就地弹出）。
    /// 右上角「选项」按钮：与会话页菜单按钮同款样式（纯三点 + 圆底 32pt）。
    private var optionsButton: some View {
        // 系统格式（与会话页 Menu 同款）：label 仅放图标。
        Image(systemName: "ellipsis")
    }

    /// 右上角「选项」菜单：使用 Menu（popover），从按钮位置就地弹出，而非从底部 sheet 弹出。
    /// - 终端：Alpine 未启动（alpineReady=false）时灰色禁用，不可点击。
    /// - Rootfs 管理 / 浏览器：始终可用。
    /// 终端与 Rootfs 管理仅在集成 iSH 的构建中显示。
    private var optionsMenu: some View {
        Menu {
            #if ISH_ENABLED
            Section {
                Button {
                    showTerminal = true
                } label: {
                    Label(L10n.l("terminal"), systemImage: "terminal")
                }
                .disabled(!alpineReady)

                Button {
                    showRootfsManager = true
                } label: {
                    Label(L10n.l("rootfs_management"), systemImage: "folder")
                }
            }
            #endif
            Button {
                // 切到首页手动浏览上下文，与任何 智能体会话完全隔离，
                // 避免首页浏览器看到某会话 智能体搜过的内容。
                BrowserController.shared.setManualSession()
                showBrowserSheet = true
            } label: {
                Label(L10n.l("browser"), systemImage: "globe")
            }
        } label: {
            optionsButton
        }
    }

    // MARK: - Actions

    private func createNewSession() {
        // 必须经 SessionManager 注册（入内存 sessions + 落盘 + 建会话隔离目录），
        // 否则 AgentRunService.startRun 的会话注册 guard 会拦截 → 发送消息无 AI 回复。
        guard let session = SessionManager.shared.createSession(
            model: appState.currentModelDisplayName,
            agentName: appState.agentName
        ) else { return }
        appState.selectedSession = session
    }

    private func deleteSession(_ session: ChatSession) {
        let sid = session.id
        // 2026-08-12 治本:删除统一走 SessionManager(先改数组再 send,reload 读到新数组即消失);
        // 不做本地乐观移除,避免与 manager 时序双写。
        SessionManager.shared.deleteSession(id: sid)
        // 清理会话隔离资源：注销 fsContext 映射 + 删除 Sessions/<uuid>/ 宿主目录
        SessionFileRouter.shared.unregister(sessionID: sid)
        // 顺手清掉该会话的子代理运行期注册表（复用状态不再需要）。
        SubagentRuntimeRegistry.shared.clear(sessionID: sid)
        ContextUsageStore.shared.clear(sessionID: sid)
    }

    private func togglePin(_ session: ChatSession) {
        // 走 SessionManager 统一更新出口(会 objectWillChange 广播 → 首页重排分组),
        // 直接改 session.isPinned 不触发列表重排,置顶"看起来没反应"(2026-08-13 修复)。
        SessionManager.shared.updateSession(id: session.id, isPinned: !session.isPinned)
    }

    // MARK: - 多选 / 长按操作

    private func enterSelectionMode(preselect: Set<UUID> = []) {
        selectedSessionIDs = preselect
        withAnimation(.easeInOut(duration: 0.2)) {
            isSelectionMode = true
        }
    }

    private func exitSelectionMode() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isSelectionMode = false
            selectedSessionIDs.removeAll()
        }
    }

    private func toggleSelection(_ session: ChatSession) {
        if selectedSessionIDs.contains(session.id) {
            selectedSessionIDs.remove(session.id)
        } else {
            selectedSessionIDs.insert(session.id)
        }
    }

    private func selectAll() {
        selectedSessionIDs = Set(sessions.map { $0.id })
    }

    private func exportSelectedSessions(as format: SessionExportFormat) {
        let selected = sessions.filter { selectedSessionIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        generateExport(sessions: selected, as: format)
    }

    private func deleteSelected() {
        let toDelete = sessions.filter { selectedSessionIDs.contains($0.id) }
        guard !toDelete.isEmpty else { exitSelectionMode(); return }
        let ids = toDelete.map(\.id)
        // 2026-08-12 治本:删除统一走 SessionManager(先改数组再 send),不做本地双写。
        for s in toDelete { SessionManager.shared.deleteSession(id: s.id) }
        // 清理各会话隔离资源：注销 fsContext 映射 + 删除 Sessions/<uuid>/ 宿主目录
        for id in ids {
            SessionFileRouter.shared.unregister(sessionID: id)
            // 顺手清掉该会话的子代理运行期注册表（复用状态不再需要）。
            SubagentRuntimeRegistry.shared.clear(sessionID: id)
            ContextUsageStore.shared.clear(sessionID: id)
        }
        exitSelectionMode()
    }

    /// 把会话导出为 JSON / 文本文件并弹出系统分享面板。
    /// 多选时**每个会话单独成一个文件**，分享面板一次性带上所有文件（而非合并成单个文件）。
    private func generateExport(sessions: [ChatSession], as format: SessionExportFormat) {
        let sorted = sessions.sorted { $0.updatedAt > $1.updatedAt }
        let urls: [URL] = sorted.enumerated().map { index, session in
            let data: Data
            let fileExtension: String
            switch format {
            case .json:
                data = (try? JSONSerialization.data(withJSONObject: session.exportDictionary(), options: [.prettyPrinted, .sortedKeys])) ?? Data()
                fileExtension = "json"
            case .text:
                data = Data(session.exportText().utf8)
                fileExtension = "txt"
            }

            // 单会话：直接用标题命名；多选：追加序号避免同名冲突
            let baseName: String
            if sorted.count == 1 {
                baseName = sanitizedFileName(session.title)
            } else {
                baseName = "\(sanitizedFileName(session.title))_\(index + 1)"
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(baseName).\(fileExtension)")
            try? data.write(to: url, options: .atomic)
            return url
        }

        sharePayload = SessionSharePayload(urls: urls)
    }

    private func sanitizedFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "_")
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "session" : trimmed
    }
}
