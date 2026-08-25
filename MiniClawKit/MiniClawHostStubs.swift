import SwiftUI
import UIKit
import Combine
import WebKit
import AVFoundation
import AVKit

// ============================================================
// 移植组件宿主设施适配桩(MiniClaw 2026-08-09)
// 移植组件依赖的宿主类型在此提供最小可用实现;
// 各桩按需扩展,业务接入见对应 TODO。
// ============================================================

// MARK: - 日志(移植模块自包含;与宿主 App 的 AppLogger 同名不同模块,互不干扰)
@MainActor
final class VoiceOutputPlayer {
    static let shared = VoiceOutputPlayer()
    static let manualOwnerId = UUID(uuidString: "00000000-0000-0000-0000-00000000FFFF")!
    // 2026-08-12 治本:朗读从空桩改为真实 TTS(AVSpeechSynthesizer,系统语音,
    // 与 iOS 文件 App 朗读同一引擎)。
    private let synthesizer = AVSpeechSynthesizer()
    func stopAll() {
        synthesizer.stopSpeaking(at: .immediate)
    }
    func enqueueSegmented(_ text: String, sessionId: UUID) {
        speak(text)
    }
    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first ?? "zh-CN")
        synthesizer.speak(utterance)
    }
}

struct AppLogger {
    let category: String
    init(category: String) { self.category = category }

    /// 高频诊断类别降噪（2026-08-13 用户要求）：这些类别的 info/debug 日志
    /// 不再 print 也不落盘（每次消息渲染 / 滚动采样 / 键盘变化都刷屏）。
    /// WARN/ERROR 永远保留；排查需要时把对应类别移出此集合即可恢复。
    private static let quietCategories: Set<String> = [
        "SnapshotDiag", "ScrollDiag", "ScrollStall", "ScrollDecel", "PendingSnap",
        "Settle", "SettleJitter", "FGLayout", "KbdDiag", "CellSizing",
        "StreamDiag", "ThinkingCollapse", "AttachHotPath", "AttachBoundsHot",
        "MarkdownRenderer", "ThinkPerf", "WatchdogProbe"
    ]
    /// 按实际生效类别判断是否降噪（info/debug 的 category 参数可覆盖实例类别）。
    private func isQuiet(_ category: String?) -> Bool {
        Self.quietCategories.contains(category ?? self.category)
    }

    /// 写日志文件(与主工程 AppLogger 同目录:Documents/MiniClaw/logs/MiniClaw-YYYY-MM-DD.log)。
    /// 2026-08-11 之前桩只 print 不进文件,导致 MiniClawKit 全链路日志(StreamDiag/
    /// ScrollDiag/KbdDiag)从未落盘,排查只能靠猜;补写文件后与主工程日志统一拉取。
    private func persist(_ level: String,_ message: String,_ category: String?) {
        let cat = category ?? self.category
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory,in: .userDomainMask).first else { return }
        let dir = docs.appendingPathComponent("MiniClaw/logs",isDirectory: true)
        try? fm.createDirectory(at: dir,withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let file = dir.appendingPathComponent("MiniClaw-\(df.string(from: Date())).log")
        let ts = DateFormatter()
        ts.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(ts.string(from: Date()))] MiniClaw[\(ProcessInfo.processInfo.processIdentifier)] [MiniClaw][\(level)][\(cat)] \(message)\n"
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8) ?? Data())
            try? h.close()
        } else {
            try? line.data(using: .utf8)?.write(to: file)
        }
    }
    func debug(_ message: String,category: String? = nil,subsystem: String? = nil) {
        guard !isQuiet(category) else { return }
        print("[MiniClaw][DEBUG][\(category ?? self.category)] \(message)")
        persist("DEBUG",message,category)
    }
    func info(_ message: String,category: String? = nil,subsystem: String? = nil) {
        guard !isQuiet(category) else { return }
        print("[MiniClaw][\(category ?? self.category)] \(message)")
        persist("INFO",message,category)
    }
    func warning(_ message: String,category: String? = nil,subsystem: String? = nil) {
        print("[MiniClaw][WARN][\(category ?? self.category)] \(message)")
        persist("WARN",message,category)
    }
    func error(_ message: String,category: String? = nil,subsystem: String? = nil) {
        print("[MiniClaw][ERROR][\(category ?? self.category)] \(message)")
        persist("ERROR",message,category)
    }
}

