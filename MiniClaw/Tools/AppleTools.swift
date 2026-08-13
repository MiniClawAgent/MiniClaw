import Foundation
import UIKit
import AVFoundation
import NaturalLanguage
import UserNotifications

// MARK: - 4.2 Apple 原生框架工具（21个）

// MARK: - 1. apple-alarm (AlarmKit, iOS 26+)

struct AppleAlarmTool: AgentTool {
    let name = "apple-alarm"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-alarm",
            description: L10n.l("alarm_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: L10n.l("op_reminder_actions"), enum: ["set", "cancel", "list"]),
                    "time": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_alarm_time")),
                    "label": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_tab_label")),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: L10n.l("not_implemented_alarm"))
    }
}

// MARK: - 2. apple-bluetooth (CoreBluetooth)

struct AppleBluetoothTool: AgentTool {
    let name = "apple-bluetooth"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-bluetooth",
            description: L10n.l("bluetooth_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: L10n.l("op_ble_actions"), enum: ["scan", "connect", "disconnect", "read", "write", "notify"]),
                    "device_id": JSONSchema.JSONProperty(type: "string", description: L10n.l("device_uuid")),
                    "service_uuid": JSONSchema.JSONProperty(type: "string", description: L10n.l("service_uuid")),
                    "characteristic_uuid": JSONSchema.JSONProperty(type: "string", description: L10n.l("characteristic_uuid")),
                    "data": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_write_data")),
                    "duration": JSONSchema.JSONProperty(type: "integer", description: L10n.l("param_scan_duration")),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: L10n.l("not_implemented_bluetooth"))
    }
}

// MARK: - 3. apple-calendar (EventKit)

struct AppleCalendarTool: AgentTool {
    let name = "apple-calendar"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-calendar",
            description: L10n.l("calendar_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: L10n.l("op_crud_actions"), enum: ["list", "create", "update", "delete"]),
                    "title": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_event_title")),
                    "start_date": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_start_time")),
                    "end_date": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_end_time")),
                    "event_id": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_event_id")),
                    "calendar_name": JSONSchema.JSONProperty(type: "string", description: L10n.l("calendar_name")),
                    "notes": JSONSchema.JSONProperty(type: "string", description: L10n.l("note_label")),
                    "location": JSONSchema.JSONProperty(type: "string", description: L10n.l("place_param")),
                    "all_day": JSONSchema.JSONProperty(type: "boolean", description: L10n.l("param_all_day")),
                    "range_days": JSONSchema.JSONProperty(type: "integer", description: L10n.l("param_query_days")),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: L10n.l("not_implemented_calendar"))
    }
}

// MARK: - 4. apple-clipboard (UIKit UIPasteboard)

struct AppleClipboardTool: AgentTool {
    let name = "apple-clipboard"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-clipboard",
            description: L10n.l("clipboard_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: L10n.l("op_health_actions"), enum: ["read", "write"]),
                    "text": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_write_text")),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let action = parameters["action"] as? String else {
            throw ToolError.invalidParameters(L10n.l("err_missing_action"))
        }
        switch action {
        case "read":
            let text: String = await MainActor.run { UIPasteboard.general.string ?? L10n.l("clipboard_empty") }
            if text == L10n.l("clipboard_empty") {
                return ToolResult(success: true, text: text)
            }
            return ToolResult(success: true, text: text)
        case "write":
            guard let text = parameters["text"] as? String else {
                return ToolResult(success: false, text: L10n.l("err_missing_text"))
            }
            await MainActor.run { UIPasteboard.general.string = text }
            return ToolResult(success: true, text: String(format: L10n.l("apple_clipboard_written"), text.count))
        default:
            return ToolResult(success: false, text: String(format: L10n.l("apple_unsupported_action"), action))
        }
    }
}

// MARK: - 5. apple-device (UIKit UIDevice)

struct AppleDeviceTool: AgentTool {
    let name = "apple-device"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-device",
            description: L10n.l("device_info_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "info": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_query_items"), enum: ["all", "model", "os", "battery", "storage", "network", "screen"]),
                ],
                required: []
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        let info = (parameters["info"] as? String) ?? "all"
        let parts: [String] = await MainActor.run {
            let device = UIDevice.current
            var p: [String] = []
            if info == "all" || info == "model" {
                p.append(String(format: L10n.l("apple_device_model"), device.model, device.name))
            }
            if info == "all" || info == "os" {
                p.append(String(format: L10n.l("apple_system"), device.systemName, device.systemVersion))
                p.append("标识: " + (device.identifierForVendor.map { String($0.uuidString.prefix(12)) } ?? L10n.l("unknown")))
            }
            if info == "all" || info == "battery" {
                device.isBatteryMonitoringEnabled = true
                let pct = Int(device.batteryLevel * 100)
                let state: String = {
                    switch device.batteryState {
                    case .unplugged: return L10n.l("battery_usage")
                    case .charging: return L10n.l("charging_status")
                    case .full: return L10n.l("battery_full")
                    default: return L10n.l("unknown")
                    }
                }()
                p.append(String(format: L10n.l("apple_battery"), pct, state))
            }
            if info == "all" || info == "screen" {
                let screen = UIScreen.main
                let bounds = screen.bounds
                p.append(String(format: L10n.l("apple_screen"), Int(bounds.width), Int(bounds.height), Int(screen.scale)))
            }
            if info == "storage" {
                p.append(L10n.l("not_implemented_storage"))
            }
            return p
        }
        return ToolResult(success: true, text: parts.joined(separator: "\n"))
    }
}

