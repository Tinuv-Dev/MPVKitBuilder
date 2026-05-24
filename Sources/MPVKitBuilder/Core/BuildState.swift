import Foundation

struct BuildState: Codable {
    var schemaVersion: Int = 1
    var lastRunStartedAt: Date = Date()
    var libraries: [String: LibraryRecord] = [:]

    struct LibraryRecord: Codable {
        var status: Status
        var version: String
        var inputHash: String
        var finishedAt: Date?
        var phase: String?
        var platform: String?
        var arch: String?
        var error: String?
    }

    enum Status: String, Codable { case finished, failed, inProgress }
}

// MARK: - Persistence

final class BuildStateStore {
    let url: URL
    var state: BuildState

    init(url: URL) {
        self.url = url
        self.state = Self.load(from: url) ?? BuildState()
    }

    static func load(from url: URL) -> BuildState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BuildState.self, from: data)
    }

    func flush() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func markFinished(_ library: Library, version: String, inputHash: String) throws {
        state.libraries[library.rawValue] = .init(
            status: .finished,
            version: version,
            inputHash: inputHash,
            finishedAt: Date(),
            phase: nil, platform: nil, arch: nil, error: nil
        )
        try flush()
    }

    func markFailed(_ library: Library, version: String, inputHash: String,
                    phase: String?, platform: String?, arch: String?, error: Error) throws {
        state.libraries[library.rawValue] = .init(
            status: .failed,
            version: version,
            inputHash: inputHash,
            finishedAt: nil,
            phase: phase,
            platform: platform,
            arch: arch,
            error: String(describing: error)
        )
        try flush()
    }

    func isFinished(_ library: Library, currentInputHash: String) -> Bool {
        guard let rec = state.libraries[library.rawValue] else { return false }
        return rec.status == .finished && rec.inputHash == currentInputHash
    }

    func clear(_ libraries: Set<Library>) throws {
        for lib in libraries { state.libraries.removeValue(forKey: lib.rawValue) }
        try flush()
    }

    func clearAll() throws {
        state = BuildState()
        try flush()
    }
}
