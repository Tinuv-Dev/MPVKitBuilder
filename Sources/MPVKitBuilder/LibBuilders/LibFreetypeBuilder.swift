import Foundation

final class LibFreetypeBuilder: MesonBuilder {
    init(context: BuildContext) {
        super.init(lib: .libfreetype, context: context)
    }

    override func mesonExtraSetupArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> [String] {
        [
            "-Dbrotli=disabled",
            "-Dharfbuzz=disabled",
            "-Dpng=disabled",
            "-Dzlib=disabled",
        ]
    }
}
