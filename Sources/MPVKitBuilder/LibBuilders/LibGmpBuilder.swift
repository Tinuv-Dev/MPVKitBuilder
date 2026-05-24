import Foundation

final class LibGmpBuilder: AutoconfBuilder {
    init(context: BuildContext) {
        super.init(lib: .gmp, context: context)
    }

    override func configureArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> [String] {
        // --disable-assembly: GMP's hand-rolled aarch64 ASM doesn't play nice with cross-compile / Apple toolchain.
        // C fallback is plenty fast for our use (samba uses GMP for big-int only via nettle).
        try super.configureArguments(platform: platform, arch: arch, buildDirectory: buildDirectory) + [
            "--disable-maintainer-mode",
            "--disable-assembly",
            "--with-pic",
            "--disable-fast-install",
            "--disable-dependency-tracking",
        ]
    }
}
