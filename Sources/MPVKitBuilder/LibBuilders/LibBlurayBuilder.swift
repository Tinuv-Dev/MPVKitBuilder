import Foundation

final class LibBlurayBuilder: AutoconfBuilder {
    init(context: BuildContext) {
        super.init(lib: .libbluray, context: context)
    }

    override func dependencyLibraries() -> [Library] {
        [.libfreetype]
    }

    // Only macOS supports disc mounting (platform constraint from upstream)
    override func platforms() -> [PlatformType] {
        super.platforms().filter { $0 == .macos }
    }

    override func preCompile() throws {
        try super.preCompile()
        // libudfread is a git submodule — not fetched by shallow clone
        try ctx.runner.launch(
            executable: "/usr/bin/git",
            arguments: ["submodule", "update", "--init"],
            currentDirectory: ctx.sourceDir(lib),
            logTo: ctx.logFile(lib.rawValue)
        )
    }

    override func configureArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> [String] {
        try super.configureArguments(platform: platform, arch: arch, buildDirectory: buildDirectory) + [
            "--disable-bdjava-jar",
            "--disable-silent-rules",
            "--disable-dependency-tracking",
            "--without-fontconfig",   // fontconfig 不在 Apple SDK 里，跨架构链接失败
        ]
    }

    override func environment(platform: PlatformType, arch: ArchType) -> [String: String] {
        var env = super.environment(platform: platform, arch: arch)
        // 让 configure 认为没有 Java，跳过 BDFontMetrics.c 的编译
        env["JAVA_HOME"] = ""
        env["JAVAC"] = "no"
        env["JAVA"] = "no"
        return env
    }
}