public struct MiniClawLinkPreviewView: View {
    let url: URL
    var browserPool: MiniClawTabPool?
    public init(url: URL,browserPool: MiniClawTabPool? = nil) {
        self.url = url
        self.browserPool = browserPool
    }
    public var body: some View {
        Text(url.absoluteString).font(.caption).foregroundStyle(.secondary)
    }
}

/// 终端视图(桩;接入 MiniClaw 终端时替换)
public final class SystemResourceMonitor: ObservableObject {
    var formattedCPU: String { "0%" }
    func formattedMem(compact: Bool = false) -> String { "0 MB" }
    func start() {}
    func stop() {}
}

/// 后台保活(桩)
public final class BackgroundKeepAliveManager: ObservableObject {
    static let shared = BackgroundKeepAliveManager()
    @Published var enhancedBackgroundEffective = false
}

// MARK: - 通知名补(原 SoulStore 通知)
public enum RawMessage {
    static func isInternalBridgeText(_ text: String) -> Bool { false }
}

/// 工具快照(原 ChatStore.ToolSnapshot)
struct AssistantSoulName: View {
    var body: some View { Text("MiniClaw") }
}



// MARK: - 深链协调桩(接入 MiniClaw 深链时替换)
@discardableResult
func noff_try_objc(_ body: () throws -> Void) -> Bool {
    do { try body(); return true } catch { return false }
}

// MARK: - 三件套依赖桩(2026-08-09 第三批)

/// 思考强度档位
struct MiniClawAudioPreviewView: View {
    let fileURL: URL
    var body: some View {
        HStack {
            Image(systemName: "speaker.wave.2")
            Text("Audio")
        }
    }
}

extension Notification.Name {
    static let soulMdChanged = Notification.Name("soulMdChanged")
    static let dismissAllImmersivePresentations = Notification.Name("dismissAllImmersivePresentations")
}

// MARK: - 会话活动追踪桩
struct ImagePreviewView: View {
    let image: UIImage
    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
    }
}

@MainActor
final class GlobalAudioPlayer: ObservableObject {
    static let shared = GlobalAudioPlayer()
    @Published var isPlaying = false
    @Published var activeFileURL: URL?
    func isActive(url: URL) -> Bool { activeFileURL == url }
    func togglePlayPause() {}
    func play(url: URL) { activeFileURL = url; isPlaying = true }
    func seek(to time: TimeInterval) {}
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
}

/// 媒体文件引用(原版 ChatStore.MediaRef)
public struct MediaRef: Codable,Hashable {
    public let id: String
    public let relativePath: String
    public let mimeType: String
    public let originalFileName: String?
    public let linuxPath: String?
}

public struct ToolSnapshot: Codable,Hashable {
    enum SnapshotType: String,Codable,Hashable { case text,image }
    let type: SnapshotType
    let text: String?
    let mediaRef: MediaRef?
    let duration: TimeInterval?
}

/// 媒体文件引用(原 ChatStore.MediaRef)
final class MiniClawOpenURLBroker: ObservableObject {
    static let shared = MiniClawOpenURLBroker()
    @Published var pendingURL: URL?
    var toolSheetVisible = false
    var toolSheetOpenURL: URL?
    func open(_ url: URL) {}
    func openInToolSheet(_ url: URL) { pendingURL = url }
    func consume() { pendingURL = nil }
    static func isWebScheme(_ scheme: String?) -> Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "about"
    }
}

/// 缩放大图查看器(桩)
public final class DeepLinkCoordinator: ObservableObject {
    static let shared = DeepLinkCoordinator()
    var pendingFilePath: URL?
    func setFocus(rawQueryValue: String) {}
    var pendingSettingsTarget: SettingsTarget?
    enum SettingsTarget {
        case background
        case providers
    }
}

public struct LLMUsage: Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationInputTokens: Int?
    let cacheReadInputTokens: Int?
}

// MARK: - 浏览器标签池桩(接入 MiniClaw BrowserController 时替换)
/// 浏览器管理器(桩;接入 MiniClaw BrowserController 时替换)
struct QueuedAttachmentPreview: View {
    let attachments: [InputAttachment]
    var body: some View { EmptyView() }
}

