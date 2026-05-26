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
        case .assemble:
            try AssemblePipeline.run(options, logger: logger)
            return
        case .package:
            try generatePackageManifest(options: options, logger: logger)
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

        let runner = ProcessRunner(logger: logger, streamOutput: options.verboseOutput)
        let ctx = BuildContext(options: options, logger: logger, store: store, runner: runner)
        BuildContext.current = ctx

        try ReportGenerator.writeFFmpegConfigure(
            options: options,
            context: ctx,
            to: options.reportDirectory.appendingPathComponent("ffmpeg-configure.txt")
        )
        logger.write(.info, "")
        logger.write(.info, "  dependency-graph : \(options.reportDirectory.appendingPathComponent("dependency-graph.txt").path)")
        logger.write(.info, "  ffmpeg-configure : \(options.reportDirectory.appendingPathComponent("ffmpeg-configure.txt").path)")

        if options.command == .dryRun {
            logger.section("Dry run — no compilation will be performed")
            return
        }

        try runBuild(plan: plan, options: options, store: store, logger: logger, ctx: ctx)
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
        let runner = ProcessRunner(logger: logger, streamOutput: options.verboseOutput)
        let ctx = BuildContext(options: options, logger: logger, store: store, runner: runner)
        BuildContext.current = ctx
        try ReportGenerator.writeFFmpegConfigure(
            options: options,
            context: ctx,
            to: options.reportDirectory.appendingPathComponent("ffmpeg-configure.txt")
        )
        ProgressReporter.printPlan(plan, options: options, logger: logger)
        logger.write(.success, "  reports written to \(options.reportDirectory.path)")
    }

    static func runBuild(plan: BuildPlan, options: BuildOptions, store: BuildStateStore, logger: BuildLogger, ctx: BuildContext) throws {
        if plan.toBuild.isEmpty {
            logger.section("Nothing to build")
            return
        }

        logger.section("Building")
        var records: [ReportGenerator.SummaryRecord] = []

        for (index, lib) in plan.toBuild.enumerated() {
            let builder = try lib.makeBuilder(context: ctx)
            if plan.forcedRebuild.contains(lib) {
                try builder.cleanBuildProducts()
            }

            logger.libraryStart(name: lib.rawValue, version: lib.version, index: index + 1, total: plan.toBuild.count)
            let started = Date()
            do {
                try builder.build()
                try store.markFinished(
                    lib,
                    version: lib.version,
                    inputHash: ResumePlanner.inputHash(for: lib, options: options)
                )
                logger.libraryFinished(name: lib.rawValue)
                records.append(.init(library: lib, success: true, elapsed: Date().timeIntervalSince(started)))
                if options.cleanAfterLib {
                    cleanIntermediateOutputs(for: lib, options: options, logger: logger, ctx: ctx)
                }
            } catch {
                try? store.markFailed(
                    lib,
                    version: lib.version,
                    inputHash: ResumePlanner.inputHash(for: lib, options: options),
                    phase: builder.phase.rawValue,
                    platform: builder.currentPlatform?.rawValue,
                    arch: builder.currentArch?.rawValue,
                    error: error
                )
                logger.libraryFailed(name: lib.rawValue, error: error)
                records.append(.init(library: lib, success: false, elapsed: Date().timeIntervalSince(started)))
                try? ReportGenerator.writeBuildSummary(
                    records: records,
                    distDirectory: options.distDirectory,
                    to: options.reportDirectory.appendingPathComponent("build-summary.txt")
                )
                throw error
            }
        }

        try ReportGenerator.writeBuildSummary(
            records: records,
            distDirectory: options.distDirectory,
            to: options.reportDirectory.appendingPathComponent("build-summary.txt")
        )
        logger.write(.success, "  summary written to \(options.reportDirectory.appendingPathComponent("build-summary.txt").path)")

        if options.generatePackage {
            logger.section("Package manifest")
            do {
                try PackageManifestGenerator.write(
                    distDirectory: options.distDirectory,
                    platforms: options.packagePlatforms ?? options.platforms,
                    logger: logger
                )
            } catch {
                // The build itself succeeded; manifest generation failure is non-fatal.
                logger.write(.warn, "  failed to generate dist/Package.swift: \(error)")
            }
        }
    }

    static func generatePackageManifest(options: BuildOptions, logger: BuildLogger) throws {
        logger.section("Package manifest")
        try PackageManifestGenerator.write(
            distDirectory: options.distDirectory,
            platforms: options.packagePlatforms ?? options.platforms,
            logger: logger
        )
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

    /// Aggressive cleanup after a library has been fully built. Used by `clean-after-lib`
    /// so GitHub-hosted runners can survive the 14 GB SSD budget. We keep `thin/` (downstream
    /// compiles need the static libs + headers + .pc files) and `<lib>-frameworks/` (the
    /// XCFrameworkAssembler reads from it when reassembling on resume), and drop everything
    /// that can be regenerated: the cloned source tree and every per-platform scratch dir.
    static func cleanIntermediateOutputs(for lib: Library, options: BuildOptions, logger: BuildLogger, ctx: BuildContext) {
        let fm = FileManager.default
        var freed: [String] = []

        // 1. source tree (`build/<lib>-source-<ver>/`).
        let source = ctx.sourceDir(lib)
        if fm.fileExists(atPath: source.path) {
            try? fm.removeItem(at: source)
            freed.append(source.lastPathComponent)
        }

        // 2. per-platform scratch (`build/<lib>-build/<platform>/scratch/`).
        let buildRoot = ctx.libBuildRoot(lib)
        if let platforms = try? fm.contentsOfDirectory(atPath: buildRoot.path) {
            for platform in platforms {
                let scratch = buildRoot
                    .appendingPathComponent(platform)
                    .appendingPathComponent("scratch")
                if fm.fileExists(atPath: scratch.path) {
                    try? fm.removeItem(at: scratch)
                    freed.append("\(lib.rawValue)-build/\(platform)/scratch")
                }
            }
        }

        if freed.isEmpty {
            logger.write(.info, "  clean-after-lib: nothing to remove for \(lib.rawValue)")
        } else {
            logger.write(.info, "  clean-after-lib: removed \(freed.joined(separator: ", "))")
        }
    }
}
