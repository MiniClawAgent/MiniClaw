import Foundation

// MARK: - miniclaw-ios-cli — iOS 原生能力专用 CLI（Layer 2）
//
// 本 CLI 是「原生能力请求代理」：它描述需要的能力与用途，
// 但**绝不自行发起 iOS 系统授权**——所有涉及系统授权、敏感数据的操作
// 必须路由回宿主 App，由宿主 App 在设备上弹出系统授权弹窗。
// 即：CLI 不得绕过 iOS 权限机制（spec 无头执行安全策略）。

let capabilities = [
    "location": "定位（NSLocationWhenInUseUsageDescription）",
    "bluetooth": "蓝牙（NSBluetoothAlwaysUsageDescription）",
    "health": "健康（NSHealthShare / NSHealthUpdate）",
    "homekit": "HomeKit（NSHomeKitUsageDescription）",
    "calendar": "日历（NSCalendarsUsageDescription）",
    "reminders": "提醒事项（NSRemindersUsageDescription）",
    "microphone": "麦克风（NSMicrophoneUsageDescription）",
    "speech": "语音识别（NSSpeechRecognitionUsageDescription）",
    "camera": "相机（NSCameraUsageDescription）",
    "photos": "照片库（NSPhotoLibraryUsageDescription）",
    "notifications": "通知（NSUserNotificationsUsageDescription）",
    "nfc": "NFC（NFCReaderUsageDescription）",
    "music": "Apple Music（NSAppleMusicUsageDescription）",
    "localnetwork": "本地网络（NSLocalNetworkUsageDescription）"
]

func run() -> Int32 {
    let all = Array(CommandLine.arguments.dropFirst())
    guard !all.isEmpty else { usage(); return 1 }
    let command = all[0]
    let args = Args(Array(all.dropFirst()))

    switch command {
    case "request":
        return request(capability: args.string("capability") ?? args.positionals.first, purpose: args.string("purpose"), args: args)
    case "list":
        return listCapabilities()
    case "availability":
        return availability()
    case "-h", "--help":
        usage(); return 0
    default:
        print(fail("未知命令: \(command)。可用: request / list / availability"))
        return 1
    }
}

/// 请求某原生能力：始终 requiresHostApproval，由宿主 App 兑现。
func request(capability: String?, purpose: String?, args: Args) -> Int32 {
    guard let cap = capability, !cap.isEmpty else {
        print(fail("request 需要 --capability（如 location / photos / camera）")); return 1
    }
    guard capabilities[cap] != nil else {
        print(fail("未知能力: \(cap)。用 list 查看可用能力。")); return 1
    }
    let reason = purpose ?? "Agent 需要使用 \(capabilities[cap] ?? cap)"
    // iOS 域：全部需宿主 App 确认（权限不可由 CLI 绕过）
    switch SecurityGate.classify(domain: "ios", operation: cap) {
    case .direct:
        print(ok(["note": "ios.\(cap) 由宿主 App 执行"])); return 0
    case .requiresHostApproval(_, _):
        if SecurityGate.isApproved(args) {
            print(ok(["note": "ios.\(cap) 已获宿主批准，由宿主 App 发起系统授权"])); return 0
        }
        print(SecurityGate.approvalResponse(domain: "ios", operation: cap,
                                            capability: "ios.\(cap)", reason: reason))
        return 2
    }
}

func listCapabilities() -> Int32 {
    print(ok(["capabilities": capabilities.map { ["key": $0.key, "description": $0.value] }]))
    return 0
}

func availability() -> Int32 {
    // 在 CLI 宿主（macOS / iSH）上无法发起 iOS 系统授权；能力由宿主 App 兑现。
    print(ok([
        "host": "CLI runner (macOS / iSH)",
        "iosPermissionCapable": false,
        "note": "iOS 系统授权须在宿主 App 内由设备发起；本 CLI 仅作为请求代理。"
    ]))
    return 0
}

func usage() {
    print("""
    miniclaw-ios-cli — iOS 原生能力专用 CLI（Layer 2 · 请求代理）

    用法:
      miniclaw-ios-cli <command> [参数]

    命令:
      request --capability <cap> [--purpose <用途>]   请求某原生能力（始终路由宿主 App 确认）
      list                                           列出所有受支持的原生能力
      availability                                   查看 CLI 宿主的能力边界

    说明:
      - 本 CLI 不自行发起任何 iOS 系统授权；凡涉及系统授权/敏感数据的操作，
        均返回 requiresHostApproval，由宿主 App 在设备上弹出系统弹窗。
      - CLI 不得绕过 iOS 权限机制（spec 无头执行安全策略）。
    """)
}

let code = run()
exit(code)