/// markdown 链接处理器(桩)
public struct LoggingManager {
    static let shared = LoggingManager()
    init() {}
    func writeRawLine(_ line: String) {
        print("[MiniClaw][RAW] \(line)")
    }
    func writeRawLine(category: String,level: String,message: String) {
        print("[MiniClaw][\(category):\(level)] \(message)")
    }
    func flush() {}
}

// MARK: - 语音输出桩(TTS;当前 no-op,接入 MiniClaw TTS 时替换)
public enum ChatColors {
    static let background = Color(UIColor.systemBackground)
    static let secondaryBg = Color(UIColor.secondarySystemBackground)
    static let inputIconBg = Color(UIColor.secondarySystemBackground)
    static let inputIconBorder = Color(UIColor.separator)
    static let inputBg = Color(UIColor.systemBackground)
    static let inputBorder = Color(UIColor.separator)
    static let primaryText = Color(UIColor.label)
    static let secondaryText = Color(UIColor.secondaryLabel)
    static let tertiaryText = Color(UIColor.tertiaryLabel)
    static let userBubble = Color(UIColor.tertiarySystemFill)
    static let toolBg = Color(UIColor.tertiarySystemGroupedBackground)
    static let toolBorder = Color(UIColor.separator).opacity(0.5)
    static let accent = Color(UIColor.label)
    static let sendButton = Color(UIColor.label)
    static let sendButtonDisabled = Color(UIColor.quaternaryLabel)
}

/// 链接打开代理(桩:内部链接走系统)
public final class SessionActivityTracker: ObservableObject {
    static let shared = SessionActivityTracker()
    func isActive(_ sessionId: String) -> Bool { false }
    func recordEvent(_ name: String) {}
}

// MARK: - 环境键(原 ChatSessionIdEnvironment)
private struct ChatSessionIdKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    var chatSessionId: UUID? {
        get { self[ChatSessionIdKey.self] }
        set { self[ChatSessionIdKey.self] = newValue }
    }
}

// MARK: - 三件套依赖桩(2026-08-09 第四批)

/// 调色板(原 AIChatView.ChatColors)
struct ISHTerminalView: View {
    var sessionId: UUID?
    var showCloseButton: Bool = false
    var initCommand: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "terminal")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Terminal")
                .font(.headline)
            if let initCommand, !initCommand.isEmpty {
                Text(initCommand)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.horizontal)
            }
            Text("Terminal is not available in this tool view yet. Use Settings > Terminal.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
            if showCloseButton {
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                .padding(.bottom, 16)
            }
        }
        .background(Color(.systemBackground))
    }
}

/// ObjC 异常捕获辅助(原移植 C 辅助;桩版用 Swift do-catch)
struct StreamingHangLogger {
    static let shared = StreamingHangLogger()
    init() {}
    func recordAssignedText(_ text: String,messageId: UUID?,blockId: UUID?,length: Int) {}
    func recordAssignedText(_ text: String,messageId: UUID?,blockId: UUID?,length: Int,isStreaming: Bool) {}
    func recordAssignedText(messageId: UUID?,blockId: UUID?,length: Int,isStreaming: Bool) {}
    func recordAssignedText(messageId: UUID?,markdown: String,attrLen: Int,path: String) {}
    func recordAssignedText(messageId: UUID?,markdown: String,attrLen: Int,path: String,isStreaming: Bool) {}
}

// MARK: - 媒体视图桩(占位;接入 MiniClaw 播放器/预览时替换)
enum MarkdownImageTapRouter {
    static let tappedNotification = Notification.Name("MarkdownImageTapRouterTapped")
    static func postTap(messageId: UUID?,sourceURL: String?) {
        NotificationCenter.default.post(name: tappedNotification,object: nil)
    }
}

// MARK: - VM 契约(AIChatViewModel 精简版,2026-08-10 重建)
// 列表组件消费的视图模型契约:宿主(MiniClawChatBridge)持有并驱动。
// 按参考实现 AIChatViewModel 的列表相关接口裁剪,依赖宿主设施
// (SQLite/语音/图片压缩)的部分不在此。

import Combine

@MainActor
public final class AIChatViewModel: ObservableObject {
    @Published public var messages: [ChatMessage] = []
    @Published public var isProcessing = false
    @Published public var canResume = false
    @Published public var isNearBottom = false
    @Published public var isLoadingSession = false
    @Published public var streamingUIUpdatesSuspended = false
    @Published public var autoRetryAttempt = 0
    @Published public var autoRetryCountdown = 0
    @Published public var isCompacting = false
    @Published public var isAtFirstTurn = true
    @Published public var toolSnapshots: [ToolSnapshotItem] = []
    @Published public var commandStartTime: Date?

