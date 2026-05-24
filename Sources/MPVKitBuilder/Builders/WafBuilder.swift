import Foundation

class WafBuilder: Builder {
    func wafExecutable(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> String {
        let path = ctx.sourceDir(lib).appendingPathComponent("waf")
        if FileManager.default.isExecutableFile(atPath: path.path) {
            return path.path
        }
        throw BuildError.unexpected("missing waf executable: \(path.path)")
    }

    func wafWorkingDirectory(platform: PlatformType, arch: ArchType, buildDirectory: URL) -> URL {
        ctx.sourceDir(lib)
    }

    func wafConfigureArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> [String] {
        [
            "configure",
            "--host=\(platform.host(arch: arch))",
            "--prefix=\(ctx.thinDir(lib, platform: platform, arch: arch).path)",
        ]
    }

    func wafExtraConfigureArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> [String] {
        []
    }

    func wafBuildArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) -> [String] {
        ["build", "-j\(ProcessInfo.processInfo.activeProcessorCount)"]
    }

    func wafInstallArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) -> [String] {
        ["install"]
    }

    override func doCompile(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws {
        let waf = try wafExecutable(platform: platform, arch: arch, buildDirectory: buildDirectory)
        let env = environment(platform: platform, arch: arch)
        let workDir = wafWorkingDirectory(platform: platform, arch: arch, buildDirectory: buildDirectory)
        var configureArguments = try wafConfigureArguments(platform: platform, arch: arch, buildDirectory: buildDirectory)
        configureArguments.append(contentsOf: try wafExtraConfigureArguments(platform: platform, arch: arch, buildDirectory: buildDirectory))

        try ctx.runner.launch(
            executable: waf,
            arguments: configureArguments,
            currentDirectory: workDir,
            environment: env,
            logTo: ctx.logFile(lib.rawValue)
        )
        try ctx.runner.launch(
            executable: waf,
            arguments: wafBuildArguments(platform: platform, arch: arch, buildDirectory: buildDirectory),
            currentDirectory: workDir,
            environment: env,
            logTo: ctx.logFile(lib.rawValue)
        )
        try ctx.runner.launch(
            executable: waf,
            arguments: wafInstallArguments(platform: platform, arch: arch, buildDirectory: buildDirectory),
            currentDirectory: workDir,
            environment: env,
            logTo: ctx.logFile(lib.rawValue)
        )
    }
}
