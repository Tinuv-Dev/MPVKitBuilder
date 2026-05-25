import Foundation

// MoltenVK has its own build system (make + fetchDependencies).
// It produces a single xcframework covering all platforms — we copy it directly.
// For each (platform, arch) we also write a vulkan.pc into the thin dir so
// downstream builders (libplacebo, ffmpeg) can find Vulkan via pkg-config.

final class LibVulkanBuilder: Builder {
    init(context: BuildContext) {
        super.init(lib: .vulkan, context: context)
    }

    // MARK: - Build override

    override func obtainSource() throws {
        // In prebuilt mode there is no source tree to clone.
        if ctx.options.prebuiltVulkanDir != nil {
            ctx.logger.step("using prebuilt MoltenVK bundle, skip source clone")
            return
        }
        try super.obtainSource()
    }

    override func preCompile() throws {
        if ctx.options.prebuiltVulkanDir != nil {
            ctx.logger.step("using prebuilt MoltenVK bundle, skip patches")
            return
        }
        try super.preCompile()
    }

    override func compile() throws {
        if let prebuilt = ctx.options.prebuiltVulkanDir {
            try compilePrebuilt(prebuiltDir: prebuilt)
            return
        }

        let source = ctx.sourceDir(lib)
        let targetPlatforms = platforms()
        let platformArgs = targetPlatforms.map { "--\($0.name)" }

        ctx.logger.phase("compile")

        let externalBuild = source.appendingPathComponent("External/build/Release")
        if !externalSlicesExist(root: externalBuild, platforms: targetPlatforms) {
            ctx.logger.step("fetchDependencies \(platformArgs.joined(separator: " "))")
            try ctx.runner.launch(
                executable: source.appendingPathComponent("fetchDependencies").path,
                arguments: platformArgs,
                currentDirectory: source,
                logTo: ctx.logFile(lib.rawValue)
            )
        }

        let xcfBuilt = source.appendingPathComponent("Package/Release/MoltenVK/static/MoltenVK.xcframework")
        if !moltenVKSlicesExist(root: xcfBuilt, platforms: targetPlatforms) {
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

        let xcfDst = ctx.xcFrameworkURL(framework: "MoltenVK")
        let xcfSrc: URL = {
            if let prebuilt = ctx.options.prebuiltVulkanDir {
                return prebuilt.appendingPathComponent("MoltenVK.xcframework")
            }
            return ctx.sourceDir(lib)
                .appendingPathComponent("Package/Release/MoltenVK/static/MoltenVK.xcframework")
        }()

        // Always materialise MoltenVK.xcframework into dist/ so consumers downloading the
        // dist/ artifact get a working framework. In split-platform mode we also expose it
        // under dist-platform/ so the aggregate step finds it next to per-platform slices.
        try removeIfExists(xcfDst)
        try FileManager.default.copyItem(at: xcfSrc, to: xcfDst)
        ctx.logger.step("copied MoltenVK.xcframework to \(xcfDst.path)")

        if ctx.options.enableSplitPlatform {
            try mirrorXCFrameworkToSplitDir(source: xcfSrc)
        }
    }

    override func frameworks() throws -> [String] {
        ["MoltenVK"]
    }

    // builtLibrariesExist is used by the standard compile() loop — we override compile()
    // so this is only checked if someone calls the default path. Check the .pc file instead.
    override func builtLibrariesExist(platform: PlatformType, arch: ArchType) -> Bool {
        let pc = ctx.thinDir(lib, platform: platform, arch: arch)
            .appendingPathComponent("lib/pkgconfig/vulkan.pc")
        let xcf: URL = {
            if let prebuilt = ctx.options.prebuiltVulkanDir {
                return prebuilt.appendingPathComponent("MoltenVK.xcframework")
            }
            return ctx.sourceDir(lib)
                .appendingPathComponent("Package/Release/MoltenVK/static/MoltenVK.xcframework")
        }()
        return FileManager.default.fileExists(atPath: pc.path)
            && moltenVKSliceExists(root: xcf, platform: platform)
    }
}

// MARK: - Prebuilt mode

extension LibVulkanBuilder {
    func compilePrebuilt(prebuiltDir: URL) throws {
        ctx.logger.phase("compile")
        ctx.logger.step("prebuilt vulkan: \(prebuiltDir.path)")

        let xcframework = prebuiltDir.appendingPathComponent("MoltenVK.xcframework")
        guard FileManager.default.fileExists(atPath: xcframework.path) else {
            throw BuildError.unexpected("prebuilt vulkan dir missing MoltenVK.xcframework: \(xcframework.path)")
        }
        let includeDir = prebuiltDir.appendingPathComponent("include")
        guard FileManager.default.fileExists(atPath: includeDir.path) else {
            throw BuildError.unexpected("prebuilt vulkan dir missing include/: \(includeDir.path)")
        }

        for platform in platforms() {
            // The prebuilt xcframework must contain a slice that matches each target platform.
            guard moltenVKSliceExists(root: xcframework, platform: platform) else {
                throw BuildError.platformNotSupported(library: lib.rawValue, platform: platform.rawValue)
            }
            for arch in architectures(for: platform) {
                try createPrebuiltPkgConfig(platform: platform, arch: arch, prebuiltDir: prebuiltDir)
            }
        }
    }

