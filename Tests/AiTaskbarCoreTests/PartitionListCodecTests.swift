import Foundation
import Testing
import os
@testable import AiTaskbarCore

@Suite("PartitionListCodec hex-plist round-trip")
struct PartitionListCodecTests {
    @Test("encode → decode round-trips the partition IDs")
    func round_trip() {
        let partitions = ["apple:", "apple-tool:", "teamid:5HHL78743R"]
        let hex = PartitionListCodec.encode(partitions: partitions)
        #expect(hex != nil)
        #expect(PartitionListCodec.decode(hexDescription: hex!) == partitions)
    }

    @Test("decodes a real-world macOS partition plist")
    func decodes_real_payload() {
        // xml plist {"Partitions": ["apple:"]} as macOS stores it, hex-encoded.
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Partitions</key><array><string>apple:</string></array></dict></plist>
        """
        let hex = Data(plist.utf8).map { String(format: "%02x", $0) }.joined()
        #expect(PartitionListCodec.decode(hexDescription: hex) == ["apple:"])
    }

    @Test("garbage input decodes to nil, not a crash")
    func garbage_input() {
        #expect(PartitionListCodec.decode(hexDescription: "zz-not-hex") == nil)
        #expect(PartitionListCodec.decode(hexDescription: "abc") == nil)   // odd length
        #expect(PartitionListCodec.decode(hexDescription: "deadbeef") == nil) // not a plist
        #expect(PartitionListCodec.decode(hexDescription: "") == nil)
    }

    @Test("adding appends only when missing")
    func adding_dedupes() {
        let base = ["apple:"]
        #expect(PartitionListCodec.adding("teamid:X", to: base) == ["apple:", "teamid:X"])
        #expect(PartitionListCodec.adding("apple:", to: base) == ["apple:"])
    }
}

@Suite("AppError.isKeychainACLBlocked")
struct KeychainACLBlockedTests {
    @Test("matches the errSecInteractionNotAllowed credentials error")
    func matches_acl_block() {
        let err = AppError.credentials("Keychain access denied (errSecInteractionNotAllowed). …")
        #expect(err.isKeychainACLBlocked)
    }

    @Test("matches the errSecAuthFailed credentials error")
    func matches_auth_failed_block() {
        let err = AppError.credentials("Keychain access denied (errSecAuthFailed). …")
        #expect(err.isKeychainACLBlocked)
    }

    @Test("other errors do not match")
    func other_errors() {
        #expect(!AppError.credentials("no credentials available").isKeychainACLBlocked)
        #expect(!AppError.http(status: 401, body: "errSecInteractionNotAllowed").isKeychainACLBlocked)
    }
}

@Suite("KeychainPromptSuppressor")
struct KeychainPromptSuppressorTests {
    /// The reference counting must disable interaction exactly once on the
    /// outermost enter and re-enable exactly once on the outermost exit —
    /// nested sections must not flip the process-global flag mid-way.
    @Test("nested enter/exit flips the flag only at the boundaries")
    func nested_reference_counting() {
        // Thread-safe recorder: the apply seam is @Sendable (it is called
        // inside the suppressor's own lock), so a bare captured var won't do.
        let transitions = OSAllocatedUnfairLock(initialState: [Bool]())
        let record: @Sendable (Bool) -> Void = { flag in
            transitions.withLock { $0.append(flag) }
        }
        KeychainPromptSuppressor.enter(apply: record)
        KeychainPromptSuppressor.enter(apply: record)
        #expect(transitions.withLock { $0 } == [false])
        KeychainPromptSuppressor.exit(apply: record)
        #expect(transitions.withLock { $0 } == [false])
        KeychainPromptSuppressor.exit(apply: record)
        #expect(transitions.withLock { $0 } == [false, true])
    }
}
