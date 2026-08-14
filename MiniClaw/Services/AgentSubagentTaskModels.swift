import Foundation

/// 子代理派发参数模型与解析（2026-08 提取：与引擎执行解耦）。

    /// 一次派发请求里的单个子任务描述（P2-4 并行编排的最小单元）。
struct SubagentTaskSpec {
        let task: String
        let focus: String?
        let profile: String?
        let reuseID: UUID?
    }


    /// 单个子代理的运行结果。
struct SubagentRunResult {
        let id: UUID
        let name: String
        let body: String
        let ok: Bool
        var rendered: String { String(format: L10n.l("loop_subagent_prefix"), name, id.uuidString, body) }
    }

/// dispatch_subagent 参数解析（顶层函数入口）。
enum AgentSubagentParsing {

    /// 解析 dispatch_subagent 参数为子任务列表：优先读 `tasks` 数组（对象或纯字符串元素），
    /// 无 tasks 时回落到顶层 `task` / `query` 单任务。
    static func parseSubagentSpecs(from args: [String: Any]) -> [SubagentTaskSpec] {
        func uuid(_ any: Any?) -> UUID? {
            guard let s = any as? String else { return nil }
            return UUID(uuidString: s)
        }
        func trimmed(_ any: Any?) -> String {
            ((any as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let rawList = args["tasks"] as? [Any], !rawList.isEmpty {
            // 顶层 profile 作为 tasks 元素的默认角色（元素级可覆盖）。
            let topProfile = trimmed(args["profile"])
            var specs: [SubagentTaskSpec] = []
            for raw in rawList {
                if let s = raw as? String {
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty {
                        specs.append(SubagentTaskSpec(task: t, focus: nil, profile: topProfile.isEmpty ? nil : topProfile, reuseID: nil))
                    }
                } else if let dict = raw as? [String: Any] {
                    let t = trimmed(dict["task"] ?? dict["query"])
                    if !t.isEmpty {
                        let f = trimmed(dict["focus"])
                        let p = trimmed(dict["profile"])
                        let profile = p.isEmpty ? (topProfile.isEmpty ? nil : topProfile) : p
                        specs.append(SubagentTaskSpec(task: t, focus: f.isEmpty ? nil : f, profile: profile, reuseID: uuid(dict["subagent_id"])))
                    }
                }
            }
            if !specs.isEmpty { return specs }
        }

        let t = trimmed(args["task"] ?? args["query"])
        guard !t.isEmpty else { return [] }
        let f = trimmed(args["focus"])
        let p = trimmed(args["profile"])
        return [SubagentTaskSpec(task: t, focus: f.isEmpty ? nil : f, profile: p.isEmpty ? nil : p, reuseID: uuid(args["subagent_id"]))]
    }
}
