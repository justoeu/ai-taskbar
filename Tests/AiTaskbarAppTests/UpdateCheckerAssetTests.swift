import Foundation
import Testing
@testable import AiTaskbarApp

@Suite("UpdateChecker DMG asset selection")
struct UpdateCheckerAssetTests {
    private let both = ["checksums-0.8.0.txt",
                        "ai-taskbar-0.8.0-arm64.dmg",
                        "ai-taskbar-0.8.0.dmg"]

    @Test("arm64 prefers the arch-specific DMG")
    func arm64_prefers_arch_specific() {
        #expect(UpdateChecker.pickDMGAsset(names: both, isARM64: true)
                == "ai-taskbar-0.8.0-arm64.dmg")
    }

    @Test("Intel takes the universal DMG")
    func intel_takes_universal() {
        #expect(UpdateChecker.pickDMGAsset(names: both, isARM64: false)
                == "ai-taskbar-0.8.0.dmg")
    }

    @Test("old single-DMG release works on both arches")
    func single_dmg_release() {
        let old = ["ai-taskbar-0.7.2.dmg"]
        #expect(UpdateChecker.pickDMGAsset(names: old, isARM64: true) == "ai-taskbar-0.7.2.dmg")
        #expect(UpdateChecker.pickDMGAsset(names: old, isARM64: false) == "ai-taskbar-0.7.2.dmg")
    }

    @Test("Intel never takes an arm64-only DMG")
    func intel_rejects_arm64_only() {
        let armOnly = ["ai-taskbar-0.8.0-arm64.dmg"]
        #expect(UpdateChecker.pickDMGAsset(names: armOnly, isARM64: false) == nil)
        #expect(UpdateChecker.pickDMGAsset(names: armOnly, isARM64: true)
                == "ai-taskbar-0.8.0-arm64.dmg")
    }

    @Test("no DMG assets yields nil")
    func no_dmg_assets() {
        #expect(UpdateChecker.pickDMGAsset(names: ["notes.txt"], isARM64: true) == nil)
        #expect(UpdateChecker.pickDMGAsset(names: [], isARM64: false) == nil)
    }
}
