import Foundation

do {
    let options = try BuildOptions.parse(CommandLine.arguments)
    try BuildPipeline.run(options)
} catch let error as BuildError {
    FileHandle.standardError.write(Data(("error: " + error.description + "\n").utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data(("error: \(error)\n").utf8))
    exit(1)
}