    public let sessionId: String?
    public var browserTabPool: MiniClawTabPool?
    /// 2026-08-12:浏览器接管内容的宿主提供者(主工程注入 BrowserView)。
    /// 照原版机制——浏览器由 ToolLiveSheet 自己的二级 sheet 呈现(同视图树、
    /// 同 present 链,无跨层 present 竞争);Kit 不能引用主工程视图,故由宿主注入闭包。
    public var browserContentProvider: ((URL?) -> AnyView)?

    // 信号(列表组件订阅)
    public let scrollToBottomSignal = PassthroughSubject<Void,Never>()
    public let forceScrollToBottom = PassthroughSubject<Void,Never>()
    public let forceScrollToTop = PassthroughSubject<Void,Never>()
    public let contentOffsetYSignal = PassthroughSubject<CGFloat,Never>()
    public let contentSizeDeltaSignal = PassthroughSubject<CGFloat,Never>()
    public let blockContentFilledSignal = PassthroughSubject<(UUID,UUID),Never>()
    public let retrySnapshotReloadSignal = PassthroughSubject<Void,Never>()
    /// 流式 UI 挂起恢复回调(宿主注入;恢复时由列表组件调用)
    public var onStreamingUIUpdatesResumed: (() -> Void)?

    /// 会话页 onAppear 时间戳(布局诊断用,CFAbsoluteTime 基准)
    public static let onAppearTimestamp: TimeInterval = CFAbsoluteTimeGetCurrent()

    /// 自动重试延迟阶梯(秒,原版 AIChatViewModel+Fallback)
    public static let retryDelays = [3,5,10,15,30]

    public init(sessionId: String? = nil,browserTabPool: MiniClawTabPool? = nil) {
        self.sessionId = sessionId
        self.browserTabPool = browserTabPool
    }

    public func setStreamingUIUpdatesSuspended(_ suspended: Bool) {
        streamingUIUpdatesSuspended = suspended
        if !suspended {
            onStreamingUIUpdatesResumed?()
        }
    }

    public var isReadingAloud = false
    public var speechPaused = false

    public func syncSpeechStateToGlobal(registerActive: Bool) {
        VoiceOutputState.shared.activeController = registerActive ? self : nil
        VoiceOutputState.shared.isSpeaking = isReadingAloud && !speechPaused
    }

    public func appendToInputText(_ text: String) {}
    public func appendSystemInfo(_ text: String,icon: String) {}
    public func retryFromMessage(_ id: UUID) {}
    public func retryFromToolBlock(blockId: UUID) {}
    // 2026-08-12 治本:朗读菜单(Read Selection/Read from Start)从空桩改为真实 TTS。
    public func speakText(_ text: String?) {
        guard let text else { return }
        VoiceOutputPlayer.shared.speak(text)
    }
    public func readReplyFromStart(_ message: ChatMessage) {
        VoiceOutputPlayer.shared.speak(message.content)
    }
    public func invalidateAttributedStringCaches() {}
}

// MARK: - 路径/会话静态成员(宿主桥接:主工程 Documents/MiniClaw-Sessions)
extension AIChatViewModel {
    /// 当前活跃会话 id(宿主在 attach 时设置)
    nonisolated(unsafe) public static var activeSessionId: String?

    /// 会话持久化根:Documents/MiniClaw-Sessions(与主工程 SessionFileRouter 一致)
    nonisolated public static var miniClawPersistentBase: URL {
        let docs = FileManager.default.urls(for: .documentDirectory,in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("MiniClaw-Sessions", isDirectory: true)
    }

    /// 全局 skills 目录(Documents/MiniClaw/skills)
    nonisolated public static var miniClawSkillsPersistentDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory,in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("MiniClaw/skills", isDirectory: true)
    }

    /// 全局 memory 目录(Documents/MiniClaw/memory)
    nonisolated public static var miniClawMemoryPersistentDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory,in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("MiniClaw/memory", isDirectory: true)
    }
}

// MARK: - Soul/思考档契约(精简版,2026-08-10 重建)

