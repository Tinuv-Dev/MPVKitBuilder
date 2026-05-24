import Foundation

class AutoconfBuilder: Builder {
    func configureExecutable(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> String {
        ctx.sourceDir(lib).appendingPathComponent("configure").path
    }

    func configureArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> [String] {
        [
            "--prefix=\(ctx.thinDir(lib, platform: platform, arch: arch).path)",
            "--host=\(platform.host(arch: arch))",
            "--enable-static",
            "--disable-shared",
        ]
    }

    func configureWorkingDirectory(platform: PlatformType, arch: ArchType, buildDirectory: URL) -> URL {
        buildDirectory
    }

    func buildWorkingDirectory(platform: PlatformType, arch: ArchType, buildDirectory: URL) -> URL {
        buildDirectory
    }

    func makeArguments(platform: PlatformType, arch: ArchType) -> [String] {
        ["-j\(ProcessInfo.processInfo.activeProcessorCount)"]
    }

    func installArguments(platform: PlatformType, arch: ArchType) -> [String] {
        ["install"]
    }

    func prepareConfigure(platform: PlatformType, arch: ArchType, buildDirectory: URL, environment: [String: String]) throws {}

    override func doCompile(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws {
        let env = environment(platform: platform, arch: arch)
        try prepareConfigure(platform: platform, arch: arch, buildDirectory: buildDirectory, environment: env)

        try ctx.runner.launch(
            executable: try configureExecutable(platform: platform, arch: arch, buildDirectory: buildDirectory),
            arguments: try configureArguments(platform: platform, arch: arch, buildDirectory: buildDirectory),
            currentDirectory: configureWorkingDirectory(platform: platform, arch: arch, buildDirectory: buildDirectory),
            environment: env,
            logTo: ctx.logFile(lib.rawValue)
        )

        let workDir = buildWorkingDirectory(platform: platform, arch: arch, buildDirectory: buildDirectory)
        try ctx.runner.launch(
            executable: "/usr/bin/make",
            arguments: makeArguments(platform: platform, arch: arch),
            currentDirectory: workDir,
            environment: env,
            logTo: ctx.logFile(lib.rawValue)
        )
        try ctx.runner.launch(
            executable: "/usr/bin/make",
            arguments: installArguments(platform: platform, arch: arch),
            currentDirectory: workDir,
            environment: env,
            logTo: ctx.logFile(lib.rawValue)
        )
    }
}
