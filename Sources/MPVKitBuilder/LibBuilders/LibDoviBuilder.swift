import Foundation

final class LibDoviBuilder: Builder {
    init(context: BuildContext) {
        super.init(lib: .libdovi, context: context)
    }

    // Stable Rust cross-compilation targets only cover macOS, iOS, and iOS Simulator.
    // tvOS, visionOS, and Mac Catalyst require nightly Rust and are deferred.
    override func platforms() -> [PlatformType] {
        let supported: Set<PlatformType> = [.macos, .ios, .isimulator]
        return super.platforms().filter { supported.contains($0) }
    }

    // arm64e has no corresponding Rust target triple.
    override func architectures(for platform: PlatformType) -> [ArchType] {
        super.architectures(for: platform).filter { $0 != .arm64e }
    }

    override func build() throws {
        if platforms().isEmpty {
            ctx.logger.step("no supported Rust targets in current platform set — skipping libdovi")
            return
        }
        try super.build()
    }

    override func preCompile() throws {
        try super.preCompile()
        _ = try requireTool(
            "cargo",
            hint: "Install Rust: brew install rust  OR  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
        )
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cargo/bin")
        // cargo-c installs as cargo-cinstall (and siblings), not a single cargo-c binary.
        let cargoInstallPath = home.appendingPathComponent("cargo-cinstall").path
        let legacyPath = home.appendingPathComponent("cargo-c").path
        guard FileManager.default.isExecutableFile(atPath: cargoInstallPath)
            || FileManager.default.isExecutableFile(atPath: legacyPath)
            || toolPath("cargo-cinstall") != nil
            || toolPath("cargo-c") != nil else {
            throw BuildError.missingTool(name: "cargo-c", hint: "cargo install cargo-c")
        }
    }

    override func doCompile(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws {
        let rustTarget = try rustTargetTriple(platform: platform, arch: arch)
        let cargo = try requireTool("cargo", hint: "Install Rust")
        let thin = ctx.thinDir(lib, platform: platform, arch: arch)
        let source = ctx.sourceDir(lib)

        // Add the Rust target if rustup is available.
        // rustup lives in ~/.cargo/bin which is not in Builder's default toolPath search.
        if let rustup = rustupPath() {
            try? ctx.runner.launch(
                executable: rustup,
                arguments: ["target", "add", rustTarget],
                logTo: ctx.logFile(lib.rawValue)
            )
        }

        var env = ProcessInfo.processInfo.environment
        let cargoHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cargo/bin").path
        env["PATH"] = "\(cargoHome):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\(env["PATH"] ?? "")"

        let clang = platform.xcrunFind(tool: "clang")
        if !clang.isEmpty {
            env["CC"] = clang
            env["CFLAGS"] = cFlags(platform: platform, arch: arch).joined(separator: " ")
            // Tell cargo which linker to use when targeting this Apple platform.
            let linkerKey = "CARGO_TARGET_\(rustTarget.uppercased().replacingOccurrences(of: "-", with: "_"))_LINKER"
            env[linkerKey] = clang
        }

        // dolby_vision is a standalone crate under the dolby_vision/ subdirectory;
        // the repo root is dovi_tool (no workspace), so --package would fail.
        let doviCrate = source.appendingPathComponent("dolby_vision")
        try ctx.runner.launch(
            executable: cargo,
            arguments: [
                "cinstall",
                "--features", "capi",
                "--target", rustTarget,
                "--prefix", thin.path,
                "--library-type", "staticlib",
                "--release",
            ],
            currentDirectory: doviCrate,
            environment: env,
            logTo: ctx.logFile(lib.rawValue)
        )
    }

    override func frameworks() throws -> [String] {
        ["Libdovi"]
    }
}

// MARK: - Rust helpers

extension LibDoviBuilder {
    func rustupPath() -> String? {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cargo/bin/rustup").path,
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? toolPath("rustup")
    }
}

// MARK: - Rust target triple mapping

extension LibDoviBuilder {
    func rustTargetTriple(platform: PlatformType, arch: ArchType) throws -> String {
        switch (platform, arch) {
        case (.macos, .arm64):        return "aarch64-apple-darwin"
        case (.macos, .x86_64):       return "x86_64-apple-darwin"
        case (.ios, .arm64):          return "aarch64-apple-ios"
        case (.isimulator, .arm64):   return "aarch64-apple-ios-sim"
        case (.isimulator, .x86_64):  return "x86_64-apple-ios"
        default:
            throw BuildError.platformNotSupported(
                library: lib.rawValue,
                platform: "\(platform.rawValue)/\(arch.rawValue)"
            )
        }
    }
}
