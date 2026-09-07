import Foundation
import Network

/// `remote-host`：通过 iSH 内的 SSH 控制远程主机（Mac / Linux / Windows）。
///
/// v0 通道 = iSH 的 openssh-client（`apk add openssh-client`），执行复用
/// `ShellRuntimeFactory.runtime.execute`；产品化 v1 换 App 内嵌 Citadel，
/// 工具面（本 schema）保持不变。
///
/// **主机发现与 IP 自愈（2026-09-07 通用化设计）**：
/// 目标机 IP（DHCP）随时可能变化，工具不依赖写死的 IP——
/// - macOS/Linux 的 SSH 服务会自动广播 Bonjour 服务（`_ssh._tcp.local`），
///   App 层用 `NWBrowser` 浏览并列出局域网内所有可 SSH 的设备（零配置发现）；
/// - `connect` 保存「Bonjour 服务名 + 当时解析的 IP 缓存」；
/// - `exec` 优先用 IP 缓存，**连接类失败自动重新解析服务名 → 更新缓存 → 重试一次**
///   （解析在 App 层完成——iSH 的 DNS 不走 mDNS，解析不了 `.local`，所以 IP
///   必须由 App 解析后以点分形式喂给 iSH 的 ssh）；
/// - 手动路径仍可用：直接传 host=IP（如 Tailscale 的 100.x 固定地址）。
///
/// 职责切分：`setup` 不自己执行 apk/keygen 等长任务——输出精确命令清单交 AI
/// 用 `shell_execute` 跑（iSH 模拟下可能数分钟，塞进工具超时既危险又无进度）。
struct RemoteHostTool: AgentTool {
    /// 远程执行有设备外副作用：与 shell_execute 同样走执行前确认。
    var resumePolicy: ResumePolicy { .requiresUserConfirmation }
    let name = "remote-host"

    private static let configFileName = "remote-hosts.json"
    private static let defaultKeyPath = "~/.ssh/miniclaw"
    private static let bonjourServiceType = "_ssh._tcp."

