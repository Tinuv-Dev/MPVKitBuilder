import Foundation

/// libnfs：给 FFmpeg 提供 `nfs` protocol（`--enable-libnfs`）。
/// 纯 C、无外部依赖，只把测试 / 工具 / 示例关掉即可。
final class LibNfsBuilder: CMakeBuilder {
    init(context: BuildContext) {
        super.init(lib: .libnfs, context: context)
    }

    override func cmakeExtraConfigureArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> [String] {
        [
            "-Wno-dev",
            // 这几个目标会链出可执行文件，交叉编译下没意义还容易失败。
            "-DENABLE_TESTS=OFF",
            "-DENABLE_UTILS=OFF",
            "-DENABLE_EXAMPLES=OFF",
            "-DENABLE_DOCUMENTATION=OFF",
        ]
    }
}
