import Foundation

final class LibPlaceboBuilder: MesonBuilder {
    init(context: BuildContext) {
        super.init(lib: .libplacebo, context: context)
    }

    override func dependencyLibraries() -> [Library] {
        [.vulkan, .libshaderc, .lcms2]
    }

    override func ldFlags(platform: PlatformType, arch: ArchType) -> [String] {
        // Meson resolves libplacebo deps via pkg-config; injecting dependency -l flags
        // into global link checks makes probes like stdatomic pick up host libraries.
        platform.ldFlags(arch: arch)
    }

    override func cFlags(platform: PlatformType, arch: ArchType) -> [String] {
        var flags = super.cFlags(platform: platform, arch: arch)
        if !vulkanIsSupported(on: platform) {
            let include = ctx.sourceDir(.vulkan)
                .appendingPathComponent("Package/Release/MoltenVK/include")
            if FileManager.default.fileExists(atPath: include.path) {
                flags.append("-I\(include.path)")
            }
        }
        return flags
    }

    override func preCompile() throws {
        try super.preCompile()
        patchDemosMesonBuild()
        patchVulkanMesonBuild()
        patchVulkanUtilsGen()
        patchVulkanGpuApi14()
        try fetchFastFloatSubmodule()
    }

    // MoltenVK 1.2.11 仅提供到 VK_API_VERSION_1_3，gpu.c 中的 1.4 分支会编译失败
    func patchVulkanGpuApi14() {
        let path = ctx.sourceDir(lib).appendingPathComponent("src/vulkan/gpu.c")
        guard var content = try? String(contentsOf: path) else { return }
        let marker = "#ifdef VK_API_VERSION_1_4\n    if (vk->api_ver >= VK_API_VERSION_1_4)"
        if content.contains(marker) { return }
        let original = """
            if (vk->api_ver >= VK_API_VERSION_1_4) {
                return (struct pl_spirv_version) {
                    .env_version = VK_API_VERSION_1_4,
                    .spv_version = PL_SPV_VERSION(1, 6),
                };
            }
        """
        let patched = """
        #ifdef VK_API_VERSION_1_4
            if (vk->api_ver >= VK_API_VERSION_1_4) {
                return (struct pl_spirv_version) {
                    .env_version = VK_API_VERSION_1_4,
                    .spv_version = PL_SPV_VERSION(1, 6),
                };
            }
        #endif
        """
        guard content.contains(original) else { return }
        content = content.replacingOccurrences(of: original, with: patched)
        try? content.write(to: path, atomically: true, encoding: .utf8)
    }

    // fast_float 是 convert.cc 浮点解析所需的子模块；shallow clone 默认不拉
    func fetchFastFloatSubmodule() throws {
        let header = ctx.sourceDir(lib)
            .appendingPathComponent("3rdparty/fast_float/include/fast_float/fast_float.h")
        if FileManager.default.fileExists(atPath: header.path) { return }
        try ctx.runner.launch(
            executable: "/usr/bin/git",
            arguments: ["submodule", "update", "--init", "--depth", "1", "3rdparty/fast_float"],
            currentDirectory: ctx.sourceDir(lib),
            logTo: ctx.logFile(lib.rawValue)
        )
    }

    override func environment(platform: PlatformType, arch: ArchType) -> [String: String] {
        var env = super.environment(platform: platform, arch: arch)
        // meson --internal exe runs Python without user site-packages; inject the path
        // so that jinja2 (installed via --user) is visible during GLSL preprocessing
        let userSite = (ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
            + "/Library/Python/3.13/lib/python/site-packages"
        let existing = env["PYTHONPATH"] ?? ""
        env["PYTHONPATH"] = existing.isEmpty ? userSite : "\(userSite):\(existing)"
        return env
    }

    override func mesonExtraSetupArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> [String] {
        let vkXml = ctx.sourceDir(.vulkan)
            .appendingPathComponent("External/Vulkan-Headers/registry/vk.xml")
        var args = [
            "-Dxxhash=disabled",
            "-Dopengl=disabled",
            "-Dtests=false",
            "-Ddemos=false",
        ]
        if vulkanIsSupported(on: platform) {
            args.append("-Dvulkan=enabled")
            args.append("-Dvulkan-registry=\(vkXml.path)")
        } else {
            args.append("-Dvulkan=disabled")
            args.append("-Dvk-proc-addr=disabled")
        }
        return args
    }

    func vulkanIsSupported(on platform: PlatformType) -> Bool {
        Library.vulkan.supportedPlatforms(from: [platform]).contains(platform)
    }

    func patchVulkanMesonBuild() {
        let path = ctx.sourceDir(lib).appendingPathComponent("src/vulkan/meson.build")
        guard var content = try? String(contentsOf: path) else { return }
        content = content.replacingOccurrences(
            of: """
            vulkan_loader = dependency('vulkan', required: false)
            vulkan_headers = vulkan_loader.partial_dependency(includes: true, compile_args: true)
            """,
            with: """
            vulkan_loader = dependency('vulkan', required: vulkan_build)
            vulkan_headers = vulkan_loader.found() ? vulkan_loader.partial_dependency(includes: true, compile_args: true) : declare_dependency()
            """
        )
        content = content.replacingOccurrences(
            of: """
            build_deps += vulkan_headers

            if vulkan_build.allowed()
            """,
            with: """
            if vulkan_build.allowed()
              build_deps += vulkan_headers
            """
        )
        try? content.write(to: path, atomically: true, encoding: .utf8)
    }

    // Disable SDL demo build — it fails without an SDL2 cross-compile setup
    func patchDemosMesonBuild() {
        let path = ctx.sourceDir(lib).appendingPathComponent("demos/meson.build")
        guard var content = try? String(contentsOf: path) else { return }
        content = content.replacingOccurrences(of: "if sdl.found()", with: "if false")
        try? content.write(to: path, atomically: true, encoding: .utf8)
    }

    // Python 3.13 tightened ElementTree.__init__: it no longer accepts an
    // ElementTree as the root. Pass .getroot() so VkXML constructs cleanly.
    func patchVulkanUtilsGen() {
        let path = ctx.sourceDir(lib).appendingPathComponent("src/vulkan/utils_gen.py")
        guard var content = try? String(contentsOf: path) else { return }
        let original = "VkXML(ET.parse(xmlfile))"
        let patched = "VkXML(ET.parse(xmlfile).getroot())"
        guard content.contains(original) else { return }
        content = content.replacingOccurrences(of: original, with: patched)
        try? content.write(to: path, atomically: true, encoding: .utf8)
    }
}