// MARK: - 6. apple-healthkit (HealthKit)

struct AppleHealthKitTool: AgentTool {
    let name = "apple-healthkit"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-healthkit",
            description: L10n.l("health_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: L10n.l("op_bluetooth_actions"), enum: ["read", "write", "query"]),
                    "data_type": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_data_type")),
                    "value": JSONSchema.JSONProperty(type: "number", description: L10n.l("param_write_value")),
                    "unit": JSONSchema.JSONProperty(type: "string", description: L10n.l("unit_label")),
                    "start_date": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_query_start")),
                    "end_date": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_query_end")),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: L10n.l("not_implemented_healthkit"))
    }
}

// MARK: - 7. apple-homekit (HomeKit)

struct AppleHomeKitTool: AgentTool {
    let name = "apple-homekit"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-homekit",
            description: L10n.l("homekit_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: L10n.l("op_homekit_actions"), enum: ["list", "get", "set", "control"]),
                    "device_name": JSONSchema.JSONProperty(type: "string", description: L10n.l("device_name")),
                    "characteristic": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_characteristic_name")),
                    "value": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_target_value")),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: L10n.l("not_implemented_homekit"))
    }
}

// MARK: - 8. apple-location (CoreLocation)

struct AppleLocationTool: AgentTool {
    let name = "apple-location"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-location",
            description: L10n.l("location_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: L10n.l("op_location_actions"), enum: ["current", "geocode", "reverse_geocode"]),
                    "address": JSONSchema.JSONProperty(type: "string", description: L10n.l("address_param")),
                    "latitude": JSONSchema.JSONProperty(type: "number", description: L10n.l("param_latitude_reverse")),
                    "longitude": JSONSchema.JSONProperty(type: "number", description: L10n.l("param_longitude_reverse")),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: L10n.l("not_implemented_location"))
    }
}

// MARK: - 9. apple-maps (MapKit)

struct AppleMapsTool: AgentTool {
    let name = "apple-maps"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-maps",
            description: L10n.l("maps_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: L10n.l("op_map_actions"), enum: ["search_poi", "route", "eta"]),
                    "query": JSONSchema.JSONProperty(type: "string", description: L10n.l("poi_search_keyword")),
                    "from": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_origin")),
                    "to": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_destination")),
                    "transport_type": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_transit_mode"), enum: ["driving", "walking", "transit"]),
                    "limit": JSONSchema.JSONProperty(type: "integer", description: L10n.l("param_result_limit")),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: L10n.l("not_implemented_maps"))
    }
}

// MARK: - 10. apple-media (MediaPlayer)

struct AppleMediaTool: AgentTool {
    let name = "apple-media"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-media",
            description: L10n.l("music_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: L10n.l("op_music_actions"), enum: ["play", "pause", "next", "previous", "search", "info"]),
                    "query": JSONSchema.JSONProperty(type: "string", description: L10n.l("search_keyword_alt")),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: L10n.l("not_implemented_media"))
    }
}

// MARK: - 11. apple-nfc (CoreNFC)

struct AppleNFCTool: AgentTool {
    let name = "apple-nfc"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-nfc",
            description: L10n.l("nfc_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: L10n.l("op_nfc_actions"), enum: ["read", "write", "emv"]),
                    "message": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_ndef_message")),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: L10n.l("not_implemented_nfc"))
    }
}

// MARK: - 12. apple-nlp (NaturalLanguage)

struct AppleNLPTool: AgentTool {
    let name = "apple-nlp"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-nlp",
            description: L10n.l("nlp_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: L10n.l("op_nlp_actions"), enum: ["language", "detect_entities", "sentiment", "tokenize"]),
                    "text": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_text_to_analyze")),
                ],
                required: ["action", "text"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let action = parameters["action"] as? String,
              let text = parameters["text"] as? String else {
            throw ToolError.invalidParameters(L10n.l("err_missing_action_text"))
        }
        switch action {
        case "language":
            let result: String = await MainActor.run {
                let recognizer = NLLanguageRecognizer()
                recognizer.processString(text)
                let lang = recognizer.dominantLanguage?.rawValue ?? L10n.l("unknown")
                let conf = recognizer.languageHypotheses(withMaximum: 3)
                    .map { "\($0.key.rawValue): \(String(format: "%.0f%%", $0.value * 100))" }
                    .joined(separator: ", ")
                return String(format: L10n.l("apple_language"), lang, conf)
            }
            return ToolResult(success: true, text: result)

        case "sentiment":
            let result: String = await MainActor.run {
                let tagger = NLTagger(tagSchemes: [.sentimentScore])
                tagger.string = text
                let (score, _) = tagger.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore)
                let s = Double(score?.rawValue ?? "0") ?? 0
                let label = s > 0.3 ? L10n.l("sentiment_positive") : (s < -0.3 ? L10n.l("sentiment_negative") : L10n.l("sentiment_neutral"))
                return L10n.l("sentiment_label") + label + " (score: " + String(format: "%.2f", s) + ")"
            }
            return ToolResult(success: true, text: result)

        case "tokenize":
            let tokens: [String] = await MainActor.run {
                let tokenizer = NLTokenizer(unit: .word)
                tokenizer.string = text
                var t: [String] = []
                tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                    t.append(String(text[range]))
                    return true
                }
                return t
            }
            return ToolResult(success: true, text: "分词结果 (" + String(tokens.count) + " 个): " + tokens.joined(separator: " | "))

