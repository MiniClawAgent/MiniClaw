//
// ToolLiveSheet.swift
// MiniClawApp
//
// Expandable live tool preview — the floating toolbar above the input
// bar plus the full-screen sheet that shows tool arguments, streaming
// shell output, file edits/writes, browser snapshots, memory edits and
// image tools with full scrubbing and zoom. Extracted from
// ChatView.swift so the chat view can focus on message layout.
//

import Combine
import SwiftUI
import UIKit
import WebKit

/// environment — callers override that to present MiniClawLinkPreviewView.
///
fileprivate func attributedShellLine(_ text: String) -> AttributedString {
    let text = sanitizeForDisplay(text)
    guard !text.isEmpty else { return AttributedString(text) }
    guard let detector = _shellURLDetector else { return AttributedString(text) }
    let ns = text as NSString
    let matches = detector.matches(in: text,range: NSRange(location: 0,length: ns.length))
    guard !matches.isEmpty else { return AttributedString(text) }

    let mutable = NSMutableAttributedString(string: text)
    for m in matches {
        guard let url = m.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { continue }
        // which matches path fragments in shell output (e.g. "/Users/.../github.com/example-org/...").
        let matched = ns.substring(with: m.range)
        let lower = matched.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { continue }
        mutable.addAttributes([
            .link: url,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .foregroundColor: UIColor.cyan,
        ],range: m.range)
    }
    return AttributedString(mutable)
}

