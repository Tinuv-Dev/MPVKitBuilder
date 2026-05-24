import Foundation

final class LibLcms2Builder: AutoconfBuilder {
    init(context: BuildContext) {
        super.init(lib: .lcms2, context: context)
    }

    override func configureArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> [String] {
        try super.configureArguments(platform: platform, arch: arch, buildDirectory: buildDirectory) + [
            "--without-jpeg",
            "--without-tiff",
            "--without-zlib",
            "--disable-fast-install",
        ]
    }
}
