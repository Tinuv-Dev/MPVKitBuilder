import Foundation

struct BuildPlan {
    let order: [Library]            // full topological order, after filters
    let toBuild: [Library]          // libraries to actually run
    let skipFinished: [Library]     // already finished, skipped
    let skipExplicit: [Library]     // skipped because skip=
    let forcedRebuild: Set<Library> // forced to rebuild (via force=)
}

enum ResumePlanner {
    static func plan(options: BuildOptions, store: BuildStateStore) -> BuildPlan {
        let order = LibraryDependency.topologicalOrder { lib in
            if !options.enableGPL, lib == .libsmbclient { return false }
            return true
        }

        let forced = forcedSet(options: options, fullOrder: order)
        let onlyFilter = options.only

        var toBuild: [Library] = []
        var skipFinished: [Library] = []
        var skipExplicit: [Library] = []

        for lib in order {
            if options.skip.contains(lib) {
                skipExplicit.append(lib)
                continue
            }
            if !onlyFilter.isEmpty, !onlyFilter.contains(lib) {
                skipExplicit.append(lib)
                continue
            }
            if !forced.contains(lib),
               store.isFinished(lib, currentInputHash: inputHash(for: lib, options: options)) {
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

    /// Hash of inputs that affect a library's output. If the hash changes, the cached
    /// "finished" state is automatically invalidated.
    static func inputHash(for lib: Library, options: BuildOptions) -> String {
        var parts: [String] = [
            "v=\(lib.version)",
            "gpl=\(options.enableGPL)",
            "debug=\(options.enableDebug)",
            "platforms=\(options.platforms.map(\.rawValue).sorted().joined(separator: ","))",
        ]
        if lib == .ffmpeg || lib == .libmpv {
            parts.append("ffmpegExtra=\(options.ffmpegExtraArgs.joined(separator: " "))")
        }
        return parts.joined(separator: "|")
    }
}