/// Wrapper that @ObservedObject's the RenderMessage so SwiftUI re-evaluates
struct ToolLiveSheet: View {
    let toolBlocks: [AssistantBlock]
    @State var currentIdx: Int
    var toolSnapshots: [ToolSnapshotItem] = []
    var browserPool: MiniClawTabPool?
    var onBrowserTakeover: (() -> Void)?
    var onTakeoverDone: (() -> Void)?
    /// 2026-08-12:浏览器接管内容宿主提供者(主工程注入 BrowserView)。
    /// 照原版机制:浏览器由本弹层的二级 sheet 呈现(同视图树同 present 链,
    /// 稳定弹出);有 provider 时显示主工程浏览器,否则回退 Kit 内置 BrowserSheetView。
    var browserContentProvider: ((URL?) -> AnyView)?
    /// 2026-09-01 卡片形态（ToolCardOverlay 宿主）：关闭回调。提供时关闭按钮走
    /// 此回调（overlay 无 dismiss 环境语义）；缺省 nil = 沿用 dismiss（sheet 形态）。
    var onClose: (() -> Void)? = nil
    /// 卡片模式下隐藏底部「上一个/下一个」切换行——TabView 横向分页 + 圆点指示替代。
    var hidesSwitchRow: Bool = false
    /// 卡片模式底色：用 systemGray5（深浅色都与纯黑/纯白会话页有明确边界对比），
    /// 而非 systemGroupedBackground（深色≈纯黑、浅色≈纯白，卡片会融进会话页背景）。
    var cardSurface: Bool = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.chatSessionId) private var sessionId

    @State private var browserSnapshot: UIImage?
    @State private var snapshotTimer: Timer?
    @State private var showTerminal = false
    @State private var navCopyDone = false
    @State private var blockUpdateTick = 0
    /// 用户点击结果区后暂停自动跟随（安心上滑看历史）；切换工具块时重置。
    @State private var tailFollowPaused = false
    @State private var activeSheet: ActiveSecondarySheet?

    enum ActiveSecondarySheet: Identifiable,Equatable {
        case takeoverBrowser
        case linkPreview(URL)

        var id: String {
            switch self {
            case .takeoverBrowser: return "takeoverBrowser"
            case .linkPreview(let url): return "linkPreview:\(url.absoluteString)"
            }
        }
    }
    @StateObject private var resourceMonitor = SystemResourceMonitor()

    /// Number of 40-line chunks currently
    @State private var revealedChunkCount: Int = 0
    @State private var revealedForBlockId: UUID?

    private static let lazyRenderChunkLines = 40
    private static let lazyRenderInitialChunks = 5
    private static let lazyRenderBatchChunks = 5
    private static let lazyRenderInitialByteCap = 10*1024

    /// 快照桥（主会话 cell 传入）：观察其 objectWillChange，结果快照更新时浮层实时重绘
    /// （2026-09-02 修复「执行中打开浮层看不到结果」——原实现为 init 值拷贝，不随更新）。
    var snapshotBridge: CellStateBridge? = nil
    @State private var snapshotTick = 0
    init(toolBlocks: [AssistantBlock],initialIdx: Int,toolSnapshots: [ToolSnapshotItem] = [],snapshotBridge: CellStateBridge? = nil,browserPool: MiniClawTabPool?,
         onBrowserTakeover: (() -> Void)? = nil,onTakeoverDone: (() -> Void)? = nil,
         browserContentProvider: ((URL?) -> AnyView)? = nil,
         onClose: (() -> Void)? = nil, hidesSwitchRow: Bool = false,
         cardSurface: Bool = false) {
        self.toolBlocks = toolBlocks
        self._currentIdx = State(initialValue: initialIdx)
        self.toolSnapshots = toolSnapshots
        self.snapshotBridge = snapshotBridge
        self.browserPool = browserPool
        self.onBrowserTakeover = onBrowserTakeover
        self.onTakeoverDone = onTakeoverDone
        self.browserContentProvider = browserContentProvider
        self.onClose = onClose
        self.hidesSwitchRow = hidesSwitchRow
        self.cardSurface = cardSurface
    }

    /// 快照桥的更新信号（optional publisher 的类型显式化包装）。
    private var snapshotBridgePublisher: AnyPublisher<Void, Never> {
        snapshotBridge?.objectWillChange.eraseToAnyPublisher()
            ?? Empty<Void, Never>().eraseToAnyPublisher()
    }

    /// 优先读 bridge 的实时快照（响应 objectWillChange）；无桥时回退 init 拷贝。
    private var currentSnapshot: ToolSnapshotItem? {
        let _ = snapshotTick
        guard let blockId = block.toolUseId else { return nil }
        if let live = snapshotBridge?.toolSnapshots.first(where: { $0.id == blockId }) {
            return live
        }
        return toolSnapshots.first(where: { $0.id == blockId })
    }

    private var block: AssistantBlock {
        let idx = min(currentIdx,toolBlocks.count-1)
        guard idx >= 0 else { return AssistantBlock(kind: .text, content: "") }
        return toolBlocks[idx]
    }

    private var isLive: Bool {
        guard !toolBlocks.isEmpty else { return false }
        if case .streaming = block.toolStatus { return true }
        if case .running = block.toolStatus { return true }
        return false
    }

    /// < 60s → "3s"
    /// 60-3600s → "2m30s"
    /// ≥ 3600s → "1h12m"
    private func durationLabel(started: Date) -> String {
        let secs: TimeInterval
        let stillRunning: Bool
        if let dur = block.toolDuration {
            secs = dur
            stillRunning = false
        } else {
            secs = max(0,Date().timeIntervalSince(started))
            stillRunning = isLive
        }
        return MiniClawStepTimestampFormatter.duration(seconds: secs,stillRunning: stillRunning)
    }

    var body: some View {
        // 2026-08-10:ViewBuilder 对 4 个复杂 some View 子视图的组合类型检查
        // 触发编译器 failed-to-produce-diagnostic——用 let 提取为局部变量,
        // 让每个子视图单独完成类型检查后再组合。
        let nav = sheetNavBar
        let divider = Divider().foregroundStyle(Color(white: 0.2))
        // [2026-08-14 快照三级布局] L3 结果内容：限高为快照页一半，
        // 超出在工具框架内滚动，不撑破整体布局（各内容分支自带 ScrollView）。
        // ⚠️ 读依赖必须用 `let _ = tick`（触发 body 重算且 identity 不变，滚动位置保留）；
        // 不能用 `.id(tick)`——tick 每 0.15s 递增会把整棵内容子树（含 ScrollView）
        // 销毁重建，滚动位置反复重置到顶部（2026-09-03 TopFlow实测：流式期间无法下滑）。
        let _ = blockUpdateTick
        let content = liveContent
            .frame(maxWidth: .infinity)
        // 链式修饰拆分:2026-08-10 编译器 failed-diagnostic
        // [2026-08-14 快照三级布局] 由「单内容+底部导航」改为：
        // L1 工具信息行（常显）→ L2 操作参数行（常显）→ L3 结果内容（限高滚动）→ 底部切换行。
        // 切换行保留上/下一工具块切换（渲染方式与内容均保持原样）。
        return bodyModifiers(
            GeometryReader { geo in
                VStack(spacing: 0) {
                    nav
                    if !cardSurface { divider }
                    // [2026-08-14 Apple Music 风格卡片] L1+L2 摘要卡（灰底圆角矩形）：
                    // 工具信息行 + 参数行作为「摘要」，卡片内细线分隔。
                    // 2026-09-01 卡片模式（cardSurface）：内容满铺到外框边缘，
                    // 去掉内层水平 padding 与内层圆角——外框（圆角 20 + 描边）即内容边界，
                    // 避免「框大内容小、圆角不齐」（TopFlow真机反馈）。
                    VStack(spacing: 0) {
                        toolInfoRow
                        if hasParameterRow {
                            Divider()
                                .padding(.leading, 16)
                        }
                        parameterRow
                    }
                    .background(Color(UIColor.systemGray6))
                    .clipShape(cardSurface ? AnyShape(Rectangle()) : AnyShape(RoundedRectangle(cornerRadius: 12)))
                    .padding(.horizontal, cardSurface ? 0 : 12)
                    .padding(.top, cardSurface ? 0 : 12)
                    .padding(.bottom, cardSurface ? 0 : 8)

                    // L3 内容卡（灰底圆角矩形，占满剩余；内部各内容分支自带
                    // 白色结果卡/截图卡，形成「灰卡托白卡」的层级，Apple Music 风格）。
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(UIColor.systemGray6))
                        .clipShape(cardSurface ? AnyShape(Rectangle()) : AnyShape(RoundedRectangle(cornerRadius: 12)))
                        .padding(.horizontal, cardSurface ? 0 : 12)
                        .padding(.bottom, cardSurface ? 0 : 4)

                    // 卡片形态：TabView 横向分页 + 圆点指示替代上/下切换行。
                    if !hidesSwitchRow {
                        switchRow
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        )
    }

    /// 2026-08-10:把 body 的整条链式修饰拆到函数,避免 ViewBuilder 组合
    /// 类型检查触发编译器 failed-to-produce-diagnostic。
    /// 2026-08-10:modifier 链拆四段,每段独立类型检查(编译器 failed-diagnostic)
    private func bodyModifiers(_ root: some View) -> some View {
        lifecycleModifiers(appearanceModifiers(root))
    }

    private func appearanceModifiers(_ root: some View) -> some View {
        root
            .frame(maxWidth: .infinity,maxHeight: .infinity)
            // 卡片模式（cardSurface）不自画整页背景——由 ToolCardOverlay 外层容器
            // 统一画 systemGray5 底并裁圆角/描边，保证背景与描边边界完全一致
            //（TopFlow反馈：背景比描边框大、圆角看不出来）。L1/L2/L3 内容卡自带 systemGray6。
            .background(cardSurface ? Color.clear : Color(UIColor.systemGroupedBackground))
    }

    private func lifecycleModifiers(_ root: some View) -> some View {
        urlObservers(liveObservers(sheetModifiers(root)))
    }

    /// 2026-08-10:提取 publisher(编译器 failed-diagnostic)
    private var pendingURLPublisher: AnyPublisher<URL,Never> {
        MiniClawOpenURLBroker.shared.$pendingURL
            .dropFirst()
            .compactMap { $0 }
            .eraseToAnyPublisher()
    }

    private func urlObservers(_ root: some View) -> some View {
        root
            .onReceive(pendingURLPublisher) { url in
                guard MiniClawOpenURLBroker.isWebScheme(url.scheme) else { return }
                activeSheet = .linkPreview(url)
                MiniClawOpenURLBroker.shared.consume()
            }
    }

    private func liveObservers(_ root: some View) -> some View {
        root
            .onAppear {
                startBrowserTimer()
                if isLive && isCurrentShell { resourceMonitor.start() }
                MiniClawOpenURLBroker.shared.toolSheetVisible = true
            }
            .onDisappear {
                stopBrowserTimer()
                resourceMonitor.stop()
                MiniClawOpenURLBroker.shared.toolSheetVisible = false
            }
            .onChange(of: isLive) { live in
                if live && isCurrentShell { resourceMonitor.start() } else { resourceMonitor.stop() }
            }
            .onReceive(block.objectWillChange) { _ in
                blockUpdateTick += 1
            }
            // 快照桥更新 → 驱动浮层重绘（结果到达实时显示，2026-09-02）。
            .onReceive(snapshotBridgePublisher) { _ in
                snapshotTick += 1
            }
            .presentationDragIndicator(.hidden)
    }

    private func sheetModifiers(_ root: some View) -> some View {
        root
            .environment(\.openURL,openURLAction)
            .sheet(item: $activeSheet,content: secondarySheetContent)
            // iOS16 兼容:onChange 单参版本(原双参 + initial 语义等价——初始 nil 不触发)。
            .onChange(of: activeSheet) { newValue in
                if newValue == nil {
                    onTakeoverDone?()
                }
            }
    }

    /// 2026-08-10:拆分 ViewBuilder 复杂闭包(编译器 failed-diagnostic)
    @ViewBuilder
    private func secondarySheetContent(_ sheet: ActiveSecondarySheet) -> some View {
        switch sheet {
        case .takeoverBrowser:
            // 2026-08-12:照原版机制——浏览器由本弹层的二级 sheet 直接呈现
            // (同视图树同 present 链,稳定弹出,不再跨层通知宿主)。有宿主 provider 时
            // 显示主工程 BrowserView(其 startURL 处理=新标签打开,不覆盖池内网页);
            // 否则回退 Kit 内置 BrowserSheetView。
            if let provider = browserContentProvider {
                provider(takeoverURL)
            } else if let pool = browserPool {
                BrowserSheetView(pool: pool,isAgentBusy: false)
                    .onAppear {
                        let url = resolvedBrowserURL
                        if pool.tabs.isEmpty {
                            if url.isEmpty {
                                pool.ensureTabForUI()
                            } else {
                                _ = pool.newTab(url: url)
                            }
                        } else if !url.isEmpty {
                            pool.activeManager?.loadURL(url)
                        }
                    }
            }
        case .linkPreview(let url):
            MiniClawLinkPreviewView(url: url,browserPool: browserPool)
        }
    }

    /// 2026-08-12:浏览器接管要打开的 URL(传给宿主 provider)。
    /// URL 优先级:激活标签 URL > 池里第一个非空 URL 的标签 > block 解析。
    /// selectedTabId 可能指向 ensureTabForUI 新建的空白 tab(activeManager 无 URL),
    /// 而网页在其它标签里,所以必须遍历 tabs 找第一个有 URL 的。
    private var takeoverURL: URL? {
        var urlString = browserPool?.activeManager?.currentURL ?? ""
        if urlString.isEmpty {
            urlString = browserPool?.tabs.first(where: { !$0.manager.currentURL.isEmpty })?.manager.currentURL ?? ""
        }
        if urlString.isEmpty { urlString = resolvedBrowserURL }
        // 编码兜底:URL(string:) 对中文/空格直接失败;编码时保留已有 %XX(否则 %20→%2520 双重编码)
        let allowed = CharacterSet.urlQueryAllowed.union(CharacterSet(charactersIn: "%"))
        let fallback = urlString.addingPercentEncoding(withAllowedCharacters: allowed) ?? urlString
        guard let u = URL(string: urlString) ?? URL(string: fallback),
              let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return u
    }

    /// 2026-08-10:拆分 OpenURLAction(编译器 failed-diagnostic)
    private var openURLAction: OpenURLAction {
        OpenURLAction { url in
            if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                activeSheet = .linkPreview(url)
                return .handled
            }
            return .systemAction
        }
    }

    private var isCurrentShell: Bool {
        if case .shellTool = block.kind { return true }
        return false
    }

    private var sheetNavBar: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    // 卡片形态（ToolCardOverlay 宿主）走 onClose；sheet 形态走 dismiss。
                    if let onClose { onClose() } else { dismiss() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14,weight: .semibold))
                        .foregroundStyle(ChatColors.primaryText)
                        .frame(width: 32,height: 32)
                        .background(ChatColors.secondaryBg)
                        .clipShape(Circle())
                }

                Spacer()

                // [2026-09-14 TopFlow] 原为固定文案 `MiniClaw Computer`；现将 L1 工具信息行的
                // 标题**上提到这里**（那一行只留副标题与耗时）—— 即"第二行改到标题行、去掉
                // MiniClaw Computer"。文案本身改走中文且**不带 MiniClaw 前缀**，只说明在用什么
                // 工具（见 `toolTitle`，已按 i18n 规则落 `Localizable.xcstrings`）。
                Text(toolTitle)
                    .font(.system(size: 15,weight: .semibold))
                    .lineLimit(1)

                Spacer()

                if isLive,onBrowserTakeover != nil,case .browserTool = block.kind {
                    Button {
                        onBrowserTakeover?()
                        activeSheet = .takeoverBrowser
                    } label: {
                        ZStack {
                            Image(systemName: "hand.point.up.left")
                                .font(.system(size: 13,weight: .semibold))
                                .offset(x: -2,y: -1)
                            Image(systemName: "globe")
                                .font(.system(size: 8,weight: .bold))
                                .offset(x: 5,y: 5)
                        }
                        .foregroundStyle(ChatColors.primaryText)
                        .frame(width: 32,height: 32)
                        .background(ChatColors.secondaryBg)
                        .clipShape(Circle())
                    }
                } else if case .browserTool = block.kind,browserPool != nil {
                    Button { activeSheet = .takeoverBrowser } label: {
                        toolIcon
                            .font(.system(size: 14))
                            .foregroundStyle(ChatColors.primaryText)
                            .frame(width: 32,height: 32)
                            .background(ChatColors.secondaryBg)
                            .clipShape(Circle())
                    }
                } else if case .fileWriteTool = block.kind {
                    Button {
                        let text = block.streamingFileContent
                            ?? extractWriteContent()
                            ?? block.content
                        UIPasteboard.general.string = text
                        navCopyDone = true
                        DispatchQueue.main.asyncAfter(deadline: .now()+2) { navCopyDone = false }
                    } label: {
                        Image(systemName: navCopyDone ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 14))
                            .foregroundStyle(navCopyDone ? Color.green : ChatColors.primaryText)
                            .frame(width: 32,height: 32)
                            .background(ChatColors.secondaryBg)
                            .clipShape(Circle())
                    }
                } else if case .fileReadTool = block.kind {
                    Button {
                        UIPasteboard.general.string = block.content
                        navCopyDone = true
                        DispatchQueue.main.asyncAfter(deadline: .now()+2) { navCopyDone = false }
                    } label: {
                        Image(systemName: navCopyDone ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 14))
                            .foregroundStyle(navCopyDone ? Color.green : ChatColors.primaryText)
                            .frame(width: 32,height: 32)
                            .background(ChatColors.secondaryBg)
                            .clipShape(Circle())
                    }
                } else if case .fileEditTool = block.kind {
                    Button {
                        let editStrings = extractEditStrings()
                        let text = editStrings.map { "OLD:\n\($0.oldString)\n\nNEW:\n\($0.newString)" } ?? block.content
                        UIPasteboard.general.string = text
                        navCopyDone = true
                        DispatchQueue.main.asyncAfter(deadline: .now()+2) { navCopyDone = false }
                    } label: {
                        Image(systemName: navCopyDone ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 14))
                            .foregroundStyle(navCopyDone ? Color.green : ChatColors.primaryText)
                            .frame(width: 32,height: 32)
                            .background(ChatColors.secondaryBg)
                            .clipShape(Circle())
                    }
                } else if case .readImageTool = block.kind {
                    Button {
                        if let path = block.imageFilePath,let img = UIImage(contentsOfFile: path) {
                            UIPasteboard.general.image = img
                        }
                        navCopyDone = true
                        DispatchQueue.main.asyncAfter(deadline: .now()+2) { navCopyDone = false }
                    } label: {
                        Image(systemName: navCopyDone ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 14))
                            .foregroundStyle(navCopyDone ? Color.green : ChatColors.primaryText)
                            .frame(width: 32,height: 32)
                            .background(ChatColors.secondaryBg)
                            .clipShape(Circle())
                    }
                } else if case .memoryTool = block.kind {
                    Button {
                        let text = memoryWriteContentFromArgs() ?? block.content
                        UIPasteboard.general.string = text
                        navCopyDone = true
                        DispatchQueue.main.asyncAfter(deadline: .now()+2) { navCopyDone = false }
                    } label: {
                        Image(systemName: navCopyDone ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 14))
                            .foregroundStyle(navCopyDone ? Color.green : ChatColors.primaryText)
                            .frame(width: 32,height: 32)
                            .background(ChatColors.secondaryBg)
                            .clipShape(Circle())
                    }
                } else {
                    Button { showTerminal = true } label: {
                        toolIcon
                            .font(.system(size: 14))
                            .foregroundStyle(ChatColors.primaryText)
                            .frame(width: 32,height: 32)
                            .background(ChatColors.secondaryBg)
                            .clipShape(Circle())
                    }
                }
            }

        }
        .padding(.horizontal,16)
        .padding(.vertical,10)
        // [2026-09-14 TopFlow] 背景改为**与下面那张正式卡片同色**（L1/L2/L3 内容卡用的是
        // `systemGray6`，见 `body` 里三处 `.background(Color(UIColor.systemGray6))`）。
        // 上一轮这里用的是 `systemGray5`（= cardSurface 外层容器的底色）⇒ 与紧邻的内容卡
        // **差一档**，顶部标题行看起来像另贴了一层。TopFlow原话：「卡片顶部 miniclaw computer
        // 标题行背景对齐下面正式卡片的背景颜色」。
        .background(cardSurface ? Color(UIColor.systemGray6) : Color(UIColor.systemBackground))
        .fullScreenCover(isPresented: $showTerminal) {
            NavigationStack {
                ISHTerminalView(
                    sessionId: sessionId,
                    showCloseButton: true,
                    initCommand: terminalPrefillCommand
                )
            }
        }
    }

    private var terminalPrefillCommand: String? {
        if case .shellTool(let cmd) = block.kind,!cmd.isEmpty {
            return cmd
        }
        return nil
    }

    private var navToolDetail: String {
        switch block.kind {
        case .text,.thinking:
            return ""
        case .question:
            return ""
        case .shellTool(let cmd):
            return "shell-execute(\(truncateParam(cmd)))"
        case .fileReadTool(let path):
            return "file-read(\(truncateParam(path)))"
        case .fileWriteTool(let path):
            return "file-write(\(truncateParam(path)))"
        case .fileEditTool(let path):
            return "file-edit(\(truncateParam(path)))"
        case .browserTool(let action):
            return "browser_use(\(truncateParam(action)))"
        case .readImageTool(let path):
            return "read_image(\(truncateParam(path)))"
        case .memoryTool(let action):
            return "\(truncateParam(action))"
        case .subagentTool(let action):
            return "subagent(\(truncateParam(action)))"
        case .info:
            return ""
        case .file:
            return ""
        }
    }

    private func truncateParam(_ s: String) -> String {
        s.count>100 ? String(s.prefix(100))+"..." : s
    }

    @ViewBuilder
    private var toolIcon: some View {
        switch block.kind {
        case .shellTool: Image(systemName: "terminal")
        case .fileReadTool: Image(systemName: "doc.text")
        case .fileWriteTool: Image(systemName: "doc.text.fill")
        case .fileEditTool: Image(systemName: "square.and.pencil")
        case .browserTool: Image(systemName: "globe")
        case .readImageTool: Image(systemName: "photo")
        case .memoryTool: Image(systemName: "brain.head.profile")
        case .subagentTool: Image(systemName: "person.2.fill")
        case .question: Image(systemName: "questionmark.bubble.fill")
        case .info: Image(systemName: "arrow.triangle.2.circlepath")
        case .text: Image(systemName: "text.alignleft")
        case .thinking: Image("ThinkingIcon")
        case .file: Image(systemName: "doc.fill")
        }
    }

    @ViewBuilder
    private var liveContent: some View {
        if isLive {
            switch block.kind {
            case .browserTool: browserContent
            case .fileWriteTool:
                let liveText = block.streamingFileContent.flatMap { $0.isEmpty ? nil : $0 } ?? block.content
                fileEditorContent(liveText,isStreaming: true)
            case .fileEditTool:
                fileDiffContent(isStreaming: true)
            case .fileReadTool: fileEditorContent(block.content)
            case .memoryTool:
                let content = memoryWriteContentFromArgs() ?? block.content
                memoryEditorContent(content,action: memoryActionName(),isStreaming: true)
            default: textContent
            }
        } else if let snap = currentSnapshot {
            snapshotContent(snap)
        } else {
            switch block.kind {
            case .browserTool:
                if let img = block.imageFilePath.flatMap({ UIImage(contentsOfFile: $0) }) {
                    browserResultContent(image: img,text: block.content)
                } else {
                    browserTextResultContent(block.content)
                }
            case .readImageTool:
                if let img = block.imageFilePath.flatMap({ UIImage(contentsOfFile: $0) }) {
                    browserResultContent(image: img,text: block.content)
                } else {
                    textContent
                }
            case .fileEditTool:
                fileDiffContent()
            case .fileWriteTool(let path),.fileReadTool(let path):
                let hostURL = RootfsManager.shared.dataPath.appendingPathComponent(String(path.dropFirst()))
                let diskContent = (try? String(contentsOf: hostURL, encoding: .utf8)) ?? ""
                if !diskContent.isEmpty {
                    fileEditorContent(diskContent,toolResult: block.content)
                } else {
                    fileEditorContent(block.content)
                }
            case .memoryTool:
                let content = memoryWriteContentFromArgs() ?? block.content
                memoryEditorContent(content,action: memoryActionName(),resultText: block.content)
            default:
                textContent
            }
        }
    }

    @ViewBuilder
    private func snapshotContent(_ item: ToolSnapshotItem) -> some View {
        switch item.snapshot.type {
        case .image:
            if let ref = item.snapshot.mediaRef {
                let url = item.mediaResolver(ref)
                if let img = UIImage(contentsOfFile: url.path) {
                    browserResultContent(image: img,text: block.content)
                } else {
                    textContent
                }
            } else {
                textContent
            }
        case .text:
            if case .fileWriteTool = block.kind,let text = item.snapshot.text,!text.isEmpty {
                fileEditorContent(text,toolResult: block.content)
            } else if case .fileEditTool = block.kind {
                fileDiffContent()
            } else if case .fileReadTool = block.kind,let text = item.snapshot.text,!text.isEmpty {
                fileEditorContent(text)
            } else if case .memoryTool = block.kind {
                let content = memoryWriteContentFromArgs() ?? item.snapshot.text ?? block.content
                memoryEditorContent(content,action: memoryActionName(),resultText: block.content)
            } else if case .browserTool = block.kind,let text = item.snapshot.text,!text.isEmpty {
                browserTextResultContent(text)
            } else if let text = item.snapshot.text,!text.isEmpty {
                snapshotTextContent(text)
            } else {
                textContent
            }
        }
    }

    /// Combined browser result: screenshot image + result text card.
    /// [2026-08-14 三级布局] action+URL 胶囊层已上移为 L2 parameterRow，此处不再重复渲染。
    private func browserResultContent(image: UIImage,text: String) -> some View {
        let script: String? = browserScriptFromArgs()

        return ScrollView {
            VStack(alignment: .leading,spacing: 12) {
                if let script {
                    jsScriptCard(script)
                }

                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(UIColor.separator).opacity(0.5),lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.18),radius: 8,x: 0,y: 3)
                    .contextMenu {
                        Button { UIPasteboard.general.image = image } label: {
                            Label("Copy Image", systemImage: "doc.on.doc")
                        }
                    }
                    .padding(.horizontal,12)
                    .padding(.top,12)

                    if !text.isEmpty {
                        VStack(spacing: 0) {
                            HStack(spacing: 6) {
                                Image(systemName: "globe")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(UIColor.secondaryLabel))
                                Text("Result")
                                    .font(.system(size: 13,weight: .medium))
                                    .foregroundStyle(Color(UIColor.label))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical,10)
                            .background(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.13,alpha: 1) : UIColor(white: 0.92,alpha: 1) }))

                            Divider()

                            Text(text)
                                .font(.system(size: 13,design: .monospaced))
                                .foregroundStyle(Color(UIColor.label))
                                .frame(maxWidth: .infinity,alignment: .leading)
                                .textSelection(.enabled)
                                .padding(14)
                        }
                        .background(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.10,alpha: 1) : UIColor(white: 0.94,alpha: 1) }))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.25,alpha: 1) : UIColor(white: 0.82,alpha: 1) }),lineWidth: 0.5))
                        .padding(.horizontal,12)
                    }
            }
            .padding(.bottom,16)
        }
    }

    /// Browser text-only result: file-editor-style result card.
    /// [2026-08-14 三级布局] action+URL 胶囊层已上移为 L2 parameterRow，此处不再重复渲染。
    private func browserTextResultContent(_ text: String) -> some View {
        let script: String? = browserScriptFromArgs()

        return ScrollView {
            VStack(alignment: .leading,spacing: 12) {
                if let script {
                    jsScriptCard(script)
                }

                if !text.isEmpty {
                    VStack(spacing: 0) {
                        HStack(spacing: 6) {
                            Image(systemName: "globe")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(UIColor.secondaryLabel))
                            Text("Result")
                                .font(.system(size: 13,weight: .medium))
                                .foregroundStyle(Color(UIColor.label))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical,10)
                        .background(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.13,alpha: 1) : UIColor(white: 0.92,alpha: 1) }))

                        Divider()

                        Text(sanitizeForDisplay(text))
                            .font(.system(size: 13,design: .monospaced))
                            .foregroundStyle(Color(UIColor.label))
                            .frame(maxWidth: .infinity,alignment: .leading)
                            .textSelection(.enabled)
                            .padding(14)
                    }
                    .background(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.10,alpha: 1) : UIColor(white: 0.94,alpha: 1) }))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.25,alpha: 1) : UIColor(white: 0.82,alpha: 1) }),lineWidth: 0.5))
                    .padding(.horizontal,12)
                }
            }
            .padding(.bottom,16)
        }
    }

    private func zoomableImage(_ img: UIImage) -> some View {
        ZoomableImageView(image: img)
    }

    private func snapshotTextContent(_ text: String) -> some View {
        GeometryReader { geo in
            let cardWidth = geo.size.width-24 // 12pt horizontal padding each side
            let cardMinHeight = cardWidth*3.0/4.0
            Group {
                if case .shellTool(let cmd) = block.kind {
                    let cmdPrefix = "$ \(cmd)\n"
                    let output = text.hasPrefix(cmdPrefix) ? String(text.dropFirst(cmdPrefix.count)) : text
                    let chunks = Self.chunkedLines(output.isEmpty ? " " : output)
                    ScrollView {
                        VStack(alignment: .leading,spacing: 0) {
                            Text("$ \(cmd)")
                                .font(.system(size: 13,weight: .bold,design: .monospaced))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity,alignment: .leading)
                                .padding(.horizontal,14)
                                .padding(.top,14)

                            ForEach(chunks,id: \.id) { chunk in
                                Text(attributedShellLine(chunk.text))
                                    .font(.system(size: 13,design: .monospaced))
                                    .foregroundColor(accentColor)
                                    .frame(maxWidth: .infinity,alignment: .leading)
                                    .padding(.horizontal,14)
                            }
                        }
                        .textSelection(.enabled)
                        .padding(.bottom,14)
                        .frame(maxWidth: .infinity,minHeight: cardMinHeight,alignment: .topLeading)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.25,alpha: 1) : UIColor(white: 0.82,alpha: 1) }),lineWidth: 0.5))
                        .padding(.horizontal,12)
                        .padding(.top,12)
                        .padding(.bottom,16)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading,spacing: 0) {
                            if !contentHeader.isEmpty {
                                Text(contentHeader)
                                    .font(.system(size: 12,weight: .medium))
                                    .foregroundStyle(ChatColors.secondaryText)
                                    .padding(.horizontal,16)
                                    .padding(.top,16)
                                    .padding(.bottom,8)
                                    .frame(maxWidth: .infinity,alignment: .center)
                            }

                            Text(sanitizeForDisplay(text))
                                .font(.system(size: 13,design: .monospaced))
                                .foregroundStyle(accentColor)
                                .frame(maxWidth: .infinity,minHeight: cardMinHeight,alignment: .topLeading)
                                .textSelection(.enabled)
                                .padding(14)
                                .background(Color(white: 0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .padding(.horizontal,12)
                        }
                        .padding(.bottom,16)
                    }
                }
            }
        }
    }

    private func fileReadInfoView(fileName: String,charCount: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(Color(UIColor.secondaryLabel))
            Text(fileName)
                .font(.system(size: 13,weight: .medium))
                .foregroundStyle(Color(UIColor.label))
                .lineLimit(1)
            Text("(\(Self.formatCharCount(charCount)))")
                .font(.system(size: 11))
                .foregroundStyle(Color(UIColor.tertiaryLabel))
        }
        .frame(maxWidth: .infinity,alignment: .leading)
        .padding(.horizontal,16)
        .padding(.vertical,12)
    }

    /// - Parameter toolResult: Optional tool result info (miniclaw_url etc.) shown below the editor.

    private func extractEditStrings() -> (oldString: String,newString: String)? {
        guard let json = block.toolInputArgs,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let old = dict["old_string"] as? String,
              let new = dict["new_string"] as? String else { return nil }
        return (old,new)
    }

    private func extractWriteContent() -> String? {
        guard let json = block.toolInputArgs,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = dict["content"] as? String else { return nil }
        return content
    }

    private func fileDiffContent(isStreaming: Bool = false) -> some View {
        let filePath: String = {
            if case .fileEditTool(let p) = block.kind { return p }
            return "file"
        }()
        let fileName = (filePath as NSString).lastPathComponent
        let editStrings = extractEditStrings()
        let oldText = editStrings?.oldString ?? block.streamingFileContent ?? ""
        let newText = editStrings?.newString ?? ""
        let hasEditData = editStrings != nil || (block.streamingFileContent != nil && !(block.streamingFileContent?.isEmpty ?? true))
        let toolResult = isStreaming ? nil : block.content

        let sizeLabel: String = {
            if isStreaming { return "streaming…" }
            let totalBytes = oldText.utf8.count+newText.utf8.count
            return Self.formatBytes(totalBytes)
        }()

        let resultDetail: String? = {
            guard let result = toolResult,!result.isEmpty else { return nil }
            if let range = result.range(of: #"\(([^)]+)\)"#, options: .regularExpression) {
                return String(result[range])
            }
            return nil
        }()

        return Group {
            if hasEditData {
                GeometryReader { geo in
                    let cardWidth = geo.size.width-24 // 12pt horizontal padding each side
                    let cardMinHeight = cardWidth*3.0/4.0
                    ScrollView {
                        VStack(alignment: .leading,spacing: 0) {
                            VStack(spacing: 0) {
                            HStack(spacing: 6) {
                                Image(systemName: "square.and.pencil")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.orange)
                                Text(fileName)
                                    .font(.system(size: 13,weight: .medium))
                                    .foregroundStyle(Color(UIColor.label))
                                    .lineLimit(1)
                                Text("(\(sizeLabel))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(isStreaming ? Color.orange.opacity(0.8) : Color(UIColor.tertiaryLabel))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical,10)
                            .background(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.13,alpha: 1) : UIColor(white: 0.92,alpha: 1) }))

                            Divider()

                            VStack(alignment: .leading,spacing: 0) {
                                if !oldText.isEmpty {
                                    let oldChunks = Self.chunkedDiffLines(oldText, prefix: "- ")
                                    ForEach(oldChunks,id: \.id) { chunk in
                                        Text(chunk.text)
                                            .font(.system(size: 13,design: .monospaced))
                                            .foregroundStyle(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 1,green: 0.4,blue: 0.4,alpha: 1) : UIColor(red: 0.8,green: 0.1,blue: 0.1,alpha: 1) }))
                                            .frame(maxWidth: .infinity,alignment: .leading)
                                            .padding(.horizontal,14)
                                            .padding(.vertical,2)
                                            .background(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.3,green: 0.08,blue: 0.08,alpha: 1) : UIColor(red: 1,green: 0.9,blue: 0.9,alpha: 1) }))
                                    }
                                }
                                if !newText.isEmpty {
                                    let newChunks = Self.chunkedDiffLines(newText, prefix: "+ ")
                                    ForEach(newChunks,id: \.id) { chunk in
                                        Text(chunk.text)
                                            .font(.system(size: 13,design: .monospaced))
                                            .foregroundStyle(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.4,green: 1,blue: 0.4,alpha: 1) : UIColor(red: 0.1,green: 0.6,blue: 0.1,alpha: 1) }))
                                            .frame(maxWidth: .infinity,alignment: .leading)
                                            .padding(.horizontal,14)
                                            .padding(.vertical,2)
                                            .background(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.08,green: 0.2,blue: 0.08,alpha: 1) : UIColor(red: 0.9,green: 1,blue: 0.9,alpha: 1) }))
                                    }
                                }
                            }
                            .textSelection(.enabled)

                            if !isStreaming {
                                Spacer(minLength: 0)
                                Divider()

                                let (label,labelColor): (String,Color) = {
                                    switch block.toolStatus {
                                    case .failed: return (String(localized: "Failed to edit"), .red)
                                    case .cancelled: return (String(localized: "Cancelled"), .orange)
                                    default: return (String(localized: "Edited"), Color(UIColor.label))
                                    }
                                }()
                                let isFailure: Bool = {
                                    if case .failed = block.toolStatus { return true }
                                    if case .cancelled = block.toolStatus { return true }
                                    return false
                                }()
                                VStack(alignment: .leading,spacing: 4) {
                                    HStack(spacing: 4) {
                                        Text(label)
                                            .font(.system(size: 13,weight: .semibold))
                                            .foregroundStyle(labelColor)
                                        Text(filePath)
                                            .font(.system(size: 12,design: .monospaced))
                                            .foregroundStyle(Color(UIColor.secondaryLabel))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                    }
                                    if isFailure,let errText = toolResult,!errText.isEmpty {
                                        Text(Self.trimmedErrorMessage(errText))
                                            .font(.system(size: 12,design: .monospaced))
                                            .foregroundStyle(Color(UIColor.secondaryLabel))
                                            .lineLimit(6)
                                            .frame(maxWidth: .infinity,alignment: .leading)
                                            .textSelection(.enabled)
                                    } else if let detail = resultDetail {
                                        Text(detail)
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color(UIColor.tertiaryLabel))
                                    }
                                }
                                .padding(.horizontal,14)
                                .padding(.vertical,10)
                            }
                        }
                            .frame(maxWidth: .infinity,minHeight: cardMinHeight,maxHeight: .infinity,alignment: .topLeading)
                            .background(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.10,alpha: 1) : UIColor(white: 0.94,alpha: 1) }))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.25,alpha: 1) : UIColor(white: 0.82,alpha: 1) }),lineWidth: 0.5))
                            .padding(.horizontal,12)
                            .padding(.top,12)
                        }
                        .padding(.bottom,16)
                    }
                }
            } else {
                fileEditorContent(block.content)
            }
        }
    }

    private func memoryWriteContentFromArgs() -> String? {
        guard let argsJson = block.toolInputArgs,
              let data = argsJson.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? String else { return nil }
        return content
    }

    private func memoryActionName() -> String {
        if case .memoryTool(let action) = block.kind { return action }
        return "memory"
    }

    ///
    private var resolvedBrowserURL: String {
        guard case .browserTool = block.kind else { return "" }
        if let url = block.browserURL,!url.isEmpty { return url }
        if let url = extractURLFromArgs(block) { return url }
        let idx = min(currentIdx,toolBlocks.count-1)
        if idx>0 {
            for i in stride(from: idx-1,through: 0,by: -1) {
                let prev = toolBlocks[i]
                if let url = prev.browserURL,!url.isEmpty { return url }
                if let url = extractURLFromArgs(prev) { return url }
            }
        }
        return ""
    }

    private func extractURLFromArgs(_ blk: AssistantBlock) -> String? {
        guard let json = blk.toolInputArgs,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // 顶层 url(apple-open 等工具)
        if let url = dict["url"] as? String, !url.isEmpty { return url }
        // browser_use 嵌套 params.url(2026-08-12 修复:参数格式为
        // {"action":"navigate","params":{"url":"https://..."}},顶层 url 恒为空)
        if let params = dict["params"] as? [String: Any],
           let url = params["url"] as? String,
           !url.isEmpty { return url }
        return nil
    }

    private func browserScriptFromArgs() -> String? {
        guard let json = block.toolInputArgs,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let script = dict["script"] as? String,
              !script.isEmpty else { return nil }
        return script
    }

    private func jsScriptCard(_ script: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange.opacity(0.7))
                Text("JavaScript")
                    .font(.system(size: 13,weight: .medium))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                Spacer()
                Text(Self.formatBytes(script.utf8.count))
                    .font(.system(size: 11))
                    .foregroundStyle(Color(UIColor.tertiaryLabel))
            }
            .padding(.horizontal,12)
            .padding(.vertical,10)
            .background(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.13,alpha: 1) : UIColor(white: 0.92,alpha: 1) }))

            Divider()

            Text(script)
                .font(.system(size: 12,design: .monospaced))
                .foregroundStyle(Color(UIColor.label))
                .frame(maxWidth: .infinity,alignment: .leading)
                .textSelection(.enabled)
                .padding(12)
        }
        .background(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.10,alpha: 1) : UIColor(white: 0.94,alpha: 1) }))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.25,alpha: 1) : UIColor(white: 0.82,alpha: 1) }),lineWidth: 0.5))
        .padding(.horizontal,12)
    }

    private func memoryEditorContent(_ memoryContent: String,action: String,resultText: String? = nil,isStreaming: Bool = false) -> some View {
        let byteCount = memoryContent.utf8.count
        let sizeLabel = isStreaming
            ? "\(Self.formatBytes(byteCount)) received"
            : Self.formatBytes(byteCount)

        return ScrollView {
            VStack(alignment: .leading,spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 12))
                            .foregroundStyle(.pink.opacity(0.6))
                        Text(action)
                            .font(.system(size: 13,weight: .medium))
                            .foregroundStyle(.pink)
                            .lineLimit(1)
                        Text("(\(sizeLabel))")
                            .font(.system(size: 11))
                            .foregroundStyle(isStreaming ? Color.orange.opacity(0.8) : .pink.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical,10)
                    .background(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.13,alpha: 1) : UIColor(white: 0.92,alpha: 1) }))

                    Divider()

                    VStack(alignment: .leading,spacing: 0) {
                        let chunks = isStreaming
                            ? Self.liveChunkedLines(memoryContent.isEmpty ? " " : memoryContent)
                            : Self.chunkedLines(memoryContent.isEmpty ? " " : memoryContent)
                        ForEach(chunks,id: \.id) { chunk in
                            Text(chunk.text)
                                .font(.system(size: 13,design: .monospaced))
                                .foregroundStyle(.pink.opacity(0.85))
                                .frame(maxWidth: .infinity,alignment: .leading)
                                .padding(.horizontal,14)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.vertical,14)
                }
                .background(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.10,alpha: 1) : UIColor(white: 0.94,alpha: 1) }))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.25,alpha: 1) : UIColor(white: 0.82,alpha: 1) }),lineWidth: 0.5))
                .padding(.horizontal,12)
                .padding(.top,12)
            }
            .padding(.bottom,16)
        }
    }

    private func fileEditorContent(_ fileContent: String,toolResult: String? = nil,isStreaming: Bool = false) -> some View {
        let fileName: String = {
            if case .fileWriteTool(let p) = block.kind { return (p as NSString).lastPathComponent }
            if case .fileEditTool(let p) = block.kind { return (p as NSString).lastPathComponent }
            if case .fileReadTool(let p) = block.kind { return (p as NSString).lastPathComponent }
            return "file"
        }()
        let isRead = { if case .fileReadTool = block.kind { return true }; return false }()
        let byteCount = fileContent.utf8.count
        let sizeLabel = isStreaming
            ? "\(Self.formatBytes(byteCount)) received"
            : Self.formatBytes(byteCount)

        let chunks = isStreaming
            ? Self.liveChunkedLines(fileContent.isEmpty ? " " : fileContent)
            : Self.chunkedLines(fileContent.isEmpty ? " " : fileContent)

        return ScrollView {
            VStack(alignment: .leading,spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: isRead ? "doc.text" : "doc.text.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(UIColor.secondaryLabel))
                        Text(fileName)
                            .font(.system(size: 13,weight: .medium))
                            .foregroundStyle(Color(UIColor.label))
                            .lineLimit(1)
                        Text("(\(sizeLabel))")
                            .font(.system(size: 11))
                            .foregroundStyle(isStreaming ? Color.orange.opacity(0.8) : Color(UIColor.tertiaryLabel))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical,10)
                    .background(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.13,alpha: 1) : UIColor(white: 0.92,alpha: 1) }))

                    Divider()

                    VStack(alignment: .leading,spacing: 0) {
                        ForEach(chunks,id: \.id) { chunk in
                            Text(chunk.text)
                                .font(.system(size: 13,design: .monospaced))
                                .foregroundStyle(Color(UIColor.label))
                                .frame(maxWidth: .infinity,alignment: .leading)
                                .padding(.horizontal,14)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.vertical,14)
                }
                .background(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.10,alpha: 1) : UIColor(white: 0.94,alpha: 1) }))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.25,alpha: 1) : UIColor(white: 0.82,alpha: 1) }),lineWidth: 0.5))
                .padding(.horizontal,12)
                .padding(.top,12)

                let footerPath: String? = {
                    if isStreaming { return nil }
                    if case .fileWriteTool(let p) = block.kind { return p }
                    if case .fileReadTool(let p) = block.kind { return p }
                    return nil
                }()
                if let fullPath = footerPath {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(UIColor.secondaryLabel))
                        Text(fullPath)
                            .font(.system(size: 12,design: .monospaced))
                            .foregroundStyle(Color(UIColor.label))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(sizeLabel)
                            .font(.system(size: 12,design: .monospaced))
                            .foregroundStyle(Color(UIColor.tertiaryLabel))
                    }
                    .padding(.horizontal,12)
                    .padding(.vertical,10)
                    .background(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.15,alpha: 1) : UIColor(white: 0.95,alpha: 1) }))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.25,alpha: 1) : UIColor(white: 0.82,alpha: 1) }),lineWidth: 0.5))
                    .padding(.horizontal,12)
                    .padding(.top,8)
                }
            }
            .padding(.bottom,16)
        }
    }

    private static func formatCharCount(_ count: Int) -> String {
        if count<1000 { return "\(count) chars" }
        if count<1_000_000 { return String(format: "%.1fK chars", Double(count)/1000.0) }
        return String(format: "%.1fM chars", Double(count)/1_000_000.0)
    }

    private static func formatBytes(_ bytes: Int) -> String {
        if bytes<1024 { return "\(bytes) B" }
        if bytes<1024*1024 { return String(format: "%.1f KB", Double(bytes)/1024.0) }
        return String(format: "%.1f MB", Double(bytes)/(1024.0*1024.0))
    }

    private static func trimmedErrorMessage(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("Error: ") { s.removeFirst("Error: ".count) }
        return s
    }

    private static func chunkedLines(_ text: String,chunkSize: Int = 40) -> [(id: Int,text: String)] {
        let sanitized = sanitizeForDisplay(text)
        let allLines = sanitized.split(separator: "\n", omittingEmptySubsequences: false)
        return stride(from: 0,to: max(allLines.count,1),by: chunkSize).map { i in
            let end = min(i+chunkSize,allLines.count)
            return (i, allLines[i..<end].joined(separator: "\n"))
        }
    }

    /// Initial number of chunks to reveal for a
    private static func initialRevealCount(_ chunks: [(id: Int,text: String)]) -> Int {
        guard !chunks.isEmpty else { return 0 }
        var count = 0
        var bytes = 0
        for chunk in chunks.prefix(lazyRenderInitialChunks) {
            bytes += chunk.text.utf8.count
            count += 1
            if bytes >= lazyRenderInitialByteCap { break }
        }
        return max(1,count)
    }

    @ViewBuilder
    private func loadMoreFooter(totalChunks: Int) -> some View {
        if revealedChunkCount<totalChunks {
            let remaining = totalChunks-revealedChunkCount
            let nextBatch = min(Self.lazyRenderBatchChunks,remaining)
            HStack(spacing: 16) {
                Button {
                    revealedChunkCount = min(revealedChunkCount+Self.lazyRenderBatchChunks,totalChunks)
                } label: {
                    Label("Load more (\(nextBatch * Self.lazyRenderChunkLines) lines)", systemImage: "chevron.down")
                        .font(.system(size: 13,weight: .medium))
                }
                Button {
                    revealedChunkCount = totalChunks
                } label: {
                    Text("Load all")
                        .font(.system(size: 13,weight: .medium))
                }
            }
            .padding(.vertical,12)
            .frame(maxWidth: .infinity)
            .onAppear {
                revealedChunkCount = min(revealedChunkCount+Self.lazyRenderBatchChunks,totalChunks)
            }
        }
    }

    private func resetRevealWindow(for chunks: [(id: Int,text: String)]) {
        guard revealedForBlockId != block.id else { return }
        revealedForBlockId = block.id
        revealedChunkCount = Self.initialRevealCount(chunks)
    }

    private static func liveChunkedLines(_ text: String,chunkSize: Int = 40,maxLines: Int = 500) -> [(id: Int,text: String)] {
        let sanitized = sanitizeForDisplay(text)
        let allLines = sanitized.split(separator: "\n", omittingEmptySubsequences: false)
        let start = allLines.count>maxLines ? allLines.count-maxLines : 0
        let visibleLines = allLines[start...]
        return stride(from: 0,to: max(visibleLines.count,1),by: chunkSize).map { i in
            let sliceStart = visibleLines.startIndex+i
            let sliceEnd = min(sliceStart+chunkSize,visibleLines.endIndex)
            return (start+i, visibleLines[sliceStart..<sliceEnd].joined(separator: "\n"))
        }
    }

    private static func chunkedDiffLines(_ text: String,prefix: String,chunkSize: Int = 40) -> [(id: Int,text: String)] {
        let sanitized = sanitizeForDisplay(text)
        let allLines = sanitized.components(separatedBy: "\n")
        return stride(from: 0,to: max(allLines.count,1),by: chunkSize).map { i in
            let end = min(i+chunkSize,allLines.count)
            let chunk = allLines[i..<end].map { prefix+$0 }.joined(separator: "\n")
            return (i,chunk)
        }
    }

    private var textContent: some View {
        GeometryReader { geo in
            let cardWidth = geo.size.width-24 // 12pt horizontal padding each side
            let cardMinHeight = cardWidth*3.0/4.0
            ScrollViewReader { proxy in
            ScrollView {
                if case .shellTool(let cmd) = block.kind {
                    let allChunks = isLive
                        ? Self.liveChunkedLines(block.content.isEmpty ? " " : block.content)
                        : Self.chunkedLines(block.content.isEmpty ? " " : block.content)
                    // In the detail (non-live)
                    let chunks = isLive ? allChunks : Array(allChunks.prefix(max(revealedChunkCount,1)))
                    VStack(alignment: .leading,spacing: 0) {
                        Text("$ \(cmd)")
                            .font(.system(size: 13,weight: .bold,design: .monospaced))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity,alignment: .leading)
                            .padding(.horizontal,14)
                            .padding(.top,14)

                        ForEach(chunks,id: \.id) { chunk in
                            Text(attributedShellLine(chunk.text))
                                .font(.system(size: 13,design: .monospaced))
                                .foregroundColor(accentColor)
                                .frame(maxWidth: .infinity,alignment: .leading)
                                .padding(.horizontal,14)
                        }

                        if !isLive {
                            loadMoreFooter(totalChunks: allChunks.count)
                        }

                        Color.clear.frame(height: 1).id("end")
                    }
                    .onAppear { if !isLive { resetRevealWindow(for: allChunks) } }
                    .textSelection(.enabled)
                    .padding(.bottom,14)
                    .frame(maxWidth: .infinity,minHeight: cardMinHeight,alignment: .topLeading)
                    .background(Color.black)
                    // [2026-08-14] 资源监控桩未接入（SystemResourceMonitor 恒返回 0%/0 MB），
                    // 暂隐藏底部 "0% 0 MB" 叠加条，避免误导；接入真实 iSH 资源采样后恢复。
                    // .overlay(alignment: .bottom) { if isLive { ... } }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.25,alpha: 1) : UIColor(white: 0.82,alpha: 1) }),lineWidth: 0.5))
                    .padding(.horizontal,12)
                    .padding(.top,12)
                    .padding(.bottom,16)
                } else {
                    VStack(alignment: .leading,spacing: 0) {
                        if !contentHeader.isEmpty {
                            Text(contentHeader)
                                .font(.system(size: 12,weight: .medium))
                                .foregroundStyle(ChatColors.secondaryText)
                                .padding(.horizontal,16)
                                .padding(.top,16)
                                .padding(.bottom,8)
                                .frame(maxWidth: .infinity,alignment: .center)
                        }

                        let allChunks = isLive
                            ? Self.liveChunkedLines(block.content.isEmpty ? " " : block.content)
                            : Self.chunkedLines(block.content.isEmpty ? " " : block.content)
                        // Reveal an initial
                        let chunks = isLive ? allChunks : Array(allChunks.prefix(max(revealedChunkCount,1)))
                        VStack(alignment: .leading,spacing: 0) {
                            ForEach(chunks,id: \.id) { chunk in
                                Text(chunk.text)
                                    .font(.system(size: 13,design: .monospaced))
                                    .foregroundColor(accentColor)
                                    .frame(maxWidth: .infinity,alignment: .leading)
                                    .padding(.horizontal,14)
                            }
                            if !isLive {
                                loadMoreFooter(totalChunks: allChunks.count)
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .onAppear { if !isLive { resetRevealWindow(for: allChunks) } }
                        .textSelection(.enabled)
                        .padding(.vertical,14)
                        .frame(maxWidth: .infinity,minHeight: cardMinHeight,alignment: .topLeading)
                        .background(Color(white: 0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal,12)
                    }
                    .padding(.bottom,16)
                }
            }
            // 点击结果区 = 暂停自动跟随（用户上滑看历史时输出不再拉回底部）；
            // 切换工具块或重开浮层时恢复。
            .onTapGesture { tailFollowPaused = true }
            .onChange(of: block.content.count) { _ in
                if isLive && !tailFollowPaused {
                    proxy.scrollTo("end", anchor: .bottom)
                }
            }
            // Switching to another tool block
            .onChange(of: block.id) { _ in
                tailFollowPaused = false // 切换工具块恢复跟随
                guard !isLive else { return }
                let chunks = Self.chunkedLines(block.content.isEmpty ? " " : block.content)
                revealedForBlockId = block.id
                revealedChunkCount = Self.initialRevealCount(chunks)
            }
            }
        }
    }

    /// [2026-08-14 三级布局] action+URL 胶囊层已上移为 L2 parameterRow，Live 区不再重复渲染。
    private var browserContent: some View {
        let script: String? = browserScriptFromArgs()

        return VStack(spacing: 0) {
            if let img = browserSnapshot ?? block.imageFilePath.flatMap({ UIImage(contentsOfFile: $0) }) {
                ScrollView {
                    VStack(alignment: .leading,spacing: 12) {
                        if let script {
                            jsScriptCard(script)
                                .padding(.top,12)
                        }

                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(UIColor.separator).opacity(0.5),lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.18),radius: 8,x: 0,y: 3)
                            .contextMenu {
                                Button { UIPasteboard.general.image = img } label: {
                                    Label("Copy Image", systemImage: "doc.on.doc")
                                }
                            }
                            .padding(.horizontal,12)
                            .padding(.top, script == nil ? 12 : 0)
                    }
                    .padding(.bottom,16)
                }
            } else {
                VStack(spacing: 0) {
                    if let script {
                        jsScriptCard(script)
                            .padding(.top,12)
                    }
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "globe")
                            .font(.system(size: 32))
                            .foregroundStyle(ChatColors.tertiaryText)
                        Text("Loading...")
                            .font(.system(size: 13))
                            .foregroundStyle(ChatColors.tertiaryText)
                    }
                    Spacer()
                }
            }
        }
        .onChange(of: block.imageFilePath) { path in
            if let path,let img = UIImage(contentsOfFile: path) {
                browserSnapshot = img
            }
        }
    }

    // MARK: - [2026-08-14 快照三级布局] L1 工具信息行（常显）
    // 由原 bottomBar 的 Tool info row 拆出：状态图标 + 标题/副标题 + 耗时/开始时间。

    private var toolInfoRow: some View {
        HStack(spacing: 8) {
            statusIcon
            VStack(alignment: .leading,spacing: 1) {
                // [2026-09-14 TopFlow] 这里原有一行 `Text(toolTitle)`（13pt semibold，文案
                // "MiniClaw is using Browser"）——**已上提到 nav 标题行**（见 `sheetNavBar`），
                // 本行只留副标题 + 耗时。
                // 副标题字号 11 → **14**（TopFlow：这一行字体加大点）。颜色不动（仍是 secondary，
                // 保持与标题行的层级差；只按要求改字号，不擅自改配色）。
                Text(toolSubtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(ChatColors.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            let dur = block.toolDuration ?? currentSnapshot?.snapshot.duration
            if dur != nil || block.toolStartTime != nil || (isRunningStatus && block.commandStartedAt != nil) {
                VStack(alignment: .trailing,spacing: 1) {
                    if let dur {
                        // 已完成：静态耗时。
                        Text(Self.formatDuration(dur))
                            .font(.system(size: 11,design: .monospaced))
                            .foregroundStyle(ChatColors.tertiaryText)
                    } else if isRunningStatus, let started = block.commandStartedAt {
                        // 运行中：实时计时（SwiftUI 自动每秒刷新，2026-09-05）。
                        Text(timerInterval: started...Date.distantFuture, countsDown: false)
                            .font(.system(size: 11,design: .monospaced))
                            .foregroundStyle(ChatColors.tertiaryText)
                    }
                    if let started = block.toolStartTime {
                        Text(MiniClawStepTimestampFormatter.string(from: started))
                            .font(.system(size: 9,design: .monospaced))
                            .foregroundStyle(ChatColors.tertiaryText.opacity(0.75))
                    }
                }
            }
        }
        .padding(.horizontal,16)
        .padding(.vertical,10)
    }

    // MARK: - [2026-08-14 快照三级布局] L2 操作参数行（常显）
    // 该工具"动作 + 参数"摘要：browser → action 胶囊 + 可复制 URL 胶囊；
    // shell → $ 命令；文件/图片 → 路径；memory → 动作胶囊。

    /// 参数行是否有内容：为空时不显示 L1/L2 之间的分隔线。
    private var hasParameterRow: Bool {
        switch block.kind {
        case .browserTool:
            return !contentHeader.isEmpty || !resolvedBrowserURL.isEmpty || browserScriptFromArgs() != nil
        case .shellTool:
            return !contentHeader.isEmpty
        case .fileReadTool, .fileWriteTool, .fileEditTool, .readImageTool:
            return !contentHeader.isEmpty
        case .memoryTool:
            return !memoryActionName().isEmpty
        default:
            return false
        }
    }

    @ViewBuilder
    private var parameterRow: some View {
        let header = contentHeader
        switch block.kind {
        case .browserTool:
            let action = header
            let url = resolvedBrowserURL
            let script = browserScriptFromArgs()
            if !action.isEmpty || !url.isEmpty || script != nil {
                HStack(spacing: 8) {
                    if !action.isEmpty {
                        Text(action)
                            .font(.system(size: 12,weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal,10)
                            .padding(.vertical,5)
                            .background(Color.blue)
                            .clipShape(Capsule())
                    }
                    if !url.isEmpty {
                        CopyableURLCapsule(url: url)
                    }
                    if script != nil {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                    Spacer(minLength: 0)
                }
                // [2026-08-14] L2 统一高度：minHeight 在 padding 内 → 胶囊/文本总高一致；
                // 顶部 10pt 保证 L2 与上方分隔线之间有呼吸空间。
                .frame(minHeight: 30)
                .padding(.horizontal,16)
                .padding(.top,10)
                .padding(.bottom,8)
            }
        case .shellTool:
            if !header.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                    Text("$ \(header)")
                        .font(.system(size: 12,design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 30)
                .padding(.horizontal,16)
                .padding(.top,10)
                .padding(.bottom,8)
            }
        case .fileReadTool,.fileWriteTool,.fileEditTool,.readImageTool:
            if !header.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(header)
                        .font(.system(size: 12,design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 30)
                .padding(.horizontal,16)
                .padding(.top,10)
                .padding(.bottom,8)
            }
        case .memoryTool:
            let action = memoryActionName()
            if !action.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 11))
                        .foregroundStyle(.pink)
                    Text(action)
                        .font(.system(size: 12,weight: .semibold))
                        .foregroundStyle(.pink)
                        .padding(.horizontal,10)
                        .padding(.vertical,3)
                        .background(Color.pink.opacity(0.15))
                        .clipShape(Capsule())
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 30)
                .padding(.horizontal,16)
                .padding(.top,10)
                .padding(.bottom,8)
            }
        default:
            EmptyView()
        }
    }

    // MARK: - [2026-08-14 快照三级布局] 底部切换行（保留原导航行）

    private var switchRow: some View {
        HStack {
            Button {
                if currentIdx>0 { withAnimation { currentIdx -= 1 } }
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(currentIdx>0 ? ChatColors.primaryText : ChatColors.tertiaryText)
            }
            .disabled(currentIdx <= 0)

            Spacer()

            if isLive {
                HStack(spacing: 4) {
                    Circle()
                        .fill(.green)
                        .frame(width: 7,height: 7)
                    Text("Live")
                        .font(.system(size: 13,weight: .medium))
                        .foregroundStyle(ChatColors.primaryText)
                }
            } else {
                Text("\(currentIdx + 1) / \(toolBlocks.count)")
                    .font(.system(size: 13,weight: .medium,design: .monospaced))
                    .foregroundStyle(ChatColors.secondaryText)
            }

            Spacer()

            Button {
                if currentIdx<toolBlocks.count-1 { withAnimation { currentIdx += 1 } }
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(currentIdx<toolBlocks.count-1 ? ChatColors.primaryText : ChatColors.tertiaryText)
            }
            .disabled(currentIdx >= toolBlocks.count-1)
        }
        .padding(.horizontal,24)
        .padding(.vertical,12)
        .background(Color(UIColor.systemBackground))
    }

    /// 运行中（streaming/running）判定：实时计时列的显示条件之一。
    private var isRunningStatus: Bool {
        if case .streaming = block.toolStatus { return true }
        return block.toolStatus == .running
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch block.toolStatus {
        case .streaming,.running:
            ProgressView()
                .scaleEffect(0.7)
                .frame(width: 20,height: 20)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.yellow)
        case nil:
            EmptyView()
        }
    }

    /// nav 标题行文案：**中文**、**不带 `MiniClaw` 前缀**、只说明正在用哪个工具。
    ///
    /// [2026-09-14 TopFlow] 旧实现是硬编码英文（"MiniClaw is using Browser" …）⇒ **中文环境下也显示英文**，
    /// 这也是"改成中文显示"的直接原因。现按 i18n 纪律改造：catalog 的 `sourceLanguage` 是 **en**，
    /// 故 key 取英文原句，中文由 `Localizable.xcstrings` 的 `zh-Hans` 提供（条目已随本次一起加入）。
    /// 非工具类 kind 保留产品名本身（这里不是"前缀"问题，去掉会变成空字符串）。
    private var toolTitle: String {
        switch block.kind {
        case .shellTool: return String(localized: "Using Shell")
        case .fileReadTool: return String(localized: "Reading File")
        case .fileWriteTool: return String(localized: "Using Editor")
        case .fileEditTool: return String(localized: "Editing File")
        case .browserTool: return String(localized: "Using Browser")
        case .readImageTool: return String(localized: "Reading Image")
        case .memoryTool: return String(localized: "Using Memory")
        case .subagentTool: return String(localized: "Managing Subagents")
        case .question: return String(localized: "ask_user_title")
        case .info,.text,.thinking,.file: return "MiniClaw"
        }
    }

    private var toolSubtitle: String {
        let raw = if let s = block.toolSummary,!s.isEmpty { s } else { block.toolDescription }
        return raw.replacingOccurrences(of: "\n", with: " ")
    }

    private var contentHeader: String {
        switch block.kind {
        case .shellTool(let cmd): return cmd
        case .fileReadTool(let p): return (p as NSString).lastPathComponent
        case .fileWriteTool(let p): return (p as NSString).lastPathComponent
        case .fileEditTool(let p): return (p as NSString).lastPathComponent
        case .browserTool(let a): return a
        case .readImageTool(let p): return (p as NSString).lastPathComponent
        case .memoryTool(let a): return a
        default: return ""
        }
    }

    private var accentColor: Color {
        switch block.kind {
        case .shellTool: return .green
        case .fileReadTool: return .primary
        case .fileWriteTool: return .blue
        case .fileEditTool: return .orange
        case .browserTool: return .blue
        case .readImageTool: return .purple
        case .memoryTool: return .pink
        case .subagentTool: return .purple
        case .question: return .orange
        case .info: return .secondary
        case .text: return .primary
        case .thinking: return .blue
        case .file: return .secondary
        }
    }

    private static func formatDuration(_ dur: TimeInterval) -> String {
        if dur<1 { return String(format: "%.1fs", dur) }
        if dur<60 { return String(format: "%.0fs", dur) }
        let mins = Int(dur)/60
        let secs = Int(dur)%60
        return "\(mins)m \(secs)s"
    }

    private func startBrowserTimer() {
        guard case .browserTool = block.kind else { return }
        takeBrowserSnapshot()
        let timer = Timer.scheduledTimer(withTimeInterval: 3,repeats: true) { _ in
            takeBrowserSnapshot()
        }
        snapshotTimer = timer
    }

    private func stopBrowserTimer() {
        snapshotTimer?.invalidate()
        snapshotTimer = nil
    }

    private func takeBrowserSnapshot() {
        guard let manager = browserPool?.activeManager else { return }
        Task { @MainActor in
            let config = WKSnapshotConfiguration()
            if let img = try? await manager.webView.takeSnapshot(configuration: config) {
                browserSnapshot = img
            }
        }
    }
}

