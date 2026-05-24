import Foundation

final class LibDav1dBuilder: MesonBuilder {
    init(context: BuildContext) {
        super.init(lib: .libdav1d, context: context)
    }

    override func preCompile() throws {
        try super.preCompile()
        _ = try requireTool("nasm", hint: "Install NASM with: brew install nasm")
    }

    override func mesonExtraSetupArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> [String] {
        [
            "-Denable_asm=true",
            "-Denable_tools=false",
            "-Denable_examples=false",
            "-Denable_tests=false",
            "-Denable_docs=false",
        ]
    }
}
