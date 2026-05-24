import Foundation

final class LibHarfbuzzBuilder: MesonBuilder {
    init(context: BuildContext) {
        super.init(lib: .libharfbuzz, context: context)
    }

    override func dependencyLibraries() -> [Library] {
        [.libfreetype]
    }

    override func mesonExtraSetupArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> [String] {
        [
            "-Dglib=disabled",
            "-Ddocs=disabled",
            "-Dtests=disabled",
            "-Dintrospection=disabled",
        ]
    }
}