enum MiniClawStepTimestampFormatter {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    /// < 60s → "3s"
    /// < 1h → "2m30s" (drops the seconds suffix when seconds == 0)
    /// ≥ 1h → "1h12m"
    static func duration(seconds: TimeInterval,stillRunning: Bool = false) -> String {
        let safe = (seconds.isFinite && seconds>0) ? seconds : 0
        let totalSecs = Int(safe.rounded())
        let base: String
        if totalSecs<60 {
            base = "\(totalSecs)s"
        } else if totalSecs<3600 {
            let m = totalSecs/60
            let s = totalSecs%60
            base = s == 0 ? "\(m)m" : "\(m)m\(s)s"
        } else {
            let h = totalSecs/3600
            let m = (totalSecs%3600)/60
            base = m == 0 ? "\(h)h" : "\(h)h\(m)m"
        }
        return stillRunning ? "\(base)…" : base
    }
}

private struct ToolStatusBar: View {
    @ObservedObject var block: AssistantBlock
    let toolBlocks: [AssistantBlock]
    let displayedIdx: Int
    @Binding var expanded: Bool
    @Binding var selectedIdx: Int?
    var leadingInset: CGFloat = 0

    var body: some View {
        HStack(spacing: 2) {
            statusIcon

            Text(displayTitle)
                .font(.system(size: 13,weight: .medium))
                .foregroundStyle(ChatColors.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { expanded = true } }

            Spacer(minLength: 1)

            if toolBlocks.count>1 {
                HStack(spacing: 2) {
                    Button {
                        let prev = (selectedIdx ?? displayedIdx)-1
                        if prev >= 0 { withAnimation { selectedIdx = prev } }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10,weight: .semibold))
                            .foregroundStyle(displayedIdx>0 ? ChatColors.primaryText : ChatColors.tertiaryText)
                            .frame(width: 20,height: 20)
                            .contentShape(Rectangle())
                    }
                    .disabled(displayedIdx <= 0)

                    Text("\(displayedIdx + 1)/\(toolBlocks.count)")
                        .font(.system(size: 11,weight: .medium,design: .monospaced))
                        .foregroundStyle(ChatColors.secondaryText)

                    Button {
                        let next = (selectedIdx ?? displayedIdx)+1
                        if next<toolBlocks.count { withAnimation { selectedIdx = next } }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10,weight: .semibold))
                            .foregroundStyle(displayedIdx<toolBlocks.count-1 ? ChatColors.primaryText : ChatColors.tertiaryText)
                            .frame(width: 20,height: 20)
                            .contentShape(Rectangle())
                    }
                    .disabled(displayedIdx >= toolBlocks.count-1)
                }
            }
        }
        .padding(.leading,leadingInset>0 ? leadingInset : 12)
        .padding(.trailing,12)
        .padding(.vertical,5)
        .frame(minHeight: 38)
        .frame(maxWidth: .infinity)
        .background(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.15,alpha: 1) : UIColor.systemBackground }))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(UIColor.separator).opacity(0.3),lineWidth: 0.5)
        )
        .shadow(color: Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.08,alpha: 0.75) : UIColor(white: 0,alpha: 0.12) }),radius: 8,x: 0,y: 4)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch block.toolStatus {
        case .streaming,.running:
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 16,height: 16)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.yellow)
        case nil:
            EmptyView()
        }
    }

    private var displayTitle: String {
        if let s = block.toolSummary,!s.isEmpty { return s }
        return block.toolDescription
    }
}

