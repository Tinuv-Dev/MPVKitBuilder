import Foundation

final class BuildLogger {
    enum Level: Int { case debug = 0, info, warn, error, success }

    let consoleLevel: Level
    let logFileURL: URL?
    let startedAt: Date = Date()
    var libraryStartedAt: Date?

    init(consoleLevel: Level = .info, logFileURL: URL? = nil) {
        self.consoleLevel = consoleLevel
        self.logFileURL = logFileURL
        if let url = logFileURL {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
        }
    }
}

// MARK: - Section / banner

extension BuildLogger {
    func banner() {
        let line = String(repeating: "═", count: 62)
        write(.info, "\n\(line)")
        write(.info, " MPVKitBuilder")
        write(.info, line + "\n")
    }

    func section(_ title: String) {
        let line = String(repeating: "═", count: 62)
        write(.info, "\n\(line)")
        write(.info, " " + title.uppercased())
        write(.info, line)
    }

    func kv(_ key: String, _ value: String) {
        write(.info, "  " + key.padding(toLength: 10, withPad: " ", startingAt: 0) + ": " + value)
    }
}

// MARK: - Library lifecycle

extension BuildLogger {
    func libraryStart(name: String, version: String, index: Int, total: Int) {
        libraryStartedAt = Date()
        let header = String(format: "\n[%02d/%02d] ⏳ %@ %@", index, total, name, version)
        write(.info, header)
    }

    func libraryFinished(name: String) {
        let elapsed = libraryStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        write(.success, "✅ \(name)  (\(Self.format(seconds: elapsed)))")
    }

    func libraryFailed(name: String, error: Error) {
        write(.error, "❌ \(name)  \(error)")
    }

    func librarySkipped(name: String, reason: String) {
        write(.info, "⏭  \(name)  (\(reason))")
    }
}

// MARK: - Phase / step

extension BuildLogger {
    func phase(_ phase: String, platform: String? = nil, arch: String? = nil) {
        var line = "  ↳ \(phase)"
        if let platform { line += " · \(platform)" }
        if let arch { line += "/\(arch)" }
        write(.info, line)
    }

    func phaseFinished(_ phase: String, elapsed: TimeInterval, platform: String? = nil, arch: String? = nil) {
        var line = "  ↳ \(phase)"
        if let platform { line += " · \(platform)" }
        if let arch { line += "/\(arch)" }
        line += " (\(Self.format(seconds: elapsed)))"
        write(.info, line)
    }

    func step(_ message: String, level: Level = .info) {
        write(level, "    " + message)
    }

    func processCommand(_ executable: String, _ arguments: [String]) {
        write(.debug, "    $ \(executable) \(arguments.joined(separator: " "))")
    }
}

// MARK: - Output

extension BuildLogger {
    func write(_ level: Level, _ line: String) {
        if level.rawValue >= consoleLevel.rawValue {
            print(line)
        }
        if let url = logFileURL {
            let stamped = "[\(ISO8601DateFormatter().string(from: Date()))] " + line + "\n"
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                if let data = stamped.data(using: .utf8) {
                    try? handle.write(contentsOf: data)
                }
                try? handle.close()
            }
        }
    }

    static func format(seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return m > 0 ? "\(m)m\(String(format: "%02d", s))s" : "\(s)s"
    }
}
