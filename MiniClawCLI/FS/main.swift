import Foundation

// MARK: - miniclaw-fs-cli — 文件与 Shell 专用 CLI（Layer 2）
//
// 普通文件读/写/编辑可无头完成（受 /var/MiniClaw/ 边界约束）；
// Shell 执行为高风险操作，经 SecurityGate 标记需宿主 App 确认。
// 命令中的 $VAR / ${VAR} 由环境变量安全注入（spec 12.2.1）。

let root = "/var/MiniClaw"

func run() -> Int32 {
    let all = Array(CommandLine.arguments.dropFirst())
    guard !all.isEmpty else { usage(); return 1 }
    let command = all[0]
    let params = Array(all.dropFirst())
    let args = Args(params)

    switch command {
    case "read":
        return read(path: args.string("path") ?? args.positionals.first, offset: args.int("offset"), limit: args.int("limit"), tail: args.int("tail"))
    case "write":
        return write(path: args.string("path") ?? args.positionals.first, content: args.string("content") ?? args.positionals.dropFirst().joined(separator: " "), append: args.bool("append"))
    case "edit":
        return edit(path: args.string("path") ?? args.positionals.first, old: args.string("old"), new: args.string("new"))
    case "ls":
        return ls(path: args.string("path") ?? args.positionals.first ?? root)
    case "mkdir":
        return mkdir(path: args.string("path") ?? args.positionals.first)
    case "shell":
        return shell(command: args.string("command") ?? args.positionals.dropFirst().joined(separator: " "), args: args)
    case "-h", "--help":
        usage(); return 0
    default:
        print(fail("未知命令: \(command)。可用: read / write / edit / ls / mkdir / shell"))
        return 1
    }
}

// MARK: - 路径安全（12.2.3）

func safePath(_ requested: String?) -> String? {
    guard let p = requested, !p.isEmpty else { return nil }
    // 必须以 /var/MiniClaw/ 开头（解析符号链接后）
    let url = URL(fileURLWithPath: p)
    let resolved = url.resolvingSymlinksInPath().path
    guard resolved == root || resolved.hasPrefix(root + "/") else {
        return nil
    }
    return p
}

// MARK: - 命令实现

func read(path: String?, offset: Int?, limit: Int?, tail: Int?) -> Int32 {
    guard let p = safePath(path) else {
        print(fail("read 需要 /var/MiniClaw/ 下的路径"))
        return 1
    }
    do {
        let text = try String(contentsOfFile: p, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let slice: [String]
        if let t = tail {
            slice = Array(lines.suffix(t))
        } else {
            let start = min(offset ?? 0, lines.count)
            let end = limit.map { min(start + $0, lines.count) } ?? lines.count
            slice = Array(lines[start..<end])
        }
        print(ok(["path": p, "lines": slice.count, "content": slice.joined(separator: "\n")]))
        return 0
    } catch {
        print(fail("读取失败: \(error.localizedDescription)"))
        return 1
    }
}

func write(path: String?, content: String?, append: Bool) -> Int32 {
    guard let p = safePath(path) else {
        print(fail("write 需要 /var/MiniClaw/ 下的路径"))
        return 1
    }
    guard let c = content else {
        print(fail("write 需要 --content"))
        return 1
    }
    // 写操作受安全门约束：越界写需宿主确认（此处 safePath 已保证在边界内，越界在 safePath 层拦截）
    let dir = (p as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    do {
        if append, FileManager.default.fileExists(atPath: p) {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: p))
            handle.seekToEndOfFile()
            handle.write(c.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try c.write(toFile: p, atomically: true, encoding: .utf8)
        }
        print(ok(["path": p, "written": true, "append": append]))
        return 0
    } catch {
        print(fail("写入失败: \(error.localizedDescription)"))
        return 1
    }
}

func edit(path: String?, old: String?, new: String?) -> Int32 {
    guard let p = safePath(path) else {
        print(fail("edit 需要 /var/MiniClaw/ 下的路径"))
        return 1
    }
    guard let o = old, let n = new else {
        print(fail("edit 需要 --old 与 --new"))
        return 1
    }
    do {
        var text = try String(contentsOfFile: p, encoding: .utf8)
        guard text.contains(o) else {
            print(fail("未找到 old_string"))
            return 1
        }
        text = text.replacingOccurrences(of: o, with: n)
        try text.write(toFile: p, atomically: true, encoding: .utf8)
        print(ok(["path": p, "edited": true]))
        return 0
    } catch {
        print(fail("编辑失败: \(error.localizedDescription)"))
        return 1
    }
}

func ls(path: String?) -> Int32 {
    guard let p = safePath(path) else {
        print(fail("ls 需要 /var/MiniClaw/ 下的路径"))
        return 1
    }
    guard let items = try? FileManager.default.contentsOfDirectory(atPath: p) else {
        print(fail("无法列出目录: \(p)"))
        return 1
    }
    print(ok(["path": p, "entries": items]))
    return 0
}

func mkdir(path: String?) -> Int32 {
    guard let p = safePath(path) else {
        print(fail("mkdir 需要 /var/MiniClaw/ 下的路径"))
        return 1
    }
    do {
        try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        print(ok(["path": p, "created": true]))
        return 0
    } catch {
        print(fail("创建目录失败: \(error.localizedDescription)"))
        return 1
    }
}

func shell(command: String?, args: Args) -> Int32 {
    guard let cmd = command, !cmd.isEmpty else {
        print(fail("shell 需要 --command"))
        return 1
    }
    // 高风险：需宿主 App 确认
    switch SecurityGate.classify(domain: "fs", operation: "shell") {
    case .direct:
        break
    case .requiresHostApproval(let cap, let reason):
        if !SecurityGate.isApproved(args) {
            print(SecurityGate.approvalResponse(domain: "fs", operation: "shell", capability: cap, reason: reason))
            return 2
        }
    }

    // 收集 --env KEY=VALUE 注入并展开 $VAR
    var envTable: [String: String] = [:]
    for (k, v) in args.flags where k == "env" {
        let parts = v.split(separator: "=", maxSplits: 1).map(String.init)
        if parts.count == 2 { envTable[parts[0]] = parts[1] }
    }
    let expanded = EnvExpander.expand(cmd, table: envTable)

    let result = HostExecutor.run(command: expanded, timeout: TimeInterval(args.int("timeout") ?? 900), workingDirectory: root, environment: envTable)
    if !result.stdout.isEmpty { print(result.stdout, terminator: "") }
    if !result.stderr.isEmpty { FileHandle.standardError.write(result.stderr.data(using: .utf8)!) }
    if result.timedOut {
        print(fail("命令超时已被终止"))
    }
    return result.exitCode == 0 ? 0 : 1
}

func usage() {
    print("""
    miniclaw-fs-cli — 文件与 Shell 专用 CLI（Layer 2）

    用法:
      miniclaw-fs-cli <command> [参数]

    命令:
      read <path> [--offset N] [--limit N] [--tail N]
      write <path> --content <文本> [--append]
      edit <path> --old <旧> --new <新>
      ls <path>
      mkdir <path>
      shell --command "<cmd>" [--env KEY=VALUE ...] [--timeout 900] [--approved]

    约束:
      - 所有路径必须以 /var/MiniClaw/ 开头（文件系统边界，spec 12.2.3）。
      - shell 为高风险操作，默认返回 requiresHostApproval；宿主 App 确认后加 --approved 重放。
      - 命令可用 $VAR / ${VAR} 引用 --env 注入的变量（机密不落明文）。
    """)
}

let code = run()
exit(code)
