import AppKit
import Combine
import Foundation
import SwiftUI
import XCTest

/// 示例模板的结构不变量：模板是给用户直接用的活文档，字段缺失或命令写错都要在测试里暴露
final class CustomItemsPresetTests: XCTestCase {
    func testPresetIdentifiersAndNamesAreUnique() {
        let ids = CustomItemPresets.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "模板 id 必须唯一")
        let names = CustomItemPresets.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "模板名必须唯一（文档按名字一一对应）")
    }

    func testPresetFieldsAreFilledAndCommandsHaveNoBlankLine() {
        for preset in CustomItemPresets.all {
            XCTAssertFalse(preset.id.isEmpty, "模板缺少 id")
            XCTAssertFalse(preset.name.isEmpty, "模板缺少名称：\(preset.id)")
            XCTAssertFalse(preset.command.isEmpty, "模板缺少命令：\(preset.id)")
            XCTAssertFalse(preset.note.isEmpty, "模板缺少说明：\(preset.id)")
            for line in preset.command.split(separator: "\n", omittingEmptySubsequences: false) {
                XCTAssertFalse(line.trimmingCharacters(in: .whitespaces).isEmpty,
                               "命令不能含空行：\(preset.name)")
            }
        }
    }

    func testEveryPresetBelongsToAKnownCategoryAndEveryCategoryHasTemplates() {
        let known = Set(CustomItemPresets.Category.allCases)
        for preset in CustomItemPresets.all {
            XCTAssertTrue(known.contains(preset.category), "分类不合法：\(preset.name)")
        }
        for category in CustomItemPresets.categories {
            XCTAssertFalse(CustomItemPresets.presets(in: category).isEmpty,
                           "分类「\(category.rawValue)」下应有模板")
        }
        // 分组结果与全量列表一一对应（分组展示不能漏模板）
        let grouped = CustomItemPresets.categories.flatMap { CustomItemPresets.presets(in: $0) }
        XCTAssertEqual(grouped.count, CustomItemPresets.all.count)
        XCTAssertEqual(Set(grouped.map(\.id)), Set(CustomItemPresets.all.map(\.id)))
    }

    /// 含管道的命令必须前置 pipefail：否则上游失败会被管道吞掉、失败不标红
    func testCommandsWithPipesDeclarePipefail() {
        for preset in CustomItemPresets.all where preset.command.contains("|") {
            XCTAssertTrue(preset.command.hasPrefix("set -o pipefail; "),
                          "含管道的命令必须以 `set -o pipefail; ` 开头：\(preset.name)")
        }
    }

    /// 模板是给用户复制即用的，不能写死本机路径
    func testCommandsDoNotContainMachineSpecificPaths() {
        for preset in CustomItemPresets.all {
            XCTAssertFalse(preset.command.contains("/Users/"), "命令含本机专有路径：\(preset.name)")
            XCTAssertFalse(preset.command.contains("/Volumes/"), "命令含本机专有路径：\(preset.name)")
        }
    }

    /// 语法自检：zsh -n 只解析不执行，不会真的发起网络请求
    func testPresetCommandsPassShellSyntaxCheck() {
        for preset in CustomItemPresets.all {
            let result = Shell.execute("/bin/zsh", arguments: ["-n", "-c", preset.command], timeout: 5)
            XCTAssertEqual(result.completion, .exited(0),
                           "命令语法有误：\(preset.name)：\(result.errorOutput)")
        }
    }

    /// 对照用例：确认 `zsh -n` 真的能挡下语法错误，否则上面的检查形同虚设
    func testShellSyntaxCheckRejectsBrokenCommand() {
        let broken = Shell.execute("/bin/zsh", arguments: ["-n", "-c", "if then"], timeout: 5)
        XCTAssertNotEqual(broken.completion, .exited(0), "语法错误的命令应被 zsh -n 拒绝")
    }

    /// 本地类模板实跑：只跑不依赖网络 / docker / git / 占位符的模板，断言能执行成功并解析出数字。
    /// 语法检查挡不住「参数非法」这类运行期错误（历史模板 ps -arcHo 就因此一直是坏的）。
    func testLocalPresetsRunAndParseNumbers() throws {
        let runnable = ["磁盘占用", "磁盘剩余空间", "内存占用百分比", "CPU 总占用"]
        var denied: [String] = []
        for name in runnable {
            let preset = try XCTUnwrap(CustomItemPresets.all.first { $0.name == name })
            // 超时与模块内执行一致（6 秒），避免模板在产品里必然超时
            let result = Shell.execute("/bin/zsh", arguments: ["-lc", preset.command], timeout: 6)
            if isEnvironmentDenied(result) {
                denied.append(name)
                continue
            }
            XCTAssertEqual(result.completion, .exited(0),
                           "模板执行失败：\(name)：\(result.errorOutput)\(result.output)")
            XCTAssertFalse(CustomItemsModule.numbers(in: result.output, limit: 90).isEmpty,
                           "模板没有解析出数字：\(name)：\(result.output)")
        }
        // 受限环境（沙箱）拒绝执行某些系统程序：已跑通的照常断言，被拒的单独说明
        if !denied.isEmpty {
            throw XCTSkip("受限环境禁止执行这些模板依赖的系统程序，跳过：\(denied.joined(separator: "、"))")
        }
    }

    /// 受限环境（沙箱）会拒绝执行某些系统程序；这种情况跳过而不是判失败
    private func isEnvironmentDenied(_ result: Shell.Result) -> Bool {
        if case .launchFailed = result.completion { return true }
        let message = (result.errorOutput + result.output).lowercased()
        return message.contains("operation not permitted") || message.contains("permission denied")
    }
}

