import Foundation

final class LibGnutlsBuilder: AutoconfBuilder {
    init(context: BuildContext) {
        super.init(lib: .libgnutls, context: context)
    }

    override func obtainSource() throws {
        let source = ctx.sourceDir(lib)
        let configure = source.appendingPathComponent("configure")
        if FileManager.default.fileExists(atPath: configure.path) {
            ctx.logger.step("source exists: \(source.path)")
            return
        }

        if FileManager.default.fileExists(atPath: source.path) {
            ctx.logger.step("discarding incomplete GnuTLS source: \(source.path)")
            try removeIfExists(source)
        }

        let archive = ctx.options.workDirectory.appendingPathComponent("gnutls-\(lib.version).tar.xz")
        try FileManager.default.createDirectory(at: ctx.options.workDirectory, withIntermediateDirectories: true)
        try removeIfExists(archive)

        ctx.logger.phase("fetch")
        try ctx.runner.launch(
            executable: "/usr/bin/curl",
            arguments: ["-fL", "--retry", "3", "--connect-timeout", "30", "-o", archive.path, releaseArchiveURL()],
            logTo: ctx.logFile(lib.rawValue)
        )

        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        do {
            try ctx.runner.launch(
                executable: "/usr/bin/tar",
                arguments: ["-xJf", archive.path, "-C", source.path, "--strip-components", "1"],
                logTo: ctx.logFile(lib.rawValue)
            )
            try removeIfExists(archive)
        } catch {
            try? removeIfExists(source)
            throw error
        }

        if !FileManager.default.fileExists(atPath: configure.path) {
            throw BuildError.unexpected("missing configure script in GnuTLS release archive: \(configure.path)")
        }
    }

    override func dependencyLibraries() -> [Library] {
        [.gmp, .nettle]
    }

    override func environment(platform: PlatformType, arch: ArchType) -> [String: String] {
        var env = super.environment(platform: platform, arch: arch)
        // gnutls's autoreconf needs bison >= 2.4; macOS ships 2.3 in /usr/bin. Prefer brew's.
        let brewBison = "/opt/homebrew/opt/bison/bin"
        let localBison = "/usr/local/opt/bison/bin"
        env["PATH"] = "\(brewBison):\(localBison):" + (env["PATH"] ?? "")
        return env
    }

    override func postConfigure(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws {
        // gnutls's lib/accelerated/aarch64 Makefile sets AM_CCASFLAGS using flags that don't survive
        // cross-compile to Apple targets. Comment it out so the assembler uses the inherited CFLAGS.
        // Patch both the build-tree Makefile and the source-tree Makefile.in so the change sticks
        // even if config.status regenerates the Makefile mid-build.
        let candidates = [
            buildDirectory.appendingPathComponent("lib/accelerated/aarch64/Makefile"),
            ctx.sourceDir(lib).appendingPathComponent("lib/accelerated/aarch64/Makefile.in"),
        ]
        for path in candidates {
            guard var content = try? String(contentsOf: path, encoding: .utf8) else { continue }
            guard content.contains("AM_CCASFLAGS =") else { continue }
            content = content.replacingOccurrences(of: "AM_CCASFLAGS =", with: "#AM_CCASFLAGS =")
            try? content.write(to: path, atomically: true, encoding: .utf8)
        }
    }

    override func configureArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> [String] {
        try super.configureArguments(platform: platform, arch: arch, buildDirectory: buildDirectory) + [
            // Use bundled libtasn1 / unistring so we don't have to bring in another build pair.
            "--with-included-libtasn1",
            "--with-included-unistring",
            "--without-brotli",
            "--without-idn",
            "--without-p11-kit",
            "--without-zlib",
            "--without-zstd",
            "--enable-hardware-acceleration",
            "--disable-openssl-compatibility",
            "--disable-code-coverage",
            "--disable-doc",
            "--disable-maintainer-mode",
            "--disable-manpages",
            "--disable-nls",
            "--disable-rpath",
            "--disable-tools",
            "--disable-full-test-suite",
            "--with-pic",
            "--disable-fast-install",
            "--disable-dependency-tracking",
        ]
    }

    func releaseArchiveURL() -> String {
        let series = lib.version
            .split(separator: ".")
            .prefix(2)
            .joined(separator: ".")
        return "https://www.gnupg.org/ftp/gcrypt/gnutls/v\(series)/gnutls-\(lib.version).tar.xz"
    }
}
