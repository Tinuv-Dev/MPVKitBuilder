import Foundation

class MesonBuilder: Builder {
    func mesonSourceDirectory(platform: PlatformType, arch: ArchType, buildDirectory: URL) -> URL {
        ctx.sourceDir(lib)
    }

    func mesonCrossFile(platform: PlatformType, arch: ArchType, buildDirectory: URL) -> URL {
        buildDirectory.appendingPathComponent("cross-file.meson")
    }

    func mesonSetupArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> [String] {
        [
            "setup",
            buildDirectory.path,
            mesonSourceDirectory(platform: platform, arch: arch, buildDirectory: buildDirectory).path,
            "--cross-file", mesonCrossFile(platform: platform, arch: arch, buildDirectory: buildDirectory).path,
            "--prefix", ctx.thinDir(lib, platform: platform, arch: arch).path,
            "--libdir", "lib",
            "--default-library", "static",
            "--buildtype", ctx.options.enableDebug ? "debug" : "release",
        ]
    }

    func mesonExtraSetupArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> [String] {
        []
    }

    func mesonCompileArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) -> [String] {
        ["compile", "-C", buildDirectory.path, "--verbose"]
    }

    func mesonInstallArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) -> [String] {
        ["install", "-C", buildDirectory.path]
    }

    func writeMesonCrossFile(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws {
        let crossFile = mesonCrossFile(platform: platform, arch: arch, buildDirectory: buildDirectory)
        let pkgConfig = try requireTool("pkg-config", hint: "Install pkg-config with: brew install pkg-config")
        let cFlagsText = mesonArray(cFlags(platform: platform, arch: arch))
        let ldFlagsText = mesonArray(ldFlags(platform: platform, arch: arch))
        let content = """
        [binaries]
        c = '\(platform.xcrunFind(tool: "clang"))'
        cpp = '\(platform.xcrunFind(tool: "clang++"))'
        objc = '\(platform.xcrunFind(tool: "clang"))'
        objcpp = '\(platform.xcrunFind(tool: "clang++"))'
        ar = '\(platform.xcrunFind(tool: "ar"))'
        strip = '\(platform.xcrunFind(tool: "strip"))'
        pkg-config = '\(pkgConfig)'
        nasm = '\(toolPath("nasm") ?? "nasm")'

        [properties]
        needs_exe_wrapper = true
        pkg_config_libdir = '\(pkgConfigLibdir(platform: platform, arch: arch))'

        [host_machine]
        system = 'darwin'
        subsystem = '\(platform.mesonSubSystem)'
        kernel = 'xnu'
        cpu_family = '\(arch.cpuFamily)'
        cpu = '\(arch.targetCpu)'
        endian = 'little'

        [built-in options]
        c_args = [\(cFlagsText)]
        cpp_args = [\(cFlagsText)]
        objc_args = [\(cFlagsText)]
        objcpp_args = [\(cFlagsText)]
        c_link_args = [\(ldFlagsText)]
        cpp_link_args = [\(ldFlagsText)]
        objc_link_args = [\(ldFlagsText)]
        objcpp_link_args = [\(ldFlagsText)]
        """
        try content.write(to: crossFile, atomically: true, encoding: .utf8)
    }

    override func doCompile(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws {
        let meson = try requireTool("meson", hint: "Install Meson and Ninja with: brew install meson ninja")
        _ = try requireTool("ninja", hint: "Install Ninja with: brew install ninja")
        let env = environment(platform: platform, arch: arch)
        try writeMesonCrossFile(platform: platform, arch: arch, buildDirectory: buildDirectory)

        var setupArguments = try mesonSetupArguments(platform: platform, arch: arch, buildDirectory: buildDirectory)
        setupArguments.append(contentsOf: try mesonExtraSetupArguments(platform: platform, arch: arch, buildDirectory: buildDirectory))
        try ctx.runner.launch(
            executable: meson,
            arguments: setupArguments,
            currentDirectory: ctx.sourceDir(lib),
            environment: env,
            logTo: ctx.logFile(lib.rawValue)
        )
        try ctx.runner.launch(
            executable: meson,
            arguments: mesonCompileArguments(platform: platform, arch: arch, buildDirectory: buildDirectory),
            environment: env,
            logTo: ctx.logFile(lib.rawValue)
        )
        try ctx.runner.launch(
            executable: meson,
            arguments: mesonInstallArguments(platform: platform, arch: arch, buildDirectory: buildDirectory),
            environment: env,
            logTo: ctx.logFile(lib.rawValue)
        )
    }
}
