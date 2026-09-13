import Foundation
import AVFoundation
import Speech

// MARK: - 跨 actor 边界的数据

/// 统一结果。`SFSpeechRecognizer` / `AVAudioEngine` 不是 Sendable，
/// 识别结果与失败原因都在桥接层内组装成文本后回传。
private struct SpeechOutcome: Sendable {
    let success: Bool
    let text: String

    static func ok(_ text: String) -> SpeechOutcome { SpeechOutcome(success: true, text: text) }
    static func fail(_ text: String) -> SpeechOutcome { SpeechOutcome(success: false, text: text) }
}

// MARK: - apple-speech (Speech)

/// 语音识别工具：把麦克风输入或音频文件转成文字。
///
/// ## 与 `apple-speak` 的分工
/// `apple-speak` 是文字 → 语音（TTS，输出给用户听）；本工具是语音 → 文字
/// （STT，把用户说的话/音频文件变成模型能读的文本）。两者方向相反。
///
/// ## 权限是两道，缺一不可
/// 麦克风转写同时需要**麦克风**（录音）与**语音识别**（转文字）两项授权，
/// 缺任一项都要给出可执行的引导，而不是笼统报「失败」。
/// 只转写已有音频文件时不需要麦克风权限——按来源分别索取，不超额申请。
///
/// ## 录音时长上限
/// 麦克风模式默认 10 秒、封顶 60 秒：语音识别按音频时长计费/配额，
/// 且工具调用是同步阻塞的，不该让一次调用把会话挂死。
struct AppleSpeechTool: AgentTool {
    let name = "apple-speech"
    /// [2026-09-13 路径统一] 当前会话 ID：会话独享目录（attachments/workspace/browser/offloads）
    /// 必须按它解析才能落到本会话目录；其余写法一律走 `FileSystemManager.resolveAgentPath`
    ///（强制 `/var/MiniClaw/` 前缀 + 拒绝目录穿越）。
    let currentSessionID: UUID?

    init(currentSessionID: UUID? = nil) {
        self.currentSessionID = currentSessionID
    }

    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-speech",
            description: String(localized: "stt_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(
                        type: "string",
                        description: String(localized: "op_speech_actions"),
                        enum: ["transcribe", "languages", "status"]
                    ),
                    "source": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_speech_source")),
                    "language": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_lang_code_en")),
                    "duration": JSONSchema.JSONProperty(type: "integer", description: String(localized: "param_speech_duration")),
                    "on_device": JSONSchema.JSONProperty(type: "boolean", description: String(localized: "param_on_device")),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let action = parameters["action"] as? String else {
            throw ToolError.invalidParameters(String(localized: "err_missing_action"))
        }

        switch action {
        case "transcribe":
            let outcome: SpeechOutcome
            if let source = Self.string(parameters["source"]), !Self.isMic(source) {
                outcome = await SpeechBridge.transcribeFile(
                    path: source,
                    localeID: Self.string(parameters["language"]),
                    onDevice: Self.bool(parameters["on_device"]),
                    sessionID: currentSessionID)
            } else {
                outcome = await SpeechBridge.transcribeMic(
                    seconds: Self.int(parameters["duration"]),
                    localeID: Self.string(parameters["language"]),
                    onDevice: Self.bool(parameters["on_device"]))
            }
            return ToolResult(success: outcome.success, text: outcome.text)

        case "languages":
            let outcome = await SpeechBridge.languages()
            return ToolResult(success: outcome.success, text: outcome.text)

        case "status":
            let outcome = await SpeechBridge.status()
            return ToolResult(success: outcome.success, text: outcome.text)

        default:
            return ToolResult(success: false, text: String(localized: "speech_unknown_action") + action)
        }
    }
}

// MARK: - 入参摊平

extension AppleSpeechTool {
    /// 空 / mic / microphone 都算「用麦克风」，其余按文件路径处理。
    private static func isMic(_ raw: String) -> Bool {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["mic", "microphone", "system-mic", "system_mic"].contains(normalized)
    }

