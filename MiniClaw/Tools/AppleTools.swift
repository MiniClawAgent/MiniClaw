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
            description: "管理闹钟和计时器。支持设置/取消闹钟、创建倒计时。需要 AlarmKit（iOS 26+）。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: "操作: set/cancel/list", enum: ["set", "cancel", "list"]),
                    "time": JSONSchema.JSONProperty(type: "string", description: "闹钟/计时器时间（ISO 8601 或 HH:mm）"),
                    "label": JSONSchema.JSONProperty(type: "string", description: "标签/名称"),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: "🔴 alarm 尚未接入。AlarmKit 需要 iOS 26+ 和系统授权。")
    }
}

// MARK: - 2. apple-bluetooth (CoreBluetooth)

struct AppleBluetoothTool: AgentTool {
    let name = "apple-bluetooth"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-bluetooth",
            description: "蓝牙 BLE 扫描、连接、读写操作。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: "操作: scan/connect/disconnect/read/write/notify", enum: ["scan", "connect", "disconnect", "read", "write", "notify"]),
                    "device_id": JSONSchema.JSONProperty(type: "string", description: "设备 UUID"),
                    "service_uuid": JSONSchema.JSONProperty(type: "string", description: "服务 UUID"),
                    "characteristic_uuid": JSONSchema.JSONProperty(type: "string", description: "特征 UUID"),
                    "data": JSONSchema.JSONProperty(type: "string", description: "要写入的数据（Base64 或 hex）"),
                    "duration": JSONSchema.JSONProperty(type: "integer", description: "扫描时长（秒）"),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: "🔴 bluetooth 尚未接入。CoreBluetooth 需要蓝牙权限和硬件支持。")
    }
}

// MARK: - 3. apple-calendar (EventKit)

struct AppleCalendarTool: AgentTool {
    let name = "apple-calendar"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-calendar",
            description: "管理日历事件和提醒事项。支持 CRUD 操作。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: "操作: list/create/update/delete", enum: ["list", "create", "update", "delete"]),
                    "title": JSONSchema.JSONProperty(type: "string", description: "事件标题"),
                    "start_date": JSONSchema.JSONProperty(type: "string", description: "开始时间（ISO 8601）"),
                    "end_date": JSONSchema.JSONProperty(type: "string", description: "结束时间（ISO 8601）"),
                    "event_id": JSONSchema.JSONProperty(type: "string", description: "事件 ID（用于更新/删除）"),
                    "calendar_name": JSONSchema.JSONProperty(type: "string", description: "日历名称"),
                    "notes": JSONSchema.JSONProperty(type: "string", description: "备注"),
                    "location": JSONSchema.JSONProperty(type: "string", description: "地点"),
                    "all_day": JSONSchema.JSONProperty(type: "boolean", description: "是否全天事件"),
                    "range_days": JSONSchema.JSONProperty(type: "integer", description: "查询范围天数（默认 30）"),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: "🔴 calendar 尚未接入。EventKit 需要日历权限授权。")
    }
}

// MARK: - 4. apple-clipboard (UIKit UIPasteboard)

