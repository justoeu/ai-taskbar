import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("AtomicFileWrite final mode")
struct AtomicFileWriteTests {
    let tmp: URL

    init() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-atomic-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
    }

    private static func mode(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func seed(_ url: URL, mode: Int) throws {
        try Data("old".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)],
                                              ofItemAtPath: url.path)
    }

    @Test("an existing 0644 destination ends at the requested 0600 (TEST-ARG-001)")
    func existing_loose_destination_is_tightened() throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dest = tmp.appendingPathComponent("secret.json")
        try seed(dest, mode: 0o644)

        try AtomicFileWrite.write(Data("new".utf8), to: dest, permissions: 0o600)

        #expect(try Self.mode(dest) == 0o600)
        #expect(try Data(contentsOf: dest) == Data("new".utf8))
    }

    @Test("the temp file already has the requested mode once the payload is on disk (RACE-CRO-010)")
    func temp_file_never_holds_payload_with_loose_mode() throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dest = tmp.appendingPathComponent("auth.json")
        let modes = TempObservations()

        try AtomicFileWrite.write(Data("token".utf8), to: dest, permissions: 0o600) { temp in
            modes.record(mode: (try? Self.mode(temp)) ?? -1,
                         bytes: (try? Data(contentsOf: temp)) ?? Data())
        }

        #expect(modes.modes == [0o600])
        #expect(modes.bytes == [Data("token".utf8)])
    }

    @Test("a requested mode looser than 0600 is applied exactly")
    func requested_mode_is_exact() throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dest = tmp.appendingPathComponent("shared.json")

        try AtomicFileWrite.write(Data("x".utf8), to: dest, permissions: 0o640)

        #expect(try Self.mode(dest) == 0o640)
    }

    @Test("nil permissions keeps an existing destination's mode")
    func nil_permissions_preserve_existing_mode() throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dest = tmp.appendingPathComponent("baseline.json")
        try seed(dest, mode: 0o600)

        try AtomicFileWrite.write(Data("new".utf8), to: dest)

        #expect(try Self.mode(dest) == 0o600)
        #expect(try Data(contentsOf: dest) == Data("new".utf8))
    }

    @Test("a successful overwrite leaves no temp file behind")
    func no_leftover_temp_files() throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dest = tmp.appendingPathComponent("a.json")
        try seed(dest, mode: 0o644)

        try AtomicFileWrite.write(Data("1".utf8), to: dest, permissions: 0o600)
        try AtomicFileWrite.write(Data("2".utf8), to: dest, permissions: 0o600)

        let names = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
        #expect(names == ["a.json"])
        #expect(try Data(contentsOf: dest) == Data("2".utf8))
    }

    @Test("a symlinked destination is refused: link and target untouched")
    func symlinked_destination_is_refused() throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let target = tmp.appendingPathComponent("real.toml")
        try seed(target, mode: 0o644)
        let link = tmp.appendingPathComponent("config.toml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: AppError.self) {
            try AtomicFileWrite.write(Data("new".utf8), to: link, permissions: 0o600)
        }

        let linkType = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        expectTrue(linkType == .typeSymbolicLink)
        #expect(try Data(contentsOf: target) == Data("old".utf8))
        #expect(try Self.mode(target) == 0o644)
        let names = try FileManager.default.contentsOfDirectory(atPath: tmp.path).sorted()
        #expect(names == ["config.toml", "real.toml"])
    }
}

/// Collects what the temp-file seam saw. The seam runs synchronously on the
/// writer's thread, so a plain class is enough.
private final class TempObservations {
    private(set) var modes: [Int] = []
    private(set) var bytes: [Data] = []

    func record(mode: Int, bytes data: Data) {
        modes.append(mode)
        bytes.append(data)
    }
}
