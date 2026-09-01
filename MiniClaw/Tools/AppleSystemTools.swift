import Foundation
import UIKit
import AVFoundation
import NaturalLanguage
import UserNotifications

struct AppleNotificationTool: AgentTool {
    let name = "apple-notification"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-notification",
            description: L10n.l("send_local_notification"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "title": JSONSchema.JSONProperty(type: "string", description: L10n.l("notification_title")),
                    "body": JSONSchema.JSONProperty(type: "string", description: L10n.l("notification_body")),
                    "delay_seconds": JSONSchema.JSONProperty(type: "integer", description: L10n.l("param_delay_seconds")),
                    "sound": JSONSchema.JSONProperty(type: "string", description: L10n.l("sound_filename_param")),
                ],
                required: ["title", "body"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let title = parameters["title"] as? String,
              let body = parameters["body"] as? String else {
            throw ToolError.invalidParameters(L10n.l("err_missing_title_body"))
        }
        let delay = (parameters["delay_seconds"] as? Int) ?? 1
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(max(delay, 1)), repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        do {
            try await UNUserNotificationCenter.current().add(request)
            return ToolResult(success: true, text: String(format: L10n.l("apple_notification_scheduled"), delay))
        } catch {
            return ToolResult(success: false, text: String(format: L10n.l("apple_notification_failed"), error.localizedDescription))
        }
    }
}

// MARK: - 14. apple-open (UIKit UIApplication)

struct AppleOpenTool: AgentTool {
    let name = "apple-open"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-open",
            description: L10n.l("apple_open_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "url": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_url_schemes")),
                ],
                required: ["url"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let urlString = parameters["url"] as? String,
              let url = URL(string: urlString) else {
            throw ToolError.invalidParameters(L10n.l("err_missing_url"))
        }
        // http/https → 走内置浏览器，不跳 Safari
        if url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https" {
            await MainActor.run { AppState.shared.pendingBrowserURL = url }
            return ToolResult(success: true, text: String(format: L10n.l("apple_opened_inline"), urlString))
        }
        let canOpen: Bool = await MainActor.run { UIApplication.shared.canOpenURL(url) }
        guard canOpen else {
            return ToolResult(success: false, text: String(format: L10n.l("apple_cannot_open"), urlString))
        }
        await MainActor.run { UIApplication.shared.open(url) }
        return ToolResult(success: true, text: String(format: L10n.l("apple_opened"), urlString))
    }
}

// MARK: - 14b. open-in-safari (显式外部 Safari 打开)

struct SafariOpenTool: AgentTool {
    let name = "open-in-safari"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "open-in-safari",
            description: L10n.l("safari_open_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "url": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_url_http")),
                ],
                required: ["url"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let urlString = parameters["url"] as? String,
              let url = URL(string: urlString) else {
            throw ToolError.invalidParameters(L10n.l("err_missing_url"))
        }
        let canOpen: Bool = await MainActor.run { UIApplication.shared.canOpenURL(url) }
        guard canOpen else {
            return ToolResult(success: false, text: String(format: L10n.l("apple_cannot_open"), urlString))
        }
        await MainActor.run { UIApplication.shared.open(url) }
        return ToolResult(success: true, text: String(format: L10n.l("apple_opened_safari"), urlString))
    }
}

// MARK: - 15. apple-photos (Photos)

// 注：apple-photos 的真实现已迁至 PhotosTools.swift（此处占位实现已删除）。

// MARK: - 16. apple-player (AVFoundation)

// 注：apple-player 已移除——App 内没有持久播放器实例，其能力已被已注册的
// `apple-speak`（TTS 朗读）与新增的 `apple-media`（系统播放控制）覆盖。

// MARK: - 17. apple-reminders (EventKit)

// 注：apple-reminders 的真实现已迁至 ReminderTools.swift（此处占位实现已删除）。

// MARK: - 18. apple-speak (AVSpeechSynthesizer)

struct AppleSpeakTool: AgentTool {
    let name = "apple-speak"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-speak",
            description: L10n.l("tts_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "text": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_text_to_speak")),
                    "language": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_lang_code_en")),
                    "rate": JSONSchema.JSONProperty(type: "number", description: L10n.l("param_speech_rate")),
                ],
                required: ["text"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let text = parameters["text"] as? String else {
            throw ToolError.invalidParameters(L10n.l("err_missing_text"))
        }
        let language = parameters["language"] as? String
        let rate = Float(parameters["rate"] as? Double ?? 0.5)
        await MainActor.run {
            let utterance = AVSpeechUtterance(string: text)
            if let lang = language {
                utterance.voice = AVSpeechSynthesisVoice(language: lang)
            }
            utterance.rate = max(0.0, min(1.0, rate))
            AVSpeechSynthesizer().speak(utterance)
        }
        return ToolResult(success: true, text: String(format: L10n.l("apple_speaking"), text.count))
    }
}

// MARK: - 19. apple-speech (Speech)

// 注：apple-speech 的真实现已迁至 SpeechTools.swift（此处占位实现已删除）。

// MARK: - 20. apple-vision (Vision)

// 注：apple-vision 已移除——其能力已被已注册的 `vision_analyze`（MediaTools.swift）
// 完全覆盖，留着只会让模型看到两个功能重复的工具。

// MARK: - 21. apple-weather (WeatherKit)

// 注：apple-weather 已移除——WeatherKit 需要 `com.apple.developer.weatherkit`
// entitlement 且需付费开发者账号在后台勾选 capability，v1 不引入。