/// 取数解析的边界行为：这些断言锁住「当前真实行为」，改动前先想清楚
final class CustomItemsNumberParsingTests: XCTestCase {
    func testNumbersHandlesNegativeAndPercentSuffix() {
        XCTAssertEqual(CustomItemsModule.numbers(in: "-3", limit: 10), [-3])
        XCTAssertEqual(CustomItemsModule.numbers(in: "45%", limit: 10), [45])
        XCTAssertEqual(CustomItemsModule.numbers(in: "-0.5%", limit: 10), [-0.5])
    }

    func testNumbersHandlesMultilineOutput() {
        XCTAssertEqual(CustomItemsModule.numbers(in: "1\n2\n3", limit: 10), [1, 2, 3])
        XCTAssertEqual(CustomItemsModule.numbers(in: "1 2\n3 4", limit: 10), [1, 2, 3, 4])
        XCTAssertEqual(CustomItemsModule.numbers(in: "a\n5\nb", limit: 10), [5])
    }

    /// 千分位逗号与分隔符逗号无法区分：1,234 会被切成 1 和 234。
    /// 这是当前真实行为（文档「排错」也提示 1,234 会被切错），不是回归。
    func testNumbersSplitsThousandsSeparatorAsCurrentBehavior() {
        XCTAssertEqual(CustomItemsModule.numbers(in: "1,234", limit: 10), [1, 234])
    }

    func testNumbersTruncatesAtLimit() {
        let many = (1...20).map(String.init).joined(separator: " ")
        XCTAssertEqual(CustomItemsModule.numbers(in: many, limit: 5), [1, 2, 3, 4, 5])
        XCTAssertEqual(CustomItemsModule.numbers(in: many, limit: 0), [])
        XCTAssertEqual(CustomItemsModule.numbers(in: many, limit: -1), [])
    }

    func testNumbersIgnoresNonFiniteValues() {
        XCTAssertEqual(CustomItemsModule.numbers(in: "nan inf -inf 5", limit: 10), [5])
    }
}

/// 探测间隔：存储、默认值与非法值回退
final class CustomItemsPollIntervalTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "com.notchdeck.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testDefaultIntervalIsThirtySeconds() {
        let settings = SettingsStore(defaults: defaults)
        // 旧用户没有该键时行为不变：仍是 30 秒
        XCTAssertEqual(settings.customPollInterval, 30)
        XCTAssertEqual(CustomItemsModule.defaultPollInterval, 30)
        XCTAssertEqual(CustomPollInterval.defaultValue, CustomItemsModule.defaultPollInterval)
    }

    func testIntervalPersistsAcrossRestart() {
        let settings = SettingsStore(defaults: defaults)
        settings.customPollInterval = 60
        XCTAssertEqual(SettingsStore(defaults: defaults).customPollInterval, 60)
        XCTAssertEqual(defaults.object(forKey: "settings.customPollInterval") as? Double, 60)
    }

    func testIllegalStoredIntervalFallsBackToDefault() {
        for illegal in [0.0, -5.0, 45.0, 10000.0] {
            defaults.set(illegal, forKey: "settings.customPollInterval")
            XCTAssertEqual(SettingsStore(defaults: defaults).customPollInterval, 30,
                           "非法间隔应回退默认：\(illegal)")
        }
    }

    func testAssigningIllegalIntervalIsNormalizedImmediately() {
        let settings = SettingsStore(defaults: defaults)
        settings.customPollInterval = 0
        XCTAssertEqual(settings.customPollInterval, 30)
        settings.customPollInterval = 45
        XCTAssertEqual(settings.customPollInterval, 30)
        settings.customPollInterval = 300
        XCTAssertEqual(settings.customPollInterval, 300)
    }

    func testOptionsCoverTheDocumentedPickerValues() {
        XCTAssertEqual(CustomPollInterval.options, [10, 30, 60, 300])
        XCTAssertEqual(CustomPollInterval.label(10), "10 秒")
        XCTAssertEqual(CustomPollInterval.label(30), "30 秒")
        XCTAssertEqual(CustomPollInterval.label(60), "1 分钟")
        XCTAssertEqual(CustomPollInterval.label(300), "5 分钟")
    }

    @MainActor
    func testModuleFollowsConfiguredInterval() {
        let settings = SettingsStore(defaults: defaults)
        settings.customPollInterval = 10
        let module = CustomItemsModule(settings: settings)
        XCTAssertEqual(module.pollInterval, 10)
        module.start()
        defer { module.stop() }
        // 调整间隔后立即重建定时器，不必等旧定时器自然结束
        settings.customPollInterval = 60
        let settled = expectation(description: "间隔变更生效")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(module.pollInterval, 60)
    }
}

