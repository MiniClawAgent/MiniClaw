import UIKit
import SwiftUI

/// 会话页 V2 的列表本体。
///
/// 与旧实现的三点根本差别：
/// 1. **高度交给系统**：组合布局 + 自 sizing cell，不再自建 height cache / 兜底常量；
/// 2. **视口只有一个所有者**：所有 offset/inset 写入都经 `ChatV2Viewport`；
/// 3. **状态行固定高度**：footer 恒为 `ChatV2Metrics.footerHeight`，形态切换不改高度。
/// 宿主提供的动作（ChatView 注入）。V2 只消费这些闭包，不反向依赖 ChatView。
struct ChatV2Actions {
    var onStop: (() -> Void)?
    var onRetryLast: (() -> Void)?
    var onEdit: ((UUID) -> Void)?
    var onWithdraw: ((UUID) -> Void)?
    var onSendQueued: ((UUID) -> Void)?
    var onCompact: ((UUID) -> Void)?
    var onCopyScreenshot: (() -> Void)?
    var onResume: (() -> Void)?
}

@MainActor
final class ChatV2ListViewController: UIViewController {
    // MARK: - 输入

    private let vm: MessageListModel
    private let actions: ChatV2Actions
    private var bridges: [UUID: CellStateBridge] = [:]
    private let rowBuilder: ChatV2RowBuilding

    private(set) var rows: [ChatRow] = []
    private var rowsByID: [ChatRowID: ChatRow] = [:]
    private var lastContentHeight: CGFloat = 0
    private var keyboardHeight: CGFloat = 0
    private var composerHeight: CGFloat = 0

    /// 由宿主（ChatView）在输入区尺寸变化时调用。
    func updateComposerHeight(_ h: CGFloat) {
        guard abs(h - composerHeight) > 0.5 else { return }
        let before = obscuredBottom
        composerHeight = h
        let after = obscuredBottom
        viewport.handle(.obscuredBottomChanged(delta: after - before))
    }

    private var safeBottom: CGFloat {
        view.window?.safeAreaInsets.bottom ?? view.safeAreaInsets.bottom
    }

    private var obscuredBottom: CGFloat {
        composerHeight + keyboardHeight + safeBottom + ChatV2Metrics.bottomGap
    }

    // MARK: - 组件

    private let viewport = ChatV2Viewport()
    private lazy var collectionView: UICollectionView = {
        let cv = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        cv.backgroundColor = .clear
        cv.alwaysBounceVertical = true
        cv.keyboardDismissMode = .interactive
        cv.contentInsetAdjustmentBehavior = .never
        cv.delegate = self
        cv.register(ChatV2Cell.self, forCellWithReuseIdentifier: ChatV2Cell.reuseID)
        return cv
    }()
    private lazy var diffable: UICollectionViewDiffableDataSource<Int, ChatRowID> = makeDataSource()

    // MARK: - 生命周期

    init(vm: MessageListModel,
         actions: ChatV2Actions = ChatV2Actions(),
         rowBuilder: ChatV2RowBuilding = ChatV2RowBuilder()) {
        self.vm = vm
        self.actions = actions
        self.rowBuilder = rowBuilder
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        wireViewport()
        observeKeyboard()
    }

    // MARK: - 布局

