import Foundation

struct XCFrameworkSlice: Hashable {
    let supportedPlatform: String
    let supportedPlatformVariant: String?
    let supportedArchitectures: Set<String>
}

enum XCFrameworkMetadata {
    static func availableSlices(at xcframeworkURL: URL) throws -> [XCFrameworkSlice] {
        let infoURL = xcframeworkURL.appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: infoURL)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)

        guard let root = plist as? [String: Any],
              let libraries = root["AvailableLibraries"] as? [[String: Any]] else {
            throw BuildError.unexpected("invalid XCFramework Info.plist: \(infoURL.path)")
        }

        return libraries.compactMap { entry in
            guard let platform = entry["SupportedPlatform"] as? String else { return nil }
            let variant = entry["SupportedPlatformVariant"] as? String
            let architectures = Set((entry["SupportedArchitectures"] as? [String]) ?? [])
            return XCFrameworkSlice(
                supportedPlatform: platform,
                supportedPlatformVariant: variant,
                supportedArchitectures: architectures
            )
        }
    }

    static func containsPlatform(
        _ platform: PlatformType,
        architectures: [ArchType],
        at xcframeworkURL: URL
    ) -> Bool {
        guard let slices = try? availableSlices(at: xcframeworkURL) else { return false }
        let requiredPlatform = platform.xcFrameworkSupportedPlatform
        let requiredVariant = platform.xcFrameworkSupportedPlatformVariant
        let requiredArchitectures = Set(architectures.map(\.rawValue))

        return slices.contains { slice in
            slice.supportedPlatform == requiredPlatform
                && slice.supportedPlatformVariant == requiredVariant
                && requiredArchitectures.isSubset(of: slice.supportedArchitectures)
        }
    }
}

extension PlatformType {
    var xcFrameworkSupportedPlatform: String {
        switch self {
        case .macos:
            return "macos"
        case .ios, .isimulator, .maccatalyst:
            return "ios"
        case .tvos, .tvsimulator:
            return "tvos"
        case .xros, .xrsimulator:
            return "xros"
        }
    }

    var xcFrameworkSupportedPlatformVariant: String? {
        switch self {
        case .isimulator, .tvsimulator, .xrsimulator:
            return "simulator"
        case .maccatalyst:
            return "maccatalyst"
        case .macos, .ios, .tvos, .xros:
            return nil
        }
    }

    func resolvedArchitectures(requested architectures: Set<ArchType>) -> [ArchType] {
        guard !architectures.isEmpty else { return defaultArchitectures }
        return self.architectures.filter { architectures.contains($0) }
    }
}
