import Foundation

final class LibPlaceboBuilder: MesonBuilder {
    init(context: BuildContext) {
        super.init(lib: .libplacebo, context: context)
    }

    override func dependencyLibraries() -> [Library] {
        [.vulkan, .libshaderc, .lcms2]
    }

    override func preCompile() throws {
        try super.preCompile()
        patchDemosMesonBuild()
    }

    override func mesonExtraSetupArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> [String] {
        [
            "-Dxxhash=disabled",
            "-Dopengl=disabled",
            "-Dtests=false",
            "-Ddemos=false",
        ]
    }

    // Disable SDL demo build — it fails without an SDL2 cross-compile setup
    func patchDemosMesonBuild() {
        let path = ctx.sourceDir(lib).appendingPathComponent("demos/meson.build")
        guard var content = try? String(contentsOf: path) else { return }
        content = content.replacingOccurrences(of: "if sdl.found()", with: "if false")
        try? content.write(to: path, atomically: true, encoding: .utf8)
    }
}