/// 助手身份元数据(原 SoulStore.SoulMetadata,精简:仅列表需要的 name)
public struct SoulMetadata: Equatable {
    public var name: String
    public init(name: String) { self.name = name }
}

/// 助手身份存储(桩:读 MiniClaw 的 agentName;列表仅用 cachedMetadata.name)
public enum SoulStore {
    /// 缓存元数据(宿主在 MiniClawChatBridge.attach 时刷新)
    public static var cachedMetadata = SoulMetadata(name: "MiniClaw")
    public static let soulMdChanged = Notification.Name("SoulMetadataChanged")
}

/// 思考强度档位(原 LLMTypes.ThinkingLevel,列表仅用 off/isEnabled/比较)
public enum ThinkingLevel: String,Codable,Hashable,CaseIterable,Comparable {
    case off,low,medium,high,xhigh,max,ultra

    public static func<(lhs: ThinkingLevel,rhs: ThinkingLevel) -> Bool {
        allCases.firstIndex(of: lhs)!<allCases.firstIndex(of: rhs)!
    }

    public var isEnabled: Bool { self != .off }

    public var displayName: String {
        switch self {
        case .off: return String(localized: "Off")
        case .low: return String(localized: "Low")
        case .medium: return String(localized: "Med")
        case .high: return String(localized: "High")
        case .xhigh: return String(localized: "XHigh")
        case .max: return String(localized: "Max")
        case .ultra: return String(localized: "Ultra")
        }
    }
}

// MARK: - ToolLiveSheet 依赖补全(2026-08-10)

/// 图片缩放查看(原版 ImagePreview.ZoomableImageView,原样搬入)
public struct ZoomableImageView: View {
    let image: UIImage
    var cornerRadius: CGFloat = 10

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    public init(image: UIImage,cornerRadius: CGFloat = 10) {
        self.image = image
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        GeometryReader { geo in
            let aspect = image.size.height/max(image.size.width,1)
            let fittedHeight = geo.size.width*aspect

            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: geo.size.width)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .contextMenu {
                    Button { UIPasteboard.general.image = image } label: {
                        Label("Copy Image", systemImage: "doc.on.doc")
                    }
                }
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = max(1.0,lastScale*value)
                        }
                        .onEnded { value in
                            lastScale = scale
                            if scale<1.0 {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    scale = 1.0
                                    lastScale = 1.0
                                    offset = .zero
                                    lastOffset = .zero
                                }
                            }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            guard scale>1.0 else { return }
                            offset = CGSize(
                                width: lastOffset.width+value.translation.width,
                                height: lastOffset.height+value.translation.height
                            )
                        }
                        .onEnded { _ in
                            lastOffset = offset
                        }
                )
                .simultaneousGesture(
                    TapGesture(count: 2)
                        .onEnded {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                if scale>1.0 {
                                    scale = 1.0
                                    lastScale = 1.0
                                    offset = .zero
                                    lastOffset = .zero
                                } else {
                                    scale = 3.0
                                    lastScale = 3.0
                                }
                            }
                        }
                )
                .frame(width: geo.size.width,height: max(fittedHeight*scale,geo.size.height))
                .clipped()
        }
    }
}

/// iSH 根文件系统访问(桩:dataPath 与主工程 LinuxShellRuntime 部署路径一致,
/// Application Support/MiniClaw/ish-rootfs)
public final class RootfsManager {
    public static let shared = RootfsManager()
    public let dataPath: URL = {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory,in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return support.appendingPathComponent("MiniClaw/ish-rootfs", isDirectory: true)
    }()
    private init() {}
}


// MARK: - 图片/视频解析补充(2026-08-10,按原版语义桥接主工程路径)

/// miniclaw:// URL → 磁盘子路径候选(参考实现路径解码逻辑,原样搬入)
public enum MiniClawURLPathDecoding {
    /// Candidate subpaths for a miniclaw:// URL, in priority order.
    public static func subPathCandidates(for url: URL) -> [String] {
        let p = url.path
        let base = p.hasPrefix("/") ? String(p.dropFirst()) : p
        var candidates = [base]
        if let twice = base.removingPercentEncoding,twice != base {
            candidates.append(twice)
        }
        return candidates
    }
}

