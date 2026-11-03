import Foundation
import XCTest

final class SubscriptionFileSecretStoreTests: XCTestCase {
    private func withStore(_ body: (SubscriptionFileSecretStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quota-storage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try body(SubscriptionFileSecretStore(directory: root.appendingPathComponent("Data")))
    }

    func testEncryptedRoundTripIsolationAndPermissions() throws {
        try withStore { store in
            XCTAssertNil(try store.readGLMKey(accountID: "one"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
            try store.saveGLMKey("synthetic-secret-one", accountID: "one")
            try store.saveGLMKey("synthetic-secret-two", accountID: "two")
            let auth = Data("synthetic-codex-auth".utf8)
            try store.saveCodexAuth(auth, accountID: "one")
            let restarted = SubscriptionFileSecretStore(directory: store.directory)
            XCTAssertEqual(try restarted.readGLMKey(accountID: "one"), "synthetic-secret-one")
            XCTAssertEqual(try restarted.readGLMKey(accountID: "two"), "synthetic-secret-two")
            XCTAssertEqual(try restarted.readCodexAuth(accountID: "one"), auth)
            let files = try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
            for file in files {
                let data = try Data(contentsOf: file)
                XCTAssertNil(data.range(of: Data("synthetic-secret".utf8)))
                XCTAssertNil(data.range(of: auth))
                XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
            }
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? Int, 0o700)
            try store.removeGLMKey(accountID: "one")
            XCTAssertNil(try store.readGLMKey(accountID: "one"))
            XCTAssertEqual(try store.readGLMKey(accountID: "two"), "synthetic-secret-two")
            XCTAssertEqual(try store.readCodexAuth(accountID: "one"), auth)
        }
    }

    func testTamperingAndAccountSubstitutionAreRejected() throws {
        try withStore { store in
            try store.saveGLMKey("secret", accountID: "one")
            let first = store.credentialURL(provider: .glm, accountID: "one")
            let original = try Data(contentsOf: first)
            try original.write(to: store.credentialURL(provider: .glm, accountID: "two"))
            XCTAssertThrowsError(try store.readGLMKey(accountID: "two"))
            try original.write(to: store.credentialURL(provider: .codex, accountID: "one"))
            XCTAssertThrowsError(try store.readCodexAuth(accountID: "one"))
            var damaged = original
            damaged[damaged.count - 1] ^= 1
            try damaged.write(to: first)
            XCTAssertThrowsError(try store.readGLMKey(accountID: "one"))
            try Data([2]).write(to: first)
            XCTAssertThrowsError(try store.readGLMKey(accountID: "one"))
        }
    }

    /// 同一账号 id 在不同服务下必须互相隔离：凭据的附加数据绑定了服务名。
    func testMiniMaxKeyIsIsolatedFromOtherProviders() throws {
        try withStore { store in
            try store.saveGLMKey("glm-secret", accountID: "same")
            try store.saveMiniMaxKey("minimax-secret", accountID: "same")
            try store.saveCodexAuth(Data("codex-secret".utf8), accountID: "same")
            let restarted = SubscriptionFileSecretStore(directory: store.directory)
            XCTAssertEqual(try restarted.readGLMKey(accountID: "same"), "glm-secret")
            XCTAssertEqual(try restarted.readMiniMaxKey(accountID: "same"), "minimax-secret")
            XCTAssertEqual(try restarted.readCodexAuth(accountID: "same"), Data("codex-secret".utf8))
            // 密文不能跨服务解密：把 MiniMax 密文当 Codex 登录读必须失败。
            let minimaxURL = store.credentialURL(provider: .minimaxCN, accountID: "same")
            try Data(contentsOf: minimaxURL).write(to: store.credentialURL(provider: .codex, accountID: "other"))
            XCTAssertThrowsError(try restarted.readCodexAuth(accountID: "other"))
            try store.removeMiniMaxKey(accountID: "same")
            XCTAssertNil(try restarted.readMiniMaxKey(accountID: "same"))
            XCTAssertEqual(try restarted.readGLMKey(accountID: "same"), "glm-secret")
        }
    }

    func testNonceRotationAndMissingKeyDoNotOverwriteExistingCredentials() throws {
        try withStore { store in
            try store.saveGLMKey("same-secret", accountID: "one")
            let url = store.credentialURL(provider: .glm, accountID: "one")
            let first = try Data(contentsOf: url)
            try store.saveGLMKey("same-secret", accountID: "one")
            let second = try Data(contentsOf: url)
            XCTAssertNotEqual(first, second)
            let keyURL = store.directory.appendingPathComponent("master-key-v1")
            let key = try Data(contentsOf: keyURL)
            try FileManager.default.removeItem(at: keyURL)
            XCTAssertThrowsError(try store.readGLMKey(accountID: "one"))
            XCTAssertThrowsError(try store.saveGLMKey("replacement", accountID: "one"))
            XCTAssertThrowsError(try store.saveGLMKey("new-secret", accountID: "two"))
            XCTAssertEqual(try Data(contentsOf: url), second)
            XCTAssertFalse(FileManager.default.fileExists(atPath: keyURL.path))
            try key.write(to: keyURL)
            XCTAssertEqual(try store.readGLMKey(accountID: "one"), "same-secret")
            try Data([1, 2]).write(to: keyURL)
            XCTAssertThrowsError(try store.saveGLMKey("replacement", accountID: "one"))
            XCTAssertEqual(try Data(contentsOf: url), second)
        }
    }

    func testSymlinkIsRejectedAndAccountIDsCannotEscapeDirectory() throws {
        try withStore { store in
            let id = "../../outside"
            try store.saveGLMKey("secret", accountID: id)
            let url = store.credentialURL(provider: .glm, accountID: id)
            XCTAssertEqual(url.deletingLastPathComponent().path, store.directory.path)
            let target = store.directory.deletingLastPathComponent().appendingPathComponent("target")
            try Data("untouched".utf8).write(to: target)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            XCTAssertThrowsError(try store.readGLMKey(accountID: id))
            try store.saveGLMKey("replacement", accountID: id)
            XCTAssertEqual(try Data(contentsOf: target), Data("untouched".utf8))
            XCTAssertEqual(try store.readGLMKey(accountID: id), "replacement")
            let link = store.directory.deletingLastPathComponent().appendingPathComponent("linked-directory")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: store.directory)
            XCTAssertThrowsError(try SubscriptionFileSecretStore(directory: link).saveGLMKey("bad", accountID: "one"))
        }
    }

    func testConcurrentInstancesKeepAllAccountsReadable() throws {
        try withStore { store in
            let failures = NSLock()
            var errors = 0
            DispatchQueue.concurrentPerform(iterations: 16) { index in
                do {
                    let instance = SubscriptionFileSecretStore(directory: store.directory)
                    try instance.saveGLMKey("secret-\(index)", accountID: "\(index)")
                } catch {
                    failures.lock(); errors += 1; failures.unlock()
                }
            }
            XCTAssertEqual(errors, 0)
            for index in 0..<16 {
                XCTAssertEqual(try store.readGLMKey(accountID: "\(index)"), "secret-\(index)")
            }
        }
    }
}
