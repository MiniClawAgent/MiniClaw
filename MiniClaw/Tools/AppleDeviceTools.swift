import Foundation
import Network
import UIKit
import AVFoundation
import NaturalLanguage
import UserNotifications

// MARK: - 1. apple-alarm

// 注：apple-alarm 已移除——iOS 没有第三方读写系统闹钟的公开 API
// （macOS/快捷指令侧另有通路，iOS 照搬不了）。
// 定时提醒需求走 `apple-notification`（本地通知）或 `apple-reminders`。

// MARK: - 2. apple-bluetooth (CoreBluetooth)

// 注：apple-bluetooth 已移除——BLE 中心态机（扫描/连接/特征读写/订阅）工作量大，
// v1 用不上，且会额外索取蓝牙权限、易引审核问询。

// MARK: - 3. apple-calendar (EventKit)

// 注：apple-calendar 的真实现已迁至 CalendarTools.swift（此处占位实现已删除）。

// MARK: - 4. apple-clipboard (UIKit UIPasteboard)

struct AppleClipboardTool: AgentTool {
    let name = "apple-clipboard"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-clipboard",
            description: String(localized: "clipboard_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: String(localized: "op_health_actions"), enum: ["read", "write"]),
                    "text": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_write_text")),
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
        case "read":
            let text: String = await MainActor.run { UIPasteboard.general.string ?? String(localized: "clipboard_empty") }
            if text == String(localized: "clipboard_empty") {
                return ToolResult(success: true, text: text)
            }
            return ToolResult(success: true, text: text)
        case "write":
            guard let text = parameters["text"] as? String else {
                return ToolResult(success: false, text: String(localized: "err_missing_text"))
            }
            await MainActor.run { UIPasteboard.general.string = text }
            return ToolResult(success: true, text: String(format: String(localized: "apple_clipboard_written"), text.count))
        default:
            return ToolResult(success: false, text: String(format: String(localized: "apple_unsupported_action"), action))
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
            description: String(localized: "device_info_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "info": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_query_items"), enum: ["all", "model", "os", "battery", "storage", "network", "screen"]),
                ],
                required: []
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        let info = (parameters["info"] as? String) ?? "all"
        // 网络探测是 async：先算好再进 MainActor 组装（MainActor.run 不收 async 闭包）
        let networkText: String? = (info == "all" || info == "network")
            ? await Self.currentNetworkDescription() : nil
        let parts: [String] = await MainActor.run {
            let device = UIDevice.current
            var p: [String] = []
            if info == "all" || info == "model" {
                p.append(String(format: String(localized: "apple_device_model"), device.model, device.name))
            }
            if info == "all" || info == "os" {
                p.append(String(format: String(localized: "apple_system"), device.systemName, device.systemVersion))
                p.append(String(format: String(localized: "device_identifier_label"), device.identifierForVendor.map { String($0.uuidString.prefix(12)) } ?? String(localized: "unknown")))
            }
            if info == "all" || info == "battery" {
                device.isBatteryMonitoringEnabled = true
                let pct = Int(device.batteryLevel * 100)
                let state: String = {
                    switch device.batteryState {
                    case .unplugged: return String(localized: "battery_usage")
                    case .charging: return String(localized: "charging_status")
                    case .full: return String(localized: "battery_full")
                    default: return String(localized: "unknown")
                    }
                }()
                p.append(String(format: String(localized: "apple_battery"), pct, state))
            }
            if info == "all" || info == "screen" {
                let screen = UIScreen.main
                let bounds = screen.bounds
                p.append(String(format: String(localized: "apple_screen"), Int(bounds.width), Int(bounds.height), Int(screen.scale)))
            }
            if let networkText {
                p.append(networkText)
            }
            if info == "storage" {
                p.append(String(localized: "not_implemented_storage"))
            }
            return p
        }
        return ToolResult(success: true, text: parts.joined(separator: "\n"))
    }

    /// 单次 NWPathMonitor 探测：网络类型 + 连接状态 + 省电/低数据标记。
    private static func currentNetworkDescription() async -> String {
        nonisolated(unsafe) var resumed = false
        nonisolated(unsafe) var monitorRef: NWPathMonitor? = nil
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            let finish: @Sendable (String) -> Void = { text in
                guard !resumed else { return }
                resumed = true
                monitorRef?.cancel()
                cont.resume(returning: text)
            }
            let monitor = NWPathMonitor()
            monitorRef = monitor
            monitor.pathUpdateHandler = { path in
                let kind: String
                if path.usesInterfaceType(.wifi) { kind = "Wi-Fi" }
                else if path.usesInterfaceType(.cellular) { kind = String(localized: "net_kind_cellular") }
                else if path.usesInterfaceType(.wiredEthernet) { kind = String(localized: "net_kind_wired") }
                else if path.status == .unsatisfied { kind = String(localized: "net_kind_none") }
                else { kind = String(localized: "net_kind_other") }
                let status = path.status == .satisfied
                    ? String(localized: "net_status_connected")
                    : String(localized: "net_status_disconnected")
                var extra = ""
                if path.isExpensive { extra = String(localized: "net_extra_expensive") }
                else if path.isConstrained { extra = String(localized: "net_extra_constrained") }
                finish("\(kind) · \(status)\(extra)")
            }
            monitor.start(queue: DispatchQueue.global(qos: .utility))
        }
    }
}