/// 媒体缓存指纹(简化版:miniclaw:// URL 解析到文件后取「绝对路径+修改时间」,
/// 非 miniclaw 协议返回原串)
public func miniClawMediaCacheKey(for source: String) -> String {
    guard let url = URL(string: source), url.scheme == "miniclaw" else { return source }
    let base = url.absoluteString
    guard let host = url.host else { return base }
    let subPaths = MiniClawURLPathDecoding.subPathCandidates(for: url)
    let dirs: [URL]
    switch host {
    case "memory": dirs = [AIChatViewModel.miniClawMemoryPersistentDir]
    case "skills": dirs = [AIChatViewModel.miniClawSkillsPersistentDir]
    default:
        if let sid = AIChatViewModel.activeSessionId {
            dirs = [AIChatViewModel.miniClawPersistentBase
                .appendingPathComponent(sid,isDirectory: true)
                .appendingPathComponent(host,isDirectory: true)]
        } else {
            dirs = []
        }
    }
    for dir in dirs {
        for sub in subPaths {
            let candidate = dir.appendingPathComponent(sub)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: candidate.path),
               let mod = attrs[.modificationDate] as? Date {
                return base + "|" + String(Int(mod.timeIntervalSince1970))
            }
        }
    }
    return base
}

/// 全屏视频播放器(简化版:AVPlayerViewController 包装;原版为自定义 pull-to-dismiss)
public struct MiniClawVideoFullscreenPlayer: UIViewControllerRepresentable {
    let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }

    public func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = AVPlayer(url: fileURL)
        vc.showsPlaybackControls = true
        return vc
    }

    public func updateUIViewController(_ vc: AVPlayerViewController,context: Context) {
        if vc.player?.currentItem?.asset as? AVURLAsset != AVURLAsset(url: fileURL) {
            vc.player = AVPlayer(url: fileURL)
        }
    }
}

// MARK: - 语音朗读状态(2026-08-10 重建,原版 VoiceOutputState 精简)

public struct VoiceOutputPreferences {
    public static var speedMultiplier: Double = 1.0
    public static var autoReadRepliesEnabled: Bool = false
}

public final class VoiceOutputState {
    nonisolated(unsafe) public static let shared = VoiceOutputState()
    public var isEnabled = false {
        didSet { VoiceOutputPreferences.autoReadRepliesEnabled = isEnabled }
    }
    public var isMuted = false
    public var isSpeaking = false
    public var activeController: Any?
    public init() {}
    public func syncState(reading: Bool,paused: Bool,speed: Double) {
        isSpeaking = reading
        isMuted = paused
    }
}

// MARK: - CompactSummarySheet(原版 AIChatView 组件,简化 SelectableTextView)
public struct CompactSummarySheet: View {
    let summary: String
    var onRevert: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var showRevertConfirm = false

    public init(summary: String,onRevert: (() -> Void)? = nil) {
        self.summary = summary
        self.onRevert = onRevert
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    Text(summary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity,alignment: .leading)
                        .padding(.horizontal,16)
                        .padding(.top,8)
                }
                if onRevert != nil {
                    Divider()
                    Button(role: .destructive) {
                        showRevertConfirm = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.uturn.backward")
                            Text("Revert Compact")
                        }
                        .font(.system(size: 15,weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical,14)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
            }
            .navigationTitle("Compact Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        UIPasteboard.general.string = summary
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now()+1.5) { copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc.fill")
                            .foregroundStyle(copied ? .green : .secondary)
                    }
                }
            }
            .alert("Revert this compact?", isPresented: $showRevertConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Revert", role: .destructive) {
                    let action = onRevert
                    dismiss()
                    action?()
                }
            } message: {
                Text("The summary will be discarded and the messages it covered will become active again.")
            }
        }
        .presentationDetents([.large])
    }
}

// MARK: - UserAttachmentList / MiniClawOpenURLHandler(2026-08-10,精简版)

/// miniclaw:// 链接打开桥(转发宿主:ChatView 监听 NotificationCenter)
/// http/https 按「链接打开策略」分流:内置浏览器(默认,post 通知)或外部 Safari(.systemAction)
public struct MiniClawOpenURLHandler: ViewModifier {
    /// 链接打开策略存储 key(主工程设置「链接在内置浏览器打开」共用,单一事实来源)
    public static let openLinksInlineKey = "miniClaw.openLinksInline"

    /// 链接打开策略:true = 内置浏览器(默认),false = 外部 Safari
    public static func openLinksInline() -> Bool {
        if UserDefaults.standard.object(forKey: openLinksInlineKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: openLinksInlineKey)
    }