fileprivate func sanitizeForDisplay(_ text: String) -> String {
    guard !text.isEmpty else { return text }

    var out = String()
    out.reserveCapacity(text.count)
    var i = text.unicodeScalars.startIndex
    let end = text.unicodeScalars.endIndex
    let scalars = text.unicodeScalars

    while i<end {
        let s = scalars[i]
        let v = s.value

        if v == 0x1B {
            let next = scalars.index(after: i)
            if next<end {
                let n = scalars[next].value
                if n == 0x5B { // '[' — CSI: ESC [ ... final-byte (0x40..0x7E)
                    var j = scalars.index(after: next)
                    while j<end {
                        let c = scalars[j].value
                        j = scalars.index(after: j)
                        if c >= 0x40 && c <= 0x7E { break }
                    }
                    i = j
                    continue
                } else if n == 0x5D { // ']' — OSC: ESC ] ... BEL or ESC \
                    var j = scalars.index(after: next)
                    while j<end {
                        let c = scalars[j].value
                        if c == 0x07 { // BEL
                            j = scalars.index(after: j)
                            break
                        }
                        if c == 0x1B { // ESC — check for ST (ESC \)
                            let k = scalars.index(after: j)
                            if k<end && scalars[k].value == 0x5C {
                                j = scalars.index(after: k)
                                break
                            }
                        }
                        j = scalars.index(after: j)
                    }
                    i = j
                    continue
                } else {
                    i = scalars.index(after: next)
                    continue
                }
            }
            i = next
            continue
        }

        if (v<0x20 && v != 0x0A && v != 0x09) || v == 0x7F {
            if v != 0x0D {
                out.unicodeScalars.append(Unicode.Scalar(0xFFFD)!)
            }
            i = scalars.index(after: i)
            continue
        }

        if v >= 0x80 && v <= 0x9F {
            out.unicodeScalars.append(Unicode.Scalar(0xFFFD)!)
            i = scalars.index(after: i)
            continue
        }

        out.unicodeScalars.append(s)
        i = scalars.index(after: i)
    }

    var needsWrap = false
    var run = 0
    for u in out.utf16 {
        if u == 0x0A {
            run = 0
        } else {
            run += 1
            if run>_maxRenderedLineLength { needsWrap = true; break }
        }
    }
    guard needsWrap else { return out }

    var wrapped = String()
    wrapped.reserveCapacity(out.count)
    for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.utf16.count <= _maxRenderedLineLength {
            wrapped.append(contentsOf: line)
        } else {
            var col = 0
            for ch in line {
                let w = ch.utf16.count
                if col+w>_maxRenderedLineLength {
                    wrapped.append("\n")
                    col = 0
                }
                wrapped.append(ch)
                col += w
            }
        }
        wrapped.append("\n")
    }
    if !out.hasSuffix("\n") { wrapped.removeLast() }
    return wrapped
}

