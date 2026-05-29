import Foundation

final class LibMpvBuilder: MesonBuilder {
    init(context: BuildContext) {
        super.init(lib: .libmpv, context: context)
    }

    override func dependencyLibraries() -> [Library] {
        LibraryDependency.dependencies(of: .libmpv)
    }

    override func doCompile(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws {
        try writeSystemIconvPkgConfig(platform: platform, arch: arch)
        try super.doCompile(platform: platform, arch: arch, buildDirectory: buildDirectory)
    }

    override func ldFlags(platform: PlatformType, arch: ArchType) -> [String] {
        platform.ldFlags(arch: arch)
    }

    override func additionalPkgConfigDirectories(platform: PlatformType, arch: ArchType) -> [String] {
        [
            systemPkgConfigDirectory(platform: platform, arch: arch).path,
        ]
    }

    override func environment(platform: PlatformType, arch: ArchType) -> [String: String] {
        var env = super.environment(platform: platform, arch: arch)
        env["CPPFLAGS"] = env["CFLAGS"]
        return env
    }

    override func mesonExtraSetupArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> [String] {
        var args = baseOptions()
        args.append(contentsOf: dependencyOptions(platform: platform, arch: arch))
        args.append(contentsOf: gpuOptions(platform: platform, arch: arch))
        args.append(contentsOf: appleOptions(platform: platform))
        return args
    }

    override func headerRoot(platform: PlatformType, arch: ArchType, framework: String) -> URL {
        ctx.thinDir(lib, platform: platform, arch: arch)
            .appendingPathComponent("include")
            .appendingPathComponent("mpv")
    }
}

// MARK: - Meson options

extension LibMpvBuilder {
    func baseOptions() -> [String] {
        [
            "-Dlibmpv=true",
            "-Dcplayer=false",
            "-Dtests=false",
            "-Dfuzzers=false",
            "-Dbuild-date=false",
            "-Dgpl=\(ctx.options.enableGPL ? "true" : "false")",
            "-Dhtml-build=disabled",
            "-Dmanpage-build=disabled",
            "-Dpdf-build=disabled",

            "-Dcdda=disabled",
            "-Dcplugins=disabled",
            "-Ddvbin=disabled",
            "-Ddvdnav=disabled",
            "-Djavascript=disabled",
            "-Djpeg=disabled",
            "-Dlibarchive=disabled",
            "-Dlibavdevice=disabled",
            "-Dpthread-debug=disabled",
            "-Drubberband=disabled",
            "-Dsdl2-gamepad=disabled",
            "-Dvapoursynth=disabled",
            "-Dx11-clipboard=disabled",
            "-Dzimg=disabled",
            "-Dzlib=disabled",

            "-Dalsa=disabled",
            "-Djack=disabled",
            "-Dopenal=disabled",
            "-Daudiotrack=disabled",
            "-Daaudio=disabled",
            "-Dopensles=disabled",
            "-Doss-audio=disabled",
            "-Dpipewire=disabled",
            "-Dpulse=disabled",
            "-Dsdl2-audio=disabled",
            "-Dsndio=disabled",
            "-Dwasapi=disabled",

            "-Dcaca=disabled",
            "-Dd3d11=disabled",
            "-Ddirect3d=disabled",
            "-Ddmabuf-wayland=disabled",
            "-Ddrm=disabled",
            "-Degl=disabled",
            "-Degl-android=disabled",
            "-Degl-angle=disabled",
            "-Degl-angle-lib=disabled",
            "-Degl-angle-win32=disabled",
            "-Degl-drm=disabled",
            "-Degl-wayland=disabled",
            "-Degl-x11=disabled",
            "-Dgbm=disabled",
            "-Dgl=enabled",
            "-Dgl-dxinterop=disabled",
            "-Dgl-dxinterop-d3d9=disabled",
            "-Dgl-win32=disabled",
            "-Dgl-x11=disabled",
            "-Dplain-gl=enabled",
            "-Dsdl2-video=disabled",
            "-Dshaderc=disabled",
            "-Dsixel=disabled",
            "-Dspirv-cross=disabled",
            "-Dvdpau=disabled",
            "-Dvdpau-gl-x11=disabled",
            "-Dvaapi=disabled",
            "-Dvaapi-drm=disabled",
            "-Dvaapi-wayland=disabled",
            "-Dvaapi-win32=disabled",
            "-Dvaapi-x11=disabled",
            "-Dwayland=disabled",
            "-Dx11=disabled",
            "-Dxv=disabled",

            "-Dandroid-media-ndk=disabled",
            "-Dcuda-hwaccel=disabled",
            "-Dcuda-interop=disabled",
            "-Dd3d-hwaccel=disabled",
            "-Dd3d9-hwaccel=disabled",
            "-Dvideotoolbox-gl=disabled",

            "-Dmacos-10-15-4-features=disabled",
            "-Dmacos-11-features=disabled",
            "-Dmacos-11-3-features=disabled",
            "-Dmacos-12-features=disabled",
            "-Dmacos-cocoa-cb=disabled",
            "-Dmacos-media-player=disabled",
            "-Dmacos-touchbar=disabled",
            "-Dswift-build=disabled",
        ]
    }