    public init() {}
    public func body(content: Content) -> some View {
        content.environment(\.openURL, OpenURLAction { url in
            let scheme = url.scheme?.lowercased()
            if scheme == "miniclaw" {
                NotificationCenter.default.post(name: .miniClawOpenURLRequested, object: url)
                return .handled
            }
            // 2026-08-12 治本:miniclaw:// 文件型链接(浏览器/工作区等产物)归一为
            // miniclaw:// 进同一预览通道——此前无分支直接 .systemAction,点击文件链接无反应。
            if scheme == "miniclaw",
               let host = url.host,
               ImageAttachment.fileHosts.contains(host),
               let canonical = URL(string: ImageAttachment.canonicalizeMarkdownImageSource(url.absoluteString)) {
                NotificationCenter.default.post(name: .miniClawOpenURLRequested, object: canonical)
                return .handled
            }
            if scheme == "http" || scheme == "https" {
                if Self.openLinksInline() {
                    NotificationCenter.default.post(name: .miniClawOpenURLRequested, object: url)
                    return .handled
                }
            }
            return .systemAction
        })
    }
}

extension Notification.Name {
    /// 宿主(ChatView)监听:miniclaw:// 链接请求打开(预览/浏览器/深链)
    public static let miniClawOpenURLRequested = Notification.Name("MiniClawOpenURLRequested")
}

/// 用户消息附件列表(精简版:图片缩略图 + 文件图标,点击打开/分享)
public struct UserAttachmentList: View {
    let attachments: [AttachmentMeta]
    private let tileSize: CGFloat = 64

    public init(attachments: [AttachmentMeta]) {
        self.attachments = attachments
    }

