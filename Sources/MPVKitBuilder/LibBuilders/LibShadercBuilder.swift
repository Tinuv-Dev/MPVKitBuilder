import Foundation

final class LibShadercBuilder: CMakeBuilder {
    init(context: BuildContext) {
        super.init(lib: .libshaderc, context: context)
    }

    override func frameworks() throws -> [String] {
        ["Libshaderc_combined"]
    }

    override func preCompile() throws {
        try super.preCompile()
        // Fetch glslang / spirv-tools / spirv-headers deps
        let syncDeps = ctx.sourceDir(lib).appendingPathComponent("utils/git-sync-deps")
        if FileManager.default.isExecutableFile(atPath: syncDeps.path) {
            try ctx.runner.launch(
                executable: syncDeps.path,
                arguments: [],
                currentDirectory: ctx.sourceDir(lib),
                logTo: ctx.logFile(lib.rawValue)
            )
        }
        patchSpirvTools()
    }

    override func cmakeExtraConfigureArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> [String] {
        [
            "-DSHADERC_SKIP_TESTS=ON",
            "-DSHADERC_SKIP_EXAMPLES=ON",
            "-DSHADERC_ENABLE_SHARED_CRT=OFF",
            "-DSPIRV_HEADERS_SKIP_EXAMPLES=ON",
            "-DSPIRV_HEADERS_SKIP_INSTALL=ON",
            "-DENABLE_GLSLANG_BINARIES=OFF",
            "-DENABLE_HLSL=ON",
            "-DSPIRV_SKIP_EXECUTABLES=ON",
        ]
    }

    // Rename shaderc.pc → shaderc_shared.pc, shaderc_combined.pc → shaderc.pc
    // so downstream pkg-config lookups for "shaderc" find the combined static lib.
    override func postBuild(platform: PlatformType, arch: ArchType) throws {
        let pcDir = ctx.thinDir(lib, platform: platform, arch: arch)
            .appendingPathComponent("lib/pkgconfig")
        let shared   = pcDir.appendingPathComponent("shaderc.pc")
        let combined = pcDir.appendingPathComponent("shaderc_combined.pc")
        let backup   = pcDir.appendingPathComponent("shaderc_shared.pc")
        if FileManager.default.fileExists(atPath: shared.path) {
            try? FileManager.default.moveItem(at: shared, to: backup)
        }
        if FileManager.default.fileExists(atPath: combined.path) {
            try? FileManager.default.moveItem(at: combined, to: shared)
        }
    }
}

// MARK: - spirv-tools patch

extension LibShadercBuilder {
    // std::system() is not available in cross-compile sandbox; replace with popen()
    func patchSpirvTools() {
        let paths = [
            "third_party/spirv-tools/tools/reduce/reduce.cpp",
            "third_party/spirv-tools/tools/fuzz/fuzz.cpp",
        ]
        for rel in paths {
            let path = ctx.sourceDir(lib).appendingPathComponent(rel)
            guard var content = try? String(contentsOf: path) else { continue }
            content = content.replacingOccurrences(
                of: "int res = std::system(nullptr);\n              return res != 0;",
                with: "FILE* fp = popen(nullptr, \"r\");\n              return fp == NULL;"
            )
            content = content.replacingOccurrences(
                of: "int status = std::system(command.c_str());",
                with: "FILE* fp = popen(command.c_str(), \"r\");"
            )
            content = content.replacingOccurrences(
                of: "return status == 0;",
                with: "return fp != NULL;"
            )
            try? content.write(to: path, atomically: true, encoding: .utf8)
        }
    }
}
