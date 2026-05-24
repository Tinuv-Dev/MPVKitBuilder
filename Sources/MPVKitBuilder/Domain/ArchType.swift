import Foundation

enum ArchType: String, CaseIterable, Codable {
    case arm64, x86_64, arm64e

    var cpuFamily: String {
        switch self {
        case .arm64, .arm64e: return "aarch64"
        case .x86_64:         return "x86_64"
        }
    }

    var targetCpu: String {
        switch self {
        case .arm64, .arm64e: return "arm64"
        case .x86_64:         return "x86_64"
        }
    }

    var executable: Bool {
        guard let architecture = Bundle.main.executableArchitectures?.first?.intValue else { return false }
        if architecture == 0x0100_000C, self == .arm64 || self == .arm64e { return true }
        if architecture == NSBundleExecutableArchitectureX86_64, self == .x86_64 { return true }
        return false
    }
}
