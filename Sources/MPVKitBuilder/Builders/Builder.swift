import Foundation

enum BuildPhase: String {
    case idle
    case fetch
    case patch
    case compile
    case post
    case package
}

class Builder {
    let lib: Library
    let ctx: BuildContext
    var phase: BuildPhase = .idle
    var currentPlatform: PlatformType?
    var currentArch: ArchType?

    init(lib: Library, context: BuildContext) {
        self.lib = lib
        self.ctx = context
    }

    func build() throws {
        try runPhase(.fetch) { try obtainSource() }
        try runPhase(.patch) { try preCompile() }
        try runPhase(.compile) { try compile() }
        try runPhase(.post) { try postCompile() }
        try runPhase(.package) { try createXCFramework() }
        phase = .idle
        currentPlatform = nil
        currentArch = nil
    }

    func obtainSource() throws {
        let source = ctx.sourceDir(lib)
        if FileManager.default.fileExists(atPath: source.path) {
            ctx.logger.step("source exists: \(source.path)")
            return
        }

        ctx.logger.phase("fetch")
        try ctx.runner.launch(
            executable: "/usr/bin/git",
            arguments: cloneArguments(destination: source),
            logTo: ctx.logFile(lib.rawValue)
        )
    }

    func preCompile() throws {
        guard let patchRoot = Bundle.module.resourceURL?.appendingPathComponent("Patch") else {
            ctx.logger.step("no patches")
            return
        }
        let patchDir = patchRoot.appendingPathComponent(lib.rawValue)
        guard FileManager.default.fileExists(atPath: patchDir.path) else {
            ctx.logger.step("no patches")
            return
        }

        let files = try FileManager.default.contentsOfDirectory(
            at: patchDir,
            includingPropertiesForKeys: nil
        )
        let patchFiles = files
            .filter { $0.pathExtension == "patch" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !patchFiles.isEmpty else {
            ctx.logger.step("no patches")
            return
        }

        ctx.logger.phase("patch")
        for file in patchFiles {
            try applyPatchIfNeeded(file)
        }
    }

    func compile() throws {
        for platform in platforms() {
            let archs = architectures(for: platform)
            guard !archs.isEmpty else {
                throw BuildError.invalidArgument("no requested architecture is supported by \(platform.rawValue)")
            }

            for arch in archs {
                currentPlatform = platform
                currentArch = arch
                let thin = ctx.thinDir(lib, platform: platform, arch: arch)
                let scratch = ctx.scratchDir(lib, platform: platform, arch: arch)

                if builtLibrariesExist(platform: platform, arch: arch) {
                    ctx.logger.phase("compile", platform: platform.rawValue, arch: arch.rawValue)
                    ctx.logger.step("thin output exists, skipping")
                    continue
                }

                try removeIfExists(thin)
                try removeIfExists(scratch)
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: thin, withIntermediateDirectories: true)

                let started = Date()
                ctx.logger.phase("compile", platform: platform.rawValue, arch: arch.rawValue)
                try doCompile(platform: platform, arch: arch, buildDirectory: scratch)
                try postBuild(platform: platform, arch: arch)
                ctx.logger.phaseFinished(
                    "compile",
                    elapsed: Date().timeIntervalSince(started),
                    platform: platform.rawValue,
                    arch: arch.rawValue
                )
            }
        }
    }

    func postCompile() throws {}

    func createXCFramework() throws {
        ctx.logger.phase("package")
        try XCFrameworkAssembler(context: ctx).create(builder: self)
    }

