import Foundation

final class LibOpenSSLBuilder: AutoconfBuilder {
    init(context: BuildContext) {
        super.init(lib: .openssl, context: context)
    }

    override func frameworks() throws -> [String] {
        ["Libssl", "Libcrypto"]
    }

    override func configureExecutable(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> String {
        "/usr/bin/perl"
    }

    override func configureArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> [String] {
        let prefix = ctx.thinDir(lib, platform: platform, arch: arch)
        return [
            ctx.sourceDir(lib).appendingPathComponent("Configure").path,
            try opensslTarget(platform: platform, arch: arch),
            "no-shared",
            "no-tests",
            "no-apps",
            "no-docs",
            "--prefix=\(prefix.path)",
            "--openssldir=\(prefix.appendingPathComponent("ssl").path)",
        ]
    }

    override func configureWorkingDirectory(platform: PlatformType, arch: ArchType, buildDirectory: URL) -> URL {
        ctx.sourceDir(lib)
    }

    override func buildWorkingDirectory(platform: PlatformType, arch: ArchType, buildDirectory: URL) -> URL {
        ctx.sourceDir(lib)
    }

    override func installArguments(platform: PlatformType, arch: ArchType) -> [String] {
        ["install_sw"]
    }

    override func prepareConfigure(platform: PlatformType, arch: ArchType, buildDirectory: URL, environment: [String: String]) throws {
        _ = try? ctx.runner.launch(
            executable: "/usr/bin/make",
            arguments: ["clean"],
            currentDirectory: ctx.sourceDir(lib),
            environment: environment,
            logTo: ctx.logFile(lib.rawValue)
        )
    }

    override func environment(platform: PlatformType, arch: ArchType) -> [String: String] {
        var env = super.environment(platform: platform, arch: arch)
        env["AR"] = platform.xcrunFind(tool: "ar")
        env["RANLIB"] = platform.xcrunFind(tool: "ranlib")
        return env
    }

    func opensslTarget(platform: PlatformType, arch: ArchType) throws -> String {
        switch (platform, arch) {
        case (.macos, .arm64):
            return "darwin64-arm64-cc"
        case (.macos, .x86_64):
            return "darwin64-x86_64-cc"
        default:
            throw BuildError.platformNotSupported(library: lib.rawValue, platform: "\(platform.rawValue)/\(arch.rawValue)")
        }
    }
}
