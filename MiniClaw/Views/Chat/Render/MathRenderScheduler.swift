import MiniClawKit
import UIKit

private let logger = AppLogger(category: "MathRenderSched")

///
///
///
final class MathRenderScheduler: @unchecked Sendable {
    static let shared = MathRenderScheduler()

    /// Formulas done per runloop tick before yielding. Empirically 4
    private let batchSize = 4

    private var queue: [WeakBox] = []
    private var running = false

    private var burstStart: CFAbsoluteTime = 0
    private var burstTotalCnt = 0
    private var burstDoneCnt = 0
    private var burstTotalRenderMs: Double = 0
    private var burstMaxRenderMs: Double = 0

    private init() {}

    func enqueue(_ attachment: MathAttachment) {
        let work = { [weak self] in
            guard let self else { return }
            if self.queue.isEmpty && !self.running {
                self.burstStart = CFAbsoluteTimeGetCurrent()
                self.burstTotalCnt = 0
                self.burstDoneCnt = 0
                self.burstTotalRenderMs = 0
                self.burstMaxRenderMs = 0
                logger.info("[MathSched] burst begin first enqueue")
            }
            self.queue.append(WeakBox(attachment))
            self.burstTotalCnt += 1
            if self.burstTotalCnt <= 3 || self.burstTotalCnt%100 == 0 {
                logger.info("[MathSched] enqueue #\(self.burstTotalCnt) queueLen=\(self.queue.count) running=\(self.running)")
            }
            if !self.running {
                self.running = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    MainActor.assumeIsolated { self.drain() }
                }
            }
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func drain() {
        let tick0 = CFAbsoluteTimeGetCurrent()
        var done = 0

        while done<batchSize,!queue.isEmpty {
            let box = queue.removeFirst()
            guard let attachment = box.value else { continue }
            let tA = CFAbsoluteTimeGetCurrent()
            attachment.performRender()
            let ms = (CFAbsoluteTimeGetCurrent()-tA)*1000
            burstTotalRenderMs += ms
            burstMaxRenderMs = max(burstMaxRenderMs,ms)
            burstDoneCnt += 1
            done += 1
        }

        let tickMsVal = (CFAbsoluteTimeGetCurrent()-tick0)*1000

        if queue.isEmpty {
            running = false
            let totalElapsedMs = (CFAbsoluteTimeGetCurrent()-burstStart)*1000
            let avgMsVal = burstDoneCnt>0 ? burstTotalRenderMs/Double(burstDoneCnt) : 0
            logger.info("[MathSched] burst done rendered=\(burstDoneCnt)/\(burstTotalCnt) wallMs=\(String(format: "%.1f", totalElapsedMs)) cpuMs=\(String(format: "%.1f", burstTotalRenderMs)) avgMsVal=\(String(format: "%.2f", avgMsVal)) maxMs=\(String(format: "%.1f", burstMaxRenderMs)) lastTickMs=\(String(format: "%.1f", tickMsVal))")
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated { self.drain() }
            }
        }
    }

    private struct WeakBox {
        weak var value: MathAttachment?
        init(_ v: MathAttachment) { self.value = v }
    }
}
