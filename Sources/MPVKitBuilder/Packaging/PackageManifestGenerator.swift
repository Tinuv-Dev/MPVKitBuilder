import Foundation

/// Generates `dist/Package.swift` so consumers can `swift package add` or use a
/// local `path:` dependency to pick up every XCFramework produced by this run.
///
/// Mode: local only. Each XCFramework becomes one `.binaryTarget(path:)`, with
/// lightweight Swift targets carrying dependency edges and linker settings.
/// Remote (`url:checksum:`) mode is intentionally deferred — see DESIGN.md §九.
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
        try writeSupportSources(distDirectory: distDirectory)
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

    static func writeSupportSources(distDirectory: URL) throws {
        let files: [(path: String, body: String)] = [
            (
                "Sources/_MPVKit/MPVKitLinkAnchor.swift",
                "public enum MPVKitLinkAnchor {}\n"
            ),
            (
                "Sources/_FFmpeg/FFmpegLinkAnchor.swift",
                "public enum FFmpegLinkAnchor {}\n"
            ),
        ]

        for file in files {
            let url = distDirectory.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try file.body.write(to: url, atomically: true, encoding: .utf8)
        }
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
        out += "            targets: [\"_MPVKit\"]\n"
        out += "        ),\n"
        out += "    ],\n"
        out += "    targets: [\n"
        out += renderMPVKitTarget(manifest: manifest)
        if !ffmpegDependencies(manifest: manifest).isEmpty {
            out += renderFFmpegTarget(manifest: manifest)
        }
        for name in manifest.targets {
            out += "        .binaryTarget(name: \"\(name)\", path: \"\(name).xcframework\"),\n"
        }
        out += "    ]\n"
        out += ")\n"
        return out
    }

    static func renderMPVKitTarget(manifest: Manifest) -> String {
        var out = ""
        out += "        .target(\n"
        out += "            name: \"_MPVKit\",\n"
        out += "            dependencies: [\n"
        for dependency in mpvKitDependencies(manifest: manifest) {
            out += "                \(dependency),\n"
        }
        out += "            ],\n"
        out += "            path: \"Sources/_MPVKit\",\n"
        out += "            linkerSettings: [\n"
        for setting in mpvKitLinkerSettings() {
            out += "                \(setting),\n"
        }
        out += "            ]\n"
        out += "        ),\n"
        return out
    }

    static func renderFFmpegTarget(manifest: Manifest) -> String {
        var out = ""
        out += "        .target(\n"
        out += "            name: \"_FFmpeg\",\n"
        out += "            dependencies: [\n"
        for dependency in ffmpegDependencies(manifest: manifest) {
            out += "                \(dependency),\n"
        }
        out += "            ],\n"
        out += "            path: \"Sources/_FFmpeg\",\n"
        out += "            linkerSettings: [\n"
        for setting in ffmpegLinkerSettings() {
            out += "                \(setting),\n"
        }
        out += "            ]\n"
        out += "        ),\n"
        return out
    }

    static func isoTimestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}

// MARK: - Target graph

extension PackageManifestGenerator {
    static func mpvKitDependencies(manifest: Manifest) -> [String] {
        let available = Set(manifest.targets)
        let ffmpegNames = ffmpegDependencyTargetNames(manifest: manifest)
        let ffmpegCovered = Set(ffmpegNames)
        var dependencyNames: [String] = []
        var seen: Set<String> = []

        appendTargetNames(for: [.libmpv], available: available, to: &dependencyNames, seen: &seen)
        if !ffmpegNames.isEmpty, seen.insert("_FFmpeg").inserted {
            dependencyNames.append("_FFmpeg")
        }

        let mpvLibraries = rootFirstLinkClosure(for: .libmpv)
            .filter { $0 != .libmpv && $0 != .ffmpeg }
        for name in frameworkTargetNames(for: mpvLibraries, available: available) where !ffmpegCovered.contains(name) {
            appendDependencyName(name, to: &dependencyNames, seen: &seen)
        }

        return dependencyNames.map { "\"\($0)\"" }
    }

    static func ffmpegDependencies(manifest: Manifest) -> [String] {
        ffmpegDependencyTargetNames(manifest: manifest).map { "\"\($0)\"" }
    }

    static func ffmpegDependencyTargetNames(manifest: Manifest) -> [String] {
        let available = Set(manifest.targets)
        guard !frameworkTargetNames(for: [.ffmpeg], available: available).isEmpty else {
            return []
        }
        return frameworkTargetNames(for: rootFirstLinkClosure(for: .ffmpeg), available: available)
    }

    static func rootFirstLinkClosure(for root: Library) -> [Library] {
        let transitive = Set(LibraryDependency.transitiveDependencies(of: root))
        let orderedDependencies = LibraryDependency.topologicalOrder()
            .filter { transitive.contains($0) }
        return [root] + orderedDependencies
    }

    static func frameworkTargetNames(for libraries: [Library], available: Set<String>) -> [String] {
        var names: [String] = []
        var seen: Set<String> = []
        appendTargetNames(for: libraries, available: available, to: &names, seen: &seen)
        return names
    }

    static func appendTargetNames(
        for libraries: [Library],
        available: Set<String>,
        to names: inout [String],
        seen: inout Set<String>
    ) {
        for library in libraries {
            for framework in library.expectedFrameworks where available.contains(framework) {
                appendDependencyName(framework, to: &names, seen: &seen)
            }
        }
    }

    static func appendDependencyName(_ name: String, to names: inout [String], seen: inout Set<String>) {
        if seen.insert(name).inserted {
            names.append(name)
        }
    }

    static func mpvKitLinkerSettings() -> [String] {
        [
            ".linkedFramework(\"AVFoundation\")",
            ".linkedFramework(\"CoreAudio\")",
            ".linkedFramework(\"AudioToolbox\")",
        ]
    }

    static func ffmpegLinkerSettings() -> [String] {
        [
            ".linkedFramework(\"AudioToolbox\")",
            ".linkedFramework(\"CoreVideo\")",
            ".linkedFramework(\"CoreText\")",
            ".linkedFramework(\"CoreFoundation\")",
            ".linkedFramework(\"CoreMedia\")",
            ".linkedFramework(\"CoreGraphics\")",
            ".linkedFramework(\"Foundation\")",
            ".linkedFramework(\"IOSurface\")",
            ".linkedFramework(\"Metal\")",
            ".linkedFramework(\"QuartzCore\")",
            ".linkedFramework(\"Security\")",
            ".linkedFramework(\"ApplicationServices\", .when(platforms: [.macOS, .macCatalyst]))",
            ".linkedFramework(\"Cocoa\", .when(platforms: [.macOS]))",
            ".linkedFramework(\"UIKit\", .when(platforms: [.iOS, .tvOS, .visionOS, .macCatalyst]))",
            ".linkedFramework(\"IOKit\", .when(platforms: [.macOS, .iOS, .visionOS, .macCatalyst]))",
            ".linkedFramework(\"VideoToolbox\")",
            ".linkedLibrary(\"bz2\")",
            ".linkedLibrary(\"iconv\")",
            ".linkedLibrary(\"expat\")",
            ".linkedLibrary(\"resolv\")",
            ".linkedLibrary(\"xml2\")",
            ".linkedLibrary(\"z\")",
            ".linkedLibrary(\"c++\")",
        ]
    }
}