        case "detect_entities":
            let result: String = await MainActor.run {
                let tagger = NLTagger(tagSchemes: [.nameType])
                tagger.string = text
                var entities: [String: [String]] = [:]
                tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType) { tag, range in
                    if let tag = tag, tag != .other {
                        let word = String(text[range])
                        entities[tag.rawValue, default: []].append(word)
                    }
                    return true
                }
                if entities.isEmpty { return L10n.l("no_named_entities") }
                return entities.map { "\($0.key): \($0.value.joined(separator: ", "))" }.joined(separator: "\n")
            }
            return ToolResult(success: true, text: result)

        default:
            return ToolResult(success: false, text: String(format: L10n.l("apple_unsupported_action"), action))
        }
    }
}

// MARK: - 13. apple-notification (UserNotifications)

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

struct ApplePhotosTool: AgentTool {
    let name = "apple-photos"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-photos",
            description: L10n.l("photos_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: L10n.l("op_media_actions"), enum: ["list", "save", "delete"]),
                    "path": JSONSchema.JSONProperty(type: "string", description: L10n.l("image_path_save_param")),
                    "limit": JSONSchema.JSONProperty(type: "integer", description: L10n.l("param_return_limit")),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: L10n.l("not_implemented_photos"))
    }
}

// MARK: - 16. apple-player (AVFoundation)

struct ApplePlayerTool: AgentTool {
    let name = "apple-player"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-player",
            description: L10n.l("player_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: L10n.l("op_player_actions"), enum: ["play", "pause", "stop", "seek"]),
                    "url": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_media_url")),
                    "position": JSONSchema.JSONProperty(type: "number", description: L10n.l("param_seek_position")),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: L10n.l("not_implemented_player"))
    }
}

// MARK: - 17. apple-reminders (EventKit)

struct AppleRemindersTool: AgentTool {
    let name = "apple-reminders"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-reminders",
            description: L10n.l("reminders_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: L10n.l("op_todo_actions"), enum: ["list", "create", "complete", "delete"]),
                    "title": JSONSchema.JSONProperty(type: "string", description: L10n.l("reminder_title")),
                    "due_date": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_due_time")),
                    "reminder_id": JSONSchema.JSONProperty(type: "string", description: L10n.l("reminder_id")),
                    "notes": JSONSchema.JSONProperty(type: "string", description: L10n.l("note_label")),
                    "priority": JSONSchema.JSONProperty(type: "integer", description: L10n.l("param_priority")),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: L10n.l("not_implemented_reminders"))
    }
}

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

struct AppleSpeechTool: AgentTool {
    let name = "apple-speech"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-speech",
            description: L10n.l("stt_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "language": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_lang_code_zh")),
                    "duration": JSONSchema.JSONProperty(type: "integer", description: L10n.l("param_speech_duration")),
                ],
                required: []
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: L10n.l("not_implemented_speech"))
    }
}

// MARK: - 20. apple-vision (Vision)

struct AppleVisionTool: AgentTool {
    let name = "apple-vision"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-vision",
            description: L10n.l("vision_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: L10n.l("op_vision_actions"), enum: ["ocr", "face_detect", "barcode", "classify", "similarity", "stitch"]),
                    "image_path": JSONSchema.JSONProperty(type: "string", description: L10n.l("image_path_param")),
                    "image_path_2": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_second_image")),
                ],
                required: ["action", "image_path"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: L10n.l("not_implemented_vision"))
    }
}

// MARK: - 21. apple-weather (WeatherKit)

struct AppleWeatherTool: AgentTool {
    let name = "apple-weather"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-weather",
            description: L10n.l("weather_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: L10n.l("op_weather_actions"), enum: ["current", "forecast", "alerts"]),
                    "latitude": JSONSchema.JSONProperty(type: "number", description: L10n.l("param_latitude_current")),
                    "longitude": JSONSchema.JSONProperty(type: "number", description: L10n.l("param_longitude_current")),
                    "days": JSONSchema.JSONProperty(type: "integer", description: L10n.l("param_forecast_days")),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: L10n.l("not_implemented_weather"))
    }
}