    func dependencyOptions(platform: PlatformType, arch: ArchType) -> [String] {
        [
            "-Diconv=enabled",
            "-Dlcms2=\(dependencyIsBuilt(.lcms2, platform: platform, arch: arch) ? "enabled" : "disabled")",
            "-Dlibbluray=\(dependencyIsBuilt(.libbluray, platform: platform, arch: arch) ? "enabled" : "disabled")",
            "-Dlua=\(dependencyIsBuilt(.libluajit, platform: platform, arch: arch) ? "luajit" : "disabled")",
            "-Duchardet=\(dependencyIsBuilt(.libuchardet, platform: platform, arch: arch) ? "enabled" : "disabled")",
        ]
    }

    func gpuOptions(platform: PlatformType, arch: ArchType) -> [String] {
        // vo=gpu-next（libplacebo）在 Apple 上的实际链路是
        // VideoToolbox 解码 -> libplacebo -> MoltenVK(Vulkan) -> CAMetalLayer。
        // 若不开 vulkan/moltenvk/videotoolbox-pl，gpu-next 拿不到可用 GPU 上下文、
        // 也无法上传 hwdec 帧，表现为「有声音无画面」（音频走 audiounit 仍正常）。
        // 这里与官方包对齐；开关按依赖是否真正产出来 gate，避免依赖缺失时 meson 配置阶段硬失败。
        let hasVulkan = dependencyIsBuilt(.vulkan, platform: platform, arch: arch)
        let hasPlacebo = dependencyIsBuilt(.libplacebo, platform: platform, arch: arch)
        return [
            "-Dvulkan=\(hasVulkan ? "enabled" : "disabled")",
            "-Dmoltenvk=\(hasVulkan ? "enabled" : "disabled")",
            "-Dvideotoolbox-pl=\(hasPlacebo ? "enabled" : "disabled")",
            "-Dios-gl=\(platform == .macos ? "disabled" : "enabled")",
        ]
    }

    func appleOptions(platform: PlatformType) -> [String] {
        switch platform {
        case .macos:
            return [
                "-Dcocoa=disabled",
                "-Dgl-cocoa=disabled",
                "-Dcoreaudio=enabled",
                "-Daudiounit=disabled",
                "-Davfoundation=disabled",
            ]
        default:
            return [
                "-Dcocoa=disabled",
                "-Dgl-cocoa=disabled",
                "-Dcoreaudio=disabled",
                "-Daudiounit=enabled",
                "-Davfoundation=disabled",
            ]
        }
    }

    func dependencyIsBuilt(_ dependency: Library, platform: PlatformType, arch: ArchType) -> Bool {
        let thin = ctx.thinDir(dependency, platform: platform, arch: arch)
        return FileManager.default.fileExists(atPath: thin.path)
    }
}

// MARK: - System pkg-config shims

extension LibMpvBuilder {
    func systemPkgConfigDirectory(platform: PlatformType, arch: ArchType) -> URL {
        ctx.thinDir(lib, platform: platform, arch: arch)
            .appendingPathComponent("lib/pkgconfig")
    }

    func writeSystemIconvPkgConfig(platform: PlatformType, arch: ArchType) throws {
        let directory = systemPkgConfigDirectory(platform: platform, arch: arch)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let content = """
        prefix=\(platform.isysroot)/usr
        exec_prefix=${prefix}
        libdir=${prefix}/lib
        includedir=${prefix}/include

        Name: iconv
        Description: Apple SDK iconv
        Version: 1.0
        Libs: -L${libdir} -liconv
        Cflags: -I${includedir}
        """
        try content.appending("\n")
            .write(to: directory.appendingPathComponent("iconv.pc"), atomically: true, encoding: .utf8)
    }
}
