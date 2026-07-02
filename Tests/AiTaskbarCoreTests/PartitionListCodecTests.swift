import Foundation
import Testing
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

    @Test("other errors do not match")
    func other_errors() {
        #expect(!AppError.credentials("no credentials available").isKeychainACLBlocked)
        #expect(!AppError.http(status: 401, body: "errSecInteractionNotAllowed").isKeychainACLBlocked)
    }
}
