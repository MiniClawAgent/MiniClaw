import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Speech
import AVFoundation

// MARK: - 待发送附件（输入栏内选中、发送前展示）

/// 输入框里已选中的附件：复制进 attachments/ 目录后的本地副本 + 展示信息。
struct InputAttachment: Identifiable, Equatable {
    let id: UUID
    /// 已复制到 FileSystemManager.attachmentsDir 内的本地 URL（发送后由消息引用，删除 chip 时一并清除副本）。
    let url: URL
    let fileName: String
    let kind: AttachmentKind
}

/// 附件类型，用于选择展示用的 SF 图标。
enum AttachmentKind: Equatable {
    case image, video, audio, document

    var icon: String {
        switch self {
        case .image:    return "photo"
        case .video:    return "film"
        case .audio:    return "music.note"
        case .document: return "doc"
        }
    }

    /// 由文件扩展名推断类型（图片/音频/视频见 FileSystemManager.attachmentExtensions）。
    static func from(ext: String) -> AttachmentKind {
        switch ext.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp":           return .image
        case "mp4", "mov", "m4v":                            return .video
        case "mp3", "m4a", "wav":                            return .audio
        default:                                            return .document
        }
    }
}

/// 三选项弹窗中实际拉起的系统选择器。
private enum AttachmentSource: Identifiable {
    case document, camera, photoVideo
    var id: String {
        switch self {
        case .document:   return "document"
        case .camera:     return "camera"
        case .photoVideo: return "photoVideo"
        }
    }
}

struct ChatInputBar: View {
    @Binding var isAgentResponding: Bool
    @Binding var isPaused: Bool
    /// 已选中的附件（由 ChatView 持有，发送时消费并清空）。
    @Binding var attachments: [InputAttachment]

    // ── 输入文本本地化（打字卡顿修复 2026-08-06）──
    // 击键只更新本组件的 @State draft，不再经由 ChatView 的 @State 触发
    // 整个会话视图树重算（消息多时每次击键 O(N) 的根因）。
    // 与外部同步走两条通道：
    //  · onDraftChanged：草稿变化防抖 300ms 上报（草稿落盘用）；
    //  · injectedText/injectionID：外部注入（斜杠命令插入/清空/草稿恢复）。
    @State private var draft: String = ""
    var injectedText: String = ""
    var injectionID: Int = 0
    var onDraftChanged: ((String) -> Void)? = nil
    @State private var draftSyncTask: Task<Void, Never>?

    var onSend: (String) -> Void
    var onPause: () -> Void
    var onResume: () -> Void
    /// 斜杠命令执行回调：ChatView 传入各命令的具体动作。
    var onSlashCommand: ((SlashCommandItem) -> Void)?
    /// 当前模型是否支持深度思考：决定「/thinking」命令是档位选择器还是禁用态。
    var thinkingSupported: Bool = false
    /// 「/thinking」命令当前选中的等级（nil=关闭，有值=开启到该档位）。
    var thinkingSelectedLevel: String? = nil
    /// 可用的思考强度档位列表。
    var thinkingLevels: [(id: String, label: String)] = []
    var focused: FocusState<Bool>.Binding

    /// 用于把权限不足的引导跳转到 App 内「权限与后台」设置页（该页的麦克风/语音识别开关能正常申请权限，
    /// 不会触发聊天输入栏手势上下文里的 ccserver 崩溃）。
    @Environment(AppState.self) private var appState

    @State private var showSourcePicker: Bool = false
    @State private var activeSource: AttachmentSource?

    // 语音模式：内嵌于输入框，长按空输入框进入。
    @StateObject private var speechVM = SpeechViewModel()
    @State private var isVoiceMode: Bool = false
    @State private var isPressingMic: Bool = false
    @State private var controller = SpeechController()

    // 彩虹流动描边：AngularGradient 环形渐变 + hueRotation 缓慢旋转（2026-08-10 按方案 a 恢复）。
    @State private var rainbowPhase: Angle = .zero

    // ★ 权限请求解耦标志 ★
    // DragGesture 手势回调只写标志位，不直接调任何 AVAudioSession/SFSpeechRecognizer API。
    // 实际权限请求由 .onChange(of:) 在 SwiftUI 视图更新周期中触发，
    // 保证在主 RunLoop 的"干净时刻"执行（不在手势/动画回调栈内）。
    // 这避免了 _dispatch_assert_queue_fail 崩溃（已由真机 .ips 5 次验证：
    //  手势回调内直接调 AVAudioSession API → AudioSession RootQueue 断言失败）。
    @State private var shouldRequestMicPermission: Bool = false

    // 语音面板：上滑打开 / 从顶部把手下滑关闭（非手指跟随式，避免拖拽实时改高度引发抖动）。