/// 采样行为：后台轮询只探测热力图子项，文本子项不参与轮询
final class CustomItemsPollingBehaviourTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "com.notchdeck.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    /// 轮询定时器不得重跑文本子项：间隔可以调到 10 秒，
    /// 若轮询带上文本命令，用户的一次网络请求会变成每 10 秒一次。
    @MainActor
    func testPollingDoesNotRerunTextItems() {
        let settings = SettingsStore(defaults: defaults)
        let marker = NSTemporaryDirectory() + "notchdeck-text-poll-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: marker) }
        let text = CustomItem(name: "文本子项", command: "printf x >> \(marker)")
        let heat = CustomItem(name: "热力子项", command: "printf 1", display: .heatmap)
        settings.customItems = [text, heat]
        let module = CustomItemsModule(settings: settings, pollInterval: 0.3)
        module.start()
        defer { module.stop() }

        var cancellables = Set<AnyCancellable>()
        var polled = false
        let sampled = expectation(description: "轮询产生热力图样本")
        module.$samples.sink { samples in
            guard !polled, samples[heat.id]?.isEmpty == false else { return }
            polled = true
            sampled.fulfill()
        }.store(in: &cancellables)
        wait(for: [sampled], timeout: 5)

        // 再等几轮，确认轮询一直在跑而文本命令始终没被执行
        let settled = expectation(description: "多轮轮询结束")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker),
                       "后台轮询不应重跑文本子项")

        // 手动刷新会执行文本子项（证明上面的断言不是因为命令本身跑不起来）
        let executed = expectation(description: "手动刷新执行文本子项")
        module.$outputs.sink { outputs in
            if outputs[text.id] != nil { executed.fulfill() }
        }.store(in: &cancellables)
        module.refresh()
        wait(for: [executed], timeout: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker),
                      "面板展开 / 手动刷新应执行文本子项")
    }
}

/// 文档与模板一致性：改了模板忘改文档要在这里被挡住
final class CustomItemsDocumentationTests: XCTestCase {
    private func documentation() throws -> String {
        let url = try XCTUnwrap(Bundle(for: CustomItemsModule.self)
            .url(forResource: "custom-items", withExtension: "md"),
                                "测试资源里找不到 docs/custom-items.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testDocumentationHeadingsMatchPresetNames() throws {
        let document = try documentation()
        let headings = document.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("### ") else { return nil }
            return String(line.dropFirst("### ".count)).trimmingCharacters(in: .whitespaces)
        }
        let names = CustomItemPresets.all.map(\.name)
        XCTAssertEqual(Set(headings), Set(names), "文档小节标题与模板名必须一一对应")
        XCTAssertEqual(headings.count, names.count, "文档小节标题不应重复")
    }

    func testDocumentationContainsEveryPresetCommand() throws {
        let document = try documentation()
        for preset in CustomItemPresets.all {
            XCTAssertTrue(document.contains(preset.command),
                          "文档缺少模板命令原文：\(preset.name)")
        }
    }

    func testDocumentationExplainsNewRules() throws {
        let document = try documentation()
        for keyword in ["set -o pipefail", "探测间隔", "未解析到数字", "不补 0"] {
            XCTAssertTrue(document.contains(keyword), "文档缺少规则说明：\(keyword)")
        }
    }
}

/// 设置页自渲染：分组标题、Picker 对齐与中文截断必须目检（深浅两版）
@MainActor
final class CustomItemsSettingsRenderTests: XCTestCase {
    func testRenderCustomSettingsWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["NOTCHDECK_RENDER_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let suite = "com.notchdeck.custom.render.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.customItems = [
            CustomItem(name: "服务响应速度", command: "curl -sfo /dev/null -w '%{time_total}' https://www.apple.com/",
                       display: .heatmap),
            CustomItem(name: "本机 IP", command: "ipconfig getifaddr en0"),
        ]
        let view = Form {
            CustomModuleSettingsView(settings: settings)
        }
        .formStyle(.grouped)
        try render(view, name: "custom-settings", size: NSSize(width: 760, height: 1760), directory: directory)
    }

    private func render<V: View>(_ view: V, name: String, size: NSSize, directory: String) throws {
        for dark in [false, true] {
            let host = NSHostingView(rootView: view
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(dark ? Color.black : Color.white)
                .environment(\.colorScheme, dark ? .dark : .light))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            // 屏幕外呈现窗口，让布局与首帧渲染完成后再缓存，避免截到空白帧。
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            window.orderFront(nil)
            let rendered = expectation(description: "等待首帧渲染完成")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { rendered.fulfill() }
            wait(for: [rendered], timeout: 3)
            host.layoutSubtreeIfNeeded()
            defer { window.orderOut(nil) }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                XCTFail("无法渲染"); continue
            }
            host.cacheDisplay(in: host.bounds, to: rep)
            let path = directory + "/" + name + "-" + (dark ? "dark" : "light") + ".png"
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path))
        }
    }
}