    func createPrebuiltPkgConfig(platform: PlatformType, arch: ArchType, prebuiltDir: URL) throws {
        let thinDir = ctx.thinDir(lib, platform: platform, arch: arch)
        let pcDir = thinDir.appendingPathComponent("lib/pkgconfig")
        try FileManager.default.createDirectory(at: pcDir, withIntermediateDirectories: true)

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
        prefix=\(prebuiltDir.path)
        includedir=${prefix}/include
        libdir=${prefix}/MoltenVK.xcframework/\(platform.frameworkName)

        Name: Vulkan-Loader
        Description: Vulkan Loader (prebuilt MoltenVK)
        Version: \(Library.vulkan.version.dropFirst())
        Libs: -L${libdir} -lMoltenVK \(libFlags)
        Cflags: -I${includedir}
        """
        let pc = pcDir.appendingPathComponent("vulkan.pc")
        try content.write(to: pc, atomically: true, encoding: .utf8)
        ctx.logger.step("wrote vulkan.pc (prebuilt) [\(platform.rawValue)/\(arch.rawValue)]")
    }

    func mirrorXCFrameworkToSplitDir(source: URL) throws {
        // In split-platform mode the aggregate step expects MoltenVK.xcframework at the
        // root of dist-platform/. We copy it through unchanged — the xcframework already
        // contains every platform slice.
        let splitRoot = ctx.options.resolvedSplitPlatformDirectory
        try FileManager.default.createDirectory(at: splitRoot, withIntermediateDirectories: true)
        let dst = splitRoot.appendingPathComponent("MoltenVK.xcframework")
        try removeIfExists(dst)
        try FileManager.default.copyItem(at: source, to: dst)
        ctx.logger.step("mirrored MoltenVK.xcframework to \(dst.path)")
    }
}

// MARK: - pkg-config generation

extension LibVulkanBuilder {
    func externalSlicesExist(root: URL, platforms: [PlatformType]) -> Bool {
        let names = ["SPIRVCross.xcframework", "SPIRVTools.xcframework", "glslang.xcframework"]
        return names.allSatisfy { name in
            let xcf = root.appendingPathComponent(name)
            return platforms.allSatisfy { platform in
                FileManager.default.fileExists(
                    atPath: xcf.appendingPathComponent(platform.frameworkName).path
                )
            }
        }
    }

    func moltenVKSlicesExist(root: URL, platforms: [PlatformType]) -> Bool {
        platforms.allSatisfy { moltenVKSliceExists(root: root, platform: $0) }
    }

    func moltenVKSliceExists(root: URL, platform: PlatformType) -> Bool {
        let library = root
            .appendingPathComponent(platform.frameworkName)
            .appendingPathComponent("libMoltenVK.a")
        return FileManager.default.fileExists(atPath: library.path)
    }

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
