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

    override func configureArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> [String] {
        try super.configureArguments(platform: platform, arch: arch, buildDirectory: buildDirectory) + [
            "--disable-bdjava-jar",
            "--disable-silent-rules",
            "--disable-dependency-tracking",
        ]
    }
}
