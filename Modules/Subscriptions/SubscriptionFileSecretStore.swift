import CryptoKit
import Darwin
import Foundation

/// 本地随机密钥避免硬编码；同用户若能同时读取密钥与密文仍可解密，不承诺抵御同用户恶意程序。
/// 不访问旧钥匙串：保留账号元数据，由用户重新输入/导入，避免升级时触发系统授权。
struct SubscriptionFileSecretStore: SubscriptionSecretStore {
    let directory: URL
    private static let processLock = NSLock()
    private let maximumBytes = 256 * 1024 + 128

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NotchDeck/Data/SubscriptionCredentials", isDirectory: true)) {
        self.directory = directory
    }

    private func identity(_ provider: SubscriptionProvider, _ id: String) -> Data {
        Data("NotchDeck.subscription.v1:\(provider.rawValue):\(id)".utf8)
    }

    func credentialURL(provider: SubscriptionProvider, accountID: String) -> URL {
        let hash = SHA256.hash(data: identity(provider, accountID)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".enc")
    }

    /// 进程锁保护多实例，文件锁保护同时运行的应用进程，避免首次生成密钥或覆盖时互相竞争。
    private func access<T>(create: Bool, _ body: () throws -> T) throws -> T? {
        Self.processLock.lock(); defer { Self.processLock.unlock() }
        do {
            var info = stat()
            if lstat(directory.path, &info) != 0 {
                guard errno == ENOENT else { throw SubscriptionQuotaError.credentialStorage }
                guard create else { return nil }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid(), chmod(directory.path, 0o700) == 0 else {
                throw SubscriptionQuotaError.credentialStorage
            }
            let fd = open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw SubscriptionQuotaError.credentialStorage }
            defer { close(fd) }
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
                  info.st_nlink == 1, fchmod(fd, 0o600) == 0, flock(fd, LOCK_EX) == 0 else {
                throw SubscriptionQuotaError.credentialStorage
            }
            defer { flock(fd, LOCK_UN) }
            return try body()
        } catch { throw SubscriptionQuotaError.credentialStorage }
    }

    private func readFile(_ url: URL) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw SubscriptionQuotaError.credentialStorage
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_size <= maximumBytes,
              fchmod(fd, 0o600) == 0 else { throw SubscriptionQuotaError.credentialStorage }
        var bytes = [UInt8](repeating: 0, count: maximumBytes + 1)
        var total = 0
        while total < bytes.count {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress!.advanced(by: total), buffer.count - total)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw SubscriptionQuotaError.credentialStorage
            }
            if count == 0 { break }
            total += count
        }
        guard total <= maximumBytes else { throw SubscriptionQuotaError.credentialStorage }
        return Data(bytes.prefix(total))
    }

    /// 从创建时就是 0600；同目录临时文件 + rename 保证失败不会先截断已有凭据。
    private func writeFile(_ data: Data, to url: URL) throws {
        let temporary = directory.appendingPathComponent(".tmp-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SubscriptionQuotaError.credentialStorage }
        defer { close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SubscriptionQuotaError.credentialStorage }
                offset += count
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else {
            throw SubscriptionQuotaError.credentialStorage
        }
    }

    private func key(create: Bool) throws -> SymmetricKey {
        let url = directory.appendingPathComponent("master-key-v1")
        if let data = try readFile(url) {
            guard data.count == 32 else { throw SubscriptionQuotaError.credentialStorage }
            return SymmetricKey(data: data)
        }
        // 丢失密钥时不得静默生成新密钥，导致旧账号永久无法解密。
        guard create, try !FileManager.default.contentsOfDirectory(atPath: directory.path).contains(where: { $0.hasSuffix(".enc") }) else {
            throw SubscriptionQuotaError.credentialStorage
        }
        let key = SymmetricKey(size: .bits256)
        try writeFile(key.withUnsafeBytes { Data($0) }, to: url)
        return key
    }

    private func read(_ provider: SubscriptionProvider, _ id: String) throws -> Data? {
        try access(create: false) {
            guard let data = try readFile(credentialURL(provider: provider, accountID: id)) else { return nil }
            guard data.first == 1 else { throw SubscriptionQuotaError.credentialStorage }
            let box = try AES.GCM.SealedBox(combined: data.dropFirst())
            return try AES.GCM.open(box, using: key(create: false), authenticating: identity(provider, id))
        } ?? nil
    }

    private func save(_ data: Data, _ provider: SubscriptionProvider, _ id: String) throws {
        guard data.count <= 256 * 1024 else { throw SubscriptionQuotaError.credentialStorage }
        _ = try access(create: true) {
            let box = try AES.GCM.seal(data, using: key(create: true), authenticating: identity(provider, id))
            guard let combined = box.combined else { throw SubscriptionQuotaError.credentialStorage }
            try writeFile(Data([1]) + combined, to: credentialURL(provider: provider, accountID: id))
        }
    }

    private func remove(_ provider: SubscriptionProvider, _ id: String) throws {
        _ = try access(create: false) {
            let result = unlink(credentialURL(provider: provider, accountID: id).path)
            guard result == 0 || errno == ENOENT else { throw SubscriptionQuotaError.credentialStorage }
        }
    }

    func readGLMKey(accountID: String) throws -> String? {
        guard let data = try read(.glm, accountID) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else { throw SubscriptionQuotaError.credentialStorage }
        return value
    }
    func saveGLMKey(_ key: String, accountID: String) throws { try save(Data(key.utf8), .glm, accountID) }
    func removeGLMKey(accountID: String) throws { try remove(.glm, accountID) }
    func readCodexAuth(accountID: String) throws -> Data? { try read(.codex, accountID) }
    func saveCodexAuth(_ data: Data, accountID: String) throws { try save(data, .codex, accountID) }
    func removeCodexAuth(accountID: String) throws { try remove(.codex, accountID) }
    func readMiniMaxKey(accountID: String) throws -> String? {
        guard let data = try read(.minimaxCN, accountID) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else { throw SubscriptionQuotaError.credentialStorage }
        return value
    }
    func saveMiniMaxKey(_ key: String, accountID: String) throws { try save(Data(key.utf8), .minimaxCN, accountID) }
    func removeMiniMaxKey(accountID: String) throws { try remove(.minimaxCN, accountID) }
}
