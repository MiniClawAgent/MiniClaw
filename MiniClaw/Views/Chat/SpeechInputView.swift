import SwiftUI
import Speech
import AVFoundation
import UIKit

// MARK: - 语音识别控制器

/// 封装 AVAudioEngine + SFSpeechRecognizer 的实时语音转写。
/// 非 @MainActor：音频引擎在任意线程操作均安全，UI 更新通过回调闭包内派发回主线程。
/// 通过三个闭包把识别文字 / 错误 / 录音状态变化传回 SwiftUI 层。
/// @unchecked Sendable：实例仅在主线程做 start/stop 变更，但会被 @Sendable 闭包跨 actor 引用，
/// 故显式声明为 Sendable，避免 Swift 6 严格并发下把非 Sendable 引用跨 actor 捕获触发运行时崩溃。
final class SpeechController: @unchecked Sendable {
    var onUpdate: ((String, Bool) -> Void)?
    var onError: ((String) -> Void)?
    var onStateChanged: ((Bool) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let recognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))

    /// 是否已真正开始录音（installTap + audioEngine.start 成功后置 true）。
    /// 用于让 UI 侧（如松开麦克风手势）只在确实录音时才调用 stop()，
    /// 避免「从未开始却调用 stop()」去移除并不存在的 tap / 停止未运行的引擎导致崩溃。
    private var recording = false
    /// 是否已安装 inputNode tap（与 recording 配套，单独跟踪以便 stop() 幂等）。
    private var tapInstalled = false
    /// 供 UI 查询当前是否正在录音（主线程读取）。
    var isRecording: Bool { recording }

    /// 开始录音并实时识别。需先确保 语音识别 + 麦克风 权限已授权。
    /// ★ 注意：调用方必须确保本方法在 GCD 主队列上执行（AVAudioSession 内部有
    ///   dispatchPrecondition(.onQueue(.main)) 断言，@MainActor 无法满足）。
    func start() {
        guard recognitionTask == nil else { return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            onError?(String(localized: "speech_recognition_is_not_authorized_please_enable_it_in_system_settings"))
            return
        }
        // ── AVAudioSession 配置（必须在 GCD 主队列）──
        // setCategory / setActive 内部有 dispatchPrecondition(.onQueue(.main)) 断言。
        // 虽然调用方应保证在主队列调用，此处加一层防御性 DispatchQueue.main.async
        // 确保即使调用方疏忽也不会触发 _dispatch_assert_queue_fail 崩溃。
        let doAudioSessionConfig: () -> Void = {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.record, mode: .measurement, options: .duckOthers)
                try session.setActive(true, options: .notifyOthersOnDeactivation)
            } catch {
                self.onError?(String(format: String(localized: "audio_session_configuration_failed"), error.localizedDescription))
                return
            }
            self.startAudioEngine()
        }
        // 如果已在 GCD 主队列，直接执行；否则异步派发（避免嵌套 deadlock）。
        if Thread.isMainThread {
            doAudioSessionConfig()
        } else {
            DispatchQueue.main.async { doAudioSessionConfig() }
        }
    }

    /// 音频会话配置成功后，启动音频引擎和识别任务。
    private func startAudioEngine() {
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else { return }
        recognitionRequest.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }
        tapInstalled = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            onError?(String(format: String(localized: "unable_to_start_recording"), error.localizedDescription))
            return
        }
        // 引擎已真正启动录音，标记 recording，使 stop() 与 UI 侧「松开麦克风」只在确有录音时才清理音频资源。
        recording = true

        guard let recognizer, recognizer.isAvailable else {
            onError?(String(localized: "speech_recognition_is_not_supported_in_the_current_language"))
            stop()
            return
        }

        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                self?.onUpdate?(text, result.isFinal)
            }
            if let error {
                self?.onError?(error.localizedDescription)
            }
        }
        onStateChanged?(true)
    }

    /// 停止录音并让识别任务收尾（会产出最终识别结果）。
    func stop() {
        recording = false
        // 幂等保护：仅在引擎确实运行过、且 tap 确实安装过时才触碰音频硬件，
        // 避免「从未开始录音（如用户拒绝授权）却调用 stop()」去移除并不存在的 tap，
        // 触发 AVAudioEngine 内部断言崩溃。
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        recognitionRequest = nil
        recognitionTask = nil
        onStateChanged?(false)
        // setActive(false) 内部同样有 dispatchPrecondition(.onQueue(.main)) 断言，
        // 必须在 GCD 主队列上执行。
        let deactivateSession: () -> Void = {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        if Thread.isMainThread {
            deactivateSession()
        } else {
            DispatchQueue.main.async { deactivateSession() }
        }
    }

    /// 取消：等同停止，但不产出/保留结果（调用方直接关闭界面即可）。
    func cancel() {
        stop()
    }
}

// MARK: - 语音界面状态

/// 语音输入界面的可观测状态：识别文字、录音状态、提示文案、可发送标记。
/// 用 @MainActor 引用类型承载，使后台识别回调能安全写回并驱动视图刷新。
/// @unchecked Sendable：仅持有 String/Bool 等简单值，所有变更都在 @MainActor 上发生，
/// 但会被 @Sendable 权限回调闭包跨 actor 引用，故显式声明为 Sendable。
@MainActor
final class SpeechViewModel: ObservableObject, @unchecked Sendable {
    @Published var recognizedText: String = ""
    @Published var isRecording: Bool = false
    @Published var statusMessage: String = String(localized: "hold_the_microphone_to_start_speaking")
    @Published var canSend: Bool = false
    @Published var showPermissionAlert: Bool = false
    @Published var permissionAlertMessage: String = ""

    /// 标记当前是否处于「语音输入」内嵌模式（由输入框持有）。
    var inVoiceMode: Bool = false

    func reset() {
        recognizedText = ""
        isRecording = false
        statusMessage = String(localized: "hold_the_microphone_to_start_speaking")
        canSend = false
    }
}
