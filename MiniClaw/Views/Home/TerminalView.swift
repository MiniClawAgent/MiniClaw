import SwiftUI

// MARK: - 终端（iSH / Alpine 交互式终端）
//
// 直接在终端滚动区内输入命令、回车执行；通过 ShellRuntimeFactory.runtime.execute
// 在已启动的 iSH/Alpine 运行时里运行，下方实时显示 stdout / stderr。
// 仅当 iSH 已集成（ISH_ENABLED）时才编译本视图——
// 首页菜单的「终端」项也只在同条件下可点击。
//
// 会话绑定：顶部状态条右侧有绑定选择器，默认「共享区」（fs_context=0，
// /var/MiniClaw/* 落到扁平 Documents/MiniClaw/*）；选中某会话后，
// 之后的所有命令绑到该会话的 fs_context，/var/MiniClaw/* 被隔离到
// Sessions/<uuid>/*，与会话内 agent 的 shell 完全一致——可用于真机验收。

#if ISH_ENABLED

struct TerminalView: View {
    @Environment(\.dismiss) private var dismiss
    /// 会话列表：来自 SessionManager 内存态（启动全量加载,变更即时落盘）。
    private var sessions: [ChatSession] { SessionManager.shared.sessions }
    @State private var lines: [TerminalLine] = []
    @State private var input: String = ""
    @State private var isRunning: Bool = false
    @State private var bootState: String = String(localized: "detecting")
    /// 当前终端绑定的会话；nil = 共享区（fs_context=0）
    @State private var boundSessionID: UUID?
    @FocusState private var inputFocused: Bool
    private let inputAnchor = "terminalInputLine"

    /// 从会话页打开时传入的初始绑定（id + 标题）。
    /// 标题必须随 id 一起传：全新会话在发出第一条消息前尚未写入 SwiftData，
    /// `@Query` 查不到它，若仅靠查询回落会误显示「已删除的会话」。
    private let initialSessionID: UUID?
    private let initialSessionTitle: String?

    /// 从会话页打开时传入当前会话 id（和标题），终端默认绑定到该会话；
    /// 从首页打开则为 nil，默认「共享区」。
    init(initialSessionID: UUID? = nil, initialSessionTitle: String? = nil) {
        self.initialSessionID = initialSessionID
        self.initialSessionTitle = initialSessionTitle
        _boundSessionID = State(initialValue: initialSessionID)
    }

    private var boundSessionTitle: String {
        guard let id = boundSessionID else { return String(localized: "shared_area") }
        if let found = sessions.first(where: { $0.id == id })?.title { return found }
        // 查询未命中：若是打开终端时传入的当前会话（可能尚未持久化），用传入标题
        if id == initialSessionID, let title = initialSessionTitle { return title }
        return String(localized: "deleted_sessions")
    }

