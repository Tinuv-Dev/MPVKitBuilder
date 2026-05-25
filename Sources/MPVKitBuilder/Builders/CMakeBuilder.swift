import Foundation

class CMakeBuilder: Builder {
    func cmakeSourceDirectory(platform: PlatformType, arch: ArchType, buildDirectory: URL) -> URL {
        ctx.sourceDir(lib)
    }

    func cmakeBuildType() -> String {
        ctx.options.enableDebug ? "Debug" : "Release"
    }

    func cmakeConfigureArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> [String] {
        let prefix = ctx.thinDir(lib, platform: platform, arch: arch)
        let source = cmakeSourceDirectory(platform: platform, arch: arch, buildDirectory: buildDirectory)
        let cFlagsText = cFlags(platform: platform, arch: arch).joined(separator: " ")
        let asmFlagsText = cFlagsText
        let ldFlagsText = ldFlags(platform: platform, arch: arch).joined(separator: " ")
        var arguments = [
            source.path,
            "-DCMAKE_VERBOSE_MAKEFILE=0",
            "-DCMAKE_BUILD_TYPE=\(cmakeBuildType())",
            "-DCMAKE_INSTALL_PREFIX=\(prefix.path)",
            "-DCMAKE_INSTALL_LIBDIR=lib",
            "-DCMAKE_OSX_SYSROOT=\(platform.isysroot)",
            "-DCMAKE_OSX_ARCHITECTURES=\(arch.rawValue)",
        ]

        if platform != .maccatalyst {
            arguments.append("-DCMAKE_OSX_DEPLOYMENT_TARGET=\(platform.minVersion)")
        }

        arguments.append(contentsOf: [
            "-DCMAKE_C_FLAGS=\(cFlagsText)",
            "-DCMAKE_CXX_FLAGS=\(cFlagsText)",
            "-DCMAKE_ASM_FLAGS=\(asmFlagsText)",
            "-DCMAKE_EXE_LINKER_FLAGS=\(ldFlagsText)",
            "-DCMAKE_SHARED_LINKER_FLAGS=\(ldFlagsText)",
            "-DCMAKE_MODULE_LINKER_FLAGS=\(ldFlagsText)",
            "-DBUILD_SHARED_LIBS=OFF",
            "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
        ])
        return arguments
    }

    func cmakeExtraConfigureArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> [String] {
        []
    }

    func cmakeBuildArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) -> [String] {
        [
            "--build", buildDirectory.path,
            "--parallel", "\(ProcessInfo.processInfo.activeProcessorCount)",
        ]
    }

    func cmakeInstallArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) -> [String] {
        ["--install", buildDirectory.path]
    }

    override func doCompile(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws {
        let cmake = try requireTool("cmake", hint: "Install CMake with: brew install cmake")
        let env = environment(platform: platform, arch: arch)
        var configureArguments = try cmakeConfigureArguments(platform: platform, arch: arch, buildDirectory: buildDirectory)
        configureArguments.append(contentsOf: try cmakeExtraConfigureArguments(platform: platform, arch: arch, buildDirectory: buildDirectory))

        try ctx.runner.launch(
            executable: cmake,
            arguments: configureArguments,
            currentDirectory: buildDirectory,
            environment: env,
            logTo: ctx.logFile(lib.rawValue)
        )
        try ctx.runner.launch(
            executable: cmake,
            arguments: cmakeBuildArguments(platform: platform, arch: arch, buildDirectory: buildDirectory),
            currentDirectory: buildDirectory,
            environment: env,
            logTo: ctx.logFile(lib.rawValue)
        )
        try ctx.runner.launch(
            executable: cmake,
            arguments: cmakeInstallArguments(platform: platform, arch: arch, buildDirectory: buildDirectory),
            currentDirectory: buildDirectory,
            environment: env,
            logTo: ctx.logFile(lib.rawValue)
        )
    }
}
