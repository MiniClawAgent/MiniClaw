import Foundation

// MARK: - MiniClaw-sessions-cli 入口
// 直接读取模拟器中的 SwiftData 存储（底层 SQLite），经 SessionService 分层访问，不写裸 SQL。
// 架构：CLI → SessionService → { SessionStore, AgentRuntime, ArtifactStore }

func run() -> Int32 {
    let allArgs = Array(CommandLine.arguments.dropFirst())
    var storeOverride: String?
    var rest: [String] = []
    var i = 0
    while i < allArgs.count {
        let a = allArgs[i]
        if a == "--store" {
            if i + 1 < allArgs.count { storeOverride = allArgs[i + 1] }
            i += 2
            continue
        }
        if a == "-h" || a == "--help" {
            printUsage()
            return 0
        }
        rest.append(a)
        i += 1
    }

    guard !rest.isEmpty else {
        printUsage()
        return 1
    }

    let command = rest[0]
    let params = Array(rest.dropFirst())

    do {
        let service = try SessionService(storeOverride: storeOverride)
        let output = service.dispatch(command: command, params: params)
        print(output)
        return 0
    } catch {
        print(prettyJSON(["error": error.localizedDescription]))
        return 1
    }
}

func printUsage() {
    let text = """
    MiniClaw-sessions-cli — 会话数据库 CLI（方案1：直接读模拟器 SwiftData 存储）

    用法:
      minis-sessions-cli [--store <path>] <command> [参数]

    命令:
      list [--limit N]                     列出会话（默认全部）
      search <keyword> | --keyword <kw>    搜索消息内容
      messages <id>                        列出某会话的全部消息
      status <id>                          查看会话状态
      get <id>                             查看会话详情（含消息）
      create [--title T] [--model M] [--agent A]
      delete <id>
      delete-all                          清空全部会话（高风险，需 --approved 经宿主确认）
      update <id> --field <f> --value <v>  f ∈ title|model|agentName|status
      append <id> --content <文本> [--role user]
      send <id> --text <文本>              追加密信并标记为待执行
      retry <id>                           重新标记为待执行
      artifacts <id>                       列出会话附件
      open <id>                            在 MiniClaw 中打开该会话（miniclaw://session/<id>）

    说明:
      - 不传 --store 时，自动扫描 ~/Library/Developer/CoreSimulator 定位 MiniClaw 的存储。
      - 输出为 JSON（pretty）。
      - 高风险操作（如 delete-all）会返回 requiresHostApproval，需宿主 App 确认后加 --approved 重放。
    """
    print(text)
}

let code = run()
exit(code)
