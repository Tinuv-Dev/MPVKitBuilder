import Foundation

/// Generates `dist/Package.swift` so consumers can `swift package add` or use a
/// local `path:` dependency to pick up every XCFramework produced by this run.
///
/// Mode: local only. Each XCFramework becomes one `.binaryTarget(path:)`, all
/// rolled into a single `MPVKit` library product. Remote (`url:checksum:`) mode
/// is intentionally deferred — see DESIGN.md §九.
enum PackageManifestGenerator {
    struct Manifest {
        /// XCFramework names without the `.xcframework` suffix, sorted for stable output.
        let targets: [String]
        let platforms: [PlatformDeclaration]
        let distDirectory: URL
        let generatedAt: Date
    }

    enum PlatformDeclaration: CaseIterable, Hashable {
        case macOS
        case macCatalyst
        case iOS
        case tvOS
        case visionOS

        var displayName: String {
            switch self {
            case .macOS: return "macOS"
            case .macCatalyst: return "Mac Catalyst"
            case .iOS: return "iOS"
            case .tvOS: return "tvOS"
            case .visionOS: return "visionOS"
            }
        }

        var packageLine: String {
            switch self {
            case .macOS: return ".macOS(.v10_15)"
            case .macCatalyst: return ".macCatalyst(.v14)"
            case .iOS: return ".iOS(.v13)"
            case .tvOS: return ".tvOS(.v13)"
            case .visionOS: return ".visionOS(.v1)"
            }
        }
    }

    /// Scan `dist/`, render `Package.swift`, write it next to the XCFrameworks.
    /// Returns the URL of the written manifest.
    @discardableResult
    static func write(
        distDirectory: URL,
        platforms: [PlatformType] = PlatformType.defaultEnabled,
        logger: BuildLogger? = nil
    ) throws -> URL {
        let manifest = try scan(distDirectory: distDirectory, platforms: platforms)
        let body = render(manifest: manifest)
        let url = distDirectory.appendingPathComponent("Package.swift")
        try body.write(to: url, atomically: true, encoding: .utf8)
        logger?.write(
            .success,
            "  Package.swift written to \(url.path) (\(manifest.targets.count) targets, \(manifest.platforms.count) platforms)"
        )
        return url
    }

    static func scan(distDirectory: URL, platforms: [PlatformType]) throws -> Manifest {
        let fm = FileManager.default
        guard fm.fileExists(atPath: distDirectory.path) else {
            throw BuildError.unexpected("dist directory not found at \(distDirectory.path)")
        }
        let entries = try fm.contentsOfDirectory(atPath: distDirectory.path)
        let targets = entries
            .filter { $0.hasSuffix(".xcframework") }
            .map { String($0.dropLast(".xcframework".count)) }
            .sorted()
        guard !targets.isEmpty else {
            throw BuildError.unexpected("no .xcframework found in \(distDirectory.path)")
        }
        let packagePlatforms = platformDeclarations(for: platforms)
        guard !packagePlatforms.isEmpty else {
            throw BuildError.invalidArgument("no supported Package.swift platforms were resolved")
        }
        return Manifest(
            targets: targets,
            platforms: packagePlatforms,
            distDirectory: distDirectory,
            generatedAt: Date()
        )
    }

    static func platformDeclarations(for platforms: [PlatformType]) -> [PlatformDeclaration] {
        var resolved = Set<PlatformDeclaration>()
        for platform in platforms {
            switch platform {
            case .macos:
                resolved.insert(.macOS)
            case .maccatalyst:
                resolved.insert(.macCatalyst)
            case .ios, .isimulator:
                resolved.insert(.iOS)
            case .tvos, .tvsimulator:
                resolved.insert(.tvOS)
            case .xros, .xrsimulator:
                resolved.insert(.visionOS)
            }
        }
        return PlatformDeclaration.allCases.filter { resolved.contains($0) }
    }
}

// MARK: - Rendering

extension PackageManifestGenerator {
    static func render(manifest: Manifest) -> String {
        var out = ""
        out += "// swift-tools-version: 5.9\n"
        out += "// MPVKitBuilder generated manifest — DO NOT EDIT BY HAND.\n"
        out += "// Generated : \(isoTimestamp(manifest.generatedAt))\n"
        out += "// Targets   : \(manifest.targets.count)\n"
        let platformList = manifest.platforms.map(\.displayName).joined(separator: ", ")
        out += "// Platforms : \(platformList)\n"
        out += "//\n"
        out += "// Drop this Package as a local SwiftPM dependency, e.g.:\n"
        out += "//   .package(path: \"\(manifest.distDirectory.path)\"),\n"
        out += "// then add `MPVKit` to your target's `dependencies`.\n"
        out += "\n"
        out += "import PackageDescription\n"
        out += "\n"
        out += "let package = Package(\n"
        out += "    name: \"MPVKit\",\n"
        out += "    platforms: [\n"
        for platform in manifest.platforms {
            out += "        \(platform.packageLine),\n"
        }
        out += "    ],\n"
        out += "    products: [\n"
        out += "        .library(\n"
        out += "            name: \"MPVKit\",\n"
        out += "            targets: [\n"
        for name in manifest.targets {
            out += "                \"\(name)\",\n"
        }
        out += "            ]\n"
        out += "        ),\n"
        out += "    ],\n"
        out += "    targets: [\n"
        for name in manifest.targets {
            out += "        .binaryTarget(name: \"\(name)\", path: \"\(name).xcframework\"),\n"
        }
        out += "    ]\n"
        out += ")\n"
        return out
    }

    static func isoTimestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
