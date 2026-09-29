import Foundation
import Security
import os
import AiTaskbarCore

/// Last check on a downloaded, checksum-verified update DMG before it is
/// revealed to the user (SEC-CER-001). Size and checksum come from the same
/// GitHub release as the DMG, so they only prove "these are the bytes the
/// release published". This seam anchors trust OUTSIDE the release.
public protocol DMGVerifying: Sendable {
    func verify(dmgAt url: URL) async throws
}

/// Production verifier: the single top-level `.app` inside the DMG must carry
/// a valid Apple-anchored signature from the SAME team as the running app.
/// Ad-hoc dev builds have no team to anchor on, so the check is skipped (and
/// logged) instead of failing every dev update.
public struct TeamSignatureDMGVerifier: DMGVerifying {
    /// Not user-facing: `UpdateChecker` maps any verifier error to the
    /// localized `updates_signature_invalid` message.
    public enum Failure: Error, Equatable {
        case invalidTeamID
        /// `hdiutil` could not be launched at all.
        case launchFailed(String)
        /// `hdiutil` did not finish (child exit and stdout drain) within the budget.
        case timedOut
        /// `hdiutil` exited non-zero. The associated value is its status.
        case hdiutilExited(Int32)
        /// `hdiutil attach` succeeded but its plist names no mount point.
        case mountFailed
        /// Unmounting the verified image failed. Wraps the underlying failure.
        /// Logged only: by then the verdict is already decided.
        indirect case detachFailed(Failure)
        case noSingleApp
        case signatureRejected(OSStatus)
    }

    public let teamID: String?
    public let timeout: TimeInterval
    private static let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")

    /// Runs `hdiutil` with (arguments, timeout) and returns stdout. A seam so
    /// tests can script attach/detach outcomes without mounting anything.
    typealias HdiutilRunner = @Sendable ([String], TimeInterval) throws -> Data

    public init(teamID: String? = CodeSignatureInfo.currentTeamID(), timeout: TimeInterval = 60) {
        self.teamID = teamID
        self.timeout = timeout
    }

    public func verify(dmgAt url: URL) async throws {
        guard let teamID else {
            AppLog.updates.notice("ad-hoc build: skipping DMG team-signature check")
            return
        }
        // The team ID is interpolated into a requirement string: accept only
        // the 10-char uppercase-alphanumeric shape Apple issues.
        guard Self.isWellFormedTeamID(teamID) else { throw Failure.invalidTeamID }
        let timeout = self.timeout
        // hdiutil can block for up to `timeout`: a GCD thread, not one of the
        // cooperative pool's few (Task.detached still runs there).
        try await OffPool.run {
            try Self.verifyBlocking(dmg: url, teamID: teamID, timeout: timeout)
        }
    }

    static func isWellFormedTeamID(_ s: String) -> Bool {
        s.count == 10 && s.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }

    static func verifyBlocking(dmg: URL, teamID: String, timeout: TimeInterval,
                               run: HdiutilRunner = runHdiutil) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-taskbar-verify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) } // best-effort: empty after detach
        // Every exit after an attach attempt detaches whatever it mounted
        // (BP-MAE-001), not only the happy path with a parsed mount point.
        let plist: Data
        do {
            plist = try run(["attach", "-nobrowse", "-readonly", "-noautoopen",
                             "-mountrandom", root.path, "-plist", dmg.path],
                            timeout)
        } catch {
            // A kill after mounting leaves the volume under the random root.
            detach(leftoverMounts(under: root), run: run)
            throw error
        }
        let mountPoint: String
        do {
            mountPoint = try Self.mountPoint(fromAttachPlist: plist)
        } catch {
            let devices = wholeDiskDevices(fromAttachPlist: plist)
            detach(devices.isEmpty ? leftoverMounts(under: root) : devices, run: run)
            throw error
        }
        defer { detach([mountPoint], run: run) }
        let apps = try FileManager.default.contentsOfDirectory(atPath: mountPoint)
            .filter { $0.hasSuffix(".app") }
        guard apps.count == 1 else { throw Failure.noSingleApp }
        try checkSignature(of: URL(fileURLWithPath: mountPoint).appendingPathComponent(apps[0]),
                           teamID: teamID)
    }

    static func checkSignature(of app: URL, teamID: String) throws {
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures
                               | kSecCSCheckNestedCode)
        let status = CodeSignatureInfo.checkRequirement(of: app, requirement: text, flags: flags)
        guard status == errSecSuccess else { throw Failure.signatureRejected(status) }
    }

    /// Force-detaches each target (mount point or device node). Logged only:
    /// by then the verdict is already decided.
    private static func detach(_ targets: [String], run: HdiutilRunner) {
        for target in targets {
            do {
                _ = try run(["detach", target, "-force"], 30)
            } catch let failure as Failure {
                AppLog.updates.error("\(String(describing: Failure.detachFailed(failure)), privacy: .public)")
            } catch {
                AppLog.updates.error("hdiutil detach failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Volumes `-mountrandom` created under our private root.
    private static func leftoverMounts(under root: URL) -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: root.path)
                .map { root.appendingPathComponent($0).path }
        } catch {
            AppLog.updates.error("listing DMG mount root failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Whole-disk device nodes (`/dev/diskN`) the attach reported; detaching
    /// one also detaches its partitions. Falls back to every reported node.
    static func wholeDiskDevices(fromAttachPlist data: Data) -> [String] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil), // unparseable = none
              let dict = root as? [String: Any],
              let entities = dict["system-entities"] as? [[String: Any]]
        else { return [] }
        let devices = entities.compactMap { $0["dev-entry"] as? String }
        let whole = devices.filter { dev in
            let suffix = dev.dropFirst("/dev/disk".count)
            return dev.hasPrefix("/dev/disk") && !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
        }
        return whole.isEmpty ? devices : whole
    }

    static func mountPoint(fromAttachPlist data: Data) throws -> String {
        let root = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dict = root as? [String: Any],
              let entities = dict["system-entities"] as? [[String: Any]],
              let mount = entities.compactMap({ $0["mount-point"] as? String }).first
        else { throw Failure.mountFailed }
        return mount
    }

    static func runHdiutil(_ args: [String], timeout: TimeInterval) throws -> Data {
        let outcome: BoundedProcess.Outcome
        do {
            outcome = try BoundedProcess.run(executable: hdiutil, arguments: args, timeout: timeout)
        } catch {
            throw Failure.launchFailed(error.localizedDescription)
        }
        guard !outcome.timedOut else { throw Failure.timedOut }
        guard outcome.status == 0 else { throw Failure.hdiutilExited(outcome.status) }
        return outcome.stdout
    }
}
