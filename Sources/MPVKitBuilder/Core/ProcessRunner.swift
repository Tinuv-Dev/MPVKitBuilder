import Foundation

final class ProcessRunner {
    let logger: BuildLogger
    let streamOutput: Bool

    init(logger: BuildLogger, streamOutput: Bool = false) {
        self.logger = logger
        self.streamOutput = streamOutput
    }

    @discardableResult
    func launch(
        executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        captureOutput: Bool = false,
        logTo: URL? = nil
    ) throws -> String {
        logger.processCommand(executable, arguments)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        if let currentDirectory { task.currentDirectoryURL = currentDirectory }

        var env = environment ?? ProcessInfo.processInfo.environment
        if env["PATH"] == nil {
            env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        task.environment = env

        var capturedPipe: Pipe?
        var outputHandle: FileHandle?
        var streamPipe: Pipe?
        if captureOutput {
            let pipe = Pipe()
            task.standardOutput = pipe
            capturedPipe = pipe
        } else if let logURL = logTo {
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            outputHandle = handle
            if streamOutput {
                let pipe = Pipe()
                streamPipe = pipe
                task.standardOutput = pipe
                task.standardError = pipe
                pipe.fileHandleForReading.readabilityHandler = { stream in
                    let data = stream.availableData
                    guard !data.isEmpty else { return }
                    try? handle.write(contentsOf: data)
                    FileHandle.standardOutput.write(data)
                }
            } else {
                task.standardOutput = handle
                task.standardError = handle
            }
        }

        try task.run()
        task.waitUntilExit()
        streamPipe?.fileHandleForReading.readabilityHandler = nil
        if let pipe = streamPipe {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if !data.isEmpty {
                try? outputHandle?.write(contentsOf: data)
                FileHandle.standardOutput.write(data)
            }
        }
        try? outputHandle?.close()

        if task.terminationStatus != 0 {
            let command = ([executable] + arguments).joined(separator: " ")
            throw BuildError.processExited(code: task.terminationStatus, command: command, log: logTo)
        }

        if let pipe = capturedPipe {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return ""
    }

    @discardableResult
    func shell(_ command: String, captureOutput: Bool = false) -> String? {
        do {
            return try launch(
                executable: "/bin/zsh",
                arguments: ["-c", command],
                captureOutput: captureOutput
            )
        } catch {
            return nil
        }
    }

    func which(_ tool: String) -> String? {
        guard let result = shell("command -v \(tool)", captureOutput: true), !result.isEmpty else { return nil }
        return result
    }
}
