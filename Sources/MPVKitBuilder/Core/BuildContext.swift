import Foundation

final class BuildContext {
    static var current: BuildContext!

    let options: BuildOptions
    let logger: BuildLogger
    let store: BuildStateStore
    let runner: ProcessRunner

    init(options: BuildOptions, logger: BuildLogger, store: BuildStateStore, runner: ProcessRunner) {
        self.options = options
        self.logger = logger
        self.store = store
        self.runner = runner
    }
}

// MARK: - Path helpers

extension BuildContext {
    func sourceDir(_ lib: Library) -> URL {
        options.workDirectory.appendingPathComponent("\(lib.rawValue)-source-\(lib.version)")
    }

    func libBuildRoot(_ lib: Library) -> URL {
        options.workDirectory.appendingPathComponent("\(lib.rawValue)-build")
    }

    func scratchDir(_ lib: Library, platform: PlatformType, arch: ArchType) -> URL {
        libBuildRoot(lib)
            .appendingPathComponent(platform.rawValue)
            .appendingPathComponent("scratch")
            .appendingPathComponent(arch.rawValue)
    }

    func thinDir(_ lib: Library, platform: PlatformType, arch: ArchType) -> URL {
        libBuildRoot(lib)
            .appendingPathComponent(platform.rawValue)
            .appendingPathComponent("thin")
            .appendingPathComponent(arch.rawValue)
    }

    func frameworksRoot(_ lib: Library) -> URL {
        options.workDirectory.appendingPathComponent("\(lib.rawValue)-frameworks")
    }

    func frameworkDir(_ lib: Library, platform: PlatformType, framework: String) -> URL {
        frameworksRoot(lib)
            .appendingPathComponent(platform.rawValue)
            .appendingPathComponent("\(framework).framework")
    }

    func xcFrameworkURL(framework: String) -> URL {
        options.distDirectory.appendingPathComponent("\(framework).xcframework")
    }

    func reportFile(_ name: String) -> URL {
        options.reportDirectory.appendingPathComponent(name)
    }

    func logFile(_ libraryName: String) -> URL {
        options.reportDirectory
            .appendingPathComponent("log")
            .appendingPathComponent("\(libraryName).log")
    }
}
