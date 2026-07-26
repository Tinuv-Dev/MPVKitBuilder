import Foundation

/// libnfs：NFSv3 客户端，单独产出 `libnfs.xcframework` 供上层直接调用。
/// 注意 FFmpeg 上游不支持 libnfs（没有 `--enable-libnfs`），所以不接进 FFmpeg，
/// nfs:// 由上层通过 mpv 的 stream_cb 接管，详见 LibFFmpegBuilder.ffmpegCanUse。
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
