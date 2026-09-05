import SwiftUI
import WebKit
import UIKit

struct BrowserView: View {
    @Environment(\.dismiss) private var dismiss
    /// 2026-09-05 修复：改用 AppState.shared 单例而非 @EnvironmentObject——
        /// 本视图存在多条呈现路径（会话 sheet/子代理页/首页/独立 UIWindow 接管），
        /// 部分路径无环境继承链（Mac 独立窗口实测致命：No ObservableObject of
        /// type AppState found）。AppState.shared 启动即置位，与呈现路径解耦。
        private var appState: AppState { AppState.shared }
    @StateObject private var controller = BrowserEngineAdapter.shared

    @State private var urlString: String = ""
    @State private var showShare: Bool = false
    @State private var shareURL: URL?
    @State private var showHistory: Bool = false
    @State private var showBrowserSettings: Bool = false
    /// 打开时自动加载的起始 URL
    var startURL: URL? = nil
    /// 输入框绿色填充的透明度：加载中 0.35，加载完成后停 1s 整体淡出到 0（原地褪色，不缩回）。
    @State private var greenFillOpacity: Double = 0.35
    @State private var fadeTask: Task<Void, Never>?
    /// 全屏浏览：隐藏全部浏览器控件，右上角仅保留退出全屏按钮。
    @State private var isFullscreen = false
    /// 标签页概览（点击底部标签页按钮进入：一行两个网页缩略图 + 标签名）。
    @State private var showTabOverview: Bool = false
    /// 概览用快照缓存：TabInfo.id → 网页缩略图（进入概览时异步生成）。
    @State private var tabSnapshots: [Int: UIImage] = [:]
    /// 地址栏是否正在编辑（编辑中不覆盖用户输入；退出编辑/导航完成后同步实际网址）。
    @State private var isEditingURL: Bool = false


