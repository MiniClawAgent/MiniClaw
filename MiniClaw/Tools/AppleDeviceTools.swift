import Foundation
import UIKit
import AVFoundation
import NaturalLanguage
import UserNotifications

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
                p.append(String(format: L10n.l("device_identifier_label"), device.identifierForVendor.map { String($0.uuidString.prefix(12)) } ?? L10n.l("unknown")))
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

