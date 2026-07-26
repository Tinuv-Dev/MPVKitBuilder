import Foundation

/// libssh：给 FFmpeg 提供 `sftp` protocol（`--enable-libssh`）。
/// 只需要客户端 + SFTP 子系统，服务端 / 示例 / 测试全部关掉，减少交叉编译面。
final class LibSshBuilder: CMakeBuilder {
    init(context: BuildContext) {
        super.init(lib: .libssh, context: context)
    }

    override func dependencyLibraries() -> [Library] {
        [.openssl]
    }

    override func cmakeExtraConfigureArguments(platform: PlatformType, arch: ArchType, buildDirectory: URL) throws -> [String] {
        let openssl = ctx.thinDir(.openssl, platform: platform, arch: arch)
        return [
            "-Wno-dev",
            // 基类只把依赖塞进 CFLAGS/LDFLAGS，而 libssh 用 find_package(OpenSSL)，
            // 那条路径不看 CFLAGS——必须显式指到我们自己编出来的 openssl，否则会去找系统的。
            "-DOPENSSL_ROOT_DIR=\(openssl.path)",
            "-DOPENSSL_USE_STATIC_LIBS=ON",
            "-DWITH_SFTP=ON",
            "-DWITH_SERVER=OFF",
            "-DWITH_EXAMPLES=OFF",
            "-DWITH_PCAP=OFF",
            // iOS / tvOS 上没有 GSSAPI，开着会在 configure 阶段找不到 krb5。
            "-DWITH_GSSAPI=OFF",
            // 传输压缩对本地网络播放没收益，关掉可以少引一个 zlib 依赖。
            "-DWITH_ZLIB=OFF",
            "-DWITH_DEBUG_CRYPTO=OFF",
            "-DWITH_DEBUG_PACKET=OFF",
            "-DWITH_DEBUG_CALLTRACE=OFF",
            "-DUNIT_TESTING=OFF",
            "-DCLIENT_TESTING=OFF",
            "-DWITH_NACL=OFF",
        ]
    }

    // 上游 libssh.pc 模板只有 `Libs: -L${libdir} -lssh`，没有任何 private 字段——
    // 那是按动态库写的（.dylib 自带 OpenSSL 依赖记录）。我们出的是静态库，
    // pkg-config --static 因此拿不到 -lcrypto，FFmpeg configure 的链接测试会挂在
    // OSSL_PARAM_* / PEM_* / RAND_* 未定义上，最终报成 "libssh >= 0.6.0 not found"。
    // 用 Requires.private 而不是 Libs.private：让 pkg-config 递归解析 libcrypto.pc，
    // 连 -L 路径一起带出来，指向我们自己编的 openssl 而不是系统的。
    override func postBuild(platform: PlatformType, arch: ArchType) throws {
        let pc = ctx.thinDir(lib, platform: platform, arch: arch)
            .appendingPathComponent("lib/pkgconfig/libssh.pc")
        guard var content = try? String(contentsOf: pc, encoding: .utf8),
              !content.contains("Requires.private") else { return }
        if !content.hasSuffix("\n") { content += "\n" }
        content += "Requires.private: libcrypto\n"
        try? content.write(to: pc, atomically: true, encoding: .utf8)
    }
}