    func doCompile(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws {
        throw BuildError.unexpected("\(lib.rawValue) has no compile implementation")
    }

    func postBuild(platform: PlatformType, arch: ArchType) throws {}

    func platforms() -> [PlatformType] {
        lib.supportedPlatforms(from: ctx.options.platforms)
    }

    func architectures(for platform: PlatformType) -> [ArchType] {
        guard !ctx.options.architectures.isEmpty else {
            return platform.defaultArchitectures
        }
        return platform.architectures.filter { ctx.options.architectures.contains($0) }
    }

    func frameworks() throws -> [String] {
        lib.expectedFrameworks
    }

    func dependencyLibraries() -> [Library] {
        []
    }

    func additionalPkgConfigDirectories(platform: PlatformType, arch: ArchType) -> [String] {
        []
    }

    func frameworkLibraryName(_ framework: String) -> String {
        if framework.hasPrefix("Lib") {
            return "lib" + framework.dropFirst(3).lowercased()
        }
        if framework.hasPrefix("lib") {
            return framework
        }
        return "lib" + framework
    }

    func headerRoot(platform: PlatformType, arch: ArchType, framework: String) -> URL {
        ctx.thinDir(lib, platform: platform, arch: arch).appendingPathComponent("include")
    }

    func frameworkExcludeHeaders(_ framework: String) -> [String] {
        []
    }

    func environment(platform: PlatformType, arch: ArchType) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let cFlags = cFlags(platform: platform, arch: arch)
        let ldFlags = ldFlags(platform: platform, arch: arch)
        let clang = platform.xcrunFind(tool: "clang")
        let clangxx = platform.xcrunFind(tool: "clang++")
        let pkgConfig = toolPath("pkg-config")

        env["LC_CTYPE"] = "C"
        env["CC"] = clang.isEmpty ? "/usr/bin/clang" : clang
        env["CXX"] = clangxx.isEmpty ? "/usr/bin/clang++" : clangxx
        env["CURRENT_ARCH"] = arch.rawValue
        env["CFLAGS"] = cFlags.joined(separator: " ")
        env["CXXFLAGS"] = cFlags.joined(separator: " ")
        env["LDFLAGS"] = ldFlags.joined(separator: " ")
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        env["PKG_CONFIG"] = pkgConfig ?? "pkg-config"
        env["PKG_CONFIG_PATH"] = pkgConfigPath(platform: platform, arch: arch)
        env["PKG_CONFIG_LIBDIR"] = pkgConfigLibdir(platform: platform, arch: arch)
        env["PKG_CONFIG_ALLOW_CROSS"] = "1"

        return env
    }

    func cFlags(platform: PlatformType, arch: ArchType) -> [String] {
        var flags = platform.cFlags(arch: arch)
        for dependency in dependencyLibraries() {
            let prefix = ctx.thinDir(dependency, platform: platform, arch: arch)
            guard FileManager.default.fileExists(atPath: prefix.path) else { continue }
            flags.append("-I\(prefix.appendingPathComponent("include").path)")
            if dependency == .libsmbclient {
                flags.append("-I\(prefix.appendingPathComponent("include/samba-4.0").path)")
            }
        }
        return flags
    }

    func ldFlags(platform: PlatformType, arch: ArchType) -> [String] {
        var flags = platform.ldFlags(arch: arch)
        for dependency in dependencyLibraries() {
            let prefix = ctx.thinDir(dependency, platform: platform, arch: arch)
            guard FileManager.default.fileExists(atPath: prefix.path) else { continue }
            flags.append("-L\(prefix.appendingPathComponent("lib").path)")
            for name in linkLibraryNames(for: dependency) {
                flags.append("-l\(name)")
            }
            if dependency == .libsmbclient {
                flags.append(contentsOf: ["-lresolv", "-lpthread", "-lz", "-liconv"])
            }
            if dependency == .libgnutls {
                // gnutls calls into Security/CoreFoundation for trust store + keychain.
                flags.append(contentsOf: ["-framework", "Security", "-framework", "CoreFoundation"])
            }
        }
        return flags
    }

    func sourceReference() -> String {
        lib.sourceReference
    }

    func cloneArguments(destination: URL) -> [String] {
        [
            "clone",
            "--depth", "1",
            "--branch", sourceReference(),
            lib.repoURL,
            destination.path,
        ]
    }

    func cleanBuildProducts() throws {
        try removeIfExists(ctx.libBuildRoot(lib))
        try removeIfExists(ctx.frameworksRoot(lib))
        for framework in try frameworks() {
            try removeIfExists(ctx.xcFrameworkURL(framework: framework))
        }
    }