    private static func string(_ v: Any?) -> String? {
        (v as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func int(_ v: Any?) -> Int? {
        if let n = v as? Int { return n }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }

    private static func bool(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let s = v as? String { return s == "true" || s == "1" }
        return false
    }
}

// MARK: - MainActor 桥接层

/// 识别器、音频引擎、识别任务都不是 Sendable，且音频会话的启停要在主线程串行执行
/// （并发启停会把 `AVAudioSession` 搞成不确定状态），故统一收在 MainActor 内。
@MainActor
private enum SpeechBridge {

    // MARK: 状态查询

    static func status() async -> SpeechOutcome {
        let recognizer = SFSpeechRecognizer() ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer else { return .fail(String(localized: "speech_unavailable")) }
        let authorized = SFSpeechRecognizer.authorizationStatus() == .authorized
        let lines = [
            String(localized: "speech_status_header"),
            String(localized: "speech_auth_label") + (authorized ? String(localized: "speech_authorized") : String(localized: "unavailable")),
            String(localized: "speech_ready_label") + (recognizer.isAvailable ? String(localized: "available_yes") : String(localized: "unavailable")),
            String(localized: "speech_locale_label") + recognizer.locale.identifier,
            String(localized: "speech_on_device_label") + (recognizer.supportsOnDeviceRecognition ? String(localized: "available_yes") : String(localized: "unavailable")),
        ]
        return .ok(lines.joined(separator: "\n"))
    }

    /// 可用语种。列表可能上百条，超出 40 条时只给前 40 并注明总数。
    static func languages() async -> SpeechOutcome {
        let locales = SFSpeechRecognizer.supportedLocales()
            .map(\.identifier)
            .sorted()
        guard !locales.isEmpty else { return .fail(String(localized: "speech_unavailable")) }
        let shown = Array(locales.prefix(40))
        var lines: [String] = [String(localized: "speech_languages_header") + "\(locales.count)"]
        for id in shown {
            let name = Locale.current.localizedString(forIdentifier: id) ?? id
            lines.append("- \(id) | \(name)")
        }
        if locales.count > shown.count {
            lines.append(String(localized: "speech_languages_truncated") + "\(locales.count - shown.count)")
        }
        return .ok(lines.joined(separator: "\n"))
    }

    // MARK: 转写

    static func transcribeFile(path: String, localeID: String?, onDevice: Bool,
                               sessionID: UUID?) async -> SpeechOutcome {
        let url = Self.resolve(path, sessionID: sessionID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .fail(String(localized: "speech_file_missing") + path)
        }
        guard let recognizer = Self.makeRecognizer(localeID: localeID) else {
            return .fail(String(localized: "speech_lang_unsupported") + (localeID ?? ""))
        }
        guard recognizer.isAvailable else { return .fail(String(localized: "speech_unavailable")) }
        guard await Self.ensureSpeechAuthorization() else { return .fail(Self.speechDeniedText) }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = onDevice && recognizer.supportsOnDeviceRecognition
        let box = TranscriptBox()
        return await withCheckedContinuation { cont in
            box.install(cont)
            box.retain(recognizer.recognitionTask(with: request) { result, error in
                SpeechBridge.consume(result: result, error: error, box: box)
            })
        }
    }

    static func transcribeMic(seconds: Int?, localeID: String?, onDevice: Bool) async -> SpeechOutcome {
        guard await Self.ensureMicAccess() else { return .fail(String(localized: "speech_mic_denied")) }
        guard let recognizer = Self.makeRecognizer(localeID: localeID) else {
            return .fail(String(localized: "speech_lang_unsupported") + (localeID ?? ""))
        }
        guard recognizer.isAvailable else { return .fail(String(localized: "speech_unavailable")) }
        guard await Self.ensureSpeechAuthorization() else { return .fail(Self.speechDeniedText) }

        let duration = min(max(seconds ?? 10, 1), 60)
        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = onDevice && recognizer.supportsOnDeviceRecognition
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        let session = AVAudioSession.sharedInstance()
        let box = TranscriptBox()

        let outcome = await withCheckedContinuation { cont in
            box.install(cont)
            box.retain(recognizer.recognitionTask(with: request) { result, error in
                SpeechBridge.consume(result: result, error: error, box: box)
            })
            // 音频回调在系统音频线程上派发；`append` 允许从任意线程调用，
            // 故闭包里只做「把 PCM 喂给识别请求」这一件事。
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            do {
                try session.setCategory(.record, mode: .measurement, options: .duckOthers)
                try session.setActive(true, options: .notifyOthersOnDeactivation)
                engine.prepare()
                try engine.start()
            } catch {
                box.finish(.fail(String(localized: "speech_failed") + error.localizedDescription))
            }
            // 到点收尾：停引擎 → 拆 tap → 告知识别请求「音频结束」（随后会收到 isFinal 结果）。
            // 放在独立的 MainActor 任务里，避免把 continuation 的等待拉长到 duration 之后。
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(duration) * 1_000_000_000)
                engine.stop()
                inputNode.removeTap(onBus: 0)
                request.endAudio()
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
        return outcome
    }

    /// 识别回调的统一处理：`isFinal` 前只更新最新文本，收到 error 或终稿才结束等待。
    ///
    /// 必须是非隔离的静态函数——回调可能在任意队列派发，这里只接触 Sendable 的盒子。
    nonisolated private static func consume(result: SFSpeechRecognitionResult?,
                                            error: Error?,
                                            box: TranscriptBox) {
        if let result { box.note(result.bestTranscription.formattedString) }
        if let error, !(error is CancellationError) {
            box.finish(.fail(String(localized: "speech_failed") + error.localizedDescription))
            return
        }
        if result?.isFinal == true {
            let text = box.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                box.finish(.ok(String(localized: "speech_no_speech")))
                return
            }
            box.finish(.ok(String(localized: "speech_result_label") + text))
        }
    }

    // MARK: 授权

    private static var speechDeniedText: String {
        String(localized: "miniclaw_needs_the_speech_recognition_permission_to_convert_your_speech_to_text_please_go_to_settings_privacy_security_speech_recognition_find_miniclaw_and_turn_on_the_switch_then_return_to_use_it")
    }

    private static func ensureSpeechAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined: break
        default: return false
        }
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    /// `AVAudioSession.requestRecordPermission` 自 iOS 17 起废弃，替代品
    /// `AVAudioApplication.requestRecordPermission` 又要 17 才有——部署目标是 16，
    /// 只能按版本分流，两分支都不产生废弃告警。
    private static func ensureMicAccess() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        }
        return await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
        }
    }

    // MARK: 辅助

    private static func makeRecognizer(localeID: String?) -> SFSpeechRecognizer? {
        guard let localeID, !localeID.isEmpty else { return SFSpeechRecognizer() }
        return SFSpeechRecognizer(locale: Locale(identifier: localeID))
    }

    /// [2026-09-13 路径统一] 与相册工具同口径：统一走 `FileSystemManager` 的 Agent 路径解析
    ///（强制 `/var/MiniClaw/` 前缀、拒绝目录穿越、会话独享目录按 `sessionID` 落到本会话目录）。
    /// 原实现是"绝对路径直接用 `URL(fileURLWithPath:)`" —— 可读任意宿主路径，且是全库**第三套**
    /// 同形的解析器。解析失败才回落到沙盒根（兼容旧式相对写法）。
    private static func resolve(_ raw: String, sessionID: UUID?) -> URL {
        (try? FileSystemManager.shared.resolveAgentPath(raw, sessionID: sessionID))
            ?? FileSystemManager.shared.miniClawRoot.appendingPathComponent(raw)
    }
}

// MARK: - 转写结果的暂存盒

/// 识别回调会多次派发（中间结果 → 终稿），而 continuation 只能 resume 一次。
/// 盒子负责「记住最新文本 + 保证只结束一次」，并顺便持有 recognition task
/// （不持有的话任务会在第一次回调后被释放，转写提前中断）。
private final class TranscriptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SpeechOutcome, Never>?
    private var latest = ""
    private var isFinished = false
    private var task: SFSpeechRecognitionTask?

    func install(_ continuation: CheckedContinuation<SpeechOutcome, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func retain(_ task: SFSpeechRecognitionTask?) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func note(_ text: String) {
        lock.lock()
        latest = text
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    func finish(_ outcome: SpeechOutcome) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
        continuation?.resume(returning: outcome)
    }
}
