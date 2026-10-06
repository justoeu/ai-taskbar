import Testing
import Foundation
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
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for form in [".alert(", ".confirmationDialog("] {
                #expect(!source.contains(form), "\(file.lastPathComponent) uses \(form)")
            }
        }
    }
}
