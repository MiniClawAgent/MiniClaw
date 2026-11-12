import Foundation

// MARK: - 恰好一次定稿的 continuation 盒

/// 「先到者定稿」的一次性等待盒。
///
/// 用于工具 / 超时 / 取消三方竞速：谁先产出结果谁 `finish`，后到者返回 `false`。
/// 它解决的是**结构化并发无法处理不可取消 continuation** 的问题：
/// `withTaskGroup` 退出前会隐式等待所有子任务，而挂在 `withCheckedContinuation` 上的
/// 工具任务可能永不 resume ⇒ group 永不返回 ⇒ 调用方永久卡死（详见 ISSUES I-02）。
/// 用本盒 + 非结构化 Task 后，超时可以**先定稿返回**，再取消挂起的工作任务。
///
/// 纪律：锁内只读写状态，`resume` 一律在锁外调用（与 `ToolTaskBag` 一致）。
final class ResumeOnceBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: T?
    private var continuation: CheckedContinuation<T, Never>?

    /// 定稿。首次返回 `true`；重复调用返回 `false`（绝不会二次 resume）。
    @discardableResult
    func finish(_ value: T) -> Bool {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return false
        }
        result = value
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: value)
        return true
    }

    /// 等待定稿；若已定稿立即返回。
    func value() async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            lock.lock()
            if let result {
                lock.unlock()
                cont.resume(returning: result)
            } else {
                continuation = cont
                lock.unlock()
            }
        }
    }
}

// MARK: - 可取消超时

/// 带超时的等待：**超时先定稿并取消 work，然后立即返回**，绝不与 work 竞速后仍等待它。
///
/// 语义与 `withTaskGroup` 竞速的区别（这是本函数存在的唯一理由）：
/// - 旧写法把工具和 `Task.sleep` 放进同一个 group，超时分支先返回后，group 仍要隐式
///   await 挂死的工具子任务 ⇒ 调用方拿不到已完成的超时结果。
/// - 本写法超时时 `workTask.cancel()` + 返回 `onTimeout()`；被挂起的 work 可能无法真正
///   停止（例如工具内部是不可取消的 `withCheckedContinuation`），但它**不再阻塞调用方**。
///   残留任务由工具侧的取消/超时修复逐步消除（ISSUES I-02 的后续项）。
///
/// - Parameters:
///   - seconds: 超时秒数，必须 > 0（<= 0 视为不限时，直接等待 work）。
///   - onTimeout: 超时结果的构造（在主 actor 语义外调用，需自行保证线程安全）。
///   - work: 实际工作；协作者应自行响应 `Task.isCancelled`。
@discardableResult
func withCancellableTimeout<T: Sendable>(
    seconds: TimeInterval,
    onTimeout: @Sendable @escaping () -> T,
    work: @Sendable @escaping () async -> T
) async -> T {
    guard seconds > 0, seconds.isFinite else {
        return await work()
    }

    let box = ResumeOnceBox<T>()
    let workTask = Task {
        box.finish(await work())
    }
    let timeoutTask = Task {
        do {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        } catch {
            return // work 先完成导致超时任务被取消：正常路径
        }
        if box.finish(onTimeout()) {
            workTask.cancel()
        }
    }

    let value = await box.value()
    timeoutTask.cancel()
    return value
}