struct AppleClipboardTool: AgentTool {
    let name = "apple-clipboard"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-clipboard",
            description: "读写系统剪贴板内容。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: "操作: read/write", enum: ["read", "write"]),
                    "text": JSONSchema.JSONProperty(type: "string", description: "要写入的文本内容"),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let action = parameters["action"] as? String else {
            throw ToolError.invalidParameters("缺少 action 参数")
        }
        switch action {
        case "read":
            let text: String = await MainActor.run { UIPasteboard.general.string ?? "(剪贴板为空)" }
            if text == "(剪贴板为空)" {
                return ToolResult(success: true, text: text)
            }
            return ToolResult(success: true, text: text)
        case "write":
            guard let text = parameters["text"] as? String else {
                return ToolResult(success: false, text: "缺少 text 参数")
            }
            await MainActor.run { UIPasteboard.general.string = text }
            return ToolResult(success: true, text: "已写入剪贴板（\(text.count) 字符）")
        default:
            return ToolResult(success: false, text: "不支持的操作: \(action)")
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
            description: "获取设备信息，包括型号、系统版本、电池、存储等。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "info": JSONSchema.JSONProperty(type: "string", description: "查询项: all/model/os/battery/storage/network/screen", enum: ["all", "model", "os", "battery", "storage", "network", "screen"]),
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
                p.append("型号: \(device.model) (\(device.name))")
            }
            if info == "all" || info == "os" {
                p.append("系统: \(device.systemName) \(device.systemVersion)")
                p.append("标识: \(device.identifierForVendor?.uuidString.prefix(12) ?? "未知")")
            }
            if info == "all" || info == "battery" {
                device.isBatteryMonitoringEnabled = true
                let pct = Int(device.batteryLevel * 100)
                let state: String = {
                    switch device.batteryState {
                    case .unplugged: return "使用电池"
                    case .charging: return "充电中"
                    case .full: return "已充满"
                    default: return "未知"
                    }
                }()
                p.append("电池: \(pct)% (\(state))")
            }
            if info == "all" || info == "screen" {
                let screen = UIScreen.main
                let bounds = screen.bounds
                p.append("屏幕: \(Int(bounds.width))x\(Int(bounds.height)) @ \(Int(screen.scale))x")
            }
            if info == "storage" {
                p.append("🔴 storage 查询需要访问文件系统总空间，暂未实现")
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
            description: "读写健康数据（步数、心率、睡眠等 100+ 类型）。需要 HealthKit 权限。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: "操作: read/write/query", enum: ["read", "write", "query"]),
                    "data_type": JSONSchema.JSONProperty(type: "string", description: "数据类型: step_count/heart_rate/sleep/weight/height/..."),
                    "value": JSONSchema.JSONProperty(type: "number", description: "要写入的值"),
                    "unit": JSONSchema.JSONProperty(type: "string", description: "单位"),
                    "start_date": JSONSchema.JSONProperty(type: "string", description: "查询开始时间"),
                    "end_date": JSONSchema.JSONProperty(type: "string", description: "查询结束时间"),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: "🔴 healthkit 尚未接入。HealthKit 需要 Info.plist 权限声明和用户授权。")
    }
}

// MARK: - 7. apple-homekit (HomeKit)

struct AppleHomeKitTool: AgentTool {
    let name = "apple-homekit"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-homekit",
            description: "控制 HomeKit 智能家居设备（灯光、空调、窗帘等）。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: "操作: list/get/set/control", enum: ["list", "get", "set", "control"]),
                    "device_name": JSONSchema.JSONProperty(type: "string", description: "设备名称"),
                    "characteristic": JSONSchema.JSONProperty(type: "string", description: "特性名称（如 power/ brightness/temperature）"),
                    "value": JSONSchema.JSONProperty(type: "string", description: "目标值"),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: "🔴 homekit 尚未接入。HomeKit 需要 entitlements 和用户授权。")
    }
}

// MARK: - 8. apple-location (CoreLocation)

struct AppleLocationTool: AgentTool {
    let name = "apple-location"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-location",
            description: "获取 GPS 定位和地理编码。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: "操作: current/geocode/reverse_geocode", enum: ["current", "geocode", "reverse_geocode"]),
                    "address": JSONSchema.JSONProperty(type: "string", description: "地址（用于 geocode）"),
                    "latitude": JSONSchema.JSONProperty(type: "number", description: "纬度（用于 reverse_geocode）"),
                    "longitude": JSONSchema.JSONProperty(type: "number", description: "经度（用于 reverse_geocode）"),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: "🔴 location 尚未接入。CoreLocation 需要位置权限授权。")
    }
}

// MARK: - 9. apple-maps (MapKit)

struct AppleMapsTool: AgentTool {
    let name = "apple-maps"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-maps",
            description: "地图服务：POI 搜索、路线规划、ETA 计算。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: "操作: search_poi/route/eta", enum: ["search_poi", "route", "eta"]),
                    "query": JSONSchema.JSONProperty(type: "string", description: "POI 搜索关键词"),
                    "from": JSONSchema.JSONProperty(type: "string", description: "起点坐标（lat,lng）或地址"),
                    "to": JSONSchema.JSONProperty(type: "string", description: "终点坐标或地址"),
                    "transport_type": JSONSchema.JSONProperty(type: "string", description: "交通方式: driving/walking/transit", enum: ["driving", "walking", "transit"]),
                    "limit": JSONSchema.JSONProperty(type: "integer", description: "结果数量上限"),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: "🔴 maps 尚未接入。MapKit 需要位置权限。")
    }
}

// MARK: - 10. apple-media (MediaPlayer)

struct AppleMediaTool: AgentTool {
    let name = "apple-media"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-media",
            description: "控制音乐播放和搜索媒体库。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: "操作: play/pause/next/previous/search/info", enum: ["play", "pause", "next", "previous", "search", "info"]),
                    "query": JSONSchema.JSONProperty(type: "string", description: "搜索关键词"),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: "🔴 media 尚未接入。MediaPlayer 需要 Apple Music 权限。")
    }
}

// MARK: - 11. apple-nfc (CoreNFC)

