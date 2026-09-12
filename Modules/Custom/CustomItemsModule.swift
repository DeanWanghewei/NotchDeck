import Combine
import Foundation
import SwiftUI

/// 自定义子项模块：执行用户定义的 shell 命令并展示输出。
/// 这是用户向面板集成自己内容的第一入口；后续可基于 NotchModule 协议扩展更丰富的插件。
final class CustomItemsModule: ObservableObject, NotchModule {
    let id = "custom"
    let title = "自定义"
    let systemImage = "curlybraces.square"

    @Published private(set) var outputs: [String: String] = [:]
    @Published private(set) var isRunning = false
    @Published private(set) var lastRefresh = Date.distantPast

    private var cancellables: Set<AnyCancellable> = []
    private var observer: NSObjectProtocol?

    var isAvailable: Bool {
        !SettingsStore.shared.customItems.isEmpty
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func start() {
        // 子项增删改 → 立即刷新
        SettingsStore.shared.$customItems
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        // 面板展开时刷新
        observer = NotificationCenter.default.addObserver(
            forName: AppModel.panelDidExpand, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    func content() -> some View {
        CustomItemsView(module: self)
    }

    /// 依次执行所有子项命令（后台队列，单条超时 6 秒）
    func refresh() {
        let items = SettingsStore.shared.customItems
        guard !items.isEmpty else {
            outputs = [:]
            return
        }
        guard !isRunning else { return }
        isRunning = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var results: [String: String] = [:]
            for item in items {
                let output = Shell.run("/bin/zsh", arguments: ["-lc", item.command], timeout: 6)
                    ?? "（执行失败或超时）"
                results[item.id] = output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            DispatchQueue.main.async {
                self?.outputs = results
                self?.isRunning = false
                self?.lastRefresh = Date()
            }
        }
    }

    func output(for item: CustomItem) -> String? {
        outputs[item.id]
    }
}