    public var body: some View {
        // 2026-08-12 治本:adaptive 网格是 flexible/fill,从不收缩到内容宽,
        // tile 从 leading 排 → 附件落在行中间。改为固定列 + fixedSize 收缩到
        // 内容宽,再 frame 推到 VStack 右缘,附件真正贴右。
        // 2026-08-13:媒体(图片/视频/音频)走 64pt 固定列 grid;文档文件(📃+文件名)
        // 宽窄随文件名自适应,不能塞 64pt 列(会被压断/挤压),单独每行一条。
        let media = attachments.filter { $0.isImage || $0.isVideo || $0.isAudio }
        let files = attachments.filter { !$0.isImage && !$0.isVideo && !$0.isAudio }
        VStack(alignment: .trailing, spacing: 6) {
            if !media.isEmpty {
                let perRow = 4
                let columns = Array(repeating: GridItem(.fixed(tileSize), spacing: 6),
                                    count: max(1, min(media.count, perRow)))
                LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                    ForEach(media) { meta in
                        attachmentTile(meta, onTap: { open(meta) })
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            ForEach(files) { meta in
                attachmentTile(meta, onTap: { open(meta) })
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func open(_ meta: AttachmentMeta) {
        if let url = URL(string: meta.miniClawURL) {
            NotificationCenter.default.post(name: .miniClawOpenURLRequested, object: url)
        }
    }

    private func attachmentTile(_ meta: AttachmentMeta,onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            if meta.isImage {
                TileImage(urlString: meta.miniClawURL)
            } else if meta.isVideo || meta.isAudio {
                // 视频/音频保持不变:图标 tile(无文件名)。
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.12))
                    Image(systemName: meta.isVideo ? "film" : "music.note")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
                .frame(width: tileSize,height: tileSize)
            } else {
                // 非媒体文件(文档):与 AI 回复的文件块(FileBlockView)同形态——
                // 灰底圆角 + 图标 + 文件名,文件名撑满整行,超出的裁剪(不预截断)。
                HStack(spacing: 8) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                    Text(meta.fileName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .buttonStyle(.plain)
    }
}

/// 附件缩略图(本地 miniclaw:// 文件)
private struct TileImage: View {
    let urlString: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64,height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 64,height: 64)
            }
        }
        .task(id: miniClawMediaCacheKey(for: urlString)) {
            guard let url = URL(string: urlString),
                  let host = url.host else { return }
            let subPaths = MiniClawURLPathDecoding.subPathCandidates(for: url)
            let base: URL? = {
                if host == "memory" { return AIChatViewModel.miniClawMemoryPersistentDir }
                if host == "skills" { return AIChatViewModel.miniClawSkillsPersistentDir }
                guard let sid = AIChatViewModel.activeSessionId else { return nil }
                return AIChatViewModel.miniClawPersistentBase
                    .appendingPathComponent(sid,isDirectory: true)
                    .appendingPathComponent(host,isDirectory: true)
            }()
            guard let base else { return }
            for sub in subPaths {
                let candidate = base.appendingPathComponent(sub)
                if let data = try? Data(contentsOf: candidate),let img = UIImage(data: data) {
                    image = img
                    return
                }
            }
        }
    }
}

// MARK: - 浏览器引擎依赖补充(2026-08-10)

/// VM 缓存(原版 ChatLifecycleSupport.ViewModelCache 的轻量版:桥接场景
/// 由 MiniClawChatBridge 持有 VM,此处仅提供 get 接口)
public final class ViewModelCache {
    public static let shared = ViewModelCache()
    private var cache: [String: AIChatViewModel] = [:]
    public init() {}
    public func get(for sid: String) -> AIChatViewModel? { cache[sid] }
    public func set(_ vm: AIChatViewModel,for sid: String) { cache[sid] = vm }
}

extension AIChatViewModel {
    /// 会话 workspace 目录(原版 miniclawWorkspacePersistentDir)
    nonisolated public static func miniClawWorkspacePersistentDir(for sid: String) -> URL {
        miniClawPersistentBase
            .appendingPathComponent(sid,isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
    }

    /// miniclaw:// URL → 磁盘文件(参考实现 miniclaw:// 解析语义,桥接主工程路径)
    nonisolated public static func resolveMiniClawURL(_ url: URL) -> URL? {
        guard url.scheme == "miniclaw", let host = url.host else { return nil }
        let subPaths = MiniClawURLPathDecoding.subPathCandidates(for: url)
        let fm = FileManager.default
        if let sid = activeSessionId {
            for sub in subPaths {
                let c = miniClawPersistentBase
                    .appendingPathComponent(sid,isDirectory: true)
                    .appendingPathComponent(host,isDirectory: true)
                    .appendingPathComponent(sub)
                if fm.fileExists(atPath: c.path) { return c }
            }
        }
        let globals: [(String,URL)] = [
            ("skills", miniClawSkillsPersistentDir),
            ("memory", miniClawMemoryPersistentDir),
        ]
        for (name,dir) in globals where host == name {
            for sub in subPaths {
                let c = dir.appendingPathComponent(sub)
                if fm.fileExists(atPath: c.path) { return c }
            }
        }
        return nil
    }
}

// MARK: - 浏览器接管弹层(引擎照搬版:直接展示引擎 webView,原版 MiniClawEngineWebView 逻辑)

/// 引擎 webView 薄壳(原版 MiniClawEngineWebView)
public struct EngineBrowserWebView: UIViewRepresentable {
    let manager: MiniClawBrowserEngine
    public init(manager: MiniClawBrowserEngine) { self.manager = manager }
    public func makeUIView(context: Context) -> WKWebView { manager.webView }
    public func updateUIView(_ uiView: WKWebView,context: Context) {}
}

/// 浏览器接管 sheet(工具实时预览弹层内使用:标签切换 + 引擎 webView)
public struct BrowserSheetView: View {
    let pool: MiniClawTabPool?
    var isAgentBusy: Bool = false

    public init(pool: MiniClawTabPool?,isAgentBusy: Bool = false) {
        self.pool = pool
        self.isAgentBusy = isAgentBusy
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let manager = pool?.activeManager {
                EngineBrowserWebView(manager: manager)
                    .id(pool?.selectedTabId)
            } else {
                // iOS16 兼容:替代 ContentUnavailableView(iOS17 API)
                VStack(spacing: 10) {
                    Image(systemName: "globe")
                        .font(.system(size: 52, weight: .regular))
                        .foregroundStyle(.secondary)
                    Text("No Page")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let pool,!pool.tabs.isEmpty {
                Divider()
                ScrollView(.horizontal,showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pool.tabs) { tab in
                            Button {
                                pool.selectedTabId = tab.id
                            } label: {
                                Text(tab.manager.pageTitle.isEmpty ? "New Tab" : tab.manager.pageTitle)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .padding(.horizontal,10).padding(.vertical,6)
                                    .background(tab.id == pool.selectedTabId ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
            }
        }
    }
}