    private func makeLayout() -> UICollectionViewLayout {
        let item: NSCollectionLayoutItem = {
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0),
                                              heightDimension: .estimated(ChatV2Metrics.textEstimate))
            return NSCollectionLayoutItem(layoutSize: size)
        }()
        let group = NSCollectionLayoutGroup.vertical(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0),
                                               heightDimension: .estimated(ChatV2Metrics.textEstimate)),
            subitems: [item]
        )
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = ChatV2Metrics.interItemSpacing
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        // 固定高度的行用绝对尺寸；其余走 estimated 自 sizing。
        return UICollectionViewCompositionalLayout(section: section)
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<Int, ChatRowID> {
        UICollectionViewDiffableDataSource<Int, ChatRowID>(collectionView: collectionView) { [weak self] cv, indexPath, rowID in
            let cell = cv.dequeueReusableCell(withReuseIdentifier: ChatV2Cell.reuseID, for: indexPath) as! ChatV2Cell
            guard let self, let row = self.rowsByID[rowID] else { return cell }
            cell.configure(row: row,
                           vm: self.vm,
                           bridge: self.bridge(for: row.message),
                           width: cv.bounds.width)
            return cell
        }
    }

    // MARK: - 数据

    func apply(messages: [RenderMessage]) {
        syncBridgeStates(messages: messages)
        // builder 是纯函数，状态逐次注入，避免"init 时快照过期"。
        var builder = rowBuilder as? ChatV2RowBuilder ?? ChatV2RowBuilder()
        builder.isProcessing = vm.isProcessing
        builder.canResume = vm.canResume
        // bottomSpacer 在 V2 里不参与渲染（短会话不需要撑满，避免又引入"填充高度"这个变量）。
        let newRows = builder.buildRows(messages: messages).filter { $0.kind != .bottomSpacer }

        // 幂等：SwiftUI 每次 update 都会调到这里；行身份与版本都没变就没有工作可做。
        if newRows.count == rows.count,
           zip(newRows, rows).allSatisfy({ $0.id == $1.id && $0.version == $1.version }) {
            return
        }
        let oldHeight = lastContentHeight

        rows = newRows
        rowsByID = Dictionary(uniqueKeysWithValues: newRows.map { ($0.id, $0) })

        var snapshot = NSDiffableDataSourceSnapshot<Int, ChatRowID>()
        snapshot.appendSections([0])
        snapshot.appendItems(newRows.map(\.id), toSection: 0)
        // 版本变化 → 只重配，不重建（保住 cell 与滚动位置）。
        lastVersion = Dictionary(uniqueKeysWithValues: newRows.map { ($0.id, $0.version) })

        UIView.performWithoutAnimation {
            self.collectionView.collectionViewLayout.invalidateLayout()
        }
        diffable.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            self.view.layoutIfNeeded()
            let newHeight = self.collectionView.contentSize.height
            let delta = newHeight - oldHeight
            self.lastContentHeight = newHeight
            AppLogger.shared.info(
                "[V2] apply rows=\(self.rows.count) h=\(String(format: "%.0f", newHeight)) Δ=\(String(format: "%.0f", delta)) pinned=\(self.viewport.isPinnedToBottom) inset=\(String(format: "%.0f", self.collectionView.contentInset.bottom)) offY=\(String(format: "%.0f", self.collectionView.contentOffset.y))",
                category: "BottomPad")
            let viewportH = self.collectionView.bounds.height
            let inset = self.collectionView.contentInset.bottom
            self.collectionView.isScrollEnabled = newHeight > viewportH - inset
            if delta != 0 {
                self.viewport.handle(.contentGrewAtBottom(delta: delta))
            }
        }
    }

    private var lastVersion: [ChatRowID: String] = [:]

    /// 每条消息一个 bridge；状态（处理中/可恢复/错误）在每次 apply 时按 vm 重算。
    /// 这是旧 Coordinator 的 `updateBridge` 的最小等价实现——只保留 V2 需要的字段。
    private func bridge(for message: RenderMessage) -> CellStateBridge {
        if let existing = bridges[message.id] { return existing }
        let bridge = CellStateBridge()
        bridge.onStop = actions.onStop
        bridge.onRetry = actions.onRetryLast
        bridge.onCompact = actions.onCompact.map { fn in { fn(message.id) } }
        bridge.onCopyScreenshot = actions.onCopyScreenshot
        bridge.onResume = actions.onResume
        bridge.onEdit = actions.onEdit.map { fn in { fn(message.id) } }
        bridge.onWithdraw = actions.onWithdraw.map { fn in { fn(message.id) } }
        bridge.onSendQueued = actions.onSendQueued.map { fn in { fn(message.id) } }
        bridges[message.id] = bridge
        return bridge
    }

    private func syncBridgeStates(messages: [RenderMessage]) {
        let lastAssistantID = messages.last(where: { $0.role == .assistant })?.id
        for message in messages {
            let b = bridge(for: message)
            let isTailAssistant = (message.id == lastAssistantID)
            b.isActiveMessage = vm.isProcessing && isTailAssistant
            b.isStreaming = vm.isProcessing && isTailAssistant
            b.canResume = vm.canResume && !vm.isProcessing && isTailAssistant
            b.autoRetryAttempt = vm.autoRetryAttempt
            b.autoRetryCountdown = vm.autoRetryCountdown
            b.browserPool = vm.browserTabPool
            b.toolSnapshots = vm.toolSnapshots
            b.commandStartTime = vm.commandStartTime
            b.onResume = b.canResume ? actions.onResume : nil
        }
    }

    // MARK: - 视口

    private func wireViewport() {
        viewport.attach(
            contentHeight: { [weak self] in self?.collectionView.contentSize.height ?? 0 },
            viewportHeight: { [weak self] in self?.collectionView.bounds.height ?? 0 },
            currentOffset: { [weak self] in self?.collectionView.contentOffset.y ?? 0 }
        )
        viewport.applyOffset = { [weak self] y, animated in
            guard let cv = self?.collectionView else { return }
            AppLogger.shared.info(
                "[V2] writeOffset \(String(format: "%.0f", cv.contentOffset.y))→\(String(format: "%.0f", y)) animated=\(animated)",
                category: "BottomPad")
            cv.setContentOffset(CGPoint(x: 0, y: y), animated: animated)
        }
        viewport.applyBottomInset = { [weak self] inset in
            self?.collectionView.contentInset.bottom = inset
        }
        viewport.handle(.obscuredBottomChanged(delta: obscuredBottom))
    }

    private func observeKeyboard() {
        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                  let window = self.view.window else { return }
            let overlap = max(0, window.bounds.maxY - window.convert(frame, from: nil).minY)
            let before = self.obscuredBottom
            self.keyboardHeight = overlap
            let after = self.obscuredBottom
            if abs(after - before) > 0.5 {
                AppLogger.shared.info(
                    "[V2] keyboard overlap=\(String(format: "%.0f", overlap)) obscured \(String(format: "%.0f", before))→\(String(format: "%.0f", after))",
                    category: "BottomPad")
                self.viewport.handle(.obscuredBottomChanged(delta: after - before))
            }
        }
    }

    private func isNearBottom(_ tolerance: CGFloat = 40) -> Bool {
        let maxOff = collectionView.contentSize.height - collectionView.bounds.height
            + collectionView.contentInset.bottom
        return maxOff - collectionView.contentOffset.y <= tolerance
    }
}

