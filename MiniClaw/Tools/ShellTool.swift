import Foundation
import UIKit
import PDFKit

struct ShellExecuteTool: AgentTool {
    var resumePolicy: ResumePolicy { .requiresUserConfirmation }
    let name = "shell_execute"
    /// 当前会话 ID：注入后该工具执行的 Shell 命令会被隔离到本会话的
    /// /var/MiniClaw/{workspace,attachments,browser,offloads}，与其他会话互不污染。
    let currentSessionID: UUID?
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "shell_execute",
            description: String(localized: "shell_execute_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "command": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_shell_command")),
                    "timeout": JSONSchema.JSONProperty(type: "integer", description: String(localized: "param_shell_timeout")),
                    "delay": JSONSchema.JSONProperty(type: "integer", description: String(localized: "param_shell_delay")),
                ],
                required: ["command"]
            )
        )
    )

    init(currentSessionID: UUID? = nil) {
        self.currentSessionID = currentSessionID
    }

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        let rawCommand = (parameters["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // 空命令守卫（2026-09-05）：模型偶发吐出缺 command 的垃圾调用（MiMo 派发子代理时实测），
        // 空命令进 iSH 只会产生一条 0.0s 的失败卡+多余工具往返。直接给明确失败文案，不进执行链。
        guard !rawCommand.isEmpty else {
            return ToolResult(
                success: false,
                text: String(localized: "shell_empty_command_error")
            )
        }
        let timeout = parameters["timeout"] as? Int ?? 900
        let delay = parameters["delay"] as? Int ?? 0
        // delay 参数：App 侧等待（不占用 iSH shell），供轮询/等待服务启动用——
        // 等待期间其他命令可并发执行；命令本身未被调度前就占着 shell。
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
        }
        // 设置快照必须先取：environmentDictionary 同样读 envvars，不能裸读
        // SettingsStore（2026-08-13 竞争修复）。maskSecrets/threshold 共用同一份快照。
        let settings = await SettingsStore.shared.snapshot()
        // 真实注入进程环境：已配置的环境变量经 /bin/sh 的进程环境下发，
        // 命令里写 $VAR / ${VAR} 由 sh 自身从环境展开（机密不进命令字符串，
        // 也不受特殊字符导致的命令注入影响）。不再使用字符串替换式展开。
        let environment = EnvVarStore.environmentDictionary(using: settings.envvars)

        // —— Bashism 检测与 bash 升级执行（自研，见 BashismDetector/BashSupport）——
        // 检测到 bash 特有语法时：bash 可用 → 用 bash -lc 包装执行（执行前决策，
        // 无重复副作用；环境变量随进程环境继承，$VAR 由 bash 展开）；
        // bash 不可用 → 尝试按需安装（独立预算+退避）；仍不可用 → 原样 sh 执行，
        // 并在结果附 system-reminder 提醒模型改写为 POSIX 语法。
        let hits = BashismDetector.detect(rawCommand)
        var effectiveCommand = rawCommand
        var bashReminder: String?
        if !hits.isEmpty {
            if await BashSupport.ensureInstalled() {
                effectiveCommand = "bash -lc " + Self.singleQuoteEscape(rawCommand)
            } else {
                let names = hits.map { $0.rule }.joined(separator: "、")
                bashReminder = String(format: String(localized: "core_bash_syntax_hint"), names)
            }
        }

        do {
            let result = try await ShellRuntimeFactory.runtime.execute(
                command: effectiveCommand,
                environment: environment,
                workingDirectory: nil,
                timeout: TimeInterval(timeout),
                // 过程流：stdout/stderr 逐行上报 → 引擎节流缓冲 → 工具块 content 实时渲染。
        onLine: { line, _ in ToolProgressScope.reporter?(line) },
                sessionID: currentSessionID
            )
            let output = result.stdout + (result.stderr.isEmpty ? "" : "\n[stderr]\n\(result.stderr)")
            let full = output.isEmpty ? String(localized: "no_output") : output
            let masked = maskSecrets(full, settings: settings)
            let thresholdBytes = settings.files.autoOffloadThresholdKB * 1024
            var final = FileSystemManager.shared.offloadIfLarge(masked, thresholdBytes: thresholdBytes, sessionID: currentSessionID)
            // 治本(2026-08-13):附上工作目录,消除 AI 对 shell 默认 cwd 的误判。
            // workingDirectory 传 nil 时命令在 iSH 会话根执行(/var/MiniClaw/sessions/<uuid>),
            // 但 AI 常误以为文件落在 /tmp 或"文件不见了"而反复扑空。附上 cwd 让 AI 明确:
            // 相对路径生成的文件落在此目录。
            let cwd = currentSessionID.map { "/var/MiniClaw/sessions/\($0.uuidString)" } ?? "/var/MiniClaw"
            final += "\n[env] cwd: \(cwd) (relative paths resolve here)"
            if let bashReminder { final += bashReminder }
            return ToolResult(success: result.exitCode == 0, text: final)
        } catch {
            return ToolResult(success: false, text: error.localizedDescription)
        }
    }

    /// 单引号包裹命令（' 转义为 '\''），供 `bash -lc '...'` 包装使用。
    private static func singleQuoteEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 当 envvars.privacyMode 开启时，把输出中的环境变量值替换为 ***
    /// 2026-08-13 改传主线程快照：不再后台线程裸读 SettingsStore（竞争修复）。
    private func maskSecrets(_ output: String, settings: AppSettings) -> String {
        guard settings.envvarsPrivacyMode else { return output }
        var text = output
        for v in settings.envvars where !v.value.isEmpty {
            text = text.replacingOccurrences(of: v.value, with: "***")
        }
        return text
    }
}
