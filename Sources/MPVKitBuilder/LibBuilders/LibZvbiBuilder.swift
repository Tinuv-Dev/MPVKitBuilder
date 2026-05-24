import Foundation

final class LibZvbiBuilder: AutoconfBuilder {
    init(context: BuildContext) {
        super.init(lib: .libzvbi, context: context)
    }

    // maccatalyst has linking issues with zvbi's internal socket usage
    override func platforms() -> [PlatformType] {
        super.platforms().filter { $0 != .maccatalyst }
    }

    override func preCompile() throws {
        try super.preCompile()
        patchConfigureAC()
    }

    // AC_FUNC_MALLOC and AC_FUNC_REALLOC cause cross-compile failures
    func patchConfigureAC() {
        let path = ctx.sourceDir(lib).appendingPathComponent("configure.ac")
        guard var content = try? String(contentsOf: path) else { return }
        content = content.replacingOccurrences(of: "AC_FUNC_MALLOC", with: "")
        content = content.replacingOccurrences(of: "AC_FUNC_REALLOC", with: "")
        try? content.write(to: path, atomically: true, encoding: .utf8)
    }
}
