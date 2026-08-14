import Foundation

final class SubagentEngineBag: @unchecked Sendable {
    private let lock = NSLock()
    private var engines: [AgentLoopEngine] = []

    func add(_ engine: AgentLoopEngine) {
        lock.lock(); engines.append(engine); lock.unlock()
    }

    func remove(_ engine: AgentLoopEngine) {
        lock.lock(); engines.removeAll { $0 === engine }; lock.unlock()
    }

    /// 取出并清空全部引擎（用于父引擎取消时批量停子代理）。
    func drain() -> [AgentLoopEngine] {
        lock.lock(); defer { lock.unlock() }
        let all = engines
        engines.removeAll()
        return all
    }

    /// 按子引擎会话 ID（= 子代理 id）取消并移除；命中返回 true。
    func cancel(id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let idx = engines.firstIndex(where: { $0.runtimeSessionID == id }) else { return false }
        let engine = engines.remove(at: idx)
        engine.cancel()
        return true
    }
}

/// 活跃工具执行 Task 容器（线程安全）。[Fix 2026-08-11 并发工具崩溃·参考实现]
///
/// 原实现是 `AgentLoopEngine.toolExecutionTask: Any?` 单一共享可变属性：
/// 并发工具(executeToolsConcurrently 的 withTaskGroup 同时跑多个 executeTool)
/// 在同一属性上写入/清空,主线程 pause/cancel 也同时读写,ARC 引用计数竞争导致
/// `swift_release_dealloc` 崩溃(用户实证:两个 shell 并发执行时偶发闪退)。
///
/// 本容器照 in-flight 集合模型(ISHExecutionCoordinator actor 持有
/// perSessionInflight PID 队列)与项目内 SubagentEngineBag 范式实现:NSLock 保护的
/// [callID: Task] 字典,每个并发工具写自己的槽位;pause/cancel 用 drain() 枚举
/// 取消**全部** in-flight 工具(stopCurrentCommand 语义:一次停止=取消整批)。
final class ToolTaskBag: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [String: Task<ToolResult, Never>] = [:]

    func insert(_ callID: String, task: Task<ToolResult, Never>) {
        lock.lock(); tasks[callID] = task; lock.unlock()
    }

    func remove(_ callID: String) {
        lock.lock(); tasks.removeValue(forKey: callID); lock.unlock()
    }

    /// 取出并清空全部工具 Task（用于暂停/取消时批量取消）。
    func drain() -> [Task<ToolResult, Never>] {
        lock.lock(); defer { lock.unlock() }
        let all = Array(tasks.values)
        tasks.removeAll()
        return all
    }
}

/// 子代理流式文本收集器：并行派发时多个子引擎在各自线程上回调 onToken，
/// 用锁保护累积字符串，避免数据竞争（引擎整体是 @unchecked Sendable，需自管同步）。
final class SubagentAnswerCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func append(_ piece: String) {
        lock.lock(); buffer += piece; lock.unlock()
    }

    var value: String {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }
}

/// 子代理时间线序号发号器（工具调用 / 思考段穿插渲染用），线程安全。
final class SubagentTimelineCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0

    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        let v = current
        current += 1
        return v
    }
}

/// 子代理展示信息（驱动会话页上方圆形图标），需 Sendable 以便跨并发域传递。
struct SubagentInfo: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    /// 智能体分配给该子代理的任务描述（用户在详情页需要看到的内容）。
    let task: String
}

/// 子代理生命周期事件，由父引擎在派发 / 运行中 / 结束时抛出，供 UI 展示。
enum SubagentEvent: Sendable {
    case started(SubagentInfo)
    case taskAdded(SubagentInfo, String)
    case token(SubagentInfo, String)
    /// 子代理发出的工具调用（与主线一致的 ToolCallEvent，用于详情页展示工具指示器）。
    case toolCall(SubagentInfo, ToolCallEvent)
    /// 子代理工具执行结果（callID 用于并发同名工具的结果配对）。
    case toolResult(SubagentInfo, String, String, String, Bool, TimeInterval)
    /// 子代理分段思考（text / 迭代序号 / 时间线序号，用于穿插渲染）。
    case reasoning(SubagentInfo, String, Int, Int)
    case error(SubagentInfo, String)
    /// 子代理被取消/中断（终态，与 finished 互斥）。
    case cancelled(SubagentInfo)
    case finished(SubagentInfo)
}