    private var configURL: URL {
        FileSystemManager.shared.sharedDir.appendingPathComponent(Self.configFileName)
    }

    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "remote-host",
            description: String(localized: "remote_host_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(
                        type: "string",
                        description: String(localized: "remote_host_param_action"),
                        enum: ["setup", "discover", "connect", "exec", "list"]
                    ),
                    "os": JSONSchema.JSONProperty(
                        type: "string",
                        description: String(localized: "remote_host_param_os"),
                        enum: ["macos", "linux", "windows"]
                    ),
                    "name": JSONSchema.JSONProperty(
                        type: "string",
                        description: String(localized: "remote_host_param_name")
                    ),
                    "host": JSONSchema.JSONProperty(
                        type: "string",
                        description: String(localized: "remote_host_param_host")
                    ),
                    "user": JSONSchema.JSONProperty(
                        type: "string",
                        description: String(localized: "remote_host_param_user")
                    ),
                    "port": JSONSchema.JSONProperty(
                        type: "integer",
                        description: String(localized: "remote_host_param_port")
                    ),
                    "key_path": JSONSchema.JSONProperty(
                        type: "string",
                        description: String(localized: "remote_host_param_keypath")
                    ),
                    "command": JSONSchema.JSONProperty(
                        type: "string",
                        description: String(localized: "remote_host_param_command")
                    ),
                    "timeout": JSONSchema.JSONProperty(
                        type: "integer",
                        description: String(localized: "remote_host_param_timeout")
                    ),
                ],
                required: ["action"]
            )
        )
    )

    // MARK: - 入口

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        let action = (parameters["action"] as? String)?.lowercased() ?? ""
        switch action {
        case "setup":    return await setupAction(os: parameters["os"] as? String)
        case "discover": return await discoverAction()
        case "connect":  return await connectAction(parameters)
        case "exec":     return await execAction(parameters)
        case "list":     return listAction()
        default:
            return ToolResult(success: false,
                              text: String(format: String(localized: "remote_host_unknown_action"), action))
        }
    }

    // MARK: - action: setup（自检 + 引导；执行交给 shell_execute）

    private func setupAction(os: String?) async -> ToolResult {
        // 一次性自检：openssh 是否已装、密钥是否已生成、公钥内容
        let check = "which ssh >/dev/null 2>&1 && echo SSH_OK || echo SSH_MISSING; test -f ~/.ssh/miniclaw && echo KEY_OK || echo KEY_MISSING; cat ~/.ssh/miniclaw.pub 2>/dev/null"
        guard let (out, _, _) = await runLocal(check, timeout: 30) else {
            return ToolResult(success: false, text: String(localized: "remote_host_shell_unavailable"))
        }

        let sshInstalled = out.contains("SSH_OK")
        let keyExists = out.contains("KEY_OK")
        let pubkey = out.components(separatedBy: "\n").drop(while: { !$0.hasPrefix("ssh-") }).first

        var lines: [String] = []
        lines.append(String(format: String(localized: "remote_host_setup_status"),
                            sshInstalled ? String(localized: "remote_host_state_installed") : String(localized: "remote_host_state_missing"),
                            keyExists ? String(localized: "remote_host_state_installed") : String(localized: "remote_host_state_missing")))

        // 未就绪：输出「一键安装」组合命令——含 apk 残留锁清理（真机实测：
        // iSH 首启偶发 apk 进程残留占锁，"Unable to lock database"）、安装、
        // 密钥生成、自检回显，AI 一次 shell_execute 即可完成，无需多轮往返。
        guard sshInstalled, keyExists else {
            lines.append(String(localized: "remote_host_setup_combo"))
            lines.append(String(localized: "remote_host_setup_run_first"))
            return ToolResult(success: true, text: lines.joined(separator: "\n"))
        }

        // 环境就绪：按目标 OS 输出「一行命令」——用户在目标电脑粘贴执行即可
        // （开启 SSH 服务端 + 写入公钥一步到位），无需多步骤手动操作。
        let guide: String
        switch (os ?? "macos").lowercased() {
        case "linux":   guide = String(format: String(localized: "remote_host_guide_linux"), pubkey ?? "")
        case "windows": guide = String(format: String(localized: "remote_host_guide_windows"), pubkey ?? "")
        default:        guide = String(format: String(localized: "remote_host_guide_macos"), pubkey ?? "")
        }
        lines.append(guide)
        lines.append(String(localized: "remote_host_setup_next_connect"))
        return ToolResult(success: true, text: lines.joined(separator: "\n\n"))
    }

    // MARK: - action: discover（局域网 Bonjour 发现，零配置列出候选）

    private func discoverAction() async -> ToolResult {
        let services = await Self.discoverSSHServices(timeout: 5)
        if !services.isEmpty {
            let lines = services.map { "- \($0)" }
            return ToolResult(success: true,
                              text: String(localized: "remote_host_discover_header") + "\n" + lines.joined(separator: "\n")
                              + "\n" + String(localized: "remote_host_discover_next"))
        }

        // Bonjour 空（跨网段 / 本地网络权限未授予）≠ 目标机不可达：
        // 自动跑局域网探测（ping + 探 22），把可连接的设备 IP 直接递给 AI。
        let candidates = await Self.healProbeLAN()
        guard !candidates.isEmpty else {
            return ToolResult(success: true, text: String(localized: "remote_host_discover_empty")
                              + "\n" + String(localized: "remote_host_discover_note"))
        }
        let lines = candidates.map { "- \($0)（22 端口开放）" }
        return ToolResult(success: true,
                          text: String(localized: "remote_host_discover_probe_header") + "\n"
                              + lines.joined(separator: "\n")
                              + "\n" + String(localized: "remote_host_discover_next"))
    }

    // MARK: - action: connect（验证 + 锁定配置；host 可省略全自动连接）

    private func connectAction(_ parameters: [String: Any]) async -> ToolResult {
        let name = stringParam(parameters, "name")
        let explicitHost = stringParam(parameters, "host") ?? ""
        let user = stringParam(parameters, "user") ?? ""
        let port = intParam(parameters, "port") ?? 22
        let keyPath = stringParam(parameters, "key_path") ?? Self.defaultKeyPath
        let os = (stringParam(parameters, "os") ?? "macos").lowercased()

        // 候选地址解析顺序（真机 2026-09-07 复盘后定稿）：
        //   ① 已保存配置优先——name（别名）或同 IP 命中已存条目 → 缓存 IP 打头、
        //      bonjourService 记下供自愈。此前 AI 给设备起新别名（如 macbook）后
        //      按名解析 Bonjour 找不到 → 断链落到探测兜底。
        //   ② Bonjour 解析——服务名（name 或 .local 名）拿 v4+v6 全部候选追加。
        //   ③ 显式 host（IP/带 zone 的 v6）插到最前。
        //   ④ 以上全空 → 局域网探测兜底。
        // 解析在 App 层完成——iSH 的 DNS 不走 mDNS。同一设备的多个地址指向同一终端，
        // 依次尝试直到连通（v4 优先，v6 带 zone id 亦可直连）。
        var bonjourService: String? = nil
        var addressCandidates: [String] = []

        // ① 已保存配置优先
        let savedHosts = Self.loadHosts().hosts
        let matched = savedHosts.first { h in
            (name != nil && h.name == name) || (!explicitHost.isEmpty && explicitHost == h.host)
        }
        if let matched {
            bonjourService = matched.bonjourService
            if !matched.host.isEmpty { addressCandidates.append(matched.host) }
        }

        // ② Bonjour 解析（跳过条件：name 就是已存配置的别名而非 Bonjour 服务名——
        //    按别名查服务必然空手，白等超时）
        let aliasNotServiceName = matched != nil && name == matched!.name && name != matched!.bonjourService
        if explicitHost.isEmpty || explicitHost.hasSuffix(".local") {
            let serviceCandidate = (explicitHost.isEmpty ? (name ?? bonjourService ?? "") : explicitHost)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let service = serviceCandidate.hasSuffix(".local")
                ? String(serviceCandidate.dropLast(6)) : serviceCandidate
            if !service.isEmpty, !aliasNotServiceName {
                bonjourService = bonjourService ?? service
                for addr in await Self.resolveBonjourAddresses(service) where !addressCandidates.contains(addr) {
                    addressCandidates.append(addr)
                }
            }
        }
        // ③ 显式 host（IP/带 zone 的 v6）单独成候选
        if !explicitHost.isEmpty, !addressCandidates.contains(explicitHost) {
            addressCandidates.insert(explicitHost, at: 0)
        }
        // ④ 解析一无所获 → 局域网探测兜底
        if addressCandidates.isEmpty {
            let candidates = await Self.healProbeLAN()
            switch candidates.count {
            case 1: addressCandidates = candidates
            case 0:
                return ToolResult(success: false,
                                  text: String(localized: "remote_host_discover_empty") + "\n"
                                      + String(localized: "remote_host_heal_none"))
            default:
                return ToolResult(success: false,
                                  text: String(format: String(localized: "remote_host_heal_candidates"),
                                               candidates.joined(separator: "、")))
            }
        }
        guard !addressCandidates.isEmpty else {
            return ToolResult(success: false, text: String(localized: "remote_host_connect_need_host"))
        }
        guard !user.isEmpty else {
            return ToolResult(success: false, text: String(localized: "remote_host_connect_need_user"))
        }
        let alias = name ?? addressCandidates[0]

        // 依次尝试全部候选地址（v4 优先、v6 带 zone 次之），首个连通者锁定为 host。
        var host = addressCandidates[0]
        var ok = false
        var lastOutput = ""
        for candidate in addressCandidates {
            let probe = Self.sshCommand(user: user, host: candidate, port: port, keyPath: keyPath,
                                        command: "echo ok && uname -s")
            let probeResult = await runLocal(probe, timeout: 90)
            let reached = probeResult?.exitCode == 0 && probeResult?.stdout.contains("ok") == true
            let output = probeResult.map { $0.stdout.isEmpty ? $0.stderr : $0.stdout } ?? ""
            if reached {
                host = candidate
                ok = true
                break
            }
            if lastOutput.isEmpty { lastOutput = output }
        }

        // 自愈第一层（换网场景，真机 2026-09-07）：缓存候选全失败 → **强制重新解析**
        //（热点/换网后缓存 IP 必失效，旧地址重试无意义），新地址逐个探活，
        // 首个连通者即为目标。
        var healNote = ""
        if !ok, let svc = bonjourService {
            let fresh = await Self.resolveBonjourAddresses(svc).filter { !addressCandidates.contains($0) }
            for candidate in fresh {
                let retry = Self.sshCommand(user: user, host: candidate, port: port, keyPath: keyPath,
                                            command: "echo ok && uname -s")
                if let r2 = await runLocal(retry, timeout: 90), r2.exitCode == 0, r2.stdout.contains("ok") {
                    host = candidate
                    ok = true
                    healNote = String(format: String(localized: "remote_host_heal_found"), candidate)
                    break
                }
            }
        }

        // 自愈第二层：局域网探测（跨网段 mDNS 盲区 / DHCP 换 IP / 网段未知三种场景全覆盖）。
        // 唯一候选自动重连；多候选列出让用户确认；无候选返回探测结论。
        if !ok {
            let candidates = await Self.healProbeLAN()
            if candidates.count == 1 {
                let ip = candidates[0]
                let retry = Self.sshCommand(user: user, host: ip, port: port, keyPath: keyPath,
                                            command: "echo ok && uname -s")
                if let r2 = await runLocal(retry, timeout: 90), r2.exitCode == 0, r2.stdout.contains("ok") {
                    host = ip
                    ok = true
                    healNote = String(format: String(localized: "remote_host_heal_found"), ip)
                } else {
                    healNote = String(format: String(localized: "remote_host_heal_candidates"), ip)
                }
            } else if candidates.count > 1 {
                healNote = String(format: String(localized: "remote_host_heal_candidates"),
                                  candidates.joined(separator: "、"))
            } else {
                healNote = String(localized: "remote_host_heal_none")
            }
        }

        if !ok {
            // 失败输出附全部候选（同一设备的 v4/v6 指向同一终端，AI 可指定 host 逐个重试）
            var text = String(localized: "remote_host_connect_failed") + "\n" + lastOutput + "\n"
                + String(format: String(localized: "remote_host_candidates_tried"),
                         addressCandidates.joined(separator: "、"))
            if !healNote.isEmpty { text += "\n" + healNote }
            return ToolResult(success: false, text: text)
        }

        var file = Self.loadHosts()
        var hosts = file.hosts
        hosts.removeAll { $0.name == alias }
        hosts.append(HostConfig(name: alias, host: host, user: user, port: port,
                                keyPath: keyPath, os: os, bonjourService: bonjourService))
        file.hosts = hosts
        guard Self.saveHosts(file) else {
            return ToolResult(success: false, text: String(localized: "remote_host_config_write_failed"))
        }
        return ToolResult(success: true,
                          text: String(format: String(localized: "remote_host_connect_ok"), alias, host, user)
                              + (healNote.isEmpty ? "" : "\n" + healNote))
    }

    // MARK: - action: exec（远程执行 + IP 自愈重试）

    private func execAction(_ parameters: [String: Any]) async -> ToolResult {
        guard let command = stringParam(parameters, "command"), !command.isEmpty else {
            return ToolResult(success: false, text: String(localized: "remote_host_exec_need_command"))
        }
        let file = Self.loadHosts()
        guard !file.hosts.isEmpty else {
            return ToolResult(success: false, text: String(localized: "remote_host_no_host"))
        }

        let name = stringParam(parameters, "name")
        let host: HostConfig
        if let name, !name.isEmpty {
            guard let matched = file.hosts.first(where: { $0.name == name }) else {
                return ToolResult(success: false, text: String(localized: "remote_host_no_host"))
            }
            host = matched
        } else if file.hosts.count == 1 {
            host = file.hosts[0]
        } else {
            let names = file.hosts.map(\.name).joined(separator: "、")
            return ToolResult(success: false,
                              text: String(format: String(localized: "remote_host_ambiguous"), names))
        }

        let timeout = intParam(parameters, "timeout") ?? 180
        var currentHost = host.host
        var configDirty = false
        var last: (stdout: String, stderr: String, exitCode: Int32)? = nil

        // 自愈阶梯（最多 3 次尝试）：直连 → Bonjour 重解析（IP 自愈）→ 局域网探测。
        // 只有「连接类失败」才进入下一级；命令可能非幂等，非连接失败绝不重试。
        for attempt in 1...3 {
            let cmd = Self.sshCommand(user: host.user, host: currentHost, port: host.port,
                                      keyPath: host.keyPath, command: command)
            guard let r = await runLocal(cmd, timeout: TimeInterval(timeout)) else {
                break // 真超时（执行预算耗尽），不再重试
            }
            last = r
            if r.exitCode == 0 { break }
            if !Self.looksLikeConnectionFailure(r.stdout + r.stderr) { break }

            if attempt == 1, let bonjour = host.bonjourService {
                // 重新解析设备的全部候选地址（v4+v6），逐个探活（echo ok），
                // 首个存活者切为目标并 continue 重跑真命令——probe 不产生副作用。
                let candidates = await Self.resolveBonjourAddresses(bonjour)
                    .filter { $0 != currentHost }
                var healed: String?
                for candidate in candidates {
                    let probe = Self.sshCommand(user: host.user, host: candidate, port: host.port,
                                                keyPath: host.keyPath, command: "echo ok")
                    if let r = await runLocal(probe, timeout: 30), r.exitCode == 0, r.stdout.contains("ok") {
                        healed = candidate
                        break
                    }
                }
                if let fresh = healed {
                    currentHost = fresh
                    configDirty = true
                    continue
                }
            }
            if attempt <= 2 {
                let candidates = await Self.healProbeLAN()
                if let pick = candidates.first(where: { $0 != currentHost }) {
                    currentHost = pick
                    configDirty = true
                    continue
                }
                break
            }
        }

        // 持久化自愈后的地址
        if configDirty {
            var file2 = Self.loadHosts()
            file2.hosts.removeAll { $0.name == host.name }
            file2.hosts.append(HostConfig(name: host.name, host: currentHost, user: host.user,
                                          port: host.port, keyPath: host.keyPath, os: host.os,
                                          bonjourService: host.bonjourService))
            _ = Self.saveHosts(file2)
        }

        guard let last else {
            return ToolResult(success: false, text: String(localized: "remote_host_exec_timeout"))
        }
        return ToolResult(success: last.exitCode == 0,
                          text: last.stdout.isEmpty ? String(localized: "no_output") : last.stdout)
    }

    /// 连接类失败判定：只有这类失败才值得走 IP 自愈重试。
    private static func looksLikeConnectionFailure(_ text: String) -> Bool {
        let markers = ["Connection timed out", "No route to host", "Connection refused",
                       "Could not resolve hostname", "connect to host"]
        return markers.contains { text.localizedCaseInsensitiveContains($0) }
    }

    // MARK: - 局域网探测自愈（discover 跨网段失效 / DHCP 换 IP 的兜底）

    /// 从 DNS 配置推断网段 → 并发 ping 找存活 → 并发 nc 探 22 端口。
    /// 真机会话验证过：iSH 里 ping/nc 可用，两个 /24 段 3 秒内扫完。
    /// 返回开 22 端口的 IP 列表（排序去重）。
    private static func healProbeLAN() async -> [String] {
        // 网段由 App 层 getifaddrs 实时提供（真机 2026-09-07：iSH 的 resolv.conf
        // 不随网络切换更新——在家装的 iSH 出门后仍推断家里网段，热点下扫了个寂寞）。
        let prefixes = currentLANIPv4Prefixes()
        guard !prefixes.isEmpty else { return [] }
        let script = """
        OUT=/tmp/remote_heal.txt
        : > $OUT
        for s in \(prefixes.joined(separator: " ")); do
          for i in $(seq 1 254); do
            ( ping -c 1 -W 1 $s.$i >/dev/null 2>&1 && echo $s.$i >> $OUT ) &
          done
          wait
        done
        sort -t. -k4 -n -u $OUT | while read ip; do
          ( nc -z -w 2 $ip 22 >/dev/null 2>&1 && echo ">>> $ip OPEN" ) &
        done
        wait
        echo HEAL_DONE
        """
        guard let (out, _, _) = await runLocalStatic(script, timeout: 90),
              out.contains("HEAL_DONE") else {
            return []
        }
        let ips = out.components(separatedBy: "\n")
            .filter { $0.hasPrefix(">>> ") && $0.hasSuffix(" OPEN") }
            .compactMap { $0.split(separator: " ").dropFirst().first }
            .map { String($0) }
            .sorted()
        return ips
    }

    /// App 层枚举本机全部 IPv4 网段前缀（排除回环与链路本地）。
    /// getifaddrs 反映**当前实时**网络：Wi-Fi→家里网段、热点→172.20.10.x，随切换更新。
    private static func currentLANIPv4Prefixes() -> [String] {
        var prefixes: [String] = []
        var seen = Set<String>()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cursor {
            if p.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET) {
                var sa = sockaddr_in()
                memcpy(&sa, p.pointee.ifa_addr, min(Int(p.pointee.ifa_addr.pointee.sa_len), MemoryLayout<sockaddr_in>.size))
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &sa.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
                let ip = String(cString: buf)
                // 排除回环与 IPv4 链路本地
                if !ip.hasPrefix("127."), !ip.hasPrefix("169.254.") {
                    let parts = ip.split(separator: ".")
                    if parts.count == 4 {
                        let prefix = parts.dropLast().joined(separator: ".")
                        if seen.insert(prefix).inserted { prefixes.append(prefix) }
                    }
                }
            }
            cursor = p.pointee.ifa_next
        }
        return prefixes
    }

    /// 同步包装（工具方法均为 async，NSLock 不可用于 async 上下文——本函数无锁需求）。
    private static func runLocalStatic(_ command: String, timeout: TimeInterval) async -> (stdout: String, stderr: String, exitCode: Int32)? {
        do {
            let result = try await ShellRuntimeFactory.runtime.execute(
                command: command,
                environment: [:],
                workingDirectory: nil,
                timeout: timeout,
                onLine: nil,
                sessionID: nil
            )
            return (result.stdout, result.stderr, result.exitCode)
        } catch {
            AppLogger.shared.error("[RemoteHost] 探测执行失败: \(error.localizedDescription)", category: "RemoteHost")
            return nil
        }
    }

    // MARK: - action: list

    private func listAction() -> ToolResult {
        let file = Self.loadHosts()
        guard !file.hosts.isEmpty else {
            return ToolResult(success: true, text: String(localized: "remote_host_no_host"))
        }
        let lines = file.hosts.map { h in
            "\(h.name): \(h.user)@\(h.host):\(h.port) [\(h.os)]" + (h.bonjourService.map { " service=\($0)" } ?? "")
        }
        return ToolResult(success: true,
                          text: String(localized: "remote_host_list_header") + "\n" + lines.joined(separator: "\n"))
    }

    // MARK: - Bonjour 发现与解析（App 层；iSH 解析不了 mDNS，IP 由这里喂给 ssh）

    /// NWBrowser 回调是 @Sendable——Swift 6 下不可捕获普通可变局部变量。
    /// 回调实际全部运行在主队列（browser.start(queue: .main)），
    /// 用 nonisolated(unsafe) 局部状态承载（官方逃生舱）；resumed 保证只 resume 一次。
    private struct BonjourProbe {
        nonisolated(unsafe) var browser: NWBrowser? = nil
        nonisolated(unsafe) var connection: NWConnection? = nil
        nonisolated(unsafe) var resumed = false
        nonisolated(unsafe) var names: Set<String> = []
    }

    /// 浏览局域网内所有 `_ssh._tcp` 服务（macOS 远程登录 / Linux avahi 自动广播）。
    /// 返回服务名列表（即 connect 的 name / bonjourService 候选）。
    static func discoverSSHServices(timeout: TimeInterval) async -> [String] {
        nonisolated(unsafe) var probe = BonjourProbe()
        return await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            let finish: @Sendable () -> Void = {
                guard !probe.resumed else { return }
                probe.resumed = true
                probe.browser?.cancel()
                probe.connection?.cancel()
                cont.resume(returning: probe.names.sorted())
            }
            let browser = NWBrowser(for: .bonjour(type: Self.bonjourServiceType, domain: "local."), using: .tcp)
            probe.browser = browser
            browser.browseResultsChangedHandler = { results, _ in
                for r in results {
                    if case let .service(name, _, _, _) = r.endpoint {
                        probe.names.insert(name)
                    }
                }
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { finish() }
            }
            browser.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish() }
        }
    }

    /// 解析 Bonjour 服务实例为该设备的**全部地址**（真机教训 2026-09-07：单地址解析
    /// 会拿到 IPv6 link-local 且此前把 zone id（%en0）剥掉 → ssh「Host is unreachable」。
    /// 链路本地地址必须带 zone 才可路由；同一设备的 v4/v6 指向同一终端，全部返回、
    /// 由 connect/exec 依次尝试，失败时 AI 在输出里可见全部候选自行判断）。
    ///
    /// 实现：DNSServiceResolve 拿 mDNS 主机名（实例名 ≠ 主机名，中文电脑名会被系统
    /// ASCII 化，不能直接拼 .local）→ getaddrinfo(AF_UNSPEC) 一次取回 v4+v6
    /// （iOS 系统层对 .local 域自动走 mDNS）。返回顺序：v4 在前（iSH 下最稳）、
    /// v6 在后（link-local 已拼 zone id）。
    static func resolveBonjourAddresses(_ serviceName: String, timeout: TimeInterval = 6) async -> [String] {
        // 主路径：NetService 拿主机名 → getaddrinfo 展开全部地址。
        // 但 NetService.resolve 依赖 runloop——放在 global queue（无 runloop）时可能
        // 静默失败（真机 2026-09-07 热点场景实测）→ 失败/空结果时回退 NWConnection
        // 直连 trick（拿当前可达的单地址，实测可用）。
        if let hostname = await Self.resolveServiceHostname(serviceName, timeout: timeout) {
            let addrs = Self.allAddresses(ofHost: hostname)
            if !addrs.isEmpty { return addrs }
        }
        if let single = await Self.resolveViaConnection(serviceName, timeout: timeout) {
            return [single]
        }
        return []
    }

    /// NWConnection 兜底：直连 service endpoint，从 remoteEndpoint 拿**当前可达**地址。
    /// v6 链路本地拼上当前接口名（zone id）——没有 zone 的 fe80:: 无法路由。
    private static func resolveViaConnection(_ serviceName: String, timeout: TimeInterval) async -> String? {
        nonisolated(unsafe) var probe = BonjourProbe()
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let finish: @Sendable (String?) -> Void = { ip in
                guard !probe.resumed else { return }
                probe.resumed = true
                probe.browser?.cancel()
                probe.connection?.cancel()
                cont.resume(returning: ip)
            }
            let browser = NWBrowser(for: .bonjour(type: Self.bonjourServiceType, domain: "local."), using: .tcp)
            probe.browser = browser
            browser.browseResultsChangedHandler = { results, _ in
                guard probe.connection == nil else { return }
                for result in results {
                    if case let .service(name, _, _, _) = result.endpoint, name == serviceName {
                        let conn = NWConnection(to: result.endpoint, using: .tcp)
                        probe.connection = conn
                        conn.stateUpdateHandler = { state in
                            switch state {
                            case .ready:
                                if let ep = conn.currentPath?.remoteEndpoint,
                                   case let .hostPort(host, _) = ep {
                                    var ip = "\(host)"
                                    // 链路本地 v6 必须带 zone（当前接口名）才可路由
                                    if ip.hasPrefix("fe80::"),
                                       let ifname = conn.currentPath?.availableInterfaces.first?.name {
                                        ip += "%" + ifname
                                    }
                                    finish(ip)
                                } else {
                                    finish(nil)
                                }
                            case .failed, .waiting, .cancelled:
                                finish(nil)
                            default: break
                            }
                        }
                        conn.start(queue: .main)
                        break
                    }
                }
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { finish(nil) }
            }
            browser.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    /// DNSServiceResolve：服务实例名 → mDNS 主机名（target）。
    ///
    /// 实现说明（2026-09-07）：首版用 dnssd C 回调 + Unmanaged box + 静态注册表，
    /// 结果①真机双重 resume 闪退、②连编译器 SendNonSendable pass 都被这个复杂
    /// 组合搞崩（swift-frontend stack dump）。改用 **NetService.resolve(withTimeout:)**
    /// ——同步阻塞、自带超时、无回调无生命周期管理；同步阻塞放在全局并发队列
    /// （非 Swift 协作线程池）上跑，await 包装不卡协程。
    private static func resolveServiceHostname(_ serviceName: String, timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let service = NetService(domain: "local.", type: Self.bonjourServiceType, name: serviceName)
                service.resolve(withTimeout: timeout)
                // resolve 返回即已完成或超时；hostName 形如 "Xxx.local."（getaddrinfo 两种都接受）
                cont.resume(returning: service.hostName)
            }
        }
    }

    /// getaddrinfo(AF_UNSPEC) 取回主机的全部地址：v4 点分 + v6（link-local 拼 zone）。
    private static func allAddresses(ofHost hostname: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(hostname, nil, &hints, &info) == 0, let first = info else { return [] }
        defer { freeaddrinfo(first) }

        var v4: [String] = []
        var v6: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let p = cursor {
            switch Int32(p.pointee.ai_family) {
            case AF_INET:
                var sa = sockaddr_in()
                memcpy(&sa, p.pointee.ai_addr, min(Int(p.pointee.ai_addrlen), MemoryLayout<sockaddr_in>.size))
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &sa.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
                v4.append(String(cString: buf))
            case AF_INET6:
                var sa6 = sockaddr_in6()
                memcpy(&sa6, p.pointee.ai_addr, min(Int(p.pointee.ai_addrlen), MemoryLayout<sockaddr_in6>.size))
                var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                inet_ntop(AF_INET6, &sa6.sin6_addr, &buf, socklen_t(INET6_ADDRSTRLEN))
                var ip = String(cString: buf)
                // 链路本地（fe80::）必须带 zone id 才可路由：sin6_scope_id 即接口 index
                if sa6.sin6_scope_id != 0 {
                    var ifname = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(sa6.sin6_scope_id, &ifname) != nil {
                        ip += "%" + String(cString: ifname)
                    }
                }
                v6.append(ip)
            default:
                break
            }
            cursor = p.pointee.ai_next
        }
        return v4 + v6
    }

    // MARK: - 本地执行（iSH 通道，与 shell_execute 同一运行时）

    private func runLocal(_ command: String, timeout: TimeInterval) async -> (stdout: String, stderr: String, exitCode: Int32)? {
        do {
            let result = try await ShellRuntimeFactory.runtime.execute(
                command: command,
                environment: [:],
                workingDirectory: nil,
                timeout: timeout,
                onLine: nil,
                sessionID: nil
            )
            return (result.stdout, result.stderr, result.exitCode)
        } catch {
            AppLogger.shared.error("[RemoteHost] 本地执行失败: \(error.localizedDescription)", category: "RemoteHost")
            return nil
        }
    }

    // MARK: - 配置文件（shared/remote-hosts.json，跨会话共享）

    private struct HostConfig: Codable {
        var name: String
        var host: String
        var user: String
        var port: Int
        var keyPath: String
        var os: String
        /// Bonjour 服务名（非 nil 时 exec 失败可自动重新解析 IP 自愈）。
        var bonjourService: String?

        static let defaultKeyPathStatic = "~/.ssh/miniclaw"

        init(name: String, host: String, user: String, port: Int, keyPath: String, os: String, bonjourService: String? = nil) {
            self.name = name; self.host = host; self.user = user
            self.port = port; self.keyPath = keyPath; self.os = os
            self.bonjourService = bonjourService
        }

        // 外部 JSON 解码纪律：全字段 decodeIfPresent + 默认值（见工程记忆 §7）
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
            user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
            port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
            keyPath = try c.decodeIfPresent(String.self, forKey: .keyPath) ?? Self.defaultKeyPathStatic
            os = try c.decodeIfPresent(String.self, forKey: .os) ?? "macos"
            bonjourService = try c.decodeIfPresent(String.self, forKey: .bonjourService)
        }

        enum CodingKeys: String, CodingKey {
            case name, host, user, port
            case keyPath = "key_path"
            case os
            case bonjourService = "bonjour_service"
        }
    }

    private struct HostsFile: Codable {
        var hosts: [HostConfig] = []
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            hosts = try c.decodeIfPresent([HostConfig].self, forKey: .hosts) ?? []
        }
        enum CodingKeys: String, CodingKey { case hosts }
    }

    private static func loadHosts() -> HostsFile {
        let url = FileSystemManager.shared.sharedDir.appendingPathComponent(configFileName)
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(HostsFile.self, from: data) else {
            return HostsFile()
        }
        return file
    }

    private static func saveHosts(_ file: HostsFile) -> Bool {
        let dir = FileSystemManager.shared.sharedDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(configFileName)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(file)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            AppLogger.shared.error("[RemoteHost] 配置写入失败: \(error.localizedDescription)", category: "RemoteHost")
            return false
        }
    }

    // MARK: - 辅助

    private func stringParam(_ parameters: [String: Any], _ key: String) -> String? {
        (parameters[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func intParam(_ parameters: [String: Any], _ key: String) -> Int? {
        switch parameters[key] {
        case let v as Int: return v
        case let v as Double: return Int(v)
        case let v as String: return Int(v)
        default: return nil
        }
    }

    /// 拼 ssh 命令：accept-new 首连免交互、ConnectTimeout 防卡死、BatchMode 防密码提示挂起、
    /// 远程命令整体单引号包裹（内部单引号按 POSIX 规则转义）。keyPath 含 ~ 不加引号（交由 shell 展开）。
    ///
    /// ⚠️ 禁止加 ControlMaster/ControlPath（2026-09-07 真机实测）：iSH 无法创建
    /// unix domain socket（unix_listener: cannot bind ... Operation not permitted，
    /// ssh 直接致命退出）。iSH 下完整握手实测仅 ~3 秒，不需要连接复用。
    private static func sshCommand(user: String, host: String, port: Int, keyPath: String, command: String) -> String {
        let escaped = command.replacingOccurrences(of: "'", with: "'\\''")
        var parts = ["ssh", "-i", keyPath,
                     "-o", "StrictHostKeyChecking=accept-new",
                     "-o", "ConnectTimeout=10",
                     "-o", "BatchMode=yes"]
        if port != 22 { parts += ["-p", String(port)] }
        parts.append("\(user)@\(host)")
        parts.append("'\(escaped)'")
        return parts.joined(separator: " ")
    }
}
