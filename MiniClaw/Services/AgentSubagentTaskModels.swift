import Foundation

/// 子代理派发参数模型与解析（2026-08 提取：与引擎执行解耦）。

    /// 一次派发请求里的单个子任务描述（P2-4 并行编排的最小单元）。
struct SubagentTaskSpec {
        let task: String
        let focus: String?
        let profile: String?
        let reuseID: UUID?
        /// 模型原始传入的复用标识（可能是 8 位短码，未必是合法 UUID）。
        /// 2026-09-10 新增：清单与 close-subagent 都以 8 位短码展示/解析，
        /// dispatch 侧原先只认完整 UUID，模型照抄短码续派会静默新建子代理
        /// （子代理常驻测试实证）。保留原串，由引擎按同一套前缀规则兜底解析。
        let reuseToken: String?

        init(task: String, focus: String?, profile: String?, reuseID: UUID?, reuseToken: String? = nil) {
            self.task = task
            self.focus = focus
            self.profile = profile
            self.reuseID = reuseID
            self.reuseToken = reuseToken
        }

        func withReuseID(_ newID: UUID?) -> SubagentTaskSpec {
            SubagentTaskSpec(task: task, focus: focus, profile: profile, reuseID: newID, reuseToken: reuseToken)
        }
    }


    /// 单个子代理的运行结果。
struct SubagentRunResult {
        let id: UUID
        let name: String
        let body: String
        let ok: Bool
        var rendered: String { String(format: String(localized: "loop_subagent_prefix"), name, id.uuidString, body) }
    }

/// dispatch-subagent 参数解析（顶层函数入口）。
enum AgentSubagentParsing {

    /// 解析 dispatch-subagent 参数为子任务列表：优先读 `tasks` 数组（对象或纯字符串元素），
    /// 无 tasks 时回落到顶层 `task` / `query` 单任务。
    static func parseSubagentSpecs(from args: [String: Any]) -> [SubagentTaskSpec] {
        func uuid(_ any: Any?) -> UUID? {
            guard let s = any as? String else { return nil }
            return UUID(uuidString: s)
        }
        /// 原始复用串（可能是 8 位短码）：非空即保留，交给引擎兜底解析。
        func reuseToken(_ any: Any?) -> String? {
            guard let s = any as? String else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
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
                        specs.append(SubagentTaskSpec(task: t, focus: f.isEmpty ? nil : f, profile: profile,
                                                      reuseID: uuid(dict["subagent_id"]),
                                                      reuseToken: reuseToken(dict["subagent_id"])))
                    }
                }
            }
            if !specs.isEmpty { return specs }
        }

        let t = trimmed(args["task"] ?? args["query"])
        guard !t.isEmpty else { return [] }
        let f = trimmed(args["focus"])
        let p = trimmed(args["profile"])
        return [SubagentTaskSpec(task: t, focus: f.isEmpty ? nil : f, profile: p.isEmpty ? nil : p,
                                 reuseID: uuid(args["subagent_id"]),
                                 reuseToken: reuseToken(args["subagent_id"]))]
    }
}
