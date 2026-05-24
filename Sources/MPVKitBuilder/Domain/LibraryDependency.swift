import Foundation

enum LibraryDependency {
    static let edges: [Library: [Library]] = [
        .openssl:      [],
        .libunibreak:  [],
        .libfreetype:  [],
        .libfribidi:   [],
        .libharfbuzz:  [.libfreetype],
        .libass:       [.libfreetype, .libfribidi, .libharfbuzz, .libunibreak],
        .libuchardet:  [],
        .libbluray:    [.libfreetype],
        .libsrt:       [.openssl],
        .libzvbi:      [],
        .gmp:          [],
        .nettle:       [.gmp],
        .libgnutls:    [.gmp, .nettle],
        .libsmbclient: [.openssl, .libgnutls],
        .vulkan:       [],
        .libshaderc:   [],
        .lcms2:        [],
        .libplacebo:   [.vulkan, .libshaderc, .lcms2],
        .libdav1d:     [],
        .libuavs3d:    [],
        .libdovi:      [],
        .libluajit:    [],
        .ffmpeg:       [.openssl, .libass, .libsmbclient, .vulkan, .libshaderc, .lcms2,
                        .libplacebo, .libdav1d, .libuavs3d, .libbluray, .libsrt, .libzvbi],
        .libmpv:       [.ffmpeg, .libass, .libplacebo, .libuchardet, .libluajit, .libbluray],
    ]

    static func dependencies(of library: Library) -> [Library] {
        edges[library] ?? []
    }

    /// Transitive dependencies of `library` (not including `library` itself), deduplicated.
    static func transitiveDependencies(of library: Library) -> [Library] {
        var result: [Library] = []
        var seen: Set<Library> = []
        var stack = dependencies(of: library)
        while let next = stack.popLast() {
            if !seen.insert(next).inserted { continue }
            result.append(next)
            stack.append(contentsOf: dependencies(of: next))
        }
        return result
    }
}

// MARK: - Topological ordering

extension LibraryDependency {
    static func topologicalOrder(filter: (Library) -> Bool = { _ in true }) -> [Library] {
        var visited: Set<Library> = []
        var result: [Library] = []
        func visit(_ lib: Library) {
            if visited.contains(lib) { return }
            visited.insert(lib)
            for dep in dependencies(of: lib) where filter(dep) {
                visit(dep)
            }
            if filter(lib) { result.append(lib) }
        }
        for lib in Library.allCases where filter(lib) {
            visit(lib)
        }
        return result
    }

    /// Set of libraries that depend (directly or transitively) on `lib`.
    static func downstream(of lib: Library) -> Set<Library> {
        var result: Set<Library> = []
        for candidate in Library.allCases where candidate != lib {
            if isReachable(from: candidate, to: lib) {
                result.insert(candidate)
            }
        }
        return result
    }

    static func isReachable(from start: Library, to target: Library) -> Bool {
        var stack = dependencies(of: start)
        var seen: Set<Library> = []
        while let next = stack.popLast() {
            if next == target { return true }
            if !seen.insert(next).inserted { continue }
            stack.append(contentsOf: dependencies(of: next))
        }
        return false
    }
}
