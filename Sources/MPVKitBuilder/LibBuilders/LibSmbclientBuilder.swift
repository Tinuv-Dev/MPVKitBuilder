import Foundation

final class LibSmbclientBuilder: WafBuilder {
    init(context: BuildContext) {
        super.init(lib: .libsmbclient, context: context)
    }

    override func dependencyLibraries() -> [Library] {
        [.openssl]
    }

    override func preCompile() throws {
        try super.preCompile()
        try removeIfExists(ctx.sourceDir(lib).appendingPathComponent("bin"))
        try copyAuxiliaryTools()
    }

    override func cFlags(platform: PlatformType, arch: ArchType) -> [String] {
        var flags = super.cFlags(platform: platform, arch: arch)
        flags.append("-Wno-error=implicit-function-declaration")
        flags.append("-Wno-int-conversion")
        return flags
    }

    override func environment(platform: PlatformType, arch: ArchType) -> [String: String] {
        var env = super.environment(platform: platform, arch: arch)
        let source = ctx.sourceDir(lib)
        let tools = source.appendingPathComponent("buildtools/bin").path
        let existingPath = env["PATH"] ?? ""
        env["HOST"] = platform.host(arch: arch)
        env["PATH"] = "\(tools):\(existingPath)"
        env["COMPILE_ET"] = source.appendingPathComponent("buildtools/bin/compile_et").path
        env["ASN1_COMPILE"] = source.appendingPathComponent("buildtools/bin/asn1_compile").path
        env["PYTHONHASHSEED"] = "1"
        env["WAF_MAKE"] = "1"
        if let python = pythonExecutable() {
            env["PYTHON"] = python
        }
        return env
    }

    override func wafExecutable(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> String {
        if let python = pythonExecutable() {
            return python
        }
        return "/usr/bin/python3"
    }

    override func wafConfigureArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> [String] {
        var arguments = [
            wafScript().path,
            "configure",
            "--without-cluster-support",
            "--disable-rpath",
            "--without-ldap",
            "--without-pam",
            "--enable-fhs",
            "--without-winbind",
            "--without-ads",
            "--disable-avahi",
            "--disable-cups",
            "--without-gettext",
            "--without-ad-dc",
            "--without-acl-support",
            "--without-utmp",
            "--disable-iprint",
            "--nopyc",
            "--nopyo",
            "--disable-python",
            "--disable-symbol-versions",
            "--without-json",
            "--without-libarchive",
            "--without-regedit",
            "--without-lttng",
            "--without-gpgme",
            "--disable-cephfs",
            "--disable-glusterfs",
            "--without-syslog",
            "--without-quotas",
            "--bundled-libraries=ALL",
            "--with-static-modules=!vfs_snapper,ALL",
            "--nonshared-binary=smbtorture,smbd/smbd,client/smbclient",
            "--builtin-libraries=!smbclient,!smbd_base,!smbstatus,ALL",
            "--host=\(platform.host(arch: arch))",
            "--prefix=\(ctx.thinDir(lib, platform: platform, arch: arch).path)",
        ]
        if requiresCrossCompile(platform: platform, arch: arch) {
            let answers = try writeCrossAnswers(platform: platform, arch: arch)
            arguments.append("--cross-compile")
            arguments.append("--cross-answers=\(answers.path)")
        }
        return arguments
    }

    override func wafBuildArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) -> [String] {
        [wafScript().path, "build", "--targets=smbclient"]
    }

    override func wafInstallArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) -> [String] {
        [wafScript().path, "install", "--targets=smbclient"]
    }

    override func postBuild(platform: PlatformType, arch: ArchType) throws {
        let sourceLib = ctx.sourceDir(lib).appendingPathComponent("bin/default/source3/libsmb/libsmbclient.a")
        let targetLib = ctx.thinDir(lib, platform: platform, arch: arch)
            .appendingPathComponent("lib/libsmbclient.a")
        try FileManager.default.createDirectory(at: targetLib.deletingLastPathComponent(), withIntermediateDirectories: true)
        try removeIfExists(targetLib)
        try FileManager.default.copyItem(at: sourceLib, to: targetLib)
        try copyHeaderIfMissing(platform: platform, arch: arch)
    }
}

// MARK: - Samba helpers

extension LibSmbclientBuilder {
    func wafScript() -> URL {
        ctx.sourceDir(lib).appendingPathComponent("buildtools/bin/waf")
    }

    func pythonExecutable() -> String? {
        toolPath("python3.8") ?? toolPath("python3")
    }

    func auxiliaryToolsDirectory() throws -> URL {
        guard let root = Bundle.module.resourceURL?.appendingPathComponent("Patch/libsmbclient/bin"),
              FileManager.default.fileExists(atPath: root.path) else {
            throw BuildError.unexpected("missing libsmbclient auxiliary tools in resources")
        }
        return root
    }

    func copyAuxiliaryTools() throws {
        let source = try auxiliaryToolsDirectory()
        let target = ctx.sourceDir(lib).appendingPathComponent("buildtools/bin")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let tools = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for tool in tools {
            let destination = target.appendingPathComponent(tool.lastPathComponent)
            try removeIfExists(destination)
            try FileManager.default.copyItem(at: tool, to: destination)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: destination.path
            )
        }
    }

    func requiresCrossCompile(platform: PlatformType, arch: ArchType) -> Bool {
        platform != .macos || !arch.executable
    }

    func writeCrossAnswers(platform: PlatformType, arch: ArchType) throws -> URL {
        let url = ctx.sourceDir(lib).appendingPathComponent("cross-answers.txt")
        let content = """
        Checking uname sysname type: "Darwin"
        Checking uname machine type: "\(arch.targetCpu)"
        Checking uname release type: "23.0.0"
        Checking uname version type: "Darwin Kernel Version"
        """
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func copyHeaderIfMissing(platform: PlatformType, arch: ArchType) throws {
        let includeRoot = ctx.thinDir(lib, platform: platform, arch: arch).appendingPathComponent("include")
        let installed = includeRoot.appendingPathComponent("samba-4.0/libsmbclient.h")
        if FileManager.default.fileExists(atPath: installed.path) {
            return
        }
        let source = ctx.sourceDir(lib).appendingPathComponent("source3/include/libsmbclient.h")
        let target = includeRoot.appendingPathComponent("samba-4.0/libsmbclient.h")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: target)
    }
}