struct FloatingToolBar: View {
    let toolBlocks: [AssistantBlock]
    var toolSnapshots: [ToolSnapshotItem] = []
    var browserPool: MiniClawTabPool?
    var onBrowserTakeover: (() -> Void)?
    var onTakeoverDone: (() -> Void)?
    @State private var selectedIdx: Int? = nil
    @State private var expanded = false
    @AppStorage("toolPreviewEnabled") private var toolPreviewEnabled: Bool = true

    private var displayedIdx: Int {
        if let idx = selectedIdx,idx<toolBlocks.count { return idx }
        if let activeIdx = toolBlocks.lastIndex(where: {
            if case .streaming = $0.toolStatus { return true }
            if case .running = $0.toolStatus { return true }
            return false
        }) { return activeIdx }
        return toolBlocks.count-1
    }

    private var displayedBlock: AssistantBlock {
        toolBlocks[displayedIdx]
    }

    private static let thumbnailWidth: CGFloat = 100

    private var displayedSnapshot: ToolSnapshotItem? {
        guard let blockId = displayedBlock.toolUseId else { return nil }
        return toolSnapshots.first(where: { $0.id == blockId })
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ToolStatusBar(
                block: displayedBlock,
                toolBlocks: toolBlocks,
                displayedIdx: displayedIdx,
                expanded: $expanded,
                selectedIdx: $selectedIdx,
                leadingInset: toolPreviewEnabled ? Self.thumbnailWidth+18 : 0
            )

            if toolPreviewEnabled {
                ToolPreviewThumbnail(
                    block: displayedBlock,
                    snapshot: displayedSnapshot,
                    browserPool: browserPool,
                    onTap: { withAnimation { expanded = true } }
                )
                .offset(x: 10)
            }
        }
        .animation(.easeInOut(duration: 0.15),value: displayedIdx)
        .sheet(isPresented: $expanded) {
            ToolLiveSheet(
                toolBlocks: toolBlocks,
                initialIdx: displayedIdx,
                toolSnapshots: toolSnapshots,
                browserPool: browserPool,
                onBrowserTakeover: onBrowserTakeover,
                onTakeoverDone: onTakeoverDone
            )
        }
    }
}

