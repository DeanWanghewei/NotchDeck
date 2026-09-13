import AppKit
import Combine
import SwiftUI

/// 已安装应用扫描（/Applications、/System/Applications、~/Applications 及其一级子目录）
enum InstalledApps {
    struct InstalledApp: Identifiable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
        let path: String
    }

    static func scan() -> [InstalledApp] {
        let fileManager = FileManager.default
        var roots = ["/Applications", "/System/Applications"]
        let homeApplications = NSHomeDirectory() + "/Applications"
        roots.append(homeApplications)

        var paths: [String] = []
        for root in roots {
            guard let items = try? fileManager.contentsOfDirectory(atPath: root) else { continue }
            for item in items where item.hasSuffix(".app") {
                paths.append(root + "/" + item)
            }
            // 一级子目录（Utilities 等）
            for item in items where !item.contains(".") {
                let subdirectory = root + "/" + item
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: subdirectory, isDirectory: &isDirectory),
                      isDirectory.boolValue,
                      let subItems = try? fileManager.contentsOfDirectory(atPath: subdirectory) else { continue }
                for subItem in subItems where subItem.hasSuffix(".app") {
                    paths.append(subdirectory + "/" + subItem)
                }
            }
        }

        var seenBundleIDs = Set<String>()
        var apps: [InstalledApp] = []
        for path in paths {
            guard let bundle = Bundle(path: path),
                  let bundleID = bundle.bundleIdentifier,
                  bundleID != "com.notchdeck.app",
                  !seenBundleIDs.contains(bundleID) else { continue }
            seenBundleIDs.insert(bundleID)
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            apps.append(InstalledApp(bundleID: bundleID, name: name, path: path))
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// 应用快捷控制模块：用户从已安装应用中挑选添加，
/// 面板内一键启动/退出并显示运行状态；白名单应用带"已适配"标记。
/// 全部通过 NSWorkspace / NSRunningApplication 实现，零权限。
final class AppLauncherModule: ObservableObject, NotchModule {
    let id = "apps"
    let title = "应用"
    let systemImage = "square.grid.2x2"

    @Published private(set) var runningBundleIDs: Set<String> = []

    private let settings = SettingsStore.shared
    private var workspaceObservers: [NSObjectProtocol] = []
    private var panelObserver: NSObjectProtocol?

    deinit {
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        if let panelObserver {
            NotificationCenter.default.removeObserver(panelObserver)
        }
    }

    var isAvailable: Bool {
        !settings.panelApps.isEmpty
    }

    func start() {
        guard workspaceObservers.isEmpty else { return }
        refreshRunning()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            workspaceObservers.append(workspaceCenter.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshRunning()
            })
        }
        panelObserver = NotificationCenter.default.addObserver(
            forName: AppModel.panelDidExpand, object: nil, queue: .main) { [weak self] _ in
            self?.refreshRunning()
        }
    }

    func stop() {
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
        if let panelObserver {
            NotificationCenter.default.removeObserver(panelObserver)
        }
        panelObserver = nil
    }

    func content() -> some View {
        AppLauncherView(module: self)
    }

    // MARK: - 状态与操作

    func isRunning(_ app: PanelApp) -> Bool {
        runningBundleIDs.contains(app.bundleID)
    }

    func isAdapted(_ app: PanelApp) -> Bool {
        AdaptedApps.isAdapted(app.bundleID)
    }

    func icon(for app: PanelApp) -> NSImage {
        NSWorkspace.shared.icon(forFile: app.path)
    }

    func open(_ app: PanelApp) {
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: app.path),
            configuration: NSWorkspace.OpenConfiguration())
    }

    /// 优雅退出（应用可取消，如弹出保存对话框）；对同用户应用无需权限
    func quit(_ app: PanelApp) {
        for running in NSWorkspace.shared.runningApplications
        where running.bundleIdentifier == app.bundleID {
            running.terminate()
        }
    }

    private func refreshRunning() {
        runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
}
