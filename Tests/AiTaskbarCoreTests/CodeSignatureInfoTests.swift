import Foundation
import Testing
@testable import AiTaskbarCore

@Suite("CodeSignatureInfo developer-name parsing")
struct CodeSignatureInfoTests {
    @Test("Developer ID CN strips role prefix and team suffix")
    func developer_id_cn() {
        let cn = "Developer ID Application: Valmir Robson Justo (5HHL78743R)"
        #expect(CodeSignatureInfo.developerName(fromCommonName: cn) == "Valmir Robson Justo")
    }

    @Test("Apple Development CN parses the same way")
    func apple_development_cn() {
        let cn = "Apple Development: Jane Doe (ABCDE12345)"
        #expect(CodeSignatureInfo.developerName(fromCommonName: cn) == "Jane Doe")
    }

    @Test("CN without role prefix keeps full name")
    func no_prefix() {
        #expect(CodeSignatureInfo.developerName(fromCommonName: "Jane Doe (ABCDE12345)") == "Jane Doe")
    }

    @Test("trailing parenthetical that is not a team ID is preserved")
    func non_team_parenthetical() {
        let cn = "Developer ID Application: Acme Corp (Brazil)"
        #expect(CodeSignatureInfo.developerName(fromCommonName: cn) == "Acme Corp (Brazil)")
    }

    @Test("CN without team suffix keeps name")
    func no_team_suffix() {
        let cn = "Developer ID Application: Jane Doe"
        #expect(CodeSignatureInfo.developerName(fromCommonName: cn) == "Jane Doe")
    }

    @Test("empty or whitespace-only name yields nil")
    func empty_name() {
        #expect(CodeSignatureInfo.developerName(fromCommonName: "") == nil)
        #expect(CodeSignatureInfo.developerName(fromCommonName: "Developer ID Application: ") == nil)
    }

    @Test("self-introspection never crashes (nil for unsigned test runner is fine)")
    func self_introspection_smoke() {
        // The swift-test runner is usually ad-hoc signed → nil. A signed run
        // returns a non-empty string. Either way, must not throw or crash.
        let name = CodeSignatureInfo.currentDeveloperName()
        if let name {
            #expect(!name.isEmpty)
        }
        let team = CodeSignatureInfo.currentTeamID()
        if let team {
            #expect(!team.isEmpty)
        }
    }
}

@Suite("Keychain partition-list remediation command")
struct RemediationCommandTests {
    @Test("signed build appends its teamid partition")
    func with_team_id() {
        let cmd = KeychainCredentialReader.remediationCommand(
            service: "Claude Code-credentials", teamID: "5HHL78743R")
        #expect(cmd == #"security set-generic-password-partition-list -S "apple-tool:,apple:,unsigned:,teamid:5HHL78743R" -s "Claude Code-credentials" login.keychain-db"#)
    }

    @Test("ad-hoc build keeps the base partitions only")
    func without_team_id() {
        let cmd = KeychainCredentialReader.remediationCommand(
            service: "Claude Code-credentials", teamID: nil)
        #expect(cmd == #"security set-generic-password-partition-list -S "apple-tool:,apple:,unsigned:" -s "Claude Code-credentials" login.keychain-db"#)
    }

    @Test("never suggests the -a account filter or the deprecated -k flag")
    func no_footguns() {
        let cmd = KeychainCredentialReader.remediationCommand(
            service: "Claude Code-credentials", teamID: "5HHL78743R")
        #expect(!cmd.contains(" -a "))
        #expect(!cmd.contains(" -k "))
    }
}
