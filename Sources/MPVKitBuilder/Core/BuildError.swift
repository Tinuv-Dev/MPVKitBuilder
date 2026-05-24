import Foundation

enum BuildError: Error, CustomStringConvertible {
    case missingTool(name: String, hint: String)
    case configFailed(library: String, phase: String, log: URL?)
    case processExited(code: Int32, command: String, log: URL?)
    case platformNotSupported(library: String, platform: String)
    case missingDependency(library: String, requires: String)
    case invalidArgument(String)
    case unexpected(String)

    var description: String {
        switch self {
        case .missingTool(let name, let hint):
            return "missing tool '\(name)'. \(hint)"
        case .configFailed(let library, let phase, let log):
            let suffix = log.map { "  log: \($0.path)" } ?? ""
            return "build failed during \(phase) for \(library).\(suffix)"
        case .processExited(let code, let command, let log):
            let suffix = log.map { "  log: \($0.path)" } ?? ""
            return "process exited with code \(code).  command: \(command)\(suffix)"
        case .platformNotSupported(let library, let platform):
            return "\(library) does not support platform \(platform)."
        case .missingDependency(let library, let requires):
            return "\(library) requires \(requires), which has not been built yet."
        case .invalidArgument(let message):
            return "invalid argument: \(message)"
        case .unexpected(let message):
            return "unexpected: \(message)"
        }
    }
}
