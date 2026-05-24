import Foundation

enum BuildPipeline {
    static func run(_ options: BuildOptions) throws {
        let logger = BuildLogger(consoleLevel: .info)
        logger.banner()

        switch options.command {
        case .clean:
            try clean(options: options, logger: logger)
            return
        case .report:
            try report(options: options, logger: logger)
            return
        case .dryRun, .build:
            break
        }

        try prepareDirectories(options: options)

        let store = BuildStateStore(url: options.stateFile)

        // Apply force=all by wiping state up-front.
        if options.force == .all {
            logger.section("Force = ALL — clearing state and build/ dist/")
            try store.clearAll()
            try removeIfExists(options.workDirectory)
            try removeIfExists(options.distDirectory)
        }

        let plan = ResumePlanner.plan(options: options, store: store)
        ProgressReporter.printPlan(plan, options: options, logger: logger)

        try ReportGenerator.writeDependencyGraph(
            plan: plan,
            options: options,
            to: options.reportDirectory.appendingPathComponent("dependency-graph.txt")
        )
        logger.write(.info, "")
        logger.write(.info, "  Report: \(options.reportDirectory.appendingPathComponent("dependency-graph.txt").path)")

        if options.command == .dryRun {
            logger.section("Dry run — no compilation will be performed")
            return
        }

        try runBuild(plan: plan, options: options, store: store, logger: logger)
    }
}

// MARK: - Subcommands

extension BuildPipeline {
    static func clean(options: BuildOptions, logger: BuildLogger) throws {
        logger.section("Clean")
        try removeIfExists(options.workDirectory)
        try removeIfExists(options.distDirectory)
        try removeIfExists(options.reportDirectory)
        try removeIfExists(options.stateFile)
        logger.write(.success, "  cleaned build/ dist/ .build/reports/ .build/state.json")
    }

    static func report(options: BuildOptions, logger: BuildLogger) throws {
        try prepareDirectories(options: options)
        let store = BuildStateStore(url: options.stateFile)
        let plan = ResumePlanner.plan(options: options, store: store)
        try ReportGenerator.writeDependencyGraph(
            plan: plan,
            options: options,
            to: options.reportDirectory.appendingPathComponent("dependency-graph.txt")
        )
        ProgressReporter.printPlan(plan, options: options, logger: logger)
        logger.write(.success, "  report written to \(options.reportDirectory.path)")
    }

    static func runBuild(plan: BuildPlan, options: BuildOptions, store: BuildStateStore, logger: BuildLogger) throws {
        if plan.toBuild.isEmpty {
            logger.section("Nothing to build")
            return
        }

        logger.section("Building")
        // Real LibBuilders are wired up in M1+. For M0 we just print the plan and exit.
        logger.write(.warn, "  LibBuilders are not implemented yet (M0 milestone). Re-run after M1 lands.")
    }
}

// MARK: - FS helpers

extension BuildPipeline {
    static func prepareDirectories(options: BuildOptions) throws {
        for url in [options.workDirectory, options.distDirectory, options.reportDirectory] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    static func removeIfExists(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