struct AppleNFCTool: AgentTool {
    let name = "apple-nfc"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-nfc",
            description: "NFC 标签读写，支持 NDEF 和 EMV。需要 CoreNFC 权限。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: "操作: read/write/emv", enum: ["read", "write", "emv"]),
                    "message": JSONSchema.JSONProperty(type: "string", description: "要写入的 NDEF 消息"),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: "🔴 nfc 尚未接入。CoreNFC 需要 NFC entitlement 和硬件支持。")
    }
}

// MARK: - 12. apple-nlp (NaturalLanguage)

struct AppleNLPTool: AgentTool {
    let name = "apple-nlp"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-nlp",
            description: "自然语言处理：语言检测、命名实体识别、情感分析、分词。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: "操作: language/detect_entities/sentiment/tokenize", enum: ["language", "detect_entities", "sentiment", "tokenize"]),
                    "text": JSONSchema.JSONProperty(type: "string", description: "要分析的文本"),
                ],
                required: ["action", "text"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let action = parameters["action"] as? String,
              let text = parameters["text"] as? String else {
            throw ToolError.invalidParameters("缺少 action 或 text 参数")
        }
        switch action {
        case "language":
            let result: String = await MainActor.run {
                let recognizer = NLLanguageRecognizer()
                recognizer.processString(text)
                let lang = recognizer.dominantLanguage?.rawValue ?? "未知"
                let conf = recognizer.languageHypotheses(withMaximum: 3)
                    .map { "\($0.key.rawValue): \(String(format: "%.0f%%", $0.value * 100))" }
                    .joined(separator: ", ")
                return "主语言: \(lang)\n可能性: \(conf)"
            }
            return ToolResult(success: true, text: result)

        case "sentiment":
            let result: String = await MainActor.run {
                let tagger = NLTagger(tagSchemes: [.sentimentScore])
                tagger.string = text
                let (score, _) = tagger.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore)
                let s = Double(score?.rawValue ?? "0") ?? 0
                let label = s > 0.3 ? "正面" : (s < -0.3 ? "负面" : "中性")
                return "情感: \(label) (score: \(String(format: "%.2f", s)))"
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
            return ToolResult(success: true, text: "分词结果 (\(tokens.count) 个): \(tokens.joined(separator: " | "))")

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
                if entities.isEmpty { return "未检测到命名实体" }
                return entities.map { "\($0.key): \($0.value.joined(separator: ", "))" }.joined(separator: "\n")
            }
            return ToolResult(success: true, text: result)

        default:
            return ToolResult(success: false, text: "不支持的操作: \(action)")
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
            description: "发送本地通知推送。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "title": JSONSchema.JSONProperty(type: "string", description: "通知标题"),
                    "body": JSONSchema.JSONProperty(type: "string", description: "通知正文"),
                    "delay_seconds": JSONSchema.JSONProperty(type: "integer", description: "延迟秒数（默认 1）"),
                    "sound": JSONSchema.JSONProperty(type: "string", description: "声音文件名（可选）"),
                ],
                required: ["title", "body"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let title = parameters["title"] as? String,
              let body = parameters["body"] as? String else {
            throw ToolError.invalidParameters("缺少 title 或 body 参数")
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
            return ToolResult(success: true, text: "通知已安排（\(delay)s 后推送）")
        } catch {
            return ToolResult(success: false, text: "通知发送失败: \(error.localizedDescription)")
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
            description: "通过系统 URL Scheme 打开外部应用或网页。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "url": JSONSchema.JSONProperty(type: "string", description: "要打开的 URL（http/https/sms/tel/mailto 等）"),
                ],
                required: ["url"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let urlString = parameters["url"] as? String,
              let url = URL(string: urlString) else {
            throw ToolError.invalidParameters("缺少有效的 url 参数")
        }
        // http/https → 走内置浏览器，不跳 Safari
        if url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https" {
            await MainActor.run { AppState.shared.pendingBrowserURL = url }
            return ToolResult(success: true, text: "已在内置浏览器中打开: \(urlString)")
        }
        let canOpen: Bool = await MainActor.run { UIApplication.shared.canOpenURL(url) }
        guard canOpen else {
            return ToolResult(success: false, text: "无法打开 URL: \(urlString)")
        }
        await MainActor.run { UIApplication.shared.open(url) }
        return ToolResult(success: true, text: "已打开: \(urlString)")
    }
}

// MARK: - 15. apple-photos (Photos)

struct ApplePhotosTool: AgentTool {
    let name = "apple-photos"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-photos",
            description: "读写照片库。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: "操作: list/save/delete", enum: ["list", "save", "delete"]),
                    "path": JSONSchema.JSONProperty(type: "string", description: "图片文件路径（用于 save）"),
                    "limit": JSONSchema.JSONProperty(type: "integer", description: "返回数量上限"),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: "🔴 photos 尚未接入。Photos 框架需要照片库权限授权。")
    }
}

