import Foundation
import IOKit

/// This Mac's hardware UUID (`IOPlatformUUID`, "Hardware UUID" in System
/// Information). It survives macOS reinstalls and disk reformats and changes
/// only with the logic board, which is why `SecretBox` v2 binds its key to it
/// rather than to a disk or volume id (those change on a reformat and would
/// lose every key for nothing).
public enum MachineIdentity {
    /// Read once per process; nil only if IOKit cannot answer.
    public static let current: String? = hardwareUUID()

    static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString,
                                                    kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
