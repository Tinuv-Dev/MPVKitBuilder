import Foundation

final class LibLuaJITBuilder: Builder {
    init(context: BuildContext) {
        super.init(lib: .libluajit, context: context)
    }

    override func doCompile(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws {
        let make = try requireTool("make", hint: "Install command line tools or GNU make")
        let source = ctx.sourceDir(lib).appendingPathComponent("src")
        let env = luaJITEnvironment(platform: platform, arch: arch)
        let buildArgs = luaJITMakeArguments(platform: platform, arch: arch)

        try ctx.runner.launch(
            executable: make,
            arguments: ["clean"],
            currentDirectory: source,
            environment: env,
            logTo: ctx.logFile(lib.rawValue)
        )
        try ctx.runner.launch(
            executable: make,
            arguments: ["-j\(ProcessInfo.processInfo.activeProcessorCount)"] + buildArgs,
            currentDirectory: source,
            environment: env,
            logTo: ctx.logFile(lib.rawValue)
        )
        try installArtifacts(platform: platform, arch: arch)
    }
}

// MARK: - Build arguments

extension LibLuaJITBuilder {
    func luaJITEnvironment(platform: PlatformType, arch: ArchType) -> [String: String] {
        var env = environment(platform: platform, arch: arch)
        if platform == .macos {
            env["MACOSX_DEPLOYMENT_TARGET"] = platform.minVersion
        } else {
            env["IPHONEOS_DEPLOYMENT_TARGET"] = platform.minVersion
        }
        return env
    }

    func luaJITMakeArguments(platform: PlatformType, arch: ArchType) -> [String] {
        let prefix = ctx.thinDir(lib, platform: platform, arch: arch)
        let clang = platform.xcrunFind(tool: "clang")
        let ar = platform.xcrunFind(tool: "ar")
        let strip = platform.xcrunFind(tool: "strip")
        let targetFlags = (cFlags(platform: platform, arch: arch) + ["-fPIC"]).joined(separator: " ")
        let targetLDFlags = ldFlags(platform: platform, arch: arch).joined(separator: " ")

        return [
            "PREFIX=\(prefix.path)",
            "BUILDMODE=static",
            "HOST_CC=/usr/bin/clang",
            "CC=\(clang)",
            "TARGET_CC=\(clang)",
            "TARGET_STCC=\(clang)",
            "TARGET_LD=\(clang)",
            "TARGET_AR=\(ar) rcus",
            "TARGET_STRIP=\(strip)",
            "TARGET_SYS=\(luaJITTargetSystem(platform))",
            "TARGET_FLAGS=\(targetFlags)",
            "TARGET_LDFLAGS=\(targetLDFlags)",
        ]
    }

    func luaJITTargetSystem(_ platform: PlatformType) -> String {
        platform == .macos ? "Darwin" : "iOS"
    }
}

// MARK: - Install

extension LibLuaJITBuilder {
    func installArtifacts(platform: PlatformType, arch: ArchType) throws {
        let source = ctx.sourceDir(lib).appendingPathComponent("src")
        let thin = ctx.thinDir(lib, platform: platform, arch: arch)
        let includeDir = thin.appendingPathComponent("include/luajit")
        let libDir = thin.appendingPathComponent("lib")
        let pcDir = libDir.appendingPathComponent("pkgconfig")

        try FileManager.default.createDirectory(at: includeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pcDir, withIntermediateDirectories: true)

        let librarySource = source.appendingPathComponent("libluajit.a")
        let libraryTarget = libDir.appendingPathComponent("libluajit.a")
        try removeIfExists(libraryTarget)
        try FileManager.default.copyItem(at: librarySource, to: libraryTarget)

        for header in ["lua.h", "lualib.h", "lauxlib.h", "luaconf.h", "luajit.h", "lua.hpp"] {
            let sourceHeader = source.appendingPathComponent(header)
            guard FileManager.default.fileExists(atPath: sourceHeader.path) else { continue }
            let targetHeader = includeDir.appendingPathComponent(header)
            try removeIfExists(targetHeader)
            try FileManager.default.copyItem(at: sourceHeader, to: targetHeader)
        }

        try writePkgConfig(prefix: thin, to: pcDir.appendingPathComponent("luajit.pc"))
    }

    func writePkgConfig(prefix: URL, to url: URL) throws {
        let content = """
        prefix=\(prefix.path)
        exec_prefix=${prefix}
        libdir=${prefix}/lib
        includedir=${prefix}/include/luajit

        Name: LuaJIT
        Description: Just-in-time compiler for Lua
        Version: 2.1.0
        Libs: -L${libdir} -lluajit -lm
        Cflags: -I${includedir}
        """
        try content.appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