// MARK: - 16. apple-player (AVFoundation)

struct ApplePlayerTool: AgentTool {
    let name = "apple-player"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-player",
            description: "音视频播放器。支持播放本地文件和远程 URL。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: "操作: play/pause/stop/seek", enum: ["play", "pause", "stop", "seek"]),
                    "url": JSONSchema.JSONProperty(type: "string", description: "媒体文件 URL 或路径"),
                    "position": JSONSchema.JSONProperty(type: "number", description: "跳转位置（秒）"),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: "🔴 player 尚未接入。AVFoundation 播放器需要后台音频模式。")
    }
}

// MARK: - 17. apple-reminders (EventKit)

struct AppleRemindersTool: AgentTool {
    let name = "apple-reminders"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-reminders",
            description: "管理提醒事项（创建、查询、完成、删除）。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: "操作: list/create/complete/delete", enum: ["list", "create", "complete", "delete"]),
                    "title": JSONSchema.JSONProperty(type: "string", description: "提醒标题"),
                    "due_date": JSONSchema.JSONProperty(type: "string", description: "截止时间（ISO 8601）"),
                    "reminder_id": JSONSchema.JSONProperty(type: "string", description: "提醒 ID"),
                    "notes": JSONSchema.JSONProperty(type: "string", description: "备注"),
                    "priority": JSONSchema.JSONProperty(type: "integer", description: "优先级（0-9）"),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: "🔴 reminders 尚未接入。EventKit 提醒事项需要权限授权。")
    }
}

// MARK: - 18. apple-speak (AVSpeechSynthesizer)

struct AppleSpeakTool: AgentTool {
    let name = "apple-speak"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-speak",
            description: "文字转语音（TTS），朗读指定文本。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "text": JSONSchema.JSONProperty(type: "string", description: "要朗读的文本"),
                    "language": JSONSchema.JSONProperty(type: "string", description: "语言代码（如 zh-CN, en-US，默认系统语言）"),
                    "rate": JSONSchema.JSONProperty(type: "number", description: "语速（0.0-1.0，默认 0.5）"),
                ],
                required: ["text"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let text = parameters["text"] as? String else {
            throw ToolError.invalidParameters("缺少 text 参数")
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
        return ToolResult(success: true, text: "正在朗读（\(text.count) 字符）")
    }
}

// MARK: - 19. apple-speech (Speech)

struct AppleSpeechTool: AgentTool {
    let name = "apple-speech"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-speech",
            description: "语音识别（STT），将语音转为文字。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "language": JSONSchema.JSONProperty(type: "string", description: "语言代码（如 zh-CN，默认系统语言）"),
                    "duration": JSONSchema.JSONProperty(type: "integer", description: "识别时长（秒，默认 5）"),
                ],
                required: []
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: "🔴 speech 尚未接入。Speech 框架需要麦克风权限和语音识别权限。")
    }
}

// MARK: - 20. apple-vision (Vision)

struct AppleVisionTool: AgentTool {
    let name = "apple-vision"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-vision",
            description: "图像分析：OCR/人脸检测/条形码/物体分类/相似度/拼接。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: "操作: ocr/face_detect/barcode/classify/similarity/stitch", enum: ["ocr", "face_detect", "barcode", "classify", "similarity", "stitch"]),
                    "image_path": JSONSchema.JSONProperty(type: "string", description: "图片文件路径"),
                    "image_path_2": JSONSchema.JSONProperty(type: "string", description: "第二张图片路径（用于 similarity/stitch）"),
                ],
                required: ["action", "image_path"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: "🔴 vision 尚未接入。Vision 框架的图像分析管线待实现。")
    }
}

// MARK: - 21. apple-weather (WeatherKit)

struct AppleWeatherTool: AgentTool {
    let name = "apple-weather"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-weather",
            description: "获取天气数据（当前天气、预报、警报）。需要 WeatherKit 权限。",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: "操作: current/forecast/alerts", enum: ["current", "forecast", "alerts"]),
                    "latitude": JSONSchema.JSONProperty(type: "number", description: "纬度（默认使用当前位置）"),
                    "longitude": JSONSchema.JSONProperty(type: "number", description: "经度（默认使用当前位置）"),
                    "days": JSONSchema.JSONProperty(type: "integer", description: "预报天数（默认 3）"),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: "🔴 weather 尚未接入。WeatherKit 需要 entitlements 和网络权限。")
    }
}
