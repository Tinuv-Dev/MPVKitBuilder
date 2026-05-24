import Foundation

final class LibFribidiBuilder: MesonBuilder {
    init(context: BuildContext) {
        super.init(lib: .libfribidi, context: context)
    }

    override func mesonExtraSetupArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> [String] {
        [
            "-Ddeprecated=false",
            "-Ddocs=false",
            "-Dtests=false",
        ]
    }
}
