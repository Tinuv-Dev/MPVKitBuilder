import Foundation

final class LibUavs3dBuilder: CMakeBuilder {
    init(context: BuildContext) {
        super.init(lib: .libuavs3d, context: context)
    }

    override func cmakeExtraConfigureArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> [String] {
        [
            "-DCOMPILE_10BIT=1",
        ]
    }
}
