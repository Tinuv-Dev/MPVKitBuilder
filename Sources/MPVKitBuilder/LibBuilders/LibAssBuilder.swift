import Foundation

final class LibAssBuilder: AutoconfBuilder {
    init(context: BuildContext) {
        super.init(lib: .libass, context: context)
    }

    override func dependencyLibraries() -> [Library] {
        [.libfreetype, .libfribidi, .libharfbuzz, .libunibreak]
    }

    override func configureArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> [String] {
        var args = try super.configureArguments(platform: platform, arch: arch, buildDirectory: buildDirectory)
        args += [
            "--disable-libtool-lock",
            "--disable-fontconfig",
            "--disable-require-system-font-provider",
            "--disable-test",
            "--disable-profile",
            "--with-pic",
            "--disable-fast-install",
            "--disable-dependency-tracking",
        ]
        if arch == .x86_64 {
            args.append("--enable-asm")
        }
        return args
    }
}
