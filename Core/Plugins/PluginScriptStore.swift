import CryptoKit
import Foundation

/// 适配脚本落盘在应用 Data 目录（与订阅凭据同一棵树）：
/// 目录 0700、文件 0600、同目录临时文件原子替换；每次读取复验 sha256，
/// 与 manifest 不符即视为未安装——磁盘脚本被篡改不会进入运行时。
final class PluginScriptStore {
    struct Manifest: Codable, Equatable {
        let version: String
        let sha256: String
        let downloadedAt: Date
    }

    struct Installed {
        let source: String
        let manifest: Manifest
    }

    static let shared = PluginScriptStore()
    private let root: URL

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("NotchDeck/Plugins")
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            self.root = base
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func directory(for pluginID: String) -> URL {
        root.appendingPathComponent(pluginID, isDirectory: true)
    }

    /// manifest 单读：市场做版本比对时不必加载与校验脚本正文。
    func installedManifest(pluginID: String) -> Manifest? {
        guard let data = try? Data(contentsOf: directory(for: pluginID).appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
        return manifest
    }

    /// 返回经哈希复验的脚本正文；任何不一致都按“未安装”处理。
    func installed(pluginID: String) -> Installed? {
        guard let manifest = installedManifest(pluginID: pluginID) else { return nil }
        let scriptURL = directory(for: pluginID).appendingPathComponent("adapter.js")
        guard let data = try? Data(contentsOf: scriptURL),
              Self.sha256Hex(data) == manifest.sha256,
              let source = String(data: data, encoding: .utf8), !source.isEmpty,
              data.count <= PluginScriptClient.maximumBytes else { return nil }
        return Installed(source: source, manifest: manifest)
    }

    func install(pluginID: String, data: Data, manifest: Manifest) throws {
        let dir = directory(for: pluginID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try writeAtomically(dir.appendingPathComponent("adapter.js"), data: data)
        let encoded = try JSONEncoder().encode(manifest)
        try writeAtomically(dir.appendingPathComponent("manifest.json"), data: encoded)
    }

    func uninstall(pluginID: String) {
        try? FileManager.default.removeItem(at: directory(for: pluginID))
    }

    /// 原子替换：先写同目录临时文件再 rename，任一时刻磁盘上都是完整版本。
    /// 不用 Data.write(.atomic/.completeFileProtection)——其内部 mkstemp 在
    /// 沙箱测试进程下会 EPERM，且文件保护选项在无对应 entitlement 的 macOS 进程中失败。
    private func writeAtomically(_ destination: URL, data: Data) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw PluginScriptError.storage
        }
    }
}
