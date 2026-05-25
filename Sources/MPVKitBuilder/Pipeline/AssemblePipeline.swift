import Foundation

enum AssemblePipeline {
    static func run(_ options: BuildOptions, logger: BuildLogger) throws {
        let fm = FileManager.default
        let splitRoot = options.resolvedSplitPlatformDirectory
        guard fm.fileExists(atPath: splitRoot.path) else {
            throw BuildError.unexpected("assemble: split-platform directory not found at \(splitRoot.path)")
        }

        try fm.createDirectory(at: options.distDirectory, withIntermediateDirectories: true)

        logger.section("Assembling XCFrameworks")
        logger.write(.info, "  split-platform : \(splitRoot.path)")
        logger.write(.info, "  dist           : \(options.distDirectory.path)")

        var groups: [String: [URL]] = [:]
        var passthroughs: [URL] = []

        let entries = try fm.contentsOfDirectory(at: splitRoot, includingPropertiesForKeys: nil)
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasSuffix(".xcframework") {
                // e.g. MoltenVK.xcframework — already multi-platform, copy through.
                passthroughs.append(entry)
                continue
            }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }

            // Treat any other top-level directory as a platform bucket of .framework slices.
            let frameworks = try fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)
            for fw in frameworks where fw.pathExtension == "framework" {
                let frameworkName = fw.deletingPathExtension().lastPathComponent
                groups[frameworkName, default: []].append(fw)
            }
        }

        try mergeGroups(groups, options: options, logger: logger)
        try copyPassthroughs(passthroughs, options: options, logger: logger)

        logger.write(.success, "  assemble: done")
    }
}

// MARK: - Steps

extension AssemblePipeline {
    static func mergeGroups(_ groups: [String: [URL]], options: BuildOptions, logger: BuildLogger) throws {
        for name in groups.keys.sorted() {
            let slices = groups[name]!.sorted { $0.path < $1.path }
            let output = options.distDirectory.appendingPathComponent("\(name).xcframework")
            try removeIfExists(output)

            var arguments = ["-create-xcframework"]
            for slice in slices {
                arguments.append("-framework")
                arguments.append(slice.path)
            }
            arguments.append("-output")
            arguments.append(output.path)

            logger.write(.info, "  ↳ \(name) [\(slices.count) slice\(slices.count == 1 ? "" : "s")]")
            try runXcodebuild(arguments: arguments, logger: logger)
        }
    }

    static func copyPassthroughs(_ urls: [URL], options: BuildOptions, logger: BuildLogger) throws {
        let fm = FileManager.default
        for src in urls {
            let dst = options.distDirectory.appendingPathComponent(src.lastPathComponent)
            try removeIfExists(dst)
            try fm.copyItem(at: src, to: dst)
            logger.write(.info, "  ↳ passthrough \(src.lastPathComponent)")
        }
    }
}

// MARK: - Helpers

extension AssemblePipeline {
    static func runXcodebuild(arguments: [String], logger: BuildLogger) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            logger.write(.error, output)
            throw BuildError.processExited(
                code: process.terminationStatus,
                command: "/usr/bin/xcodebuild " + arguments.joined(separator: " "),
                log: nil
            )
        }
    }

    static func removeIfExists(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
