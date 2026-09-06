import Foundation

/// `remote-host`：通过 iSH 内的 SSH 控制远程主机（Mac / Linux / Windows）。
///
/// v0 通道 = iSH 的 openssh-client（`apk add openssh-client`），执行复用
/// `ShellRuntimeFactory.runtime.execute`；产品化 v1 换 App 内嵌 Citadel，
/// 工具面（本 schema）保持不变。
///
/// 职责切分（2026-09-07 设计定稿）：
/// - `setup`：环境自检（openssh / 密钥）+ 按 `os` 输出目标机配置指引 + 精确命令清单。
///   **工具不自己执行 apk/keygen 等长任务**——它们交给 AI 用 `shell_execute` 跑
///   （iSH 模拟下可能数分钟，塞进工具超时既危险又看不到进度）；
/// - `connect`：连通性验证（accept-new 首连）→ 成功即把 host/user/keyPath 锁定进
///   配置文件（`shared/remote-hosts.json`）——连接参数持久化后，`exec` 从配置读取，
///   AI 不再需要（也不可能）猜用户名/密钥路径（真机踩坑：AI 猜 root 被拒）；
/// - `exec`：远程执行命令（自动拼 ssh，accept-new、ConnectTimeout、单引号转义）；
/// - `list`：列出已配置主机。
struct RemoteHostTool: AgentTool {
    /// 远程执行有设备外副作用：与 shell_execute 同样走执行前确认。
    var resumePolicy: ResumePolicy { .requiresUserConfirmation }
    let name = "remote-host"

    private static let configFileName = "remote-hosts.json"
    private static let defaultKeyPath = "~/.ssh/miniclaw"

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
                        enum: ["setup", "connect", "exec", "list"]
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
        case "setup":   return await setupAction(os: parameters["os"] as? String)
        case "connect": return await connectAction(parameters)
        case "exec":    return await execAction(parameters)
        case "list":    return listAction()
        default:
            return ToolResult(success: false,
                              text: String(format: String(localized: "remote_host_unknown_action"), action))
        }
    }

    // MARK: - action: setup（自检 + 引导；执行交给 shell_execute）

    private func setupAction(os: String?) async -> ToolResult {
        // 一次性自检：openssh 是否已装、密钥是否已生成、公钥内容
        let check = "which ssh >/dev/null 2>&1 && echo SSH_OK || echo SSH_MISSING; test -f ~/.ssh/miniclaw && echo KEY_OK || echo KEY_MISSING; cat ~/.ssh/miniclaw.pub 2>/dev/null"
        guard let (out, _, exitCode) = await runLocal(check, timeout: 30) else {
            return ToolResult(success: false, text: String(localized: "remote_host_shell_unavailable"))
        }
        guard exitCode == 0 || !out.isEmpty else {
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

        // 环境就绪：按目标 OS 输出配置指引
        switch (os ?? "macos").lowercased() {
        case "linux":   lines.append(String(localized: "remote_host_guide_linux"))
        case "windows": lines.append(String(localized: "remote_host_guide_windows"))
        default:        lines.append(String(localized: "remote_host_guide_macos"))
        }
        lines.append(String(localized: "remote_host_setup_next_connect"))
        return ToolResult(success: true, text: lines.joined(separator: "\n\n"))
    }

    // MARK: - action: connect（验证 + 锁定配置）

    private func connectAction(_ parameters: [String: Any]) async -> ToolResult {
        guard let host = stringParam(parameters, "host"), !host.isEmpty else {
            return ToolResult(success: false, text: String(localized: "remote_host_connect_need_host"))
        }
        guard let user = stringParam(parameters, "user"), !user.isEmpty else {
            return ToolResult(success: false, text: String(localized: "remote_host_connect_need_user"))
        }
        let name = stringParam(parameters, "name") ?? host
        let port = intParam(parameters, "port") ?? 22
        let keyPath = stringParam(parameters, "key_path") ?? Self.defaultKeyPath
        let os = (stringParam(parameters, "os") ?? "macos").lowercased()

        let probe = Self.sshCommand(user: user, host: host, port: port, keyPath: keyPath,
                                    command: "echo ok && uname -s")
        let probeResult = await runLocal(probe, timeout: 45)
        guard let probeResult, probeResult.exitCode == 0, probeResult.stdout.contains("ok") else {
            let detail: String
            if let r = probeResult, !r.stdout.isEmpty {
                detail = r.stdout
            } else {
                detail = String(localized: "remote_host_connect_timeout")
            }
            return ToolResult(success: false,
                              text: String(localized: "remote_host_connect_failed") + "\n" + detail)
        }

        var file = Self.loadHosts()
        var hosts = file.hosts
        hosts.removeAll { $0.name == name }
        hosts.append(HostConfig(name: name, host: host, user: user, port: port,
                                keyPath: keyPath, os: os))
        file.hosts = hosts
        guard Self.saveHosts(file) else {
            return ToolResult(success: false, text: String(localized: "remote_host_config_write_failed"))
        }
        return ToolResult(success: true,
                          text: String(format: String(localized: "remote_host_connect_ok"), name, host, user))
    }

    // MARK: - action: exec（远程执行）

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

        let timeout = intParam(parameters, "timeout") ?? 120
        let ssh = Self.sshCommand(user: host.user, host: host.host, port: host.port,
                                  keyPath: host.keyPath, command: command)
        guard let (out, _, exitCode) = await runLocal(ssh, timeout: TimeInterval(timeout)) else {
            return ToolResult(success: false, text: String(localized: "remote_host_exec_timeout"))
        }
        return ToolResult(success: exitCode == 0,
                          text: out.isEmpty ? String(localized: "no_output") : out)
    }

    // MARK: - action: list

    private func listAction() -> ToolResult {
        let file = Self.loadHosts()
        guard !file.hosts.isEmpty else {
            return ToolResult(success: true, text: String(localized: "remote_host_no_host"))
        }
        let lines = file.hosts.map { h in
            "\(h.name): \(h.user)@\(h.host):\(h.port) [\(h.os)] key=\(h.keyPath)"
        }
        return ToolResult(success: true,
                          text: String(localized: "remote_host_list_header") + "\n" + lines.joined(separator: "\n"))
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

        // 外部 JSON 解码纪律：全字段 decodeIfPresent + 默认值（见工程记忆 §7）
        init(name: String, host: String, user: String, port: Int, keyPath: String, os: String) {
            self.name = name; self.host = host; self.user = user
            self.port = port; self.keyPath = keyPath; self.os = os
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
            user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
            port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
            keyPath = try c.decodeIfPresent(String.self, forKey: .keyPath) ?? Self.defaultKeyPathStatic
            os = try c.decodeIfPresent(String.self, forKey: .os) ?? "macos"
        }
        static let defaultKeyPathStatic = "~/.ssh/miniclaw"
        enum CodingKeys: String, CodingKey { case name, host, user, port, keyPath = "key_path", os }
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

    /// 拼 ssh 命令：accept-new 首连免交互、ConnectTimeout 防卡死、
    /// 远程命令整体单引号包裹（内部单引号按 POSIX 规则转义）。keyPath 含 ~ 不加引号（交由 shell 展开）。
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
