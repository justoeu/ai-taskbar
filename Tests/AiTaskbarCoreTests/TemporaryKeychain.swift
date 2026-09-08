import Foundation
import Security
import Testing

/// Owns only dummy test credentials; never depends on an unlocked login keychain.
final class TemporaryKeychain {
    let reference: SecKeychain
    /// On-disk path, for handing the keychain to `/usr/bin/security`.
    let path: String
    /// Creation password, so tests can `security unlock-keychain -p` without a prompt.
    let password: String
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-taskbar-keychain-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("test.keychain").path
        var created: SecKeychain?
        let password = UUID().uuidString
        self.path = path
        self.password = password
        let status = password.withCString { bytes in
            SecKeychainCreate(path, UInt32(password.utf8.count), bytes, false, nil, &created)
        }
        try #require(status == errSecSuccess)
        reference = try #require(created)
    }

    deinit {
        // Best-effort teardown of this fixture's exact temporary keychain.
        SecKeychainDelete(reference)
        try? FileManager.default.removeItem(at: directory)
    }
}