private struct CopyableURLCapsule: View {
    let url: String
    @State private var showCopied = false

    var body: some View {
        Text(showCopied ? "Copied!" : url)
            .font(.system(size: 12,weight: showCopied ? .semibold : .regular))
            .foregroundStyle(showCopied ? Color.white : Color(white: 0.35))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal,10)
            .padding(.vertical,5)
            .background(showCopied ? Color.green : Color(white: 0.85))
            .clipShape(Capsule())
            .animation(.easeInOut(duration: 0.2),value: showCopied)
            .onTapGesture {
                UIPasteboard.general.string = url
                showCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now()+1.5) {
                    showCopied = false
                }
            }
    }
}

private let _maxRenderedLineLength = 2000

///
private let _shellURLDetector: NSDataDetector? = {
    try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
}()

private struct ToolPreviewThumbnail: View {
    @ObservedObject var block: AssistantBlock
    var snapshot: ToolSnapshotItem?
    var browserPool: MiniClawTabPool?
    var onTap: () -> Void
    @State private var browserSnapshot: UIImage?
    @State private var snapshotTimer: Timer?
    @StateObject private var resourceMonitor = SystemResourceMonitor()

    private var isLive: Bool {
        if case .streaming = block.toolStatus { return true }
        if case .running = block.toolStatus { return true }
        return false
    }