    var body: some View {
        VStack(spacing: 0) {
            // 网页区域：占满剩余空间；底部悬浮条盖在网页之上（不占行、无白底）。
            // 全屏：隐藏全部控件，右上角仅保留退出全屏按钮。
            ControllerWebView(controller: controller)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 标签概览打开时，当前网页整体缩小 + 下沉 + 圆角，视觉上「缩进标签网格」。
                .scaleEffect(showTabOverview ? 0.82 : 1)
                .opacity(showTabOverview ? 0.9 : 1)
                .offset(y: showTabOverview ? 24 : 0)
                .clipShape(RoundedRectangle(cornerRadius: showTabOverview ? 24 : 0))
                // 智能体托管遮罩：智能体操作浏览器期间全屏轻遮罩 + 页面中间「操作中」指示器
                // + 圆形取消托管按钮；智能体停止操作（3 秒无动作）自动隐藏。
                .overlay {
                    if controller.isAgentOperating {
                        agentOperatingOverlay
                    }
                }
                .overlay {
                    // 标签页概览：网页主视图被「一行两个缩略图」网格替代
                    if !isFullscreen && showTabOverview {
                        tabOverview
                            .transition(.scale(scale: 0.85, anchor: .center).combined(with: .opacity))
                    }
                }
                .overlay(alignment: .bottom) {
                    if !isFullscreen && !showTabOverview {
                        floatingBar
                    }
                }
                .overlay(alignment: .top) {
                    // 顶部中间悬浮小横条指示器：提示本页可下拉返回；向下拖动超过阈值即返回上级页面。
                    if !isFullscreen && !showTabOverview {
                        dragBar
                    }
                }
                .overlay(alignment: .topTrailing) {
                    // 全屏时：右上角仅显示退出全屏按钮
                    if isFullscreen {
                        Button(action: { isFullscreen = false }) {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(Color(.systemGray4), in: Circle())
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .transition(.opacity)
                    }
                }
        }
        .background(Color(.systemBackground))
        .animation(.easeInOut(duration: 0.2), value: isFullscreen)
        .onAppear {
            // 重新打开浏览器视图 = 新一轮会话期：重置「用户取消托管」标记，智能体可恢复操作。
            controller.resetAgentTakeover()
            // 重置上次浏览会话残留的进度条状态（源头修复）：关闭浏览器时若
            // 「加载完成→停 1s→淡出」的 fadeTask 未走完，greenFillOpacity 会停在
            // 0.35，而 controller.loadingProgress 是单例 @Published 不随视图销毁归零；
            // 重新进入时 loadingProgress 不再变化 → onChange 不触发 → 地址栏
            // 一直显示绿色满格。onAppear 统一重置两者。
            controller.loadingProgress = 0
            greenFillOpacity = 0.35
            fadeTask?.cancel()
            syncURL()
            if let url = startURL {
                // 程序性自动打开（会话页点链接 / 深链）：以【新标签】打开，绝不覆盖正在操作的网页。
                // 用户操作不视为接管——智能体操作浏览器优先（唯一拒绝途径=智能体操作时点「取消托管」）。
                _ = controller.uiAddTab(urlString: url.absoluteString)
            }
        }
        .onDisappear {
        }
        .onChange(of: controller.loadingProgress) { newValue in
            if newValue >= 1 {
                // 加载完成：绿色保持满格，停 1s 后整体淡出（原地褪色）。
                fadeTask?.cancel()
                fadeTask = Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.6)) {
                        greenFillOpacity = 0
                    }
                }
            } else if newValue > 0 {
                // 新导航开始：恢复绿色填充透明度。
                fadeTask?.cancel()
                greenFillOpacity = 0.35
            }
        }
        .onChange(of: controller.activeIndex) { _ in syncURL() }
        // 网页内导航（didFinish 更新 tabInfos）后地址栏同步真实网址；编辑中不覆盖输入。
        .onChange(of: controller.tabInfos) { _ in
            if !isEditingURL {
                syncURL()
            }
        }
        .onChange(of: appState.pendingBrowserResourceURL) { newValue in
            if let url = newValue {
                controller.uiNavigate(urlString: url.absoluteString)
                appState.pendingBrowserResourceURL = nil
            }
        }
        .sheet(isPresented: $showShare) {
            if let url = shareURL {
                ShareSheet(items: [url])
            }
        }
        .sheet(isPresented: $showHistory) {
            NavigationStack {
                BrowserHistoryView(
                    items: controller.uiHistoryItems(),
                    onSelect: { url in
                        controller.uiGoToHistory(url: url)
                        showHistory = false
                    }
                )
                .toolbar {
                    // 左上角：清空浏览记录
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .destructive) {
                            controller.uiClearHistory()
                            showHistory = false
                        } label: {
                            Text(String(localized: "clear_browsing_history"))
                        }
                        .disabled(controller.uiHistoryItems().isEmpty)
                    }
                }
            }
        }
        .sheet(isPresented: $showBrowserSettings) {
            NavigationStack {
                BrowserSheetSettingsView()
            }
        }
    }

    // MARK: - 智能体托管遮罩

    /// 智能体操作浏览器期间的遮罩：全屏轻遮罩拦截误触，页面中间半圆角条形指示器
    /// （高度与地址栏一致 36pt、背景与按钮一致 ultraThinMaterial：机器人图标 + 「操作中」），
    /// 右侧圆形「取消托管」按钮（点击后指示器隐藏、智能体停止操作，用户接管）。
    private var agentOperatingOverlay: some View {
        ZStack {
            // 遮罩（HIG 官方规范，2026-08 核对 developer.apple.com/design/human-interface-guidelines/materials）：
            // 覆盖层优先用语义化材质而非凭观感选色——纯黑遮罩在深色模式下会让页面完全不可读
            // （底层内容已暗，再叠黑即全黑）。ultraThinMaterial 深浅模式自动适配：
            // 浅色下磨砂提暗、深色下磨砂保持底层隐约可见；拦截用户点击（防与 智能体操作冲突），
            // 用户接管只能点右侧圆形「取消托管」按钮——遮罩本身不响应点击。
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .transition(.opacity)

            HStack(spacing: 10) {
                // 半圆角条形指示器：高 36pt（与地址栏同高），圆角 18（与地址栏一致）。
                HStack(spacing: 8) {
                    // SF Symbols 无「机器人」符号（26.5 SDK 实测 robot 不存在），
                    // 用最接近的 cpu.fill（芯片）作为机器人/硬件图标。
                    Image(systemName: "cpu.fill")
                        .font(.body)
                    Text(String(localized: "in_progress"))
                        .font(.body)
                }
                .padding(.horizontal, 16)
                .frame(height: 36)
                .background(Color(.systemGray4), in: RoundedRectangle(cornerRadius: 18))

                // 圆形取消托管按钮：36pt 与地址栏两侧圆钮一致。
                Button(action: { controller.cancelAgentOperation() }) {
                    Image(systemName: "xmark")
                        .font(.headline.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(Color(.systemGray4), in: Circle())
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controller.isAgentOperating)
    }

    /// 三元素统一高度对齐：历史/完成 36pt 圆钮，地址栏输入行固定 36pt。

    // MARK: - 底部悬浮条

    /// 顶部中间悬浮的小横条指示器：提示本页可下拉返回；在横条上向下拖动超过阈值即返回上级页面。
    private var dragBar: some View {
        RoundedRectangle(cornerRadius: 2.5)
            .fill(Color(.systemGray3))
            .frame(width: 36, height: 5)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onEnded { value in
                        if value.translation.height > 50 {
                            dismiss()
                        }
                    }
            )
    }

    /// 底部悬浮条：返回（圆形背景）+ 地址栏（内：选项按钮 | 网址搜索框 | 刷新）+ 标签页按钮（圆形背景）。
    private var floatingBar: some View {
        HStack(spacing: 6) {
            // 边缘弹性留白：整组（按钮+输入框）居中，富余空间留在屏幕两侧，不挤输入框。
            Spacer(minLength: 0)

            // 返回（圆形背景）
            BrowserToolbarButton(icon: "chevron.left", isEnabled: controller.canGoBack) { controller.uiBack() }

            // 地址栏（半圆角长条）：限宽 230pt；左侧选项菜单按钮 + 中间网址搜索框 + 右侧刷新按钮
            // 两侧固定 6pt + HStack spacing 6 → 按钮到输入框总间距 12pt，按钮向输入框靠拢。
            Spacer(minLength: 6).frame(maxWidth: 6)
            HStack(spacing: 2) {
                // 选项按钮（历史记录 / 前进 / 新标签 / 关闭标签 / 截图 / 设置 / 全屏 / 关闭浏览器）
                Menu {
                    Button(String(localized: "history_records")) { showHistory = true }
                    Button(String(localized: "forward_action")) { controller.uiForward() }
                        .disabled(!controller.canGoForward)
                    Button(String(localized: "new_tab_action")) { _ = controller.uiAddTab() }
                    Button(String(localized: "close_current_tab")) {
                        controller.uiCloseTab(index: controller.activeIndex)
                    }
                    .disabled(controller.tabInfos.count <= 1)
                    Button(String(localized: "capture_full_page_share")) {
                        Task {
                            if let link = await controller.uiScreenshot(fullPage: true),
                               let local = controller.resolveResourceURL(link) {
                                shareURL = URL(fileURLWithPath: local)
                                showShare = true
                            }
                        }
                    }
                    Button(String(localized: "browser_settings")) { showBrowserSettings = true }
                    Button(String(localized: "fullscreen_browse")) { isFullscreen = true }
                    Button(String(localized: "close_browser"), role: .destructive) { dismiss() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 38, height: 38)
                        .contentShape(Rectangle())
                }

                TextField(String(localized: "enter_url_or_search"), text: $urlString, onEditingChanged: { editing in
                    isEditingURL = editing
                })
                    .font(.body)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    // 显式指定回车键为「前往」：部分键盘/输入法下默认 returnKeyType 不触发 onSubmit，
                    // 导致「输入网址回车无反应」；submitLabel 保证键盘回车一定触发提交。
                    .submitLabel(.go)
                    .onSubmit { submit() }

                // 刷新
                Button {
                    controller.uiReload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .padding(.leading, 4)
            }
            .padding(.trailing, 4)
            .frame(maxWidth: 230)
            .frame(height: 44)
            .background(Color(.secondarySystemBackground))
            // 加载进度条：输入网址/搜索后页面加载时，绿色从左侧填充至满格，
            // 完成停 1s 后淡出（状态逻辑 loadingProgress/greenFillOpacity 一直在，
            // 此 UI 层在地址栏布局调整时丢失，现补回）。
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.green)
                        .frame(width: geo.size.width * controller.loadingProgress)
                        .opacity(greenFillOpacity)
                        .allowsHitTesting(false)
                }
            }
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(Color(.separator), lineWidth: 0.5)
            )

            // 标签页按钮：点击进入/退出「一行两个缩略图」的标签概览。
            // 点击瞬间截取当前活跃标签快照(此时 webView 在主视图、滚动位置=用户所见)，
            // 之后快照永不刷新,直到用户回到该标签重新操作。
            Spacer(minLength: 6).frame(maxWidth: 6)
            Button {
                captureSnapshotsNow()
                // 页面「缩小进入标签网格」的动画由主视图 scaleEffect + 概览 transition 共同呈现。
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    showTabOverview.toggle()
                }
            } label: {
                Image(systemName: "square.on.square")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color(.systemGray4), in: Circle())
            }

            // 边缘弹性留白（与左侧对称）
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 标签页概览

    /// 标签概览：一行两个矩形网页缩略图，缩略图下方显示标签名称；点击切换到对应标签。
    private var tabOverview: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 16) {
                ForEach(Array(controller.tabInfos.enumerated()), id: \.element.id) { index, info in
                    // 外层用 onTapGesture 而非 Button:嵌套 Button 点击会冒泡,
                    // 点关闭按钮会误触发卡片切换(2026-08-12)。
                    tabCardLabel(index: index, info: info)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            controller.uiSelectTab(index: index)
                            // 关闭概览并放大回到所选标签页
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                showTabOverview = false
                            }
                        }
                }

                // 新建标签卡
                Button {
                    _ = controller.uiAddTab()
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        showTabOverview = false
                    }
                } label: {
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.secondarySystemBackground))
                            .frame(height: 140)
                            .overlay(
                                Image(systemName: "plus")
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            )
                        Text(String(localized: "new_tab_action"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(16)
        }
        .background(Color(.systemBackground))
    }

    /// 快照生成：**只在用户点击标签页按钮的瞬间调用**（唯一更新时机）。
    /// 活跃标签立即截图并覆盖旧图（点击瞬间 webView 在主视图、滚动位置=用户所见，
    /// 截到的就是用户最后看到的那一帧）；其他标签仅补首次缺失。
    /// 生成后一律不再刷新——直到用户回到该标签重新操作，下次点击按钮时才会更新。
    private func captureSnapshotsNow() {
        let infos = controller.tabInfos
        guard !infos.isEmpty else { return }
        Task {
            let active = controller.activeIndex
            if infos.indices.contains(active) {
                let info = infos[active]
                if let img = await controller.uiSnapshot(index: active) {
                    tabSnapshots[info.id] = img
                }
            }
            for (index, info) in infos.enumerated() where index != active {
                guard tabSnapshots[info.id] == nil else { continue }
                if let img = await controller.uiSnapshot(index: index) {
                    tabSnapshots[info.id] = img
                }
            }
        }
    }

    // MARK: - Actions

    private func submit() {
        guard !urlString.isEmpty else { return }
        controller.uiNavigate(urlString: urlString)
    }

    private func syncURL() {
        if let info = controller.tabInfos[safe: controller.activeIndex] {
            urlString = info.url
        }
    }

    /// 标签卡 label(2026-08-10 拆分:编译器超时表达式)
    private func tabCardLabel(index: Int, info: BrowserEngineAdapter.TabInfo) -> some View {
        VStack(spacing: 6) {
            Group {
                if let img = tabSnapshots[info.id] {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(Color(.secondarySystemBackground))
                }
            }
            .frame(height: 140)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(index == controller.activeIndex ? Color.accentColor : Color(.separator),
                                  lineWidth: index == controller.activeIndex ? 2 : 0.5)
            )
            // 2026-08-12:标签右上角圆底叉按钮,点击关闭该标签(不触发卡片切换)
            .overlay(alignment: .topTrailing) {
                Button {
                    tabSnapshots.removeValue(forKey: info.id)
                    controller.uiCloseTab(index: index)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Color.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(6)
            }

            Text(displayTabTitle(info))
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    private func displayTabTitle(_ info: BrowserEngineAdapter.TabInfo) -> String {
        if !info.title.isEmpty { return info.title }
        if let host = URL(string: info.url)?.host { return host }
        return String(localized: "new_tab_page")
    }
}

// MARK: - 把控制器管理的 WKWebView 嵌入容器