    /// 当前绑定对应的 fs_context 真实值（0 = 共享区 / 未绑定）。
    /// 查询即注册：若该会话尚无映射，会顺带 ensureHostDirs 建好宿主目录。
    private var currentFsContext: UInt64 {
        guard let id = boundSessionID else { return 0 }
        return SessionFileRouter.shared.fsContext(for: id)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部启动状态条
                HStack(spacing: 6) {
                    Image(systemName: MiniClawiSHIsBooted() ? "checkmark.circle.fill" : "hourglass")
                        .foregroundStyle(MiniClawiSHIsBooted() ? .green : .orange)
                    Text(String(localized: "alpine_runtime_label") + bootState)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    // 会话绑定选择器：切换后立即生效，影响之后执行的命令
                    Menu {
                        Button {
                            switchBinding(to: nil)
                        } label: {
                            if boundSessionID == nil {
                                Label(String(localized: "shared_area"), systemImage: "checkmark")
                            } else {
                                Text(String(localized: "shared_area"))
                            }
                        }
                        if !sessions.isEmpty {
                            Divider()
                            ForEach(sessions) { session in
                                Button {
                                    switchBinding(to: session.id)
                                } label: {
                                    if boundSessionID == session.id {
                                        Label(session.title, systemImage: "checkmark")
                                    } else {
                                        Text(session.title)
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: boundSessionID == nil ? "globe" : "lock.fill")
                                .font(.caption2)
                            Text(boundSessionTitle)
                                .font(.caption)
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8))
                        }
                        .foregroundStyle(boundSessionID == nil ? Color.secondary : Color.accentColor)
                    }
                    .disabled(isRunning)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(lines) { line in
                                Text(line.text)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(line.isError ? Color(red: 1.0, green: 0.5, blue: 0.5) : .green)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(line.id)
                            }
                            // 直接在终端里输入：提示符与输入框同处滚动区最后一行
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("$")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.green)
                                TextField(String(localized: "enter_a_command_here_press_enter_to_run"), text: $input)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.white)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .disabled(isRunning)
                                    .focused($inputFocused)
                                    .onSubmit { runCommand() }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(inputAnchor)
                        }
                        .padding(10)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .onChange(of: lines.count) { _ in
                        withAnimation { proxy.scrollTo(inputAnchor, anchor: .bottom) }
                    }
                    .onAppear { inputFocused = true }
                    .contentShape(Rectangle())
                    .onTapGesture { inputFocused = true }
                }
            }
            .navigationTitle(Text(String(localized: "terminal")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        lines.removeAll()
                    } label: {
                        Label(String(localized: "clear_screen"), systemImage: "trash")
                    }
                    .disabled(isRunning)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "done")) { dismiss() }
                }
            }
            .task {
                refreshBootState()
                appendBindingInfo()
                runCommand("uname -a; echo '--- Alpine ---'; cat /etc/alpine-release 2>/dev/null; echo '--- arch ---'; uname -m")
            }
        }
    }

    /// 切换终端绑定目标，并在终端里打一行提示，方便区分前后命令的上下文。
    private func switchBinding(to sessionID: UUID?) {
        guard boundSessionID != sessionID else { return }
        boundSessionID = sessionID
        appendBindingInfo()
    }

    /// 在终端打印当前绑定详情：会话 id + fs_context 真实值 + 宿主落点，
    /// 用于直接肉眼验证「绑定是否生效」。
    private func appendBindingInfo() {
        if let id = boundSessionID {
            let ctx = SessionFileRouter.shared.fsContext(for: id) // 查询即注册（含建目录）
            let hostDir = SessionFileRouter.shared.sessionHostDirectory(for: id).path
            lines.append(TerminalLine(text: String(format: String(localized: "terminal_banner_bound"), boundSessionTitle)))
            lines.append(TerminalLine(text: "[session.id = \(id.uuidString)]"))
            lines.append(TerminalLine(text: String(format: String(localized: "terminal_banner_fs_context"), ctx)))
            lines.append(TerminalLine(text: String(format: String(localized: "terminal_banner_host"), hostDir)))
        } else {
            lines.append(TerminalLine(text: String(localized: "terminal_banner_shared")))
        }
    }

    private func refreshBootState() {
        switch MiniClawiSHGetBootState() {
        case .booted:     bootState = String(localized: "started")
        case .prewarming: bootState = String(localized: "prewarming_in_background")
        case .failed:     bootState = String(localized: "launch_failed")
        case .idle:       bootState = String(localized: "not_started")
        @unknown default: bootState = String(localized: "unknown")
        }
    }

    private func runCommand(_ preset: String? = nil) {
        let command = (preset ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        input = ""
        isRunning = true
        lines.append(TerminalLine(text: "$ \(command)"))
        Task {
            // 命令绑定到终端顶部选择器指定的会话：
            // - 绑定会话 → fs_context≠0，/var/MiniClaw/* 隔离到 Sessions/<uuid>/*
            // - 共享区（nil）→ fs_context=0，/var/MiniClaw/* 落到扁平 Documents/MiniClaw/*
            let sessionID: UUID? = boundSessionID
            do {
            let result = try await ShellRuntimeFactory.runtime.execute(
                command: command,
                environment: EnvVarStore.environmentDictionary,
                workingDirectory: nil,
                timeout: 120,
                onLine: nil,
                sessionID: sessionID
            )
                let out = result.stdout
                if !out.isEmpty {
                    for raw in out.components(separatedBy: "\n") {
                        await MainActor.run { lines.append(TerminalLine(text: raw)) }
                    }
                }
                if !result.stderr.isEmpty {
                    for raw in result.stderr.components(separatedBy: "\n") {
                        await MainActor.run { lines.append(TerminalLine(text: raw, isError: true)) }
                    }
                }
                if result.exitCode != 0 {
                    await MainActor.run {
                        lines.append(TerminalLine(text: String(format: String(localized: "terminal_exit_code"), result.exitCode), isError: true))
                    }
                }
            } catch {
                await MainActor.run {
                    lines.append(TerminalLine(text: String(format: String(localized: "execution_error"), error.localizedDescription), isError: true))
                }
            }
            await MainActor.run {
                isRunning = false
                inputFocused = true
            }
        }
    }
}

struct TerminalLine: Identifiable {
    let id = UUID()
    let text: String
    var isError: Bool = false
}

#endif
