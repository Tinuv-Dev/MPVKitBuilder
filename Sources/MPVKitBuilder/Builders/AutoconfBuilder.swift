import Foundation

class AutoconfBuilder: Builder {
    func configureExecutable(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> String {
        ctx.sourceDir(lib).appendingPathComponent("configure").path
    }

    func configureArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> [String] {
        [
            "--prefix=\(ctx.thinDir(lib, platform: platform, arch: arch).path)",
            "--build=\(buildHost())",
            "--host=\(platform.host(arch: arch))",
            "--enable-static",
            "--disable-shared",
        ]
    }

    func buildHost() -> String {
        if ArchType.x86_64.executable {
            return "x86_64-apple-darwin"
        }
        return "aarch64-apple-darwin"
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

    func prepareConfigure(platform: PlatformType, arch: ArchType, buildDirectory: URL, environment: [String: String]) throws {
        let configure = ctx.sourceDir(lib).appendingPathComponent("configure")
        if FileManager.default.fileExists(atPath: configure.path) {
            return
        }

        let source = ctx.sourceDir(lib)
        let autogen = source.appendingPathComponent("autogen.sh")
        let bootstrap = source.appendingPathComponent("bootstrap")
        let dotBootstrap = source.appendingPathComponent(".bootstrap")

        if FileManager.default.fileExists(atPath: autogen.path) {
            var env = environment
            env["NOCONFIGURE"] = "1"
            try ctx.runner.launch(
                executable: "/bin/sh",
                arguments: [autogen.path],
                currentDirectory: source,
                environment: env,
                logTo: ctx.logFile(lib.rawValue)
            )
        } else if FileManager.default.fileExists(atPath: bootstrap.path) {
            try ctx.runner.launch(
                executable: bootstrap.path,
                arguments: [],
                currentDirectory: source,
                environment: environment,
                logTo: ctx.logFile(lib.rawValue)
            )
        } else if FileManager.default.fileExists(atPath: dotBootstrap.path) {
            try ctx.runner.launch(
                executable: dotBootstrap.path,
                arguments: [],
                currentDirectory: source,
                environment: environment,
                logTo: ctx.logFile(lib.rawValue)
            )
        }

        if !FileManager.default.fileExists(atPath: configure.path) {
            throw BuildError.unexpected("missing configure script: \(configure.path)")
        }
    }

    func postConfigure(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws {}

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

        try postConfigure(platform: platform, arch: arch, buildDirectory: buildDirectory)

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