// MARK: - CollectionView 代理

extension ChatV2ListViewController: UICollectionViewDelegate {
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { viewport.handle(.userScrollEnded(atBottom: isNearBottom())) }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        viewport.handle(.userScrollEnded(atBottom: isNearBottom()))
    }
}

// MARK: - Cell

/// 一个 cell 承载所有行类型；内部用 SwiftUI hosting 复用现有视图。
final class ChatV2Cell: UICollectionViewCell {
    static let reuseID = "ChatV2Cell"

    func configure(row: ChatRow, vm: MessageListModel, bridge: CellStateBridge, width: CGFloat) {
        let content = ChatV2RowContent(row: row, vm: vm, bridge: bridge, cellWidth: width)
        contentConfiguration = UIHostingConfiguration {
            content
        }
        .margins(.all, 0)
        .minSize(width: 0, height: 0)
    }
}

/// 行内容 → 复用现有 SwiftUI 视图。
private struct ChatV2RowContent: View {
    let row: ChatRow
    @ObservedObject var vm: MessageListModel
    @ObservedObject var bridge: CellStateBridge
    let cellWidth: CGFloat

    var body: some View {
        switch row.kind {
        case .userBubble, .divider, .systemInfo:
            BridgedWholeMessage(message: row.message, bridge: bridge, maxWidth: 0)
                .environmentObject(vm)
        case .assistantHeader:
            ChatV2HeaderRow(message: row.message)
        case .text, .thinking, .tool, .question:
            if let block = row.block {
                BridgedAssistantBlock(block: block,
                                      message: row.message,
                                      bridge: bridge,
                                      maxWidth: 0,
                                      cellWidth: cellWidth)
                    .environmentObject(vm)
            } else {
                EmptyView()
            }
        case .footer:
            BridgedAssistantFooter(message: row.message, bridge: bridge, maxWidth: 0)
                .frame(height: ChatV2Metrics.footerHeight, alignment: .top)
                .environmentObject(vm)
        case .bottomSpacer:
            Color.clear.frame(height: 1)
        }
    }
}

/// 与旧页一致的「✨ MiniClaw」标题行（旧实现是 private，这里独立一份，样式对齐）。
private struct ChatV2HeaderRow: View {
    @ObservedObject var message: RenderMessage
    @State private var soulMeta: SoulMetadata = SoulStore.cachedMetadata
    var body: some View {
        HStack(spacing: 6) {
            Text("✨").font(.system(size: 18))
            Text(soulMeta.name.isEmpty ? "MiniClaw" : soulMeta.name)
                .font(.body.weight(.semibold))
                .foregroundStyle(ChatColors.primaryText)
            Spacer(minLength: 0)
        }
        .legibleTextShadow()
        .frame(height: ChatV2Metrics.headerHeight, alignment: .leading)
        .padding(.horizontal, ChatV2Metrics.horizontalInset)
        .opacity(message.isCompactedHistory ? 0.5 : 1.0)
        .accessibilityIdentifier("assistantHeader")
    }
}


// MARK: - SwiftUI 宿主

/// ChatView 里包一层；V2 的入口。
struct ChatV2ListHost: UIViewControllerRepresentable {
    @ObservedObject var vm: MessageListModel
    var actions: ChatV2Actions
    /// 输入区（含浮动栏）实际占据的高度；键盘由 VC 自己观察，不在此列。
    var composerHeight: CGFloat

    func makeUIViewController(context: Context) -> ChatV2ListViewController {
        ChatV2ListViewController(vm: vm, actions: actions)
    }

    func updateUIViewController(_ vc: ChatV2ListViewController, context: Context) {
        vc.updateComposerHeight(composerHeight)
        vc.apply(messages: vm.messages)
    }
}
