import Foundation

enum ProgressReporter {
    static func printPlan(_ plan: BuildPlan, options: BuildOptions, logger: BuildLogger) {
        logger.section("Build Plan")
        logger.kv("Platforms", options.platforms.map(\.rawValue).joined(separator: ", "))
        if !options.architectures.isEmpty {
            logger.kv("Archs", options.architectures.map(\.rawValue).sorted().joined(separator: ", "))
        }
        logger.kv("GPL", options.enableGPL ? "ON" : "OFF")
        logger.kv("Debug", options.enableDebug ? "ON" : "OFF")
        logger.kv("Verbose", options.verboseOutput ? "ON" : "OFF")
        logger.kv("Resume", "\(plan.skipFinished.count) finished, \(plan.toBuild.count) to build, \(plan.skipExplicit.count) filtered, \(plan.skipUnsupported.count) unsupported")
        if !plan.forcedRebuild.isEmpty {
            let names = plan.forcedRebuild.map(\.rawValue).sorted().joined(separator: ", ")
            logger.kv("Force", names)
        }
        logger.kv("Work dir", options.workDirectory.path)
        logger.kv("Dist dir", options.distDirectory.path)
        logger.kv("Reports", options.reportDirectory.path)

        if plan.toBuild.isEmpty {
            logger.write(.info, "")
            logger.write(.info, "  Nothing to build — everything is up to date.")
            return
        }

        logger.write(.info, "")
        logger.write(.info, "  Order:")
        for (i, lib) in plan.toBuild.enumerated() {
            let n = String(format: "%02d", i + 1)
            logger.write(.info, "    [\(n)] \(lib.rawValue)  \(lib.version)")
        }
    }
}
