import Foundation

final class XCFrameworkAssembler {
    let ctx: BuildContext

    init(context: BuildContext) {
        self.ctx = context
    }

    func create(builder: Builder) throws {
        let splitMode = ctx.options.enableSplitPlatform

        for framework in try builder.frameworks() {
            var frameworkURLs: [URL] = []
            for platform in builder.platforms() {
                let frameworkURL = try createFramework(builder: builder, framework: framework, platform: platform)
                frameworkURLs.append(frameworkURL)

                if splitMode {
                    try copyToSplitPlatform(frameworkURL: frameworkURL, framework: framework, platform: platform)
                }
            }

            if splitMode {
                // Don't assemble the multi-platform xcframework — the aggregate step
                // (`MPVKitBuilder assemble`) will do that after downloading every
                // platform job's slices.
                continue
            }

            let output = ctx.xcFrameworkURL(framework: framework)
            try removeIfExists(output)
            var arguments = ["-create-xcframework"]
            for url in frameworkURLs {
                arguments.append("-framework")
                arguments.append(url.path)
            }
            arguments.append("-output")
            arguments.append(output.path)
            try ctx.runner.launch(
                executable: "/usr/bin/xcodebuild",
                arguments: arguments,
                logTo: ctx.logFile(builder.lib.rawValue)
            )
            ctx.logger.step("created \(output.path)")
        }
    }

    func copyToSplitPlatform(frameworkURL: URL, framework: String, platform: PlatformType) throws {
        let platformDir = ctx.options.resolvedSplitPlatformDirectory
            .appendingPathComponent(platform.rawValue)
        try FileManager.default.createDirectory(at: platformDir, withIntermediateDirectories: true)
        let target = platformDir.appendingPathComponent("\(framework).framework")
        try removeIfExists(target)
        try FileManager.default.copyItem(at: frameworkURL, to: target)
        ctx.logger.step("split-platform: \(target.path)")
    }
}

// MARK: - Framework creation

extension XCFrameworkAssembler {
    func createFramework(builder: Builder, framework: String, platform: PlatformType) throws -> URL {
        let frameworkDir = ctx.frameworkDir(builder.lib, platform: platform, framework: framework)
        try removeIfExists(frameworkDir)
        try FileManager.default.createDirectory(at: frameworkDir, withIntermediateDirectories: true)

        let binaryURL = frameworkDir.appendingPathComponent(framework)
        let lipoInputs = try builder.architectures(for: platform).map { arch in
            try staticLibraryURL(builder: builder, framework: framework, platform: platform, arch: arch)
        }

        var lipoArgs = ["-create"]
        lipoArgs.append(contentsOf: lipoInputs.map(\.path))
        lipoArgs.append("-output")
        lipoArgs.append(binaryURL.path)
        try ctx.runner.launch(
            executable: "/usr/bin/lipo",
            arguments: lipoArgs,
            logTo: ctx.logFile(builder.lib.rawValue)
        )

        try copyHeadersIfNeeded(builder: builder, framework: framework, platform: platform, to: frameworkDir)
        try writeModuleMap(builder: builder, framework: framework, to: frameworkDir)
        try writeInfoPlist(framework: framework, platform: platform, to: frameworkDir)
        return frameworkDir
    }

    func staticLibraryURL(builder: Builder, framework: String, platform: PlatformType, arch: ArchType) throws -> URL {
        let libName = builder.frameworkLibraryName(framework)
        let path = ctx.thinDir(builder.lib, platform: platform, arch: arch)
            .appendingPathComponent("lib")
            .appendingPathComponent("\(libName).a")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw BuildError.unexpected("missing static library: \(path.path)")
        }
        return path
    }

    func copyHeadersIfNeeded(builder: Builder, framework: String, platform: PlatformType, to frameworkDir: URL) throws {
        guard let arch = builder.architectures(for: platform).first else {
            throw BuildError.invalidArgument("no architecture for \(platform.rawValue)")
        }
        let source = builder.headerRoot(platform: platform, arch: arch, framework: framework)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw BuildError.unexpected("missing headers: \(source.path)")
        }
        let target = frameworkDir.appendingPathComponent("Headers")
        try removeIfExists(target)
        try FileManager.default.copyItem(at: source, to: target)
    }

    func writeModuleMap(builder: Builder, framework: String, to frameworkDir: URL) throws {
        let modules = frameworkDir.appendingPathComponent("Modules")
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)

        var lines = [
            "framework module \(framework) [system] {",
            "    umbrella \".\"",
            "",
        ]
        for header in builder.frameworkExcludeHeaders(framework) {
            lines.append("    exclude header \"\(header).h\"")
        }
        lines.append("    export *")
        lines.append("}")

        try lines.joined(separator: "\n")
            .appending("\n")
            .write(to: modules.appendingPathComponent("module.modulemap"), atomically: true, encoding: .utf8)
    }

    func writeInfoPlist(framework: String, platform: PlatformType, to frameworkDir: URL) throws {
        let identifier = "com.mpvkitbuilder.\(framework)"
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleDevelopmentRegion</key>
            <string>en</string>
            <key>CFBundleExecutable</key>
            <string>\(framework)</string>
            <key>CFBundleIdentifier</key>
            <string>\(identifier)</string>
            <key>CFBundleInfoDictionaryVersion</key>
            <string>6.0</string>
            <key>CFBundleName</key>
            <string>\(framework)</string>
            <key>CFBundlePackageType</key>
            <string>FMWK</string>
            <key>CFBundleShortVersionString</key>
            <string>1.0</string>
            <key>CFBundleVersion</key>
            <string>1</string>
            <key>MinimumOSVersion</key>
            <string>\(platform.minVersion)</string>
            <key>CFBundleSupportedPlatforms</key>
            <array>
                <string>\(platform.sdk)</string>
            </array>
            <key>NSPrincipalClass</key>
            <string></string>
        </dict>
        </plist>
        """
        try content.write(to: frameworkDir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
    }
}

// MARK: - Helpers

extension XCFrameworkAssembler {
    func removeIfExists(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