    var body: some View {
        // ── 外层容器：斜杠命令菜单(上) + 输入栏本体(下)，菜单是输入框的兄弟节点 ──
        VStack(alignment: .leading, spacing: 0) {
            // 斜杠命令菜单：条件渲染在输入框正上方，与输入框同级、不重叠。
            // 不加额外横向 padding → 与输入框等宽（同受外层 .horizontal,16 约束）；
            // 底部留 10pt 间距，让菜单浮在输入框上方而非紧贴。
            if slashMenuVisible {
                SlashCommandOverlay(filter: slashFilter, commands: allSlashCommands) { cmd in
                    selectSlashCommand(cmd)
                }
                .padding(.bottom, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: slashMenuVisible)
            }

            // ── 输入栏本体：附件预览 + 语音文字区(可选) + 操作行 ──
            // 发送按钮通过 overlay 绝对定位在容器右下角（不参与流式布局），
            // 这样无论上方 transcript area 如何展开，按钮在屏幕上的位置始终不变。
            VStack(alignment: .leading, spacing: 0) {
                // 附件预览：仅在非空时渲染，并在底部留 6pt 间距（原 VStack spacing 的等效替代）。
                // 注意：不能依赖统一 spacing，否则收起态高度为 0 的 voiceRegion 会被上下各加 6pt，
                // 把文字操作行整体下移、造成按钮与右下发送按钮错位。
                if !attachments.isEmpty {
                    attachmentsPreviewArea
                        .padding(.bottom, 6)
                }

                // 语音区域：把手 + 识别文字 + 操作行。上滑打开时整块出现、下滑关闭时整块收起，
                // 不做手指跟随式高度动画（避免拖拽实时改高度引发的抖动）。
                voiceRegion
                    .frame(maxHeight: isVoiceMode ? 190 : 0)
                    .clipped()
                    .opacity(isVoiceMode ? 1 : 0)
                    .allowsHitTesting(isVoiceMode)
                    .animation(.easeInOut(duration: 0.18), value: isVoiceMode)

                // 文字模式操作行：仅在非语音态显示（语音态由 voiceRegion 内的 voiceOperationRow 承担）
                if !isVoiceMode {
                    textOperationRow
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: isVoiceMode ? 0 : 53)
            // 磨砂玻璃背景(2026-08-11 恢复):悬浮态 + ultraThinMaterial 磨砂,
            // 聊天内容可透出模糊光晕;彩虹流动描边仍保留作边界。
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                // 仅在语音态显示发送按钮（语音面板会展开，按钮需固定在右下角）。
                // 常规文字态的发送按钮已移入 textOperationRow 的 HStack 内、随文本框垂直居中，
                // 不再此处绝对定位，避免切换「回车发送」导致文本框高度变化时按钮位置漂移。
                if isVoiceMode {
                    voiceSendButton
                        .padding(.trailing, 12)
                        .padding(.bottom, 12)
                }
            }
            // 彩虹流动描边：环形渐变绕圆角矩形旋转一圈，视觉上呈现「缓慢流动的彩虹线」。
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        AngularGradient(
                            gradient: Gradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .red]),
                            center: .center
                        ),
                        lineWidth: 1
                    )
                    .hueRotation(rainbowPhase)
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .onAppear {
                withAnimation(.linear(duration: 15).repeatForever(autoreverses: false)) {
                    rainbowPhase = .degrees(360)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .gesture(voiceOpenGesture)
        // ★ 权限请求解耦：手势只设标志，onChange 在视图更新周期中执行实际请求 ★
        .onChange(of: shouldRequestMicPermission) { _, newValue in
            if newValue {
                // 立即复位标志（避免重复触发）
                shouldRequestMicPermission = false
                performMicPermissionRequest()
            }
        }
        .alert(L10n.tr("需要权限"), isPresented: $speechVM.showPermissionAlert) {
            Button(L10n.tr("去设置")) {
                // 跳转到 App 内「权限与后台」页（该页的麦克风/语音识别开关可由 App 内正常申请权限，
                // 不会像聊天输入栏的手势上下文那样触发系统 TCC 回调崩溃）。
                appState.showSettings = true
                appState.settingsDeepLink = "permissions"
            }
            Button(L10n.tr("取消"), role: .cancel) {
                collapseVoiceToText()
            }
        } message: { Text(speechVM.permissionAlertMessage) }
        // 三选项弹窗：附件 / 拍照 / 图片或视频
        .confirmationDialog(L10n.tr("添加附件"), isPresented: $showSourcePicker, titleVisibility: .visible) {
            Button(L10n.tr("附件")) { activeSource = .document }
            Button(L10n.tr("拍照")) { activeSource = .camera }
            Button(L10n.tr("图片或视频")) { activeSource = .photoVideo }
            Button(L10n.tr("取消"), role: .cancel) { }
        }
        // 拉起对应的系统选择器
        .sheet(item: $activeSource) { source in
            switch source {
            case .document:
                DocumentPickerRepresentable(onPicked: addPickedURL)
            case .camera:
                ImagePickerRepresentable(
                    sourceType: .camera,
                    mediaTypes: [UTType.image.identifier],
                    onPicked: handleImagePicker
                )
            case .photoVideo:
                ImagePickerRepresentable(
                    sourceType: .photoLibrary,
                    mediaTypes: [UTType.image.identifier, UTType.movie.identifier],
                    onPicked: handleImagePicker
                )
            }
        }
        // 输入本地化配套：草稿防抖上报（300ms）、外部注入应用、离开时强制同步最新文本。
        .onChange(of: draft) { _, newValue in
            draftSyncTask?.cancel()
            draftSyncTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                onDraftChanged?(newValue)
            }
        }
        .onChange(of: injectionID) { _, _ in
            draftSyncTask?.cancel()
            draft = injectedText
            onDraftChanged?(injectedText)
        }
        .onDisappear {
            draftSyncTask?.cancel()
            onDraftChanged?(draft)
        }
    }

    /// 统一发送出口：取消防抖、把最新文本同步给外部（草稿落盘），清空本地输入，再回调发送。
    private func performSend() {
        draftSyncTask?.cancel()
        let text = draft
        draft = ""
        onDraftChanged?(text)
        onSend(text)
    }

    // MARK: - 斜杠命令菜单（浮于输入框上方）

    /// 最后一个 "/" 的触发位置:任意位置输入斜杠都展开指令界面,删除斜杠即关闭。
    /// 要求斜杠后无空格(出现空格视为已选定命令或普通文本,关闭菜单)。
    private var slashTriggerIndex: String.Index? {
        guard let idx = draft.lastIndex(of: "/") else { return nil }
        let after = draft[draft.index(after: idx)...]
        return after.contains(" ") ? nil : idx
    }

    /// 菜单是否可见:输入框任意位置存在 "/"(其后无空格)时自动显示。
    private var slashMenuVisible: Bool {
        slashTriggerIndex != nil
    }

    /// 由输入内容推导的过滤关键词:取最后一个 "/" 之后的文本
    /// ("/cle" → "cle","你好/cle" → "cle",匹配规则不变);无斜杠返回空串(显示全部)。
    private var slashFilter: String {
        guard let idx = slashTriggerIndex else { return "" }
        return String(draft[draft.index(after: idx)...]).lowercased()
    }

    /// 完整命令列表：内置命令在前，用户技能命令（/技能名，按调用次数降序）在后。
    /// 「/thinking」命令按当前模型能力动态生成：
    /// - 支持思考 → kind: .thinkingPicker（展示强度 pill 选择器）；
    /// - 不支持 → kind: .disabled。
    @MainActor
    private var allSlashCommands: [SlashCommandItem] {
        let thinkingCommand: SlashCommandItem
        if thinkingSupported {
            let levels = thinkingLevels.isEmpty
                ? [("low", L10n.tr("低")), ("medium", L10n.tr("中")), ("high", L10n.tr("高"))]
                : thinkingLevels
            thinkingCommand = SlashCommandItem(
                id: "thinking",
                icon: "wand.and.sparkles",
                title: "/thinking",
                subtitle: thinkingSelectedLevel == "off" ? L10n.tr("深度思考已关闭") : L10n.tr("深度思考已开启"),
                kind: .thinkingPicker(selectedLevel: thinkingSelectedLevel, levels: levels),
                thinkingLevel: nil  // 由 row 内 pill 点击设置
            )
        } else {
            thinkingCommand = SlashCommandItem(
                id: "thinking",
                icon: "wand.and.sparkles",
                title: "/thinking",
                subtitle: L10n.tr("当前模型不支持"),
                kind: .disabled(L10n.tr("当前模型不支持"))
            )
        }
        let base = SlashCommandOverlay.defaultCommands.map { $0.id == "thinking" ? thinkingCommand : $0 }
        return base + SkillManager.shared.skillSlashCommands()
    }

    /// 选中命令：转交 ChatView 执行，并收拾菜单与输入框残留。
    private func selectSlashCommand(_ cmd: SlashCommandItem) {
        onSlashCommand?(cmd)
        // 若菜单由输入 "/" 触发：insertText 类命令会由 ChatView 覆写输入框，
        // 其余动作/切换类需清掉遗留的 "/xxx" 文本，避免留在输入框里；
        // 只删除触发斜杠及其后内容，保留斜杠前的用户文本。
        if slashTriggerIndex != nil {
            switch cmd.kind {
            case .insertText, .skill:
                // insertText / skill 由 ChatView 覆写输入框（填入前缀或 "/技能名 "），无需清理
                break
            case .toggle, .disabled, .action, .thinkingPicker:
                // 动作/切换/禁用/思考档位选择：删掉 "/xxx" 残留，保留斜杠前文本
                if let idx = slashTriggerIndex {
                    draft = String(draft[..<idx])
                }
            }
        }
    }

    // MARK: - 附件预览（输入框上方）

    @ViewBuilder
    private var attachmentsPreviewArea: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments) { att in
                        if att.kind == .image {
                            // 图片附件：输入框内显示为正方形略缩图 + 圆角，右上角可删除
                            ZStack(alignment: .topTrailing) {
                                if let thumb = UIImage(contentsOfFile: att.url.path) {
                                    Image(uiImage: thumb)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 44, height: 44)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                } else {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(.secondarySystemBackground))
                                        .frame(width: 44, height: 44)
                                        .overlay(
                                            Image(systemName: "photo")
                                                .font(.system(size: 18))
                                                .foregroundStyle(.secondary)
                                        )
                                }
                                Button(action: { removeAttachment(att) }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.white)
                                        .background(Circle().fill(Color.black.opacity(0.55)))
                                }
                                .buttonStyle(.plain)
                                .padding(2)
                            }
                        } else {
                            // 非图片附件：图标 + 文件名 chip
                            HStack(spacing: 6) {
                                Image(systemName: att.kind.icon)
                                    .font(.system(size: 15))
                                    .foregroundStyle(Color.accentColor)
                                Text(att.fileName)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .frame(maxWidth: 140, alignment: .leading)
                                Button(action: { removeAttachment(att) }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.bar, in: Capsule())
                            .overlay(Capsule().stroke(.secondary.opacity(0.2), lineWidth: 0.5))
                        }
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - 附件选择处理

    /// 文档选择器回调：把选中的文件复制进 attachments/，再加入附件列表。
    private func addPickedURL(_ url: URL) {
        let dest = FileSystemManager.shared.attachmentsDir
            .appendingPathComponent("\(UUID().uuidString)_\(url.lastPathComponent)")
        do {
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            NSLog("[ChatInputBar] 复制附件失败: \(error.localizedDescription)")
            return
        }
        let kind = AttachmentKind.from(ext: dest.pathExtension)
        attachments.append(InputAttachment(id: UUID(), url: dest, fileName: url.lastPathComponent, kind: kind))
    }

    /// 相机/相册回调：图片给 UIImage、视频给临时 URL，统一收敛后落盘。
    private func handleImagePicker(_ url: URL?, _ image: UIImage?) {
        if let url {
            addPickedURL(url)
        } else if let image {
            addPickedImage(image)
        }
    }

    /// 把 UIImage 写成 JPEG 落进 attachments/。
    private func addPickedImage(_ image: UIImage) {
        let name = "photo_\(Int(Date().timeIntervalSince1970)).jpg"
        let dest = FileSystemManager.shared.attachmentsDir
            .appendingPathComponent("\(UUID().uuidString)_\(name)")
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        do {
            try data.write(to: dest)
        } catch {
            NSLog("[ChatInputBar] 写入照片附件失败: \(error.localizedDescription)")
            return
        }
        attachments.append(InputAttachment(id: UUID(), url: dest, fileName: name, kind: .image))
    }

    /// 删除某个附件：从列表移除并删掉本地副本（避免占用磁盘）。
    private func removeAttachment(_ item: InputAttachment) {
        attachments.removeAll { $0.id == item.id }
        try? FileManager.default.removeItem(at: item.url)
    }

    // MARK: - Placeholder

    private var textFieldPlaceholder: String {
        if isAgentResponding && !isPaused {
            return L10n.tr("智能体正在回复，可继续输入加入队列...")
        } else if isPaused {
            return L10n.tr("已暂停，输入消息点发送可加入队列...")
        } else {
            return L10n.tr("输入消息...")
        }
    }

    // MARK: - 辅助按钮

    /// 输入栏内标准辅助按钮（附件 / 指令）
    private func inputAccessoryButton(systemName: String, action: @escaping () -> Void) -> some View {
        // 开源参考实现对齐(2026-08-09):34×34 圆底 secondarySystemBackground + 0.5pt 描边
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(Color(.secondarySystemBackground), in: Circle())
                .overlay(
                    Circle().strokeBorder(
                        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.35, alpha: 1) : UIColor(white: 0, alpha: 0) }),
                        lineWidth: 0.5
                    )
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 主按钮（暂停 / 继续 / 发送）

    private var accent: Color {
        Color(red: 0.098, green: 0.549, blue: 0.996)
    }

    /// 主按钮动作：按「是否回复中 / 是否已暂停 / 输入框是否为空」分流。
    /// - 回复中 + 空 → 暂停（onPause）
    /// - 回复中 + 有内容 → 入队（onSend 内部 busy 分支）
    /// - 已暂停 + 空 → 继续（onResume）
    /// - 已暂停 + 有内容 → 入队（onSend 内部 busy 分支）
    /// - 空闲（空由 disabled 拦）→ 发送（onSend）
    private var primaryAction: () -> Void {
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // 暂停优先：软暂停时 isResponding 仍为 true（与 432 行同一并存语义），
        // 先判 isPaused 才能让「继续」可达（review 2026-08-09）
        if isPaused { return empty ? onResume : performSend }
        if isAgentResponding { return empty ? onPause : performSend }
        return performSend
    }

    private var primaryColor: Color {
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isPaused { return accent }
        if isAgentResponding { return empty ? Color(.systemGray2) : accent }
        return empty ? Color.gray.opacity(0.3) : accent
    }

    private var primaryDisabled: Bool {
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isAgentResponding || isPaused { return false }
        return empty
    }

    private var primaryButton: some View {
        Button(action: primaryAction) {
            if isPaused {
                // 暂停+空 = 继续(play);暂停+有内容 = 入队发送(arrow)——与 primaryAction 分流一致
                let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if !empty {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.green)
                        .frame(width: 34, height: 34)
                        .background(Color(.secondarySystemBackground), in: Circle())
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(primaryColor, in: Circle())
                }
            } else if isAgentResponding {
                // 回复中:空 → 黄色暂停;有内容可入队 → 绿色发送箭头
                let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if !empty {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.green)
                        .frame(width: 34, height: 34)
                        .background(Color(.secondarySystemBackground), in: Circle())
                } else {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.yellow)
                        .frame(width: 34, height: 34)
                        .background(Color(.secondarySystemBackground), in: Circle())
                }
            } else {
                // 空闲:有内容 → 绿色发送;空 → 灰禁用(不变)
                let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(empty ? Color(.quaternaryLabel) : Color.green)
                    .frame(width: 34, height: 34)
                    .background(Color(.secondarySystemBackground), in: Circle())
            }
        }
        .disabled(primaryDisabled)
        .buttonStyle(.plain)
    }

    // MARK: - 语音输入（内嵌于输入框）

    /// 进入语音模式：把文字输入框已输入内容无缝带入语音识别区，收起键盘、接线识别回调。
    private func enterVoiceMode() {
        let existing = draft
        speechVM.reset()
        speechVM.inVoiceMode = true
        setupController(prefix: existing)
        speechVM.recognizedText = existing
        speechVM.canSend = !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        isVoiceMode = true
        // 注意：进入语音面板【不】弹任何权限框。权限在用户【点击录制按钮】时再申请，
        // 且顺序为「先麦克风、后语音识别」（麦克风系统框不崩，见既往修复）。
    }

    /// 退出语音模式：把语音识别内容无缝带回文字输入框（不自动弹键盘），停止录音并复位。
    private func exitVoiceMode() {
        let text = speechVM.recognizedText
        controller.stop()
        draft = text
        speechVM.reset()
        speechVM.inVoiceMode = false
        isVoiceMode = false
    }

    /// 收起语音面板回到文字输入（离散式，无手指跟随动画）：
    /// 直接切回文字态（isVoiceMode=false），整块语音区随之淡出收起，无实时高度拖动。
    private func collapseVoiceToText() {
        exitVoiceMode()
    }

    /// 把识别文字回填输入框并发送，然后退出语音模式。
    private func commitVoice() {
        let text = speechVM.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        controller.stop()
        draft = text
        performSend()
        speechVM.reset()
        speechVM.inVoiceMode = false
        isVoiceMode = false
    }

    /// 接线识别回调到语音状态机。prefix 为进入语音时已存在的文字（来自文字输入框），
    /// 录音识别出的结果会拼接在 prefix 之后，实现「文字→语音→文字」无缝衔接。
    private func setupController(prefix: String = "") {
        let base = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        controller.onUpdate = { [weak speechVM] text, isFinal in
            Task { @MainActor in
                guard let vm = speechVM else { return }
                let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if base.isEmpty {
                    vm.recognizedText = text
                } else if spoken.isEmpty {
                    vm.recognizedText = base
                } else {
                    vm.recognizedText = base + " " + spoken
                }
                if isFinal {
                    vm.canSend = !vm.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if !spoken.isEmpty {
                        vm.statusMessage = L10n.tr("识别完成，点「发送」发送")
                    }
                }
            }
        }
        controller.onError = { [weak speechVM] msg in
            Task { @MainActor in
                guard let vm = speechVM else { return }
                vm.statusMessage = msg
                vm.isRecording = false
            }
        }
        controller.onStateChanged = { [weak speechVM] recording in
            Task { @MainActor in
                guard let vm = speechVM else { return }
                vm.isRecording = recording
                if recording {
                    vm.statusMessage = L10n.tr("正在聆听…松开结束")
                } else if vm.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    vm.statusMessage = L10n.tr("按住麦克风开始说话")
                }
            }
        }
    }

    /// 语音模式顶部下拉把手（纯视觉）。下拉关闭手势由 voiceCloseGesture 挂在外层 voiceRegion 的把手上，
    /// 仅此顶部区域可触发，与底部麦克风长按、识别文字区滚动互不干扰。
    private var voiceDragHandle: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.3))
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
    }

    /// 语音面板整体：顶部把手 + 识别文字区 + 操作行。
    /// 上滑打开时整块出现、下滑关闭时整块收起（离散式，无手指跟随高度动画，避免拖拽抖动）。
    private var voiceRegion: some View {
        VStack(spacing: 6) {
            voiceDragHandle
                .gesture(voiceCloseGesture)
            voiceTranscriptArea
            voiceOperationRow
        }
    }

    /// 语音模式操作行：ZStack 布局——麦克风真正居中，键盘切换 + 发送占位贴右下（与 overlay 发送按钮对齐）。
    private var voiceOperationRow: some View {
        ZStack(alignment: .center) {
            HStack(alignment: .bottom, spacing: 6) {
                Spacer(minLength: 0)
                Button(action: {
                    collapseVoiceToText()
                }) {
                    Circle()
                        .fill(Color.secondary.opacity(0.12))
                        .frame(width: 34, height: 34)
                        .overlay {
                            Image(systemName: "keyboard")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.primary)
                        }
                }
                .buttonStyle(.plain)
                .offset(x: -4, y: 7)
                // 透明占位符：为 overlay 的发送按钮腾出空间
                Color.clear.frame(width: 34, height: 34)
            }
            // 麦克风：置于 ZStack 正中央
            voiceMicButton
        }
    }

    /// 文字模式操作行：.center 对齐，按钮垂直居中。
    private var textOperationRow: some View {
        HStack(alignment: .center, spacing: 6) {
            // 附件（点击弹三选项）
            inputAccessoryButton(systemName: "plus") {
                showSourcePicker = true
            }

            // 文本输入
            TextField(textFieldPlaceholder, text: $draft,
                      axis: SettingsStore.shared.settings.chat.enterToSend ? .horizontal : .vertical)
                .focused(focused)
                .lineLimit(SettingsStore.shared.settings.chat.enterToSend ? 1 : 6)
                .submitLabel(SettingsStore.shared.settings.chat.enterToSend ? .send : .return)
                .onSubmit {
                    // 「回车发送」开启：软键盘 / 外接键盘的 return 键即发送；
                    // 关闭：return 插入换行（由发送按钮发送）。.onKeyPress 仅响应外接键盘，
                    // 对 iPhone 软键盘无效，故改用 onSubmit 以覆盖主输入场景。
                    if SettingsStore.shared.settings.chat.enterToSend { performSend() }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 20)
                        .onEnded { value in
                            // 下滑 → 收起键盘（输入框内任意位置下滑）
                            if value.translation.height > 30 {
                                focused.wrappedValue = false
                            }
                        }
                )

            // 清除
            if !draft.isEmpty {
                Button(action: { draft = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // 发送按钮：常规文字态置于操作行内、与文本框垂直居中，
            // 不再用 overlay 绝对定位，避免「回车发送」开关切换 axis 导致文本框高度变化时按钮相对位置漂移。
            primaryButton
        }
    }

    /// 上滑展开手势：挂在外层容器，仅在非语音态响应。
    /// 离散式——只看松手时的净位移：上滑超过 30pt 即打开语音面板，不做手指跟随高度动画（避免拖拽抖动）。
    private var voiceOpenGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onEnded { value in
                guard !isVoiceMode, value.translation.height < -30 else { return }
                enterVoiceMode()
            }
    }

    /// 下拉收起手势：挂在顶部把手上，仅在语音态响应。
    /// 离散式——只看松手时的净位移：下滑超过 30pt 即收起语音面板回到文字输入。
    private var voiceCloseGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onEnded { value in
                guard isVoiceMode, value.translation.height > 30 else { return }
                collapseVoiceToText()
            }
    }

    /// 识别文字区：语音模式下在输入框上方展开，实时显示转写结果。
    private var voiceTranscriptArea: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(speechVM.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !speechVM.recognizedText.isEmpty {
                    Button(action: { speechVM.reset() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            ScrollView {
                Text(speechVM.recognizedText.isEmpty ? L10n.tr("识别出的文字会显示在这里") : speechVM.recognizedText)
                    .font(.body)
                    .foregroundStyle(speechVM.recognizedText.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 48, maxHeight: 110)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 麦克风按钮：长按开始录音，松手结束（嵌入输入框内，居中、加大）。
    private var voiceMicButton: some View {
        ZStack {
            Circle()
                .fill(speechVM.isRecording ? Color.red.opacity(0.15) : Color.accentColor.opacity(0.12))
                .frame(width: 56, height: 56)
            Image(systemName: speechVM.isRecording ? "waveform" : "mic.fill")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(speechVM.isRecording ? .red : Color.accentColor)
        }
        .contentShape(Circle())
        .scaleEffect(isPressingMic ? 1.08 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isPressingMic)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressingMic {
                        isPressingMic = true
                        AppLogger.shared.info("麦克风按下 → 设标志位 shouldRequestMicPermission=true（不直接调 API）", category: "Voice", subsystem: "Permission")
                        // ★ 只写标志位，不调用任何 AVAudioSession / SFSpeechRecognizer API ★
                        // 实际权限请求由 .onChange(of: shouldRequestMicPermission) 在视图更新周期中触发
                        shouldRequestMicPermission = true
                    }
                }
                .onEnded { _ in
                    isPressingMic = false
                    AppLogger.shared.info("麦克风松开 → controller.isRecording=\(controller.isRecording)，需停则停", category: "Voice", subsystem: "Recording")
                    // 仅当确实在录音时才停止；用户拒绝授权时 start() 从未执行，
                    // 直接 stop() 会去移除并不存在的 audio tap，可能触发 AVAudioEngine 崩溃。
                    if controller.isRecording {
                        controller.stop()
                    }
                }
        )
    }

    /// 发送按钮：有识别文字时可用，点击回填并发送。
    private var voiceSendButton: some View {
        Button(action: commitVoice) {
            Circle()
                .fill(speechVM.canSend ? accent : Color.gray.opacity(0.3))
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                }
        }
        .disabled(!speechVM.canSend)
        .buttonStyle(.plain)
    }

    // MARK: - 语音权限与录制

    /// 权限请求入口（由 .onChange(of: shouldRequestMicPermission) 在视图更新周期中调用）。
    ///
    /// ★ 核心策略：双重 DispatchQueue.main.async 延迟 ★
    /// 第一层 async：离开当前 SwiftUI 视图更新上下文（body/onChange 回调栈）。
    /// 第二层 async：到达主 RunLoop 的下一次迭代顶层（不在任何嵌套 dispatch 内）。
    /// 这确保 AVAudioSession API 在最"干净"的主队列状态下执行，
    /// 避免手势回调栈 / 动画回调栈 / 视图更新栈导致的
    /// _dispatch_assert_queue_fail 崩溃（已由真机 .ips 5 次验证）。
    private func performMicPermissionRequest() {
        AppLogger.shared.info("performMicPermissionRequest → 双重延迟派发", category: "Voice", subsystem: "Permission")
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                self.requestMicThenStart(controller: self.controller, vm: self.speechVM)
            }
        }
    }

    @available(*, unavailable, renamed: "performMicPermissionRequest")
    private func beginRecordingIfAuthorized() { fatalError("use performMicPermissionRequest") }

    /// 用户点击录制按钮：检查权限状态后启动录音。
    ///
    /// ★ 权限申请不在本视图内发起 ★
    /// 聊天输入栏的手势/动画上下文里调用 requestRecordPermission 会触发
    /// com.apple.ccserver 队列的 _dispatch_assert_queue_fail 崩溃（真机 6 次验证）。
    /// 因此本方法只【检查】状态：已授权则直接录音；未授权/未决定则弹引导框，
    /// 引导用户前往 App 内「设置 → 权限与后台」，在那里的麦克风/语音识别开关上
    /// 由 App 内常规 Button 上下文正常申请权限（该页开关已验证不崩）。
    private func requestMicThenStart(controller: SpeechController, vm: SpeechViewModel) {
        // ── 第一步：检查麦克风权限（不请求，只查）──
        let micStatus = AVAudioApplication.shared.recordPermission
        AppLogger.shared.info("麦克风权限状态：\(micStatus.rawValue)", category: "Voice", subsystem: "Permission")

        let proceedToSpeech: () -> Void = {
            DispatchQueue.main.async {
                let speechStatus = SFSpeechRecognizer.authorizationStatus()
                if speechStatus == .authorized {
                    AppLogger.shared.info("语音识别已授权 → startRecordingOnMainQueue", category: "Voice", subsystem: "Permission")
                    self.startRecordingOnMainQueue(controller)
                } else {
                    AppLogger.shared.info("语音识别未授权（\(speechStatus)）→ 弹引导框", category: "Voice", subsystem: "Permission")
                    vm.permissionAlertMessage = L10n.tr("MiniClaw 需要「语音识别」权限才能把你说的话转成文字。\n\n请点击下方「去设置」，在 App 设置 → 权限与后台 → 语音识别 中开启开关，返回即可使用。")
                    vm.showPermissionAlert = true
                }
            }
        }

        switch micStatus {
        case .granted:
            proceedToSpeech()
        case .denied:
            AppLogger.shared.info("麦克风被拒绝 → 弹提示", category: "Voice", subsystem: "Permission")
            vm.permissionAlertMessage = L10n.tr("MiniClaw 被拒绝使用麦克风。\n\n请点击下方「去设置」，在 App 设置 → 权限与后台 → 麦克风 中开启开关，返回即可使用。")
            vm.showPermissionAlert = true
        case .undetermined:
            // 未决定：引导用户去 App 内「权限与后台」页点麦克风开关申请（那里能正常弹系统授权框）。
            AppLogger.shared.info("麦克风权限未决定 → 弹引导框（去 App 内权限与后台）", category: "Voice", subsystem: "Permission")
            vm.permissionAlertMessage = L10n.tr("MiniClaw 需要使用麦克风进行语音输入。\n\n请点击下方「去设置」，在 App 设置 → 权限与后台 → 麦克风 中开启开关，返回即可使用。")
            vm.showPermissionAlert = true
        @unknown default:
            vm.permissionAlertMessage = L10n.tr("无法确定麦克风权限状态，请前往 App 设置 → 权限与后台 查看。")
            vm.showPermissionAlert = true
        }
    }

    /// 第三步：权限均已获取，在 GCD 主队列上启动录音引擎。
    /// SpeechController.start() 内部会访问 AVAudioSession（setCategory/setActive），
    /// 同样必须在 GCD 主队列上执行。
    private func startRecordingOnMainQueue(_ controller: SpeechController) {
        DispatchQueue.main.async {
            controller.start()
        }
    }
}

