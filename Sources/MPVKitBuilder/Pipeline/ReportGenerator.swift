import Foundation

enum ReportGenerator {
    struct SummaryRecord {
        let library: Library
        let success: Bool
        let elapsed: TimeInterval
    }

    static func writeDependencyGraph(plan: BuildPlan, options: BuildOptions, to url: URL) throws {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let platforms = options.platforms.map(\.rawValue).joined(separator: ", ")
        let gpl = options.enableGPL ? "ON" : "OFF"
        let debug = options.enableDebug ? "ON" : "OFF"

        var lines: [String] = []
        lines.append("# MPVKitBuilder Dependency Graph")
        lines.append("# Generated: \(timestamp)")
        lines.append("# Platforms: \(platforms)")
        lines.append("# GPL: \(gpl)  Debug: \(debug)")
        lines.append("")

        let nameWidth = 18
        let versionWidth = 18
        for lib in plan.order {
            let deps = LibraryDependency.dependencies(of: lib)
            let depsText = deps.isEmpty ? "-" : deps.map(\.rawValue).joined(separator: ", ")
            let suffix = (lib == .libsmbclient && options.enableGPL) ? "  [GPL only]" : ""
            let name = padRight(lib.rawValue, to: nameWidth)
            let version = padRight("(\(lib.version))", to: versionWidth)
            lines.append("\(name) \(version) depends on: \(depsText)\(suffix)")
        }

        lines.append("")
        lines.append("# Resume status:")
        if !plan.skipFinished.isEmpty {
            let names = plan.skipFinished.map(\.rawValue).joined(separator: ", ")
            lines.append("#   finished (skipped): \(names)")
        }
        if !plan.skipExplicit.isEmpty {
            let names = plan.skipExplicit.map(\.rawValue).joined(separator: ", ")
            lines.append("#   filtered out (only=/skip=): \(names)")
        }
        if !plan.forcedRebuild.isEmpty {
            let names = plan.forcedRebuild.map(\.rawValue).sorted().joined(separator: ", ")
            lines.append("#   forced rebuild: \(names)")
        }
        let toBuildNames = plan.toBuild.map(\.rawValue).joined(separator: ", ")
        lines.append("#   to build (\(plan.toBuild.count)): \(toBuildNames)")

        try writeText(lines.joined(separator: "\n") + "\n", to: url)
    }

    static func writeBuildSummary(records: [SummaryRecord], distDirectory: URL, to url: URL) throws {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        var lines: [String] = []
        lines.append("# MPVKitBuilder Build Summary")
        lines.append("# Finished: \(timestamp)")
        lines.append("")
        lines.append("Libraries:")
        for r in records {
            let status = r.success ? "✅" : "❌"
            let dur = BuildLogger.format(seconds: r.elapsed)
            let name = padRight(r.library.rawValue, to: 16)
            lines.append("  \(status) \(name) \(dur)")
        }
        lines.append("")
        lines.append("Output XCFrameworks (\(distDirectory.path)):")
        if let items = try? FileManager.default.contentsOfDirectory(atPath: distDirectory.path).sorted() {
            for name in items where name.hasSuffix(".xcframework") {
                let path = distDirectory.appendingPathComponent(name).path
                let size = (try? directorySize(at: path)) ?? 0
                lines.append("  \(name)  \(formatBytes(size))")
            }
        }
        try writeText(lines.joined(separator: "\n") + "\n", to: url)
    }
}

// MARK: - Helpers

extension ReportGenerator {
    static func writeText(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func directorySize(at path: String) throws -> UInt64 {
        let fm = FileManager.default
        var total: UInt64 = 0
        if let enumerator = fm.enumerator(atPath: path) {
            for case let sub as String in enumerator {
                let full = (path as NSString).appendingPathComponent(sub)
                if let attrs = try? fm.attributesOfItem(atPath: full),
                   let size = attrs[.size] as? UInt64 {
                    total += size
                }
            }
        }
        return total
    }

    /// Right-pad a string with spaces. Unlike `padding(toLength:)`, never truncates.
    static func padRight(_ s: String, to width: Int) -> String {
        if s.count >= width { return s }
        return s + String(repeating: " ", count: width - s.count)
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1024 / 1024
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }
}
