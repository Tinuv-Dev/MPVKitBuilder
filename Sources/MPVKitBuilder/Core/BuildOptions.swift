import Foundation

enum BuildCommand: String {
    case build
    case dryRun = "dry-run"
    case report
    case clean
}

enum ForceMode: Equatable {
    case none
    case all
    case libraries(Set<Library>)
}

struct BuildOptions {
    var command: BuildCommand = .build

    var workDirectory: URL
    var distDirectory: URL
    var reportDirectory: URL
    var stateFile: URL

    var platforms: [PlatformType] = PlatformType.defaultEnabled
    var architectures: Set<ArchType> = []
    var enableGPL: Bool = true
    var enableDebug: Bool = false
    var enableSplitPlatform: Bool = false

    var force: ForceMode = .none
    var only: Set<Library> = []
    var skip: Set<Library> = []
    var ffmpegExtraArgs: [String] = []
    var generatePackage: Bool = true
    var verboseOutput: Bool = false
}

extension BuildOptions {
    static var defaultRoot: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    static func makeDefault() -> BuildOptions {
        let root = defaultRoot
        return BuildOptions(
            workDirectory: root.appendingPathComponent("build"),
            distDirectory: root.appendingPathComponent("dist"),
            reportDirectory: root.appendingPathComponent(".build/reports"),
            stateFile: root.appendingPathComponent(".build/state.json")
        )
    }
}

// MARK: - CLI parsing

extension BuildOptions {
    static func parse(_ argv: [String]) throws -> BuildOptions {
        var opt = makeDefault()
        var args = Array(argv.dropFirst())

        if let head = args.first, let cmd = BuildCommand(rawValue: head) {
            opt.command = cmd
            args.removeFirst()
        }

        for token in args where !token.isEmpty {
            try applyToken(token, into: &opt)
        }
        return opt
    }

    static func applyToken(_ token: String, into opt: inout BuildOptions) throws {
        if let eq = token.firstIndex(of: "=") {
            let key = String(token[..<eq])
            let value = String(token[token.index(after: eq)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            try applyKeyValue(key: key, value: value, into: &opt)
        } else {
            try applyFlag(token, into: &opt)
        }
    }

    static func applyFlag(_ flag: String, into opt: inout BuildOptions) throws {
        switch flag {
        case "enable-gpl":             opt.enableGPL = true
        case "disable-gpl":            opt.enableGPL = false
        case "enable-debug":           opt.enableDebug = true
        case "disable-debug":          opt.enableDebug = false
        case "enable-split-platform":  opt.enableSplitPlatform = true
        case "disable-package":        opt.generatePackage = false
        case "--verbose", "verbose":    opt.verboseOutput = true
        case "dry-run":                opt.command = .dryRun
        default:
            // ignore unknown flag-like tokens silently (make passes its own MAKEFLAGS)
            break
        }
    }

    static func applyKeyValue(key: String, value: String, into opt: inout BuildOptions) throws {
        switch key {
        case "platform":
            let list = value.split(separator: ",").map(String.init)
            opt.platforms = try list.map {
                guard let p = PlatformType(rawValue: $0) else {
                    throw BuildError.invalidArgument("unknown platform '\($0)'")
                }
                return p
            }
        case "arch", "architecture":
            opt.architectures = Set(try parseArchitectureList(value))
        case "only":
            opt.only = Set(try parseLibraryList(value))
        case "skip":
            opt.skip = Set(try parseLibraryList(value))
        case "force":
            if value == "all" {
                opt.force = .all
            } else {
                opt.force = .libraries(Set(try parseLibraryList(value)))
            }
        case "extra-ffmpeg":
            opt.ffmpegExtraArgs = value
                .split(separator: " ")
                .map(String.init)
                .filter { !$0.isEmpty }
        case "work-dir":
            opt.workDirectory = URL(fileURLWithPath: value)
        case "dist-dir":
            opt.distDirectory = URL(fileURLWithPath: value)
        default:
            break
        }
    }

    static func parseLibraryList(_ value: String) throws -> [Library] {
        try value.split(separator: ",").map {
            let name = String($0)
            guard let lib = Library(rawValue: name) else {
                throw BuildError.invalidArgument("unknown library '\(name)'")
            }
            return lib
        }
    }

    static func parseArchitectureList(_ value: String) throws -> [ArchType] {
        try value.split(separator: ",").map {
            let name = String($0)
            guard let arch = ArchType(rawValue: name) else {
                throw BuildError.invalidArgument("unknown architecture '\(name)'")
            }
            return arch
        }
    }
}