// MARK: - 文档选择器（附件选项）

struct DocumentPickerRepresentable: UIViewControllerRepresentable {
    var onPicked: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // asCopy: true 自动产出沙盒内可访问的副本，避免 security-scoped 资源释放问题。
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        vc.delegate = context.coordinator
        vc.allowsMultipleSelection = true
        return vc
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) { }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPicked: (URL) -> Void
        init(onPicked: @escaping (URL) -> Void) { self.onPicked = onPicked }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            urls.forEach { onPicked($0) }
        }
    }
}

// MARK: - 相机 / 相册选择器（拍照、图片或视频）

struct ImagePickerRepresentable: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let mediaTypes: [String]
    var onPicked: (URL?, UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let vc = UIImagePickerController()
        vc.sourceType = sourceType
        vc.mediaTypes = mediaTypes
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) { }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPicked: (URL?, UIImage?) -> Void
        init(onPicked: @escaping (URL?, UIImage?) -> Void) { self.onPicked = onPicked }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            defer { picker.dismiss(animated: true) }
            if (info[.mediaType] as? String) == UTType.movie.identifier {
                if let url = info[.mediaURL] as? URL { onPicked(url, nil) }
            } else {
                if let img = info[.originalImage] as? UIImage { onPicked(nil, img) }
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

// MARK: - 斜杠命令数据模型

/// 斜杠命令项：每条命令有图标、标题、副标题、以及动作类型。
struct SlashCommandItem: Identifiable {
    let id: String           // 唯一标识，如 "clear"、"memory"
    let icon: String         // SF Symbol 名称
    let title: String        // 命令名（如 "clear"、"memory"）
    let subtitle: String     // 说明文字
    let kind: SlashCommandKind
    /// 思考档位选择器数据（仅 /thinking 使用）：当前选中等级 + 可选档位列表。
    /// 非空时菜单渲染为 pill 选择器而非 toggle/disabled。
    var thinkingLevel: String?

    enum SlashCommandKind {
        /// 立即执行的动作（如 /clear、/compact）
        case action
        /// 插入文本前缀到输入框（如 /search → "/search "）
        case insertText(String)
        /// 用户技能：点击后在输入框填入 "/技能名 "，发送时一次性注入该技能让 智能体直接使用。
        case skill(String)
        /// 带开关的切换项（如 /memory）
        case toggle(Bool)
        /// 禁用态（显示原因文字，如 /thinking 在不支持时）
        case disabled(String)
        /// 思考档位选择器（/thinking 在支持思考模型上展示强度 pills）
        case thinkingPicker(selectedLevel: String?, levels: [(id: String, label: String)])
    }
}

// MARK: - 斜杠命令覆盖层

/// 输入 "/" 时在输入框上方弹出的 inline 命令列表。
/// 样式照抄参考 App：深色圆角卡片 + 每行 图标/命令名/说明，支持过滤与开关。
struct SlashCommandOverlay: View {
    let filter: String
    var onSelect: (SlashCommandItem) -> Void

    /// 所有可用命令（由 ChatInputBar 固定定义；toggle 状态由外部传入）。
    let commands: [SlashCommandItem]

    init(filter: String, commands: [SlashCommandItem]? = nil, onSelect: @escaping (SlashCommandItem) -> Void) {
        self.filter = filter
        self.onSelect = onSelect
        // 默认命令集：若外部未传入则使用内置列表（toggle 占位符会在 ChatView 侧替换为真实状态）。
        self.commands = commands ?? Self.defaultCommands
    }

    /// 内置默认命令（toggle 状态占位，实际值由 ChatView 注入）。
    static let defaultCommands: [SlashCommandItem] = [
        SlashCommandItem(id: "clear", icon: "trash", title: "/clear", subtitle: "Clear all messages in this session", kind: .action),
        SlashCommandItem(id: "compact", icon: "arrow.up.arrow.down", title: "/compact", subtitle: "Compress conversation history into summary", kind: .action),
        SlashCommandItem(id: "memory", icon: "brain", title: "/memory", subtitle: "Writes off — tap to toggle", kind: .toggle(false)),
        SlashCommandItem(id: "thinking", icon: "wand.and.sparkles", title: "/thinking", subtitle: L10n.tr("当前模型不支持"), kind: .disabled(L10n.tr("当前模型不支持"))),
        SlashCommandItem(id: "search", icon: "globe", title: "/search", subtitle: L10n.tr("网页搜索"), kind: .insertText("/search ")),
        SlashCommandItem(id: "image", icon: "photo", title: "/image", subtitle: L10n.tr("图片生成"), kind: .insertText("/image ")),
        SlashCommandItem(id: "analyze", icon: "doc.text", title: "/analyze", subtitle: L10n.tr("文件分析"), kind: .insertText("/analyze ")),
        SlashCommandItem(id: "exec", icon: "terminal", title: "/exec", subtitle: L10n.tr("执行命令"), kind: .insertText("/exec ")),
    ]

    /// 按过滤关键词筛选命令：匹配命令名或副标题。
    private var filteredCommands: [SlashCommandItem] {
        guard !filter.isEmpty else { return commands }
        return commands.filter { cmd in
            cmd.title.lowercased().contains(filter) ||
            cmd.subtitle.lowercased().contains(filter)
        }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(filteredCommands) { cmd in
                    slashCommandRow(cmd)
                }
                if filteredCommands.isEmpty {
                    Text(L10n.tr("无匹配命令"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
        }
        // 默认只显示约 3.5 行高度，超出部分可上下滑动选择。
        .frame(maxHeight: 190)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }

    /// 单行命令项：图标 + 命令名 + 说明（右侧可选开关/禁用标记/思考档位选择器）。
    @ViewBuilder
    private func slashCommandRow(_ cmd: SlashCommandItem) -> some View {
        // 思考档位选择器：特殊布局——左侧可切换开/关，右侧 pill 独立点选档位
        if case .thinkingPicker(let selected, let levels) = cmd.kind {
            thinkingPickerRow(icon: cmd.icon, title: cmd.title, subtitle: cmd.subtitle,
                              selectedLevel: selected, levels: levels, cmd: cmd)
        } else {
            // 普通行：整个区域可点击
            Button(action: { onSelect(cmd) }) {
                commandRowContent(cmd)
            }
            .buttonStyle(.plain)
            .disabled(isDisabled(cmd))
        }
    }

    /// 思考档位选择器行：左侧标题区（点击切换开/关）+ 右侧 pill 档位条。
    @ViewBuilder
    private func thinkingPickerRow(icon: String, title: String, subtitle: String,
                                    selectedLevel: String?, levels: [(id: String, label: String)],
                                    cmd: SlashCommandItem) -> some View {
        // selectedLevel 三态：nil=模型默认（思考模型默认开启）、"off"=关闭、具体档位=开启到该档。
        let isActive = selectedLevel != "off"
        // 模型默认（nil）时显示 low 档：支持深度思考的模型一般都有 low 档，
        // 与「关→开」切换动作一致（开 = low），保证默认档永远落在模型支持的档位内。
        let effectiveSelection = selectedLevel ?? (isActive ? "low" : nil)

        HStack(spacing: 12) {
            // 左侧：图标 + 标题（点击切换开/关）
            Button(action: {
                if effectiveSelection != nil && effectiveSelection != "off" {
                    // 当前开（含模型默认 nil）：关闭 → 传 "off"
                    onSelect(SlashCommandItem(
                        id: cmd.id, icon: cmd.icon, title: cmd.title,
                        subtitle: cmd.subtitle, kind: cmd.kind, thinkingLevel: "off"
                    ))
                } else {
                    // 当前关：开启 → 默认 low 档（支持思考的模型一般都有 low 档）
                    onSelect(SlashCommandItem(
                        id: cmd.id, icon: cmd.icon, title: cmd.title,
                        subtitle: cmd.subtitle, kind: cmd.kind, thinkingLevel: "low"
                    ))
                }
            }) {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isActive ? Color.accentColor : .secondary)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(isActive ? Color.accentColor : .primary)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(isActive ? Color.accentColor.opacity(0.7) : .secondary)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // 右侧：一体式档位切换器（整体圆角容器，点击段切换档位，选中段高亮，段间分隔线）
            HStack(spacing: 0) {
                ForEach(Array(levels.enumerated()), id: \.element.id) { index, level in
                    let isSelected = effectiveSelection == level.id
                    Button(action: {
                        onSelect(SlashCommandItem(
                            id: cmd.id, icon: cmd.icon, title: cmd.title,
                            subtitle: cmd.subtitle, kind: cmd.kind, thinkingLevel: level.id
                        ))
                    }) {
                        Text(L10n.tr(level.label))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(isActive && isSelected ? .white : (isActive ? Color.accentColor : .secondary))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isActive && isSelected ? Color.accentColor : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    if index < levels.count - 1 {
                        Divider()
                            .frame(height: 14)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isActive ? Color.accentColor.opacity(0.4) : Color(.separator), lineWidth: 0.5)
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// 普通命令行的内容（图标 + 文字 + 右侧标记）。
    private func commandRowContent(_ cmd: SlashCommandItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: cmd.icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isDisabled(cmd) ? .gray : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(cmd.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isDisabled(cmd) ? .gray : .primary)
                Text(cmd.subtitle)
                    .font(.caption)
                    .foregroundStyle(isDisabled(cmd) ? .gray.opacity(0.7) : .secondary)
                    .lineLimit(1)
            }

            Spacer()

            if case .toggle(let isOn) = cmd.kind {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isOn ? Color.accentColor : Color(.tertiaryLabel))
            } else if isDisabled(cmd) {
                Image(systemName: "circle.slash")
                    .font(.system(size: 14))
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// 判断命令是否为禁用态。
    private func isDisabled(_ cmd: SlashCommandItem) -> Bool {
        if case .disabled = cmd.kind { return true }
        return false
    }
}
