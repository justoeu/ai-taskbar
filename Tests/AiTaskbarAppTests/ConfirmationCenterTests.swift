import Testing
import Foundation
import AiTaskbarCore
@testable import AiTaskbarApp

@MainActor
@Suite("In-window confirmation")
struct ConfirmationCenterTests {
    private final class Calls { var confirmed = 0; var cancelled = 0 }

    private func request(_ calls: Calls) -> ConfirmationRequest {
        ConfirmationRequest(title: "t", message: "m", confirmTitle: "ok", cancelTitle: "no",
                            onConfirm: { calls.confirmed += 1 }, onCancel: { calls.cancelled += 1 })
    }

    @Test("confirm runs the action once and closes the overlay")
    func confirm_once() {
        let center = ConfirmationCenter()
        let calls = Calls()
        center.present(request(calls))
        center.confirm()
        center.confirm()
        #expect(calls.confirmed == 1)
        #expect(calls.cancelled == 0)
        #expect(center.request == nil)
    }

    @Test("cancel runs the cancel action once; closing the popover cancels")
    func cancel_once() {
        let center = ConfirmationCenter()
        let calls = Calls()
        center.present(request(calls))
        center.cancel()
        center.cancel()
        #expect(calls.cancelled == 1)
        #expect(calls.confirmed == 0)
        #expect(center.request == nil)
    }

    @Test("an open confirmation counts as a modal for Esc")
    func modal_for_escape() {
        let monitor = PopoverKeyMonitor.shared
        let savedStore = monitor.store
        defer { ConfirmationCenter.shared.cancel(); monitor.store = savedStore }
        monitor.store = nil
        #expect(!monitor.modalShown)
        ConfirmationCenter.shared.present(request(Calls()))
        #expect(monitor.modalShown)
    }
}

@Suite("No native dialogs in the popover")
struct NoNativeDialogsTests {
    @Test("app views use ConfirmationCenter, never .alert / .confirmationDialog")
    func no_native_dialogs() throws {
        let dir = LocalizableStrings.repositoryRoot.appendingPathComponent("Sources/AiTaskbarApp")
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty)
        // `.alert (` split across lines and AppKit's NSAlert count too.
        let pattern = try NSRegularExpression(pattern: #"\.(alert|confirmationDialog)\s*\(|\bNSAlert\s*\("#)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let hits = pattern.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source))
            #expect(hits == 0, "\(file.lastPathComponent) uses a native dialog")
        }
    }
}

@MainActor
@Suite("Destructive confirmations and reset backup")
struct DestructiveConfirmationTests {
    @Test("Return confirms only harmless requests")
    func return_key_rule() {
        let harmless = ConfirmationRequest(title: "t", message: "m", confirmTitle: "ok")
        let destructive = ConfirmationRequest(title: "t", message: "m", confirmTitle: "ok", isDestructive: true)
        #expect(ConfirmationOverlay.returnConfirms(harmless))
        #expect(!ConfirmationOverlay.returnConfirms(destructive))
    }

    @Test("a new request cancels the open one instead of replacing it silently")
    func present_cancels_previous() {
        let center = ConfirmationCenter()
        var firstCancelled = 0
        center.present(ConfirmationRequest(title: "a", message: "", confirmTitle: "ok",
                                           onCancel: { firstCancelled += 1 }))
        center.present(ConfirmationRequest(title: "b", message: "", confirmTitle: "ok"))
        #expect(firstCancelled == 1)
        #expect(center.request?.title == "b")
    }

    @Test("Restore defaults keeps a copy of the previous file, keys included")
    func reset_keeps_backup() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-reset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let loader = ConfigLoader(path: dir.appendingPathComponent("config.toml"))
        var config = AppConfig()
        config.zai.apiKey = "zai-SECRET-MARKER"
        try loader.save(config)
        let vm = SettingsViewModel(config: try loader.load(), configLoader: loader)
        try vm.resetToDefaults()
        let backup = try #require(vm.lastResetBackup)
        let restored = try ConfigLoader(path: backup).load()
        #expect(restored.zai.apiKey == "zai-SECRET-MARKER")
        expectTrue(try loader.load().zai.apiKey == nil)
    }
}
