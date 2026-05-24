import Foundation

final class LibSrtBuilder: CMakeBuilder {
    init(context: BuildContext) {
        super.init(lib: .libsrt, context: context)
    }

    override func dependencyLibraries() -> [Library] {
        [.openssl]
    }

    override func cmakeExtraConfigureArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> [String] {
        [
            "-Wno-dev",
            "-DUSE_ENCLIB=openssl",
            "-DENABLE_STDCXX_SYNC=1",
            "-DENABLE_CXX11=1",
            "-DUSE_OPENSSL_PC=1",
            "-DENABLE_DEBUG=0",
            "-DENABLE_LOGGING=0",
            "-DENABLE_HEAVY_LOGGING=0",
            "-DENABLE_APPS=0",
            "-DENABLE_SHARED=0",
            // maccatalyst lacks monotonic clock
            platform == .maccatalyst ? "-DENABLE_MONOTONIC_CLOCK=0" : "-DENABLE_MONOTONIC_CLOCK=1",
        ]
    }
}
