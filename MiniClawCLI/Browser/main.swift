import Foundation

// MARK: - miniclaw-browser-cli — 浏览器控制专用 CLI（Layer 2）
//
// 只读/可达性检查可无头完成；
// 需要 WKWebView 上下文的交互控制（render/screenshot/click/fill）经 SecurityGate 路由宿主 App。

func run() -> Int32 {
    let all = Array(CommandLine.arguments.dropFirst())
    guard !all.isEmpty else { usage(); return 1 }
    let command = all[0]
    let args = Args(Array(all.dropFirst()))

    switch command {
    case "open", "navigate":
        return check(url: args.string("url") ?? args.positionals.first)
    case "render", "screenshot", "click", "fill":
        return routeToHost(command: command, args: args)
    case "settings":
        return settings()
    case "-h", "--help":
        usage(); return 0
    default:
        print(fail("未知命令: \(command)。可用: open / render / screenshot / click / fill / settings"))
        return 1
    }
}

/// 无头可达性检查：经 HostExecutor 用 curl 探活（不渲染页面）。
func check(url: String?) -> Int32 {
    guard let u = url, !u.isEmpty else { print(fail("需要 --url")); return 1 }
    let safe = u.hasPrefix("http://") || u.hasPrefix("https://") ? u : "https://\(u)"
    let result = HostExecutor.run(command: "curl -sS -o /dev/null -w '%{http_code}' --max-time 15 '\(safe)'",
                                  timeout: 20, workingDirectory: "/var/MiniClaw")
    if result.timedOut { print(fail("可达性检查超时")); return 1 }
    let code = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    print(ok(["url": safe, "httpStatus": code, "reachable": (Int(code) ?? 0) < 400]))
    return result.exitCode == 0 ? 0 : 1
}

/// 交互控制需宿主 App 的 WKWebView：返回 requiresHostApproval。
func routeToHost(command: String, args: Args) -> Int32 {
    switch SecurityGate.classify(domain: "browser", operation: command) {
    case .direct:
        print(ok(["note": "browser.\(command) 由宿主 App 执行"])); return 0
    case .requiresHostApproval(let cap, let reason):
        if SecurityGate.isApproved(args) {
            print(ok(["note": "browser.\(command) 已获宿主批准，交由宿主 App WKWebView 执行"])); return 0
        }
        print(SecurityGate.approvalResponse(domain: "browser", operation: command, capability: cap, reason: reason))
        return 2
    }
}

/// 浏览器设置说明：实际状态由宿主 App 的 SwiftData 管理。
func settings() -> Int32 {
    print(ok([
        "note": "浏览器运行态（当前 URL / 标签 / 历史）由宿主 App 的 WKWebView 管理，CLI 不直接持有。",
        "headlessCapabilities": ["open/reachability-check"],
        "hostAppCapabilities": ["render", "screenshot", "click", "fill", "tab-management"]
    ]))
    return 0
}

func usage() {
    print("""
    miniclaw-browser-cli — 浏览器控制专用 CLI（Layer 2）

    用法:
      miniclaw-browser-cli <command> [参数]

    命令:
      open <url>        无头可达性检查（curl 探活，不渲染）
      render <url>      渲染页面 —— 需宿主 App（WKWebView）
      screenshot <url>  截图 —— 需宿主 App
      click / fill      页面交互 —— 需宿主 App
      settings          查看能力边界说明

    说明:
      - 交互控制返回 requiresHostApproval，由宿主 App 在 WKWebView 上下文执行；
        CLI 不得绕过 iOS 权限机制（spec 无头执行安全策略）。
    """)
}

let code = run()
exit(code)
