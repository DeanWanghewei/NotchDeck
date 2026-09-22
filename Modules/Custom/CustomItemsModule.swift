import Combine
import Foundation
import SwiftUI

/// 自定义命令的结果只发布给对应配置；更新配置会取消旧批次并重新执行。
final class CustomItemsModule: ObservableObject, NotchModule {
    /// 热力图样本：value 为 nil 表示一次失败（命令非 0 退出或超时），渲染为红色方格
    struct CustomHeatmapSample: Equatable {
        let value: Double?
        static let failure = CustomHeatmapSample(value: nil)
        static func value(_ value: Double) -> CustomHeatmapSample { CustomHeatmapSample(value: value) }
    }

    let id = "custom"
    let title = "自定义"
    let systemImage = "curlybraces.square"

    @Published private(set) var outputs: [String: String] = [:]
    /// 热力图子项的数值序列：命令一次输出多个数值时整体替换；只输出单个数值时按刷新累积为趋势
    @Published private(set) var samples: [String: [CustomHeatmapSample]] = [:]
    /// 执行成功但输出中未解析到数值的热力图子项
    @Published private(set) var unparsedHeatmapIDs: Set<String> = []
    @Published private(set) var isRunning = false
    @Published private(set) var lastRefresh = Date.distantPast

    /// 单值热力图最多保留的历史样本数（同时限制一次输出的解析数量）
    static let sampleLimit = 90
    /// 有热力图子项时的后台探测间隔；文本子项不轮询，仅面板展开时执行
    static let defaultPollInterval: TimeInterval = 30

    private let settings: SettingsStore
    private let pollInterval: TimeInterval
    private let queue = DispatchQueue(label: "com.notchdeck.custom", qos: .utility)
    private var cancellables: Set<AnyCancellable> = []
    private var observer: NSObjectProtocol?
    private var pollTimer: Timer?
    private var cancellation: Shell.Cancellation?
    private var generation = 0
    private var active = false
    /// id → 生成当前历史序列的命令；命令变更后历史重新累积，避免混入旧数据
    private var sampleCommands: [String: String] = [:]

    init(settings: SettingsStore = .shared,
         pollInterval: TimeInterval = CustomItemsModule.defaultPollInterval) {
        self.settings = settings
        self.pollInterval = pollInterval
    }

    var isAvailable: Bool { !settings.customItems.isEmpty }

    deinit {
        cancellation?.cancel()
        pollTimer?.invalidate()
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
        // 监控类热力图子项（如网络探测）在后台持续采样，面板关闭时趋势也能累积
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            guard let self, self.active, !self.isRunning,
                  self.settings.customItems.contains(where: { $0.display == .heatmap }) else { return }
            self.refresh()
        }
        pollTimer?.tolerance = pollInterval / 6
    }

    func stop() {
        active = false
        generation += 1
        cancellation?.cancel()
        cancellation = nil
        isRunning = false
        cancellables.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        outputs = [:]
        samples = [:]
        sampleCommands = [:]
        unparsedHeatmapIDs = []
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
        func stillPresent(_ id: String) -> Bool { items.contains { $0.id == id } }
        outputs = outputs.filter { id, _ in stillPresent(id) }
        // @Published 内容不变也会重新发布；过滤后无变化就不赋值，避免向订阅方重复推送同一序列
        let keptSamples = samples.filter { id, _ in stillPresent(id) }
        if keptSamples != samples { samples = keptSamples }
        let keptUnparsed = unparsedHeatmapIDs.filter { stillPresent($0) }
        if keptUnparsed != unparsedHeatmapIDs { unparsedHeatmapIDs = keptUnparsed }
        sampleCommands = sampleCommands.filter { id, _ in stillPresent(id) }
        guard !items.isEmpty else {
            isRunning = false
            return
        }
        isRunning = true
        queue.async { [weak self] in
            var results: [String: String] = [:]
            var parsed: [String: [Double]] = [:]
            var failed: Set<String> = []
            for item in items {
                guard !token.isCancelled else { break }
                let result = Shell.execute("/bin/zsh", arguments: ["-lc", item.command],
                                           timeout: 6, cancellation: token)
                results[item.id] = Self.display(result)
                guard item.display == .heatmap else { continue }
                switch result.completion {
                case .exited(0):
                    parsed[item.id] = Self.numbers(in: result.output, limit: Self.sampleLimit)
                case .cancelled:
                    break
                default:
                    // 监控类子项：非 0 退出 / 超时记为一次失败样本（红色方格），错误详情在悬停提示里
                    failed.insert(item.id)
                }
            }
            DispatchQueue.main.async {
                guard let self, self.active, self.generation == currentGeneration,
                      self.settings.customItems == items else { return }
                self.outputs = results
                self.unparsedHeatmapIDs = Set(parsed.filter { $0.value.isEmpty }.keys)
                var merged: [String: [CustomHeatmapSample]] = [:]
                for (id, values) in parsed where !values.isEmpty {
                    if values.count == 1 {
                        merged[id] = self.accumulated(id: id, command: self.command(of: id, in: items),
                                                      sample: .value(values[0]))
                    } else {
                        merged[id] = values.map(CustomHeatmapSample.value)
                        // 整体替换的序列不带历史语义，清掉累积锚点
                        self.sampleCommands[id] = nil
                    }
                }
                for id in failed {
                    merged[id] = self.accumulated(id: id, command: self.command(of: id, in: items),
                                                  sample: .failure)
                }
                self.samples = merged
                self.isRunning = false
                self.cancellation = nil
                self.lastRefresh = Date()
            }
        }
    }

    private func command(of id: String, in items: [CustomItem]) -> String {
        items.first { $0.id == id }?.command ?? ""
    }

    /// 追加一个样本并滚动截断；命令变更后从新序列重新开始
    private func accumulated(id: String, command: String,
                             sample: CustomHeatmapSample) -> [CustomHeatmapSample] {
        var history = sampleCommands[id] == command ? (samples[id] ?? []) : []
        history.append(sample)
        if history.count > Self.sampleLimit {
            history.removeFirst(history.count - Self.sampleLimit)
        }
        sampleCommands[id] = command
        return history
    }

    /// 从命令输出提取数值：token 以空白 / 逗号 / 分号分隔，支持 "42"、"3.14"、"45%" 等写法，
    /// 无法解析的 token 忽略；适配 `curl … | jq '.[]'` 之类脚本的纯数字输出。
    /// 分隔符必须用独立的单字符字面量：同一字面量里 "\r\n" 相邻会合并为一个字素簇字符，
    /// 导致集合里没有单独的换行 / 回车，按行输出的数字就切不开了。
    private static let separators: Set<Character> = [" ", "\t", "\n", "\r", ",", ";"]

    static func numbers(in output: String, limit: Int) -> [Double] {
        guard limit > 0 else { return [] }
        var values: [Double] = []
        for token in output.split(whereSeparator: { separators.contains($0) }) {
            var text = Substring(token)
            if text.hasSuffix("%") { text = text.dropLast() }
            guard let value = Double(text), value.isFinite else { continue }
            values.append(value)
            if values.count >= limit { break }
        }
        return values
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