    var body: some View {
        Group {
            if let snapshot,let snapshotImage = loadSnapshotImage(snapshot) {
                Image(uiImage: snapshotImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 100,height: 65)
                    .clipped()
            } else if let snapshot,case .text = snapshot.snapshot.type,let text = snapshot.snapshot.text {
                if case .fileEditTool = block.kind {
                    diffPreview
                } else {
                    snapshotTextPreview(text)
                }
            } else {
                switch block.kind {
                case .browserTool:
                    browserPreview
                case .fileEditTool:
                    diffPreview
                default:
                    textPreview
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(UIColor.separator).opacity(0.4),lineWidth: 0.5)
        )
        // [2026-08-14] 资源监控桩未接入（恒返回 0%/0 MB），暂隐藏底部 "0% 0 MB" 叠加条。
        // .overlay(alignment: .bottom) { if isLive && isShell { ... } }
        .shadow(color: .black.opacity(0.3),radius: 10,x: 0,y: 3)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onAppear {
            if isLive && isShell { resourceMonitor.start() }
        }
        .onDisappear { resourceMonitor.stop() }
        .onChange(of: isLive) { live in
            if live && isShell { resourceMonitor.start() } else { resourceMonitor.stop() }
        }
    }

    private func snapshotTextPreview(_ text: String) -> some View {
        VStack(alignment: .leading,spacing: 0) {
            Text(previewHeader)
                .font(.system(size: 6,weight: .bold,design: isShell ? .monospaced : .default))
                .foregroundStyle(isShell ? .white : .white.opacity(0.45))
                .lineLimit(1)
                .padding(.horizontal,4)
                .padding(.top,4)
                .padding(.bottom,1)

            Text(lastLines(text,count: 12))
                .font(.system(size: 4,design: .monospaced))
                .foregroundStyle(accentColor.opacity(0.85))
                .lineLimit(12)
                .frame(maxWidth: .infinity,alignment: .leading)
                .padding(.horizontal,4)
                .padding(.bottom,3)
        }
        .frame(width: 100,height: 65,alignment: .topLeading)
        .clipped()
        .background(Color(red: 0.12,green: 0.12,blue: 0.14))
    }

    private func loadSnapshotImage(_ item: ToolSnapshotItem) -> UIImage? {
        guard case .image = item.snapshot.type,
              let ref = item.snapshot.mediaRef else { return nil }
        let url = item.mediaResolver(ref)
        let cacheKey = "thumb:\(url.path)"
        if let cached = NativeMediaImageCache.shared.image(for: cacheKey) {
            return cached
        }
        guard let data = try? Data(contentsOf: url),
              let thumb = downsampleImageData(data,maxPixelSize: 200) else {
            return nil
        }
        NativeMediaImageCache.shared.set(thumb,for: cacheKey)
        return thumb
    }

    private var textPreview: some View {
        let displayText: String = {
            let isFileStreamKind: Bool = {
                if case .fileWriteTool = block.kind { return true }
                if case .fileEditTool = block.kind { return true }
                return false
            }()
            if isFileStreamKind,let liveContent = block.streamingFileContent,!liveContent.isEmpty {
                return liveContent
            }
            return block.content
        }()
        return VStack(alignment: .leading,spacing: 0) {
            Text(previewHeader)
                .font(.system(size: 6,weight: .bold,design: isShell ? .monospaced : .default))
                .foregroundStyle(isShell ? .white : .white.opacity(0.45))
                .lineLimit(1)
                .padding(.horizontal,4)
                .padding(.top,4)
                .padding(.bottom,1)

            Text(lastLines(displayText,count: 12))
                .font(.system(size: 4,design: .monospaced))
                .foregroundStyle(accentColor.opacity(0.85))
                .lineLimit(12)
                .frame(maxWidth: .infinity,alignment: .leading)
                .padding(.horizontal,4)
                .padding(.bottom,3)
        }
        .frame(width: 100,height: 65,alignment: .topLeading)
        .clipped()
        .background(Color(red: 0.12,green: 0.12,blue: 0.14))
    }

    private var diffPreview: some View {
        let editStrings: (oldString: String,newString: String)? = {
            guard let json = block.toolInputArgs,
                  let data = json.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let old = dict["old_string"] as? String,
                  let new = dict["new_string"] as? String else { return nil }
            return (old,new)
        }()
        let oldText = editStrings?.oldString ?? block.streamingFileContent ?? ""
        let newText = editStrings?.newString ?? ""

        return VStack(alignment: .leading,spacing: 0) {
            Text(previewHeader)
                .font(.system(size: 6,weight: .bold))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
                .padding(.horizontal,4)
                .padding(.top,4)
                .padding(.bottom,1)

            if !oldText.isEmpty {
                Text(lastLines(oldText, count: 6).split(separator: "\n", omittingEmptySubsequences: false).map { "- "+$0 }.joined(separator: "\n"))
                    .font(.system(size: 4,design: .monospaced))
                    .foregroundStyle(Color(red: 1,green: 0.4,blue: 0.4).opacity(0.85))
                    .lineLimit(6)
                    .frame(maxWidth: .infinity,alignment: .leading)
                    .padding(.horizontal,4)
            }
            if !newText.isEmpty {
                Text(lastLines(newText, count: 6).split(separator: "\n", omittingEmptySubsequences: false).map { "+ "+$0 }.joined(separator: "\n"))
                    .font(.system(size: 4,design: .monospaced))
                    .foregroundStyle(Color(red: 0.4,green: 1,blue: 0.4).opacity(0.85))
                    .lineLimit(6)
                    .frame(maxWidth: .infinity,alignment: .leading)
                    .padding(.horizontal,4)
            }
        }
        .frame(width: 100,height: 65,alignment: .topLeading)
        .clipped()
        .background(Color(red: 0.12,green: 0.12,blue: 0.14))
    }

    private var browserPreview: some View {
        Group {
            if let img = browserSnapshot {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 100,height: 65)
                    .clipped()
            } else {
                ZStack {
                    Color(red: 0.12,green: 0.12,blue: 0.14)
                    Image(systemName: "globe")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.2))
                }
                .frame(width: 100,height: 65)
            }
        }
        .onAppear {
            startBrowserTimer()
            loadThumbnailIfNeeded()
        }
        .onDisappear { stopBrowserTimer() }
        .onChange(of: block.imageFilePath) { _ in
            loadThumbnailIfNeeded()
        }
    }

    private func loadThumbnailIfNeeded() {
        guard browserSnapshot == nil,let path = block.imageFilePath else { return }
        let cacheKey = "thumb:\(path)"
        if let cached = NativeMediaImageCache.shared.image(for: cacheKey) {
            browserSnapshot = cached
            return
        }
        Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
            guard let thumb = downsampleImageData(data,maxPixelSize: 200) else { return }
            NativeMediaImageCache.shared.set(thumb,for: cacheKey)
            await MainActor.run {
                self.browserSnapshot = thumb
            }
        }
    }

    private func startBrowserTimer() {
        takeBrowserSnapshot()
        let timer = Timer.scheduledTimer(withTimeInterval: 5,repeats: true) { _ in
            takeBrowserSnapshot()
        }
        snapshotTimer = timer
    }

    private func stopBrowserTimer() {
        snapshotTimer?.invalidate()
        snapshotTimer = nil
    }

    private func takeBrowserSnapshot() {
        guard let manager = browserPool?.activeManager else { return }
        Task { @MainActor in
            let config = WKSnapshotConfiguration()
            if let img = try? await manager.webView.takeSnapshot(configuration: config) {
                browserSnapshot = img
            }
        }
    }

    private var previewHeader: String {
        switch block.kind {
        case .shellTool(let cmd): return cmd.isEmpty ? "$ shell" : "$ \(cmd)"
        case .fileReadTool(let p):
            let name = (p as NSString).lastPathComponent
            return (!p.isEmpty && name != "/" && name.contains(".")) ? name : String(localized: "Read file")
        case .fileWriteTool(let p):
            let name = (p as NSString).lastPathComponent
            return (!p.isEmpty && name != "/" && name.contains(".")) ? name : String(localized: "Write file")
        case .fileEditTool(let p):
            let name = (p as NSString).lastPathComponent
            return (!p.isEmpty && name != "/" && name.contains(".")) ? name : String(localized: "Edit file")
        case .browserTool(let a): return a
        case .readImageTool(let p):
            let name = (p as NSString).lastPathComponent
            return (!p.isEmpty && name != "/" && name.contains(".")) ? name : String(localized: "Read image")
        case .memoryTool(let a): return a
        default: return ""
        }
    }

    private var isShell: Bool {
        if case .shellTool = block.kind { return true }
        return false
    }

    private var accentColor: Color {
        switch block.kind {
        case .shellTool: return .green
        case .fileReadTool: return .cyan
        case .fileWriteTool: return .blue
        case .fileEditTool: return .orange
        case .browserTool: return .blue
        case .readImageTool: return .purple
        case .memoryTool: return .pink
        case .subagentTool: return .purple
        case .info: return .secondary
        case .text: return .primary
        case .thinking: return .blue
        case .file: return .secondary
        case .question: return .orange
        }
    }

    private func lastLines(_ text: String,count: Int) -> String {
        let lines = text.components(separatedBy: "\n")
        return lines.suffix(count).joined(separator: "\n")
    }
}
