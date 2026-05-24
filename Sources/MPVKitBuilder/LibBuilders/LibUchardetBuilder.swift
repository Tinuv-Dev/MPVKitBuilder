import Foundation

final class LibUchardetBuilder: CMakeBuilder {
    init(context: BuildContext) {
        super.init(lib: .libuchardet, context: context)
    }

    override func preCompile() throws {
        try super.preCompile()
        disableTests()
    }

    override func cmakeExtraConfigureArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> [String] {
        [
            "-DBUILD_BINARY=OFF",
            "-DBUILD_SHARED_LIBS=OFF",
            "-DBUILD_STATIC=ON",
            "-DCHECK_SSE2=OFF",
            "-DTARGET_ARCHITECTURE=\(arch.targetCpu)",
        ]
    }

    func disableTests() {
        let path = ctx.sourceDir(lib).appendingPathComponent("CMakeLists.txt")
        guard var content = try? String(contentsOf: path) else { return }
        content = content.replacingOccurrences(of: "add_subdirectory(test)", with: "# add_subdirectory(test)")
        try? content.write(to: path, atomically: true, encoding: .utf8)
    }

    override func headerRoot(platform: PlatformType, arch: ArchType, framework: String) -> URL {
        ctx.thinDir(lib, platform: platform, arch: arch)
            .appendingPathComponent("include")
            .appendingPathComponent("uchardet")
    }
}