    func builtLibrariesExist(platform: PlatformType, arch: ArchType) -> Bool {
        do {
            return try frameworks().allSatisfy { framework in
                let libName = frameworkLibraryName(framework)
                let path = ctx.thinDir(lib, platform: platform, arch: arch)
                    .appendingPathComponent("lib")
                    .appendingPathComponent("\(libName).a")
                return FileManager.default.fileExists(atPath: path.path)
            }
        } catch {
            return false
        }
    }
}

// MARK: - Helpers

extension Builder {
    func runPhase(_ nextPhase: BuildPhase, body: () throws -> Void) throws {
        phase = nextPhase
        try body()
    }

    func removeIfExists(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func applyPatchIfNeeded(_ file: URL) throws {
        let source = ctx.sourceDir(lib)
        let log = ctx.logFile(lib.rawValue)
        if (try? ctx.runner.launch(
            executable: "/usr/bin/git",
            arguments: ["apply", "--check", file.path],
            currentDirectory: source,
            logTo: log
        )) != nil {
            try ctx.runner.launch(
                executable: "/usr/bin/git",
                arguments: ["apply", file.path],
                currentDirectory: source,
                logTo: log
            )
            ctx.logger.step("applied \(file.lastPathComponent)")
            return
        }

        if (try? ctx.runner.launch(
            executable: "/usr/bin/git",
            arguments: ["apply", "--reverse", "--check", file.path],
            currentDirectory: source,
            logTo: log
        )) != nil {
            ctx.logger.step("already applied \(file.lastPathComponent)")
            return
        }

        try ctx.runner.launch(
            executable: "/usr/bin/git",
            arguments: ["apply", "--check", file.path],
            currentDirectory: source,
            logTo: log
        )
    }

    func requireTool(_ name: String, hint: String) throws -> String {
        if let path = toolPath(name) {
            return path
        }
        throw BuildError.missingTool(name: name, hint: hint)
    }

    func toolPath(_ name: String) -> String? {
        let searchPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] + searchPaths
        for directory in candidates {
            let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    func pkgConfigPath(platform: PlatformType, arch: ArchType) -> String {
        pkgConfigDirectories(platform: platform, arch: arch).joined(separator: ":")
    }

    func pkgConfigLibdir(platform: PlatformType, arch: ArchType) -> String {
        var directories = pkgConfigDirectories(platform: platform, arch: arch)
        if let defaults = defaultPkgConfigPath(), !defaults.isEmpty {
            directories.append(defaults)
        }
        return directories.joined(separator: ":")
    }

    func pkgConfigDirectories(platform: PlatformType, arch: ArchType) -> [String] {
        // Walk transitive deps so pkg-config can recursively resolve Requires across the
        // whole graph (e.g. libass.pc → harfbuzz/freetype) without leaking into brew.
        var directories = additionalPkgConfigDirectories(platform: platform, arch: arch)
        var ordered: [Library] = []
        var seen: Set<Library> = []
        var stack = dependencyLibraries()
        while let next = stack.popLast() {
            if !seen.insert(next).inserted { continue }
            ordered.append(next)
            stack.append(contentsOf: LibraryDependency.dependencies(of: next))
        }
        directories.append(contentsOf: ordered.compactMap { dependency in
            let dir = ctx.thinDir(dependency, platform: platform, arch: arch)
                .appendingPathComponent("lib/pkgconfig")
            guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
            return dir.path
        })
        return directories
    }

    func defaultPkgConfigPath() -> String? {
        guard let pkgConfig = toolPath("pkg-config") else { return nil }
        return try? ctx.runner.launch(
            executable: pkgConfig,
            arguments: ["--variable", "pc_path", "pkg-config"],
            captureOutput: true
        )
    }

    func linkLibraryNames(for library: Library) -> [String] {
        if library == .openssl {
            return ["ssl", "crypto"]
        }
        if library == .nettle {
            return ["nettle", "hogweed"]
        }
        if library.rawValue.hasPrefix("lib") {
            return [String(library.rawValue.dropFirst(3))]
        }
        return [library.rawValue]
    }

    func mesonArray(_ values: [String]) -> String {
        values.map { "'\($0.replacingOccurrences(of: "'", with: "\\'"))'" }.joined(separator: ", ")
    }
}
