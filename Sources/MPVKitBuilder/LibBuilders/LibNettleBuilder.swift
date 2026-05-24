import Foundation

final class LibNettleBuilder: AutoconfBuilder {
    init(context: BuildContext) {
        super.init(lib: .nettle, context: context)
    }

    override func dependencyLibraries() -> [Library] {
        [.gmp]
    }

    override func configureArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> [String] {
        try super.configureArguments(platform: platform, arch: arch, buildDirectory: buildDirectory) + [
            "--disable-assembler",
            "--disable-openssl",
            "--disable-gcov",
            "--disable-documentation",
            "--enable-pic",
            "--disable-fast-install",
            "--disable-dependency-tracking",
        ]
    }
}
