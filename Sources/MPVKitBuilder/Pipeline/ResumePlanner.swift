import Foundation

struct BuildPlan {
    let order: [Library]            // full topological order, after filters
    let toBuild: [Library]          // libraries to actually run
    let skipFinished: [Library]     // already finished, skipped
    let skipExplicit: [Library]     // skipped because skip=
    let skipUnsupported: [Library]  // skipped because no requested platform is supported
    let forcedRebuild: Set<Library> // forced to rebuild (via force=)
}

enum ResumePlanner {
    static func plan(options: BuildOptions, store: BuildStateStore) -> BuildPlan {
        let order = LibraryDependency.topologicalOrder { lib in
            if !options.enableGPL, lib == .libsmbclient { return false }
            return true
        }

        let forced = forcedSet(options: options, fullOrder: order)
        let onlyFilter = expandedOnlyFilter(options.only)

        var toBuild: [Library] = []
        var skipFinished: [Library] = []
        var skipExplicit: [Library] = []
        var skipUnsupported: [Library] = []

        for lib in order {
            if options.skip.contains(lib) {
                skipExplicit.append(lib)
                continue
            }
            if !onlyFilter.isEmpty, !onlyFilter.contains(lib) {
                skipExplicit.append(lib)
                continue
            }
            if lib.supportedPlatforms(from: options.platforms).isEmpty {
                skipUnsupported.append(lib)
                continue
            }
            if !forced.contains(lib),
               store.isFinished(lib, currentInputHash: inputHash(for: lib, options: options)),
               outputsExist(for: lib, options: options) {
                skipFinished.append(lib)
                continue
            }
            toBuild.append(lib)
        }

        return BuildPlan(
            order: order,
            toBuild: toBuild,
            skipFinished: skipFinished,
            skipExplicit: skipExplicit,
            skipUnsupported: skipUnsupported,
            forcedRebuild: forced
        )
    }

    static func forcedSet(options: BuildOptions, fullOrder: [Library]) -> Set<Library> {
        switch options.force {
        case .none:
            return []
        case .all:
            return Set(fullOrder)
        case .libraries(let libs):
            var result = libs
            for lib in libs {
                result.formUnion(LibraryDependency.downstream(of: lib))
            }
            return result
        }
    }

    static func expandedOnlyFilter(_ libraries: Set<Library>) -> Set<Library> {
        guard !libraries.isEmpty else { return [] }
        var result = libraries
        var stack = Array(libraries)
        while let next = stack.popLast() {
            for dependency in LibraryDependency.dependencies(of: next) where !result.contains(dependency) {
                result.insert(dependency)
                stack.append(dependency)
            }
        }
        return result
    }

    /// Hash of inputs that affect a library's output. If the hash changes, the cached
    /// "finished" state is automatically invalidated.
    static func inputHash(for lib: Library, options: BuildOptions) -> String {
        var parts: [String] = [
            "v=\(lib.version)",
            "gpl=\(options.enableGPL)",
            "debug=\(options.enableDebug)",
            "split=\(options.enableSplitPlatform)",
            "platforms=\(options.platforms.map(\.rawValue).sorted().joined(separator: ","))",
            "archs=\(options.architectures.map(\.rawValue).sorted().joined(separator: ","))",
        ]
        if lib == .ffmpeg || lib == .libmpv {
            parts.append("ffmpegExtra=\(options.ffmpegExtraArgs.joined(separator: " "))")
        }
        if lib == .vulkan, let prebuilt = options.prebuiltVulkanDir {
            parts.append("prebuiltVulkan=\(prebuilt.path)")
        }
        return parts.joined(separator: "|")
    }

    static func outputsExist(for lib: Library, options: BuildOptions) -> Bool {
        if options.enableSplitPlatform {
            // In split-platform mode the durable per-job output is `dist-platform/<p>/<Fw>.framework`
            // for every requested platform that the library actually supports.
            let supported = lib.supportedPlatforms(from: options.platforms)
            if supported.isEmpty { return false }
            return lib.expectedFrameworks.allSatisfy { framework in
                supported.allSatisfy { platform in
                    let url = options.resolvedSplitPlatformDirectory
                        .appendingPathComponent(platform.rawValue)
                        .appendingPathComponent("\(framework).framework")
                    return FileManager.default.fileExists(atPath: url.path)
                }
            }
        }
        return lib.expectedFrameworks.allSatisfy { framework in
            let url = options.distDirectory.appendingPathComponent("\(framework).xcframework")
            return FileManager.default.fileExists(atPath: url.path)
        }
    }
}
