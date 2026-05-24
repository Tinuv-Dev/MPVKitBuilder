import Foundation

// MoltenVK has its own build system (make + fetchDependencies).
// It produces a single xcframework covering all platforms — we copy it directly.
// For each (platform, arch) we also write a vulkan.pc into the thin dir so
// downstream builders (libplacebo, ffmpeg) can find Vulkan via pkg-config.

final class LibVulkanBuilder: Builder {
    init(context: BuildContext) {
        super.init(lib: .vulkan, context: context)
    }

    // maccatalyst is not supported by MoltenVK
    override func platforms() -> [PlatformType] {
        super.platforms().filter { $0 != .maccatalyst }
    }

    // MARK: - Build override

    override func compile() throws {
        let source = ctx.sourceDir(lib)
        let targetPlatforms = platforms()
        let platformArgs = targetPlatforms.map { "--\($0.name)" }

        ctx.logger.phase("compile")

        let externalBuild = source.appendingPathComponent("External/build/Release")
        if !FileManager.default.fileExists(atPath: externalBuild.path) {
            ctx.logger.step("fetchDependencies \(platformArgs.joined(separator: " "))")
            try ctx.runner.launch(
                executable: source.appendingPathComponent("fetchDependencies").path,
                arguments: platformArgs,
                currentDirectory: source,
                logTo: ctx.logFile(lib.rawValue)
            )
        }

        let xcfBuilt = source.appendingPathComponent("Package/Release/MoltenVK/static/MoltenVK.xcframework")
        if !FileManager.default.fileExists(atPath: xcfBuilt.path) {
            ctx.logger.step("make \(targetPlatforms.map(\.name).joined(separator: " "))")
            try ctx.runner.launch(
                executable: "/usr/bin/make",
                arguments: targetPlatforms.map(\.name),
                currentDirectory: source,
                logTo: ctx.logFile(lib.rawValue)
            )
        }

        for platform in targetPlatforms {
            for arch in architectures(for: platform) {
                try createPkgConfig(platform: platform, arch: arch)
            }
        }
    }

    override func createXCFramework() throws {
        ctx.logger.phase("package")
        let source = ctx.sourceDir(lib)
        let xcfSrc = source.appendingPathComponent("Package/Release/MoltenVK/static/MoltenVK.xcframework")
        let xcfDst = ctx.xcFrameworkURL(framework: "MoltenVK")
        try removeIfExists(xcfDst)
        try FileManager.default.copyItem(at: xcfSrc, to: xcfDst)
        ctx.logger.step("copied MoltenVK.xcframework")
    }

    override func frameworks() throws -> [String] {
        ["MoltenVK"]
    }

    // builtLibrariesExist is used by the standard compile() loop — we override compile()
    // so this is only checked if someone calls the default path. Check the .pc file instead.
    override func builtLibrariesExist(platform: PlatformType, arch: ArchType) -> Bool {
        let pc = ctx.thinDir(lib, platform: platform, arch: arch)
            .appendingPathComponent("lib/pkgconfig/vulkan.pc")
        return FileManager.default.fileExists(atPath: pc.path)
    }
}

// MARK: - pkg-config generation

extension LibVulkanBuilder {
    func createPkgConfig(platform: PlatformType, arch: ArchType) throws {
        let thinDir = ctx.thinDir(lib, platform: platform, arch: arch)
        let pcDir = thinDir.appendingPathComponent("lib/pkgconfig")
        try FileManager.default.createDirectory(at: pcDir, withIntermediateDirectories: true)

        let moltenVKBase = ctx.sourceDir(lib).appendingPathComponent("Package/Release/MoltenVK")

        var sysFrameworks = ["CoreFoundation", "CoreGraphics", "Foundation",
                             "IOSurface", "Metal", "QuartzCore"]
        if platform == .macos {
            sysFrameworks.append("Cocoa")
        } else {
            sysFrameworks.append("UIKit")
        }
        if ![.tvos, .tvsimulator].contains(platform) {
            sysFrameworks.append("IOKit")
        }
        let libFlags = sysFrameworks.map { "-framework \($0)" }.joined(separator: " ")

        let content = """
        prefix=\(moltenVKBase.path)
        includedir=${prefix}/include
        libdir=${prefix}/static/MoltenVK.xcframework/\(platform.frameworkName)

        Name: Vulkan-Loader
        Description: Vulkan Loader
        Version: \(Library.vulkan.version.dropFirst())
        Libs: -L${libdir} -lMoltenVK \(libFlags)
        Cflags: -I${includedir}
        """
        let pc = pcDir.appendingPathComponent("vulkan.pc")
        try content.write(to: pc, atomically: true, encoding: .utf8)
        ctx.logger.step("wrote vulkan.pc [\(platform.rawValue)/\(arch.rawValue)]")
    }
}
