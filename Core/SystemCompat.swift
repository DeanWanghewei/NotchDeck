import Foundation

/// 实验性系统级正在播放的系统兼容性信息
enum SystemCompat {
    /// 本构建实测通过的系统（探针 + 端到端验证：适配器读取、控制指令、封面）
    static let verifiedVersion = "26.6.2"
    static let verifiedBuild = "25G83"

    /// 适配器机制（com.apple.perl 授权路径）自 macOS 15.4 起才有意义
    static var mechanismSupported: Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.majorVersion > 15 || (version.majorVersion == 15 && version.minorVersion >= 4)
    }

    static var buildIdentifier: String {
        // 形如 "Version 26.6.2 (Build 25G83)"
        let description = ProcessInfo.processInfo.operatingSystemVersionString
        guard let range = description.range(of: "Build ") else { return "未知" }
        return String(description[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: ") "))
    }

    static var currentDescription: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion) (\(buildIdentifier))"
    }

    /// 当前系统相对实测版本的适配状态
    enum Adaptation {
        case verified      // 实测通过
        case untested      // 机制可用，此版本未经实测
        case unsupported   // 机制不可用
    }

    static var adaptation: Adaptation {
        guard mechanismSupported else { return .unsupported }
        return buildIdentifier == verifiedBuild ? .verified : .untested
    }
}
