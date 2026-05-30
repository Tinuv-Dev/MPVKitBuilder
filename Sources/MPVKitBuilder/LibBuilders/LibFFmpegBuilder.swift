import Foundation

final class LibFFmpegBuilder: AutoconfBuilder {
    init(context: BuildContext) {
        super.init(lib: .ffmpeg, context: context)
    }

    override func dependencyLibraries() -> [Library] {
        LibraryDependency.dependencies(of: .ffmpeg)
    }

    // MARK: - Source / configure

    override func configureExecutable(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> String {
        ctx.sourceDir(lib).appendingPathComponent("configure").path
    }

    override func configureWorkingDirectory(platform: PlatformType, arch: ArchType, buildDirectory: URL) -> URL {
        buildDirectory
    }

    override func buildWorkingDirectory(platform: PlatformType, arch: ArchType, buildDirectory: URL) -> URL {
        buildDirectory
    }

    override func configureDiagnosticLog(platform: PlatformType, arch: ArchType, buildDirectory: URL) -> URL? {
        buildDirectory.appendingPathComponent("ffbuild/config.log")
    }

    // prepareConfigure runs from source dir; FFmpeg's configure always exists so nothing to generate.
    override func prepareConfigure(platform: PlatformType, arch: ArchType, buildDirectory: URL, environment: [String: String]) throws {}

    // MARK: - Arguments

    override func configureArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> [String] {
        let prefix = ctx.thinDir(lib, platform: platform, arch: arch)
        var args = ["--prefix=\(prefix.path)"]
        args += FFmpegOptions.base
        args += FFmpegOptions.platformExtra(platform, arch)
        args += toolchainArguments(platform: platform)
        args += enableFlags(platform: platform, arch: arch)
        if ctx.options.enableGPL {
            args.append("--enable-gpl")
        }
        if ctx.options.enableDebug {
            args.append("--enable-debug")
            args.append("--disable-stripping")
            args.append("--disable-optimizations")
        }
        args += ctx.options.ffmpegExtraArgs
        return args
    }

    // MARK: - Environment

    override func environment(platform: PlatformType, arch: ArchType) -> [String: String] {
        var env = super.environment(platform: platform, arch: arch)
        env["CPPFLAGS"] = env["CFLAGS"]
        return env
    }

    override func ldFlags(platform: PlatformType, arch: ArchType) -> [String] {
        var flags = platform.ldFlags(arch: arch)
        for dependency in LibraryDependency.transitiveDependencies(of: lib) {
            let prefix = ctx.thinDir(dependency, platform: platform, arch: arch)
            let libDir = prefix.appendingPathComponent("lib")
            guard FileManager.default.fileExists(atPath: libDir.path) else { continue }
            flags.append("-L\(libDir.path)")
        }
        return flags
    }

    // MARK: - Pre-compile

    override func preCompile() throws {
        try super.preCompile()
        _ = try requireTool("nasm", hint: "brew install nasm")
        patchVideoToolbox()
    }

    // MARK: - Post-build (copy internal headers)

    override func postBuild(platform: PlatformType, arch: ArchType) throws {
        let scratch = ctx.scratchDir(lib, platform: platform, arch: arch)
        let thin = ctx.thinDir(lib, platform: platform, arch: arch)
        let source = ctx.sourceDir(lib)
        let fm = FileManager.default

        func ensureDir(_ url: URL) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        // config.h → each libav* include subdir
        let configH = scratch.appendingPathComponent("config.h")
        for sub in ["libavutil", "libavcodec", "libavformat"] {
            let dest = thin.appendingPathComponent("include/\(sub)/config.h")
            ensureDir(dest)
            try? fm.copyItem(at: configH, to: dest)
        }

        // Internal headers from source tree
        let sourceHeaders: [(String, String)] = [
            ("libavutil/getenv_utf8.h",        "include/libavutil/getenv_utf8.h"),
            ("libavutil/libm.h",               "include/libavutil/libm.h"),
            ("libavutil/thread.h",             "include/libavutil/thread.h"),
            ("libavutil/intmath.h",            "include/libavutil/intmath.h"),
            ("libavutil/mem_internal.h",       "include/libavutil/mem_internal.h"),
            ("libavutil/attributes_internal.h","include/libavutil/attributes_internal.h"),
            ("libavcodec/mathops.h",           "include/libavcodec/mathops.h"),
            ("libavformat/os_support.h",       "include/libavformat/os_support.h"),
        ]
        for (rel, dest) in sourceHeaders {
            let src = source.appendingPathComponent(rel)
            let dst = thin.appendingPathComponent(dest)
            ensureDir(dst)
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
        }

        // internal.h: copy + patch out timer.h include and Metal key
        let internalSrc = source.appendingPathComponent("libavutil/internal.h")
        let internalDst = thin.appendingPathComponent("include/libavutil/internal.h")
        ensureDir(internalDst)
        try? fm.removeItem(at: internalDst)
        if var content = try? String(contentsOf: internalSrc) {
            content = content.replacingOccurrences(of: "#include \"timer.h\"",
                                                   with: "// #include \"timer.h\"")
            content = content.replacingOccurrences(
                of: "kCVPixelBufferIOSurfaceOpenGLTextureCompatibilityKey",
                with: "kCVPixelBufferMetalCompatibilityKey"
            )
            try? content.write(to: internalDst, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Framework discovery

    override func frameworks() throws -> [String] {
        // Scan any available thin dir for *.a — runs after compilation
        for platform in platforms() {
            for arch in architectures(for: platform) {
                let libDir = ctx.thinDir(lib, platform: platform, arch: arch)
                    .appendingPathComponent("lib")
                guard let files = try? FileManager.default.contentsOfDirectory(atPath: libDir.path) else { continue }
                let names = files
                    .filter { $0.hasPrefix("lib") && $0.hasSuffix(".a") }
                    .sorted()
                    .map { "Lib" + String($0.dropFirst(3).dropLast(2)) }
                if !names.isEmpty { return names }
            }
        }
        return ["Libavcodec", "Libavdevice", "Libavfilter", "Libavformat",
                "Libavutil", "Libswresample", "Libswscale"]
    }

    // FFmpeg installs each library's headers under include/<libname>/
    override func headerRoot(platform: PlatformType, arch: ArchType, framework: String) -> URL {
        let libName = frameworkLibraryName(framework)
        return ctx.thinDir(lib, platform: platform, arch: arch)
            .appendingPathComponent("include")
            .appendingPathComponent(libName)
    }

    override func frameworkExcludeHeaders(_ framework: String) -> [String] {
        switch framework {
        case "Libavcodec":
            return ["xvmc", "vdpau", "qsv", "dxva2", "d3d11va", "mathops", "videotoolbox"]
        case "Libavutil":
            return ["hwcontext_vulkan", "hwcontext_vdpau", "hwcontext_vaapi",
                    "hwcontext_qsv", "hwcontext_opencl", "hwcontext_dxva2",
                    "hwcontext_d3d11va", "hwcontext_d3d12va", "hwcontext_amf",
                    "hwcontext_cuda", "hwcontext_videotoolbox",
                    "getenv_utf8", "intmath", "libm", "thread",
                    "mem_internal", "internal", "attributes_internal"]
        case "Libavformat":
            return ["os_support"]
        default:
            return []
        }
    }
}

// MARK: - Dependency enable flags

extension LibFFmpegBuilder {
    func toolchainArguments(platform: PlatformType) -> [String] {
        let clang = platform.xcrunFind(tool: "clang")
        let clangxx = platform.xcrunFind(tool: "clang++")
        let ar = platform.xcrunFind(tool: "ar")
        let ranlib = platform.xcrunFind(tool: "ranlib")
        let strip = platform.xcrunFind(tool: "strip")
        let pkgConfig = toolPath("pkg-config") ?? "pkg-config"
        let hostClang = PlatformType.macos.xcrunFind(tool: "clang")
        let hostArch: ArchType = ArchType.x86_64.executable ? .x86_64 : .arm64
        let hostCFlags = PlatformType.macos.cFlags(arch: hostArch).joined(separator: " ")
        let hostLDFlags = PlatformType.macos.ldFlags(arch: hostArch).joined(separator: " ")

        var args: [String] = []
        if !clang.isEmpty {
            args.append("--cc=\(clang)")
            args.append("--objcc=\(clang)")
            args.append("--dep-cc=\(clang)")
            args.append("--ld=\(clang)")
        }
        if !clangxx.isEmpty {
            args.append("--cxx=\(clangxx)")
        }
        if !ar.isEmpty {
            args.append("--ar=\(ar)")
        }
        if !ranlib.isEmpty {
            args.append("--ranlib=\(ranlib)")
        }
        if !strip.isEmpty {
            args.append("--strip=\(strip)")
        }
        if !hostClang.isEmpty {
            args.append("--host-cc=\(hostClang)")
            args.append("--host-ld=\(hostClang)")
            args.append("--host-cflags=\(hostCFlags)")
            args.append("--host-ldflags=\(hostLDFlags)")
        }
        args.append("--pkg-config=\(pkgConfig)")
        return args
    }

    func enableFlags(platform: PlatformType, arch: ArchType) -> [String] {
        var args: [String] = []
        for dep in LibraryDependency.dependencies(of: .ffmpeg) {
            guard depIsAvailable(dep, platform: platform, arch: arch) else { continue }
            guard ffmpegCanUse(dep, platform: platform) else { continue }
            args.append("--enable-\(dep.rawValue)")
            switch dep {
            case .libsrt, .libsmbclient:
                args.append("--enable-protocol=\(dep.rawValue)")
            case .libdav1d:
                args.append("--enable-decoder=libdav1d")
            case .libass:
                args.append("--enable-filter=ass")
                args.append("--enable-filter=subtitles")
            case .libzvbi:
                args.append("--enable-decoder=libzvbi_teletext")
            case .libplacebo:
                args.append("--enable-filter=libplacebo")
            default:
                break
            }
        }
        return args
    }

    func ffmpegCanUse(_ dep: Library, platform: PlatformType) -> Bool {
        // Mac Catalyst keeps VideoToolbox hardware decode, but FFmpeg's libplacebo
        // filter is not useful without the Vulkan/MoltenVK backend and fails CI
        // pkg-config link checks under Xcode 16.2.
        if dep == .libplacebo && platform == .maccatalyst {
            return false
        }
        return true
    }

    func depIsAvailable(_ dep: Library, platform: PlatformType, arch: ArchType) -> Bool {
        let thinDir = ctx.thinDir(dep, platform: platform, arch: arch)
        if !FileManager.default.fileExists(atPath: thinDir.path) { return false }
        // Vulkan is special: thin dir holds only pkgconfig, verify the .pc file
        if dep == .vulkan {
            let pc = thinDir.appendingPathComponent("lib/pkgconfig/vulkan.pc")
            return FileManager.default.fileExists(atPath: pc.path)
        }
        return true
    }

    // Patch kCVPixelBufferOpenGLESCompatibilityKey → Metal key in videotoolbox.c
    func patchVideoToolbox() {
        let path = ctx.sourceDir(lib).appendingPathComponent("libavcodec/videotoolbox.c")
        guard var content = try? String(contentsOf: path) else { return }
        content = content.replacingOccurrences(
            of: "kCVPixelBufferOpenGLESCompatibilityKey",
            with: "kCVPixelBufferMetalCompatibilityKey"
        )
        content = content.replacingOccurrences(
            of: "kCVPixelBufferIOSurfaceOpenGLTextureCompatibilityKey",
            with: "kCVPixelBufferMetalCompatibilityKey"
        )
        try? content.write(to: path, atomically: true, encoding: .utf8)
    }
}
