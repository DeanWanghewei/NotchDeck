import Foundation

/// 目录只描述插件；可执行实现必须来自应用随附的 Swift 工厂。
/// schemaVersion 2 起，条目可另声明一个适配脚本：脚本经 sha256 校验后下载，
/// 运行在无 I/O 的 JavaScriptCore 沙箱（只能计算与解析，拿不到密钥明文），主机仍由宿主白名单约束。
struct PluginCatalog: Codable, Equatable {
    let schemaVersion: Int
    var plugins: [PluginListing]

    static let repositoryURL = URL(string: "https://github.com/DeanWanghewei/NotchDeck/tree/main/marketplace")!
    static let downloadURL = URL(string: "https://raw.githubusercontent.com/DeanWanghewei/NotchDeck/main/marketplace/catalog.json")!
    static let releasesURL = URL(string: "https://github.com/DeanWanghewei/NotchDeck/releases")!
    static let maximumBytes = 256 * 1024

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw PluginCatalogError.invalidCatalog }
        guard let catalog = try? JSONDecoder().decode(Self.self, from: data) else {
            throw PluginCatalogError.invalidCatalog
        }
        return try catalog.validated()
    }

    func validated() throws -> Self {
        guard schemaVersion == 1 || schemaVersion == 2 else { throw PluginCatalogError.unsupportedSchema }
        var ids = Set<String>()
        guard plugins.count <= 100, plugins.allSatisfy({ entry in
            !entry.id.isEmpty && entry.id.count <= 64 &&
            entry.id.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 } &&
            ids.insert(entry.id).inserted &&
            !entry.name.isEmpty && entry.name.count <= 80 &&
            !entry.summary.isEmpty && entry.summary.count <= 300 &&
            !entry.details.isEmpty && entry.details.count <= 4000 &&
            !entry.author.isEmpty && entry.author.count <= 80 &&
            entry.systemImage.count <= 80 &&
            PluginVersion(entry.version) != nil && PluginVersion(entry.minimumAppVersion) != nil &&
            entry.capabilities.count <= 12 && entry.capabilities.allSatisfy { !$0.isEmpty && $0.count <= 200 } &&
            Self.isRepositoryLink(entry.documentationURL) && Self.isRepositoryLink(entry.sourceURL) &&
            entry.script.map(Self.isValidScriptSource) ?? true
        }) else { throw PluginCatalogError.invalidCatalog }
        return self
    }

    static func bundled() throws -> Self {
        guard let url = Bundle(for: PluginMarketplace.self).url(forResource: "bundled-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { throw PluginCatalogError.missingBundle }
        return try decode(data)
    }

    private static func isRepositoryLink(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil &&
        url.port == nil && url.path.hasPrefix("/DeanWanghewei/NotchDeck/")
    }

    /// 脚本只允许从本仓库的 raw 地址下载；sha256 限定 64 位小写 hex，与下载内容逐字节比对。
    static func isValidScriptSource(_ script: PluginScriptSource) -> Bool {
        guard let url = URL(string: script.url),
              url.scheme == "https" && url.host == "raw.githubusercontent.com" &&
              url.user == nil && url.password == nil && url.port == nil &&
              url.path.hasPrefix("/DeanWanghewei/NotchDeck/"),
              script.sha256.utf8.count == 64,
              script.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              PluginVersion(script.version) != nil else { return false }
        return true
    }
}

struct PluginListing: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var summary: String
    var details: String
    var systemImage: String
    var author: String
    var version: String
    var minimumAppVersion: String
    var capabilities: [String]
    var documentationURL: URL
    var sourceURL: URL
    /// schemaVersion 2 的可选字段；v1 目录与未声明脚本的条目解码为 nil。
    var script: PluginScriptSource?
}

/// 市场适配脚本来源声明；version 独立于插件实现版本，仅用于脚本自身的更新比对。
struct PluginScriptSource: Codable, Equatable {
    let url: String
    let sha256: String
    let version: String
}

/// 当前目录使用纯数字版本，按分量比较，避免 1.10 被字符串排序判成旧版。
struct PluginVersion: Comparable {
    private let components: [Int]

    init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({
            !$0.isEmpty && $0.count <= 6 && $0.utf8.allSatisfy { (48...57).contains($0) }
        }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        components = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

enum PluginCatalogError: Error, Equatable {
    case invalidCatalog, unsupportedSchema, missingBundle, network, http(Int)

    var message: String {
        switch self {
        case .invalidCatalog: return "插件目录格式无效，已保留当前目录。"
        case .unsupportedSchema: return "该目录需要更新版本的 NotchDeck，已保留当前目录。"
        case .missingBundle: return "未找到应用随附目录，请重新下载 NotchDeck。"
        case .network: return "无法连接 GitHub，仍可使用当前目录。"
        case .http(let status): return "GitHub 目录暂不可用（HTTP \(status)），仍可使用当前目录。"
        }
    }
}
