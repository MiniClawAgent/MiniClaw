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

        // 精确命令清单：缺什么补什么（AI 拿去用 shell_execute 执行）
        if !sshInstalled {
            lines.append(String(localized: "remote_host_setup_cmd_apk"))
        }
        if !keyExists {
            lines.append(String(localized: "remote_host_setup_cmd_keygen"))
        }
        if let pubkey {
            lines.append(String(localized: "remote_host_setup_key_pub_header"))
            lines.append(pubkey)
        }

        // 环境未就绪：到此为止，AI 执行完上面的命令后再回来重新 setup
        guard sshInstalled, keyExists else {
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
        guard !services.isEmpty else {
            // mDNS 发现在跨网段 / 本地网络权限未授予时会扫不到——不代表目标机不可达。
            // 直接 connect（传 IP 或不传 host 让工具自动探测网段）仍可成功。
            return ToolResult(success: true, text: String(localized: "remote_host_discover_empty")
                              + "\n" + String(localized: "remote_host_discover_note"))
        }
        let lines = services.map { "- \($0)" }
        return ToolResult(success: true,
                          text: String(localized: "remote_host_discover_header") + "\n" + lines.joined(separator: "\n")
                          + "\n" + String(localized: "remote_host_discover_next"))
    }

    // MARK: - action: connect（验证 + 锁定配置）

    private func connectAction(_ parameters: [String: Any]) async -> ToolResult {
        let name = stringParam(parameters, "name")
        var host = stringParam(parameters, "host") ?? ""
        let user = stringParam(parameters, "user") ?? ""
        let port = intParam(parameters, "port") ?? 22
        let keyPath = stringParam(parameters, "key_path") ?? Self.defaultKeyPath
        let os = (stringParam(parameters, "os") ?? "macos").lowercased()

        // 通用路径：host 未给（或以 .local 结尾）→ 用 Bonjour 发现/解析拿当前 IP。
        // Bonjour 服务名优先取 name；host 为 .local 名时也走解析。
        var bonjourService: String? = nil
        if host.isEmpty || host.hasSuffix(".local") {
            let serviceCandidate = (host.isEmpty ? (name ?? "") : host)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            bonjourService = serviceCandidate.hasSuffix(".local")
                ? String(serviceCandidate.dropLast(6)) : serviceCandidate
            guard let service = bonjourService, !service.isEmpty else {
                return ToolResult(success: false, text: String(localized: "remote_host_connect_need_host"))
            }
            guard let ip = await Self.resolveBonjourHost(service) else {
                return ToolResult(success: false,
                                  text: String(localized: "remote_host_resolve_failed") + " "
                                      + String(localized: "remote_host_discover_hint"))
            }
            host = ip
        }
        guard !host.isEmpty else {
            return ToolResult(success: false, text: String(localized: "remote_host_connect_need_host"))
        }
        guard !user.isEmpty else {
            return ToolResult(success: false, text: String(localized: "remote_host_connect_need_user"))
        }
        let alias = name ?? host

        let probe = Self.sshCommand(user: user, host: host, port: port, keyPath: keyPath,
                                    command: "echo ok && uname -s")
        let probeResult = await runLocal(probe, timeout: 90)
        var ok = probeResult?.exitCode == 0 && probeResult?.stdout.contains("ok") == true
        var lastOutput = probeResult.map { $0.stdout.isEmpty ? $0.stderr : $0.stdout } ?? ""

        // 自愈：连接类失败 → 局域网探测（跨网段 mDNS 盲区 / DHCP 换 IP / 网段未知三种场景全覆盖）。
        // 唯一候选自动重连；多候选列出让用户确认；无候选返回探测结论。
        var healNote = ""
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
            var text = String(localized: "remote_host_connect_failed") + "\n" + lastOutput
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

            if attempt == 1, let bonjour = host.bonjourService,
               let fresh = await Self.resolveBonjourHost(bonjour), fresh != currentHost {
                AppLogger.shared.info("[RemoteHost] IP 自愈（Bonjour）：\(currentHost) → \(fresh)", category: "RemoteHost")
                currentHost = fresh
                configDirty = true
                continue
            }
            if attempt <= 2 {
                let candidates = await Self.healProbeLAN()
                if let pick = candidates.first(where: { $0 != currentHost }) {
                    AppLogger.shared.info("[RemoteHost] IP 自愈（局域网探测）：\(currentHost) → \(pick)", category: "RemoteHost")
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
        let script = """
        OUT=/tmp/remote_heal.txt
        : > $OUT
        SEGS=""
        for ns in $(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null); do
          s=$(echo $ns | cut -d. -f1-3)
          case " $SEGS " in *" $s "*) ;; *) SEGS="$SEGS $s";; esac
        done
        for s in $SEGS; do
          for i in $(seq 1 254); do
            ( ping -c 1 -W 1 $s.$i >/dev/null 2>&1 && echo $s.$i >> $OUT ) &
          done
          wait
        done
        sort -t. -k4 -n -u $OUT | while read ip; do
          ( nc -z -w 2 $ip 22 >/dev/null 2>&1 && echo ">>> $ip:22 OPEN" ) &
        done
        wait
        echo HEAL_DONE
        """
        guard let (out, _, _) = await runLocalStatic(script, timeout: 90),
              out.contains("HEAL_DONE") else {
            return []
        }
        let ips = out.components(separatedBy: "\n")
            .filter { $0.hasPrefix(">>> ") && $0.contains(":22 OPEN") }
            .compactMap { $0.split(separator: " ").dropFirst().first }
            .map { String($0) }
            .sorted()
        return ips
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

    /// 解析单个 Bonjour 服务名为当前 IP（临时 TCP 连接的 remoteEndpoint）。
    /// 每次调用都拿**当前**地址——IP 自愈就是靠「exec 失败时重新解析一次」。
    static func resolveBonjourHost(_ serviceName: String, timeout: TimeInterval = 6) async -> String? {
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
                                    if let pct = ip.firstIndex(of: "%") { ip = String(ip[..<pct]) }
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
    /// ControlMaster 复用（iSH 模拟下 ssh 加密握手慢，首连一次后 10 分钟内 exec 走复用通道毫秒级）、
    /// 远程命令整体单引号包裹（内部单引号按 POSIX 规则转义）。keyPath 含 ~ 不加引号（交由 shell 展开）。
    private static func sshCommand(user: String, host: String, port: Int, keyPath: String, command: String) -> String {
        let escaped = command.replacingOccurrences(of: "'", with: "'\\''")
        var parts = ["ssh", "-i", keyPath,
                     "-o", "StrictHostKeyChecking=accept-new",
                     "-o", "ConnectTimeout=10",
                     "-o", "BatchMode=yes",
                     "-o", "ControlMaster=auto",
                     "-o", "ControlPath=/tmp/cm-%r@%h:%p",
                     "-o", "ControlPersist=600"]
        if port != 22 { parts += ["-p", String(port)] }
        parts.append("\(user)@\(host)")
        parts.append("'\(escaped)'")
        return parts.joined(separator: " ")
    }
}
