import Combine
import Foundation
import SwiftUI

/// 自定义命令的结果只发布给对应配置；更新配置会取消旧批次并重新执行。
final class CustomItemsModule: ObservableObject, NotchModule {
    let id = "custom"
    let title = "自定义"
    let systemImage = "curlybraces.square"

    @Published private(set) var outputs: [String: String] = [:]
    @Published private(set) var isRunning = false
    @Published private(set) var lastRefresh = Date.distantPast

    private let settings: SettingsStore
    private let queue = DispatchQueue(label: "com.notchdeck.custom", qos: .utility)
    private var cancellables: Set<AnyCancellable> = []
    private var observer: NSObjectProtocol?
    private var cancellation: Shell.Cancellation?
    private var generation = 0
    private var active = false

    init(settings: SettingsStore = .shared) {
        self.settings = settings
    }

    var isAvailable: Bool { !settings.customItems.isEmpty }

    deinit {
        cancellation?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func start() {
        guard !active else { return }
        active = true
        settings.$customItems
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        observer = NotificationCenter.default.addObserver(
            forName: AppModel.panelDidExpand, object: nil, queue: .main) { [weak self] _ in
            // 面板在执行期间反复展开不重复执行同一批命令。
            guard let self, !self.isRunning else { return }
            self.refresh()
        }
    }

    func stop() {
        active = false
        generation += 1
        cancellation?.cancel()
        cancellation = nil
        isRunning = false
        cancellables.removeAll()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        outputs = [:]
    }

    func content() -> some View { CustomItemsView(module: self) }

    func refresh() {
        guard active, settings.config(for: id).enabled else { return }
        generation += 1
        let currentGeneration = generation
        cancellation?.cancel()
        let token = Shell.Cancellation()
        cancellation = token
        let items = settings.customItems
        outputs = outputs.filter { id, _ in items.contains { $0.id == id } }
        guard !items.isEmpty else {
            isRunning = false
            return
        }
        isRunning = true
        queue.async { [weak self] in
            var results: [String: String] = [:]
            for item in items {
                guard !token.isCancelled else { break }
                let result = Shell.execute("/bin/zsh", arguments: ["-lc", item.command],
                                           timeout: 6, cancellation: token)
                results[item.id] = Self.display(result)
            }
            DispatchQueue.main.async {
                guard let self, self.active, self.generation == currentGeneration,
                      self.settings.customItems == items else { return }
                self.outputs = results
                self.isRunning = false
                self.cancellation = nil
                self.lastRefresh = Date()
            }
        }
    }

    static func display(_ result: Shell.Result) -> String {
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let error = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let message: String
        switch result.completion {
        case .exited(0): message = output.isEmpty ? "（执行成功，无输出）" : output
        case .exited(let code): message = "（退出码 \(code)）\n" + (error.isEmpty ? output : error)
        case .timedOut: message = "（执行超时，已停止）"
        case .cancelled: message = "（已取消）"
        case .launchFailed: message = "（启动失败）\n" + error
        }
        return message + (result.outputTruncated ? "\n（输出过长，已截断）" : "")
    }

    func output(for item: CustomItem) -> String? { outputs[item.id] }
}
