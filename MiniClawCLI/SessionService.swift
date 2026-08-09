import Foundation
import SwiftData

/// CLI 编排层。命令进入后统一分派给三个子服务，自身不碰存储细节。
///
/// 架构：CLI → SessionService → { SessionStore, AgentRuntime, ArtifactStore }
final class SessionService {
    let store: SessionStore
    let agent: AgentRuntime
    let artifacts: ArtifactStore

    init(storeOverride: String?) throws {
        self.store = try SessionStore(storeOverride: storeOverride)
        self.agent = AgentRuntime(store: store)
        self.artifacts = ArtifactStore(store: store)
    }

    func dispatch(command: String, params: [String]) -> String {
        let args = Args(params)
        switch command {
        case "list":
            return store.list(limit: args.int("limit") ?? 0)
        case "search":
            guard let kw = args.string("keyword") ?? args.positionals.first, !kw.isEmpty else {
                return fail("search 需要关键词（search <keyword> 或 --keyword <kw>）")
            }
            return store.search(keyword: kw)
        case "messages":
            return store.messages(ref: args.sessionRef)
        case "status":
            return store.status(ref: args.sessionRef)
        case "get":
            return store.get(ref: args.sessionRef)
        case "create":
            return store.create(title: args.string("title"), model: args.string("model"), agentName: args.string("agent"))
        case "delete":
            return store.delete(ref: args.sessionRef)
        case "delete-all", "wipe":
            // 高风险：清空全部会话需宿主 App 确认（spec 无头执行安全策略）
            switch SecurityGate.classify(domain: "sessions", operation: command) {
            case .direct:
                return store.deleteAll()
            case .requiresHostApproval(let cap, let reason):
                if SecurityGate.isApproved(args) {
                    return store.deleteAll()
                }
                return SecurityGate.approvalResponse(domain: "sessions", operation: command, capability: cap, reason: reason)
            }
        case "update":
            return store.update(ref: args.sessionRef, field: args.string("field"), value: args.string("value"))
        case "append":
            let content = args.string("content") ?? args.positionals.dropFirst().joined(separator: " ")
            return store.append(ref: args.sessionRef, role: args.string("role") ?? "user", content: content)
        case "send":
            let text = args.string("text") ?? args.positionals.dropFirst().joined(separator: " ")
            return agent.send(ref: args.sessionRef, text: text)
        case "retry":
            return agent.retry(ref: args.sessionRef)
        case "artifacts":
            return artifacts.list(ref: args.sessionRef)
        case "open":
            return open(ref: args.sessionRef)
        default:
            return fail("未知命令: \(command)。可用: list / search / messages / send / retry / status / open / get / create / delete / delete-all / update / append / artifacts")
        }
    }

    /// open：构造 miniclaw://session/<id> 深链并在 macOS 上唤起 MiniClaw（模拟器）打开该会话。
    private func open(ref: String?) -> String {
        guard let ref, UUID(uuidString: ref) != nil else {
            return fail("open 需要会话 id")
        }
        let urlString = "miniclaw://session/\(ref)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [urlString]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return fail("无法打开 \(urlString): \(error.localizedDescription)")
        }
        return prettyJSON(["id": ref, "url": urlString, "action": "open"])
    }
}
