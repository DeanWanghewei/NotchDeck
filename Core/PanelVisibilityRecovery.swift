import CoreGraphics
import Foundation

/// onScreenOnly 返回整张屏幕的窗口，relativeToWindow 不能用作单窗口过滤条件。
enum PanelVisibility {
    static func isOnScreen(windowNumber: Int, windows: [[String: Any]]?) -> Bool? {
        guard let windows else { return nil }
        guard windowNumber > 0 else { return false }
        return windows.contains {
            ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == windowNumber
        }
    }
}

/// 窗口服务器异步处理 Space 切换；延后核验，并让收起或新一轮唤起废弃旧回调。
/// 调度与窗口操作可注入，回归测试无需启动主程序或切换用户的 Space。
final class PanelVisibilityRecovery {
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void

    private let isOnScreen: () -> Bool?
    private let orderFront: () -> Void
    private let reattach: () -> Void
    private let didFail: () -> Void
    private let schedule: Schedule
    private var generation = 0
    private let retryDelays: [TimeInterval] = [0.15, 0.3, 0.6, 1.0]

    init(isOnScreen: @escaping () -> Bool?,
         orderFront: @escaping () -> Void,
         reattach: @escaping () -> Void,
         didFail: @escaping () -> Void,
         schedule: @escaping Schedule = { delay, action in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
         }) {
        self.isOnScreen = isOnScreen
        self.orderFront = orderFront
        self.reattach = reattach
        self.didFail = didFail
        self.schedule = schedule
    }

    func present() {
        cancel()
        let currentGeneration = generation
        orderFront()
        verifyLater(generation: currentGeneration, attempt: 0, delay: 0.1,
                    confirmAfterTransition: true)
    }

    func cancel() {
        generation += 1
    }

    private func verifyLater(generation: Int, attempt: Int, delay: TimeInterval,
                             confirmAfterTransition: Bool) {
        schedule(delay) { [weak self] in
            guard let self, self.generation == generation else { return }
            // 查询失败不能等同于窗口不在屏幕，避免把可见面板错误收起。
            guard let visible = self.isOnScreen() else { return }
            if visible {
                if confirmAfterTransition {
                    // 全屏动画开始时可能仍在屏，动画结束后再确认一次。
                    self.verifyLater(generation: generation, attempt: attempt, delay: 0.8,
                                     confirmAfterTransition: false)
                }
                return
            }
            guard attempt < self.retryDelays.count else {
                self.cancel()
                self.didFail()
                return
            }
            self.reattach()
            self.orderFront()
            self.verifyLater(generation: generation, attempt: attempt + 1,
                             delay: self.retryDelays[attempt], confirmAfterTransition: true)
        }
    }
}
