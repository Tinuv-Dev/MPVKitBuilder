# MPVKitBuilder 详细设计文档

> 目标：从源码构建一套 **完全可控** 的 Apple 多平台 (macOS / iOS / tvOS / visionOS / Mac Catalyst + 各 Simulator) `FFmpeg + mpv` XCFramework，
> 并以 **可生成 Package.swift** 的形式直接供 Swift 项目使用。
>
> 解决的核心痛点：[mpvkit/MPVKit](https://github.com/mpvkit/MPVKit) 的 FFmpeg 配置裁剪过狠，部分 muxer / demuxer / decoder / filter 没编进去；同时其构建过程缺乏可观察性与断点续编。
>
> 参考：
> - 上游灵感：[mpvkit/MPVKit](https://github.com/mpvkit/MPVKit)（SwiftPM Script + 预构建 zip）
> - 本地祖本：`/Users/tinuv/Downloads/归档/Old/Builder/FFMPEGBuilder-working`（Xcode CLI + 全源码构建，已跑通过）

---

## 〇、最终确认决策（来自用户）

| 决策项 | 选择 |
|---|---|
| SSL 后端 | **OpenSSL**（不再走 gnutls + gmp + nettle 链） |
| GPL | **默认开启** `--enable-gpl`，并默认编译 `libsmbclient` |
| Zip 兜底 | **第一版不要**，所有库走源码。预编译 zip 留作后续可选 |
| 工作目录 | **`./build`** 相对工程根，`./dist` 存放最终产物，`./.build` 存放 SwiftPM + 报告文件 |
| 产物形态 | 同时产出 **XCFramework + 自动生成的 `Package.swift`**，可以本地路径或 binaryTarget 引用 |
| 架构要求 | 必须**比 FFMPEGBuilder-working 更清晰**，去掉历史遗留的临时性写法 |
| 断点续编 | 必须支持，按库粒度，**失败位置之前的库不重编**；提供 `force` 标记强制从 0 |
| 可观察性 | 必须有 **阶段化 progress 日志** + **依赖图 txt** + **FFmpeg 参数清单 txt**，写到 `.build/reports/` |

---

## 一、设计原则

1. **以 `FFMPEGBuilder-working` 的 `Builder` 体系为骨架**，但**重写架构**：
   - 显式分层：`Core / Domain / LibBuilders / Reporting / Pipeline`，去掉旧代码中散落的 IO 调用。
   - 全局唯一的 `BuildContext` 持有所有状态（路径、平台集合、当前库）。
   - 一个文件一个主类型；`extension + // MARK:` 分段；不使用 `private` / `fileprivate`（遵守全局 CLAUDE.md）。
2. **可重入、可继续**：每个库一次成功后写入 `state.json`，下次启动跳过已完成项；`force=all` 或 `force=libffmpeg,libmpv` 触发重编。
3. **可观察**：构建前生成 `dependency-graph.txt` 与 `ffmpeg-configure.txt`；构建中走结构化日志（带 `阶段 / 库 / 平台 / 架构 / 耗时`）；构建后写 `build-summary.txt`。
4. **SwiftPM 优先**：本项目本身是一个可 `swift run` 的 Package；最终也输出一个消费方使用的 `Package.swift`。
5. **FFmpeg 参数完全外置 + 默认全量开**：默认 `--enable-muxers/demuxers/encoders/decoders/protocols/bsfs`，通过 `extra-ffmpeg` 或源码常量按需 disable。

---

## 二、与上游 FFMPEGBuilder-working 的差异

| 维度 | FFMPEGBuilder-working | MPVKitBuilder（本项目） |
|---|---|---|
| 工程形态 | Xcode CLI 工程 | **SwiftPM Package**，`swift run MPVKitBuilder ...` |
| 路径管理 | 硬编码 `/Users/tinuv/Downloads/build` | `BuildContext.workDirectory` 默认 `./build`，CLI 可覆盖 |
| Patch 路径 | 硬编码绝对路径 | 通过 `Bundle.module` 资源 + Package 资源声明 |
| SSL | gnutls + gmp + nettle | **openssl** |
| GPL | 强制开 | 默认开（与历史一致），可 `disable-gpl` 关闭 |
| 库版本 | FFmpeg `n6.1`、mpv `v0.37.0` | FFmpeg `n8.1.1`、mpv `v0.41.0`，含 libdovi / libuavs3d / libuchardet / libluajit |
| FFmpeg 参数 | 内联在 `LibFFMPEGBuilder.swift` | 独立 `Config/FFmpegOptions.swift`，**默认全开** + 命令行透传 |
| 状态机 | 无，每次全部重跑 | 持久化 `state.json`，按库粒度断点续编 |
| 日志 | `print` 散落 | 结构化 `BuildLogger`，分级、分阶段、带时长、可写文件 |
| 报告 | 无 | 构建前 `dependency-graph.txt` + `ffmpeg-configure.txt`；构建后 `build-summary.txt` |
| 错误处理 | `fatalError()` 直接退 | `throw` 分级错误 + 异常上下文写入 `state.json.lastError` |
| 入口 | `main.swift` 直接 `FFMPEGBuilder().build()` | `main.swift` → `BuildPipeline.run(options)` |
| 不清晰之处 | 临时变量、全局静态散落 | 全部集中到 `BuildContext` / `BuildOptions` |

---

## 三、工程形态与目录结构

本项目本身是一个 SwiftPM 可执行 Package。

```text
MPVKitBuilder/
├── Package.swift                       # 本工具自己的 Package
├── Makefile                            # 包一层友好命令：make build / make clean / make force=ffmpeg
├── README.md
├── DESIGN.md                           # 本文件
├── .build/                             # SwiftPM 缓存 + 我们写入的报告
│   ├── state.json                      # 构建状态：每个库的 finished/失败/校验和
│   └── reports/
│       ├── dependency-graph.txt
│       ├── ffmpeg-configure.txt
│       ├── build-summary.txt
│       └── log/<timestamp>/<lib>.log   # 单库构建日志（Process 输出）
├── build/                              # 源码 / scratch / thin / frameworks
│   ├── <lib>-source-<ver>/
│   ├── <lib>-build/<platform>/scratch/<arch>/
│   ├── <lib>-build/<platform>/thin/<arch>/
│   └── <lib>-frameworks/<platform>/<Framework>.framework
├── dist/                               # 最终 XCFramework 产物
│   ├── Libavcodec.xcframework
│   └── ...
├── Package.dist.swift                  # 工具生成的「供消费方使用」的 Package.swift（拷到外部仓库）
└── Sources/
    └── MPVKitBuilder/
        ├── main.swift                  # 入口：解析参数 → BuildPipeline.run
        ├── Core/
        │   ├── BuildOptions.swift      # CLI 解析后的不可变选项
        │   ├── BuildContext.swift      # 全局可变上下文：路径、平台、当前库、logger
        │   ├── BuildError.swift        # 分级错误
        │   ├── BuildLogger.swift       # 结构化日志（控制台 + 文件双输出）
        │   ├── BuildState.swift        # state.json 持久化：完成集合、最后失败点
        │   └── ProcessRunner.swift     # 旧 Utility 的替代，把 Process 封装并接入 logger
        ├── Domain/
        │   ├── Library.swift           # enum + 元数据（version/url/builderFactory）
        │   ├── LibraryDependency.swift # 库 → 依赖库的拓扑（生成依赖图用）
        │   ├── PlatformType.swift
        │   ├── ArchType.swift
        │   └── BuildSystem.swift       # enum: cmake / meson / waf / autoconf；自动检测
        ├── Pipeline/
        │   ├── BuildPipeline.swift     # 编排：决定构建队列、跳过、继续、报告生成
        │   ├── ResumePlanner.swift     # 根据 state.json + force 计算「实际要做的库」
        │   ├── ReportGenerator.swift   # 写 dependency-graph.txt / ffmpeg-configure.txt / build-summary.txt
        │   └── ProgressReporter.swift  # 阶段化控制台进度
        ├── Builders/
        │   ├── Builder.swift           # 基类：5 阶段流水（obtain/preCompile/compile/postCompile/createXCFramework）
        │   ├── AutoconfBuilder.swift   # 默认 ./configure + make 实现
        │   ├── CMakeBuilder.swift      # cmake 子流程实现
        │   ├── MesonBuilder.swift      # meson + ninja + crossfile
        │   ├── WafBuilder.swift        # samba 专用
        │   └── XCFrameworkAssembler.swift  # lipo + module.modulemap + Info.plist + xcodebuild -create-xcframework
        ├── LibBuilders/
        │   ├── LibOpenSSLBuilder.swift
        │   ├── LibUnibreakBuilder.swift
        │   ├── LibFreetypeBuilder.swift
        │   ├── LibFribidiBuilder.swift
        │   ├── LibHarfbuzzBuilder.swift
        │   ├── LibAssBuilder.swift
        │   ├── LibUchardetBuilder.swift
        │   ├── LibBlurayBuilder.swift
        │   ├── LibSrtBuilder.swift
        │   ├── LibZvbiBuilder.swift
        │   ├── LibSmbclientBuilder.swift    # GPL 路径
        │   ├── LibVulkanBuilder.swift       # MoltenVK
        │   ├── LibShadercBuilder.swift
        │   ├── LibLcms2Builder.swift
        │   ├── LibPlaceboBuilder.swift
        │   ├── LibDav1dBuilder.swift
        │   ├── LibUavs3dBuilder.swift
        │   ├── LibDoviBuilder.swift         # Rust + cargo-c
        │   ├── LibLuaJITBuilder.swift
        │   ├── LibFFmpegBuilder.swift       # 主菜
        │   └── LibMpvBuilder.swift
        ├── Config/
        │   ├── FFmpegOptions.swift     # 三层参数：base / platformExtra / extraFromCLI
        │   ├── MPVOptions.swift        # mpv meson 参数
        │   └── LibraryVersions.swift   # 集中版本号
        ├── Packaging/
        │   └── PackageManifestGenerator.swift  # 生成 dist/Package.swift
        ├── Extensions/
        │   ├── URL+Path.swift
        │   └── FileManager+Safe.swift
        └── Resources/
            └── Patch/                  # 资源：每个库的 .patch
                ├── ffmpeg/
                ├── libmpv/
                └── libsmbclient/
```

> **架构纪律**：`Domain` 只有数据与纯函数；`Builders` 调用 `ProcessRunner` 与 `Domain`；`Pipeline` 编排 `Builders` 并访问 `BuildState/Report`；`main.swift` 只做参数解析与启动。**禁止 LibBuilders 直接读写 `state.json` 或控制台**——必须经 `BuildContext.logger` / `BuildContext.state`。

---

## 四、核心类型

### 4.1 `BuildOptions` — 不可变 CLI 选项

```swift
struct BuildOptions {
    let workDirectory: URL          // 默认 ./build
    let distDirectory: URL          // 默认 ./dist
    let reportDirectory: URL        // 默认 ./.build/reports
    let stateFile: URL              // 默认 ./.build/state.json

    let platforms: [PlatformType]   // 默认 macos+ios+isimulator+tvos+tvsimulator+xros+xrsimulator+maccatalyst
    let enableGPL: Bool             // 默认 true
    let enableDebug: Bool           // 默认 false
    let enableSplitPlatform: Bool   // 默认 false：true 时每个平台一个独立 xcframework

    let force: ForceMode            // .none / .all / .libraries([Library])
    let only: Set<Library>          // 仅构建这些；空集合 = 全部
    let skip: Set<Library>          // 跳过这些
    let ffmpegExtraArgs: [String]   // 透传给 ffmpeg ./configure
    let generatePackage: Bool       // 默认 true：构建后写 dist/Package.swift
    let dryRun: Bool                // 仅打印计划与报告，不真正编译

    static func parse(_ argv: [String]) throws -> BuildOptions
}

enum ForceMode {
    case none
    case all
    case libraries(Set<Library>)
}
```

CLI 文法（与 MPVKit 风格保持一致 + 扩展）：

```
swift run MPVKitBuilder build
swift run MPVKitBuilder build platform=ios,macos
swift run MPVKitBuilder build disable-gpl enable-debug
swift run MPVKitBuilder build only=libffmpeg,libmpv
swift run MPVKitBuilder build skip=vulkan
swift run MPVKitBuilder build force=all
swift run MPVKitBuilder build force=libffmpeg     # 仅重编 ffmpeg 及之后
swift run MPVKitBuilder build extra-ffmpeg="--enable-libfdk-aac --enable-nonfree"
swift run MPVKitBuilder build dry-run
swift run MPVKitBuilder clean
swift run MPVKitBuilder report                    # 只生成报告，不编译
```

### 4.2 `BuildContext` — 全局可变上下文（单例）

```swift
final class BuildContext {
    static var current: BuildContext!

    let options: BuildOptions
    let logger: BuildLogger
    var state: BuildState           // 持久化层，每次 markFinished/markFailed 后 flush

    func thinDir(_ lib: Library, _ p: PlatformType, _ a: ArchType) -> URL
    func scratchDir(_ lib: Library, _ p: PlatformType, _ a: ArchType) -> URL
    func sourceDir(_ lib: Library) -> URL
    func frameworkDir(_ lib: Library, _ p: PlatformType, _ framework: String) -> URL
    func xcFrameworkURL(_ framework: String) -> URL
}
```

### 4.3 `BuildState` — 断点续编核心

`./.build/state.json` 结构：

```json
{
  "schemaVersion": 1,
  "lastRunStartedAt": "2026-05-24T10:00:00Z",
  "options": { "enableGPL": true, "platforms": ["macos","ios"] },
  "libraries": {
    "openssl":       { "status": "finished", "version": "3.3.5", "finishedAt": "...", "platforms": ["macos","ios"] },
    "libplacebo":    { "status": "finished", "version": "7.360.1", "finishedAt": "..." },
    "libffmpeg":     { "status": "failed",   "version": "n8.1.1", "phase": "compile", "platform": "ios", "arch": "arm64", "error": "configure: nasm not found" }
  }
}
```

关键规则：
- 一个库在 **所有目标平台/架构** 都构建成功才算 `finished`。
- `finished` 状态依赖于「输入哈希」：版本 + patch 文件哈希 + 关键 CLI（platforms/enableGPL/sslBackend/ffmpegArgs hash）。任一变化自动 invalidate，无需用户手动 `force`。
- 失败时写明 `phase / platform / arch / error`，便于排查。

### 4.4 `BuildPipeline.run(_:)` — 入口编排

```swift
func run(_ options: BuildOptions) throws {
    let ctx = BuildContext(options: options)
    BuildContext.current = ctx

    let order = LibraryDependency.topologicalOrder(for: options)
    let plan  = ResumePlanner.plan(order: order, state: ctx.state, options: options)

    // 1. 生成报告（即使 dryRun 也生成）
    ReportGenerator.writeDependencyGraph(order: order, plan: plan)
    ReportGenerator.writeFFmpegConfigure(options: options)

    ctx.logger.section("BUILD PLAN")
    ProgressReporter.printPlan(plan)

    if options.dryRun { return }

    // 2. 主流程
    for (index, lib) in plan.toBuild.enumerated() {
        ctx.logger.libraryStart(lib, index: index + 1, total: plan.toBuild.count)
        do {
            try lib.builderFactory(ctx).build()
            ctx.state.markFinished(lib)
        } catch {
            ctx.state.markFailed(lib, error: error)
            ctx.logger.libraryFailed(lib, error: error)
            throw error   // 立即停，不继续后面的库
        }
    }

    // 3. 收尾
    if options.generatePackage {
        try PackageManifestGenerator.write(to: options.distDirectory)
    }
    ReportGenerator.writeBuildSummary()
}
```

### 4.5 `Builder` 基类与 5 阶段流水

```swift
class Builder {
    let lib: Library
    let ctx: BuildContext
    var phase: BuildPhase = .idle    // 仅用于日志

    func build() throws {
        try obtainSource()       // phase = .fetch
        try preCompile()         // phase = .patch
        try compile()            // phase = .compile（含 per-platform/per-arch 循环）
        try postCompile()        // phase = .post
        try createXCFramework()  // phase = .package
    }

    func platforms() -> [PlatformType] { ctx.options.platforms }
    func dependencyLibraries() -> [Library] { [] }   // 用于 cflags/ldflags 与依赖图
    func arguments(platform: PlatformType, arch: ArchType) -> [String] { [] }
    func environment(platform: PlatformType, arch: ArchType) -> [String: String]
    func buildSystem() -> BuildSystem { .autoDetect }   // 子类可强制
    func frameworks() throws -> [String] { [lib.rawValue] }
    func frameworkExcludeHeaders(_ name: String) -> [String] { [] }
}

enum BuildPhase: String { case idle, fetch, patch, compile, post, package }
```

子类只需要 override 自己关心的方法。`compile()` 内部根据 `buildSystem()` 自动 dispatch 到 `CMakeBuilder/MesonBuilder/WafBuilder/AutoconfBuilder` 的策略实现。

### 4.6 `BuildLogger` — 结构化日志

```swift
final class BuildLogger {
    enum Level { case debug, info, warn, error, success }

    func section(_ title: String)                                          // 一级分隔
    func libraryStart(_ lib: Library, index: Int, total: Int)              // 例：[3/22] ⏳ libplacebo v7.360.1
    func phase(_ phase: BuildPhase, _ p: PlatformType?, _ a: ArchType?)    // 例：    ↳ compile · ios/arm64
    func step(_ message: String, level: Level = .info)
    func processCommand(_ cmd: String, _ args: [String])                   // debug 级，写文件不写控制台
    func libraryFinished(_ lib: Library, elapsed: TimeInterval)            // ✅ libplacebo  (6m31s)
    func libraryFailed(_ lib: Library, error: Error)                       // ❌ ffmpeg  configure: nasm not found
}
```

**控制台格式（默认级别 = info）**：

```
══════════════════════════════════════════════════════════════
 BUILD PLAN
══════════════════════════════════════════════════════════════
  Platforms : macos, ios, isimulator, tvos, tvsimulator, maccatalyst
  GPL       : ON
  SSL       : OpenSSL 3.3.5
  Resume    : 4 libraries already finished, 18 to build
  Force     : (none)

[01/18] ⏳ openssl 3.3.5
  ↳ fetch   · clone https://github.com/openssl/openssl
  ↳ patch   · 2 patches applied
  ↳ compile · macos/arm64                                (2m04s)
  ↳ compile · macos/x86_64                               (2m11s)
  ↳ compile · ios/arm64                                  (1m48s)
  ↳ ...
  ↳ package · Libssl.xcframework  Libcrypto.xcframework
✅ openssl  (12m44s)

[02/18] ⏳ libunibreak ...
```

详细 Process stdout/stderr 写到 `.build/reports/log/<ts>/<lib>.log`，控制台只摘要。

### 4.7 `ReportGenerator`

#### `.build/reports/dependency-graph.txt`

```text
# MPVKitBuilder Dependency Graph
# Generated: 2026-05-24T10:00:00Z
# Platforms: macos, ios, isimulator, tvos, tvsimulator, maccatalyst
# GPL: ON   SSL: OpenSSL

openssl              (3.3.5)         depends on: -
libunibreak          (...)           depends on: -
libfreetype          (...)           depends on: -
libfribidi           (...)           depends on: -
libharfbuzz          (5.3.1)         depends on: libfreetype
libass               (0.17.4)        depends on: libfreetype, libfribidi, libharfbuzz, libunibreak
libuchardet          (0.0.8-xcode)   depends on: -
libbluray            (1.4.0)         depends on: libfreetype
libsmbclient         (...)           depends on: openssl                [GPL only]
vulkan               (1.4.1)         depends on: -
libshaderc           (2025.5.0)      depends on: -
lcms2                (2.17.0)        depends on: -
libplacebo           (7.360.1)       depends on: vulkan, libshaderc, lcms2
libdav1d             (1.5.2)         depends on: -
libuavs3d            (1.2.1-xcode)   depends on: -
ffmpeg               (n8.1.1)        depends on: openssl, libass, libsmbclient, vulkan, libshaderc,
                                                  lcms2, libplacebo, libdav1d, libuavs3d, libbluray,
                                                  libsrt, libzvbi
libluajit            (2.1.0-xcode)   depends on: -
libmpv               (v0.41.0)       depends on: ffmpeg, libass, libplacebo, libuchardet, libluajit, libbluray

# Resume status (from .build/state.json):
#   ✅ openssl, libunibreak, libfreetype, libfribidi  (skipping)
#   ⏳ libharfbuzz ... and 17 more
```

#### `.build/reports/ffmpeg-configure.txt`

完整 `./configure` 命令在每个平台/架构下的最终展开（按你最终拍板的参数），便于你在出错时直接复制到源码目录里手跑：

```text
# ffmpeg n8.1.1  --  configure command per (platform, arch)
# Generated: 2026-05-24T10:00:00Z

[macos / arm64]
./configure \
    --prefix=/Users/.../build/ffmpeg-build/macos/thin/arm64 \
    --disable-armv5te --disable-armv6 --disable-armv6t2 \
    --disable-bzlib --disable-gray --disable-iconv --disable-linux-perf \
    ...
    --enable-muxers --enable-demuxers --enable-encoders --enable-decoders \
    --enable-protocols --enable-bsfs \
    --enable-gpl \
    --enable-libxml2 --enable-openssl --enable-libass --enable-libsmbclient \
    --enable-libplacebo --enable-libdav1d --enable-libuavs3d \
    --enable-videotoolbox --enable-audiotoolbox \
    --enable-indev=avfoundation --enable-outdev=audiotoolbox \
    --arch=arm64 --target-os=darwin --enable-neon --enable-asm \
    [user extra-ffmpeg=...]

[macos / x86_64]
...

[ios / arm64]
...
```

#### `.build/reports/build-summary.txt`（编译完成后）

```text
# MPVKitBuilder Build Summary
# Finished: 2026-05-24T13:42:00Z   Elapsed: 3h 41m 23s

Libraries:
  ✅ openssl          12m44s
  ✅ libunibreak       1m12s
  ✅ libfreetype       3m05s
  ...
  ✅ ffmpeg           47m18s
  ✅ libmpv           28m51s

Output XCFrameworks (dist/):
  Libavcodec.xcframework        62 MB
  Libavformat.xcframework        7 MB
  ...
  Libmpv.xcframework            13 MB

Package.swift generated at: dist/Package.swift
```

---

## 五、断点续编规则细节

1. **完成判定**：库的 `finished` 需要满足：
   - 对每个 `(platform, arch) ∈ options.platforms × platform.architectures`，`thin/<arch>/lib/<libname>.a` 存在。
   - `XCFramework` 在 `dist/` 存在。
   - 输入哈希 (`version + patchHash + sslBackend + enableGPL + ffmpegArgsHash`) 与上次记录一致。

2. **失败 → 继续**：再次运行时：
   - 跳过 `finished` 集合，从最早的 **非 finished** 开始。
   - 若失败库存在 stale 的 `scratch/` 目录，自动清空再开干（防止半成品干扰）。

3. **`force` 语义**：
   - `force=all`：清空 `state.json` 和 `build/`，从 0 重编。
   - `force=ffmpeg,libmpv`：把这两个库及**它们的下游**（依赖它们的库，由依赖图决定）一并从 finished 中剔除，重新编译。

4. **平台扩张**：本次 `platforms=ios,macos` 跑完后，下次 `platforms=ios,macos,tvos` 仍然能复用 ios/macos 已完成的 `thin/` 产物，只补 tvos。`finished` 判定要按平台子集计算。

5. **CLI 修改 ffmpeg 参数**：会改变 `ffmpegArgsHash`，**自动只重编 ffmpeg 及其下游 (libmpv)**，不动其他库。这是你最常用的场景。

---

## 六、FFmpeg 配置：解决核心痛点

完全照搬上一版文档的三层策略，**默认全开**：

```swift
enum FFmpegOptions {
    static let base: [String] = [
        // 体积/优化、文档关、主组件、硬件加速白名单（仅 Apple）
        // …（参见上一版 §6.1，未变）
        "--enable-muxers", "--enable-demuxers",
        "--enable-encoders", "--enable-decoders",
        "--enable-protocols", "--enable-bsfs",
        "--disable-filters",            // filter 仍按需开
        // 一组常用 filter…
    ]

    static func platformExtra(_ p: PlatformType, _ a: ArchType) -> [String] { ... }
}
```

`LibFFmpegBuilder.arguments` 拼接顺序：

```
[--prefix=...]
  + FFmpegOptions.base
  + FFmpegOptions.platformExtra(p, a)
  + 自动 --enable-xxx（扫描已构建依赖库）
  + (enableGPL ? --enable-gpl : [])
  + (enableDebug ? --enable-debug --disable-stripping --disable-optimizations : [])
  + options.ffmpegExtraArgs       ← 命令行最高优先级
```

> 用户调整 FFmpeg 配置的 **三种方式**：
> 1. 编辑 `Config/FFmpegOptions.swift` 的常量（长期稳定的偏好）。
> 2. 命令行 `extra-ffmpeg="..."`（临时实验）。
> 3. 创建 `ffmpeg.extra.txt`（每行一个参数）放在工程根，CLI 自动读取（可选，第二阶段做）。

---

## 七、依赖图与拓扑序

由 `LibraryDependency.swift` 集中声明：

```swift
enum LibraryDependency {
    static let edges: [Library: [Library]] = [
        .openssl: [],
        .libunibreak: [], .libfreetype: [], .libfribidi: [],
        .libharfbuzz: [.libfreetype],
        .libass: [.libfreetype, .libfribidi, .libharfbuzz, .libunibreak],
        .libuchardet: [],
        .libbluray: [.libfreetype],
        .libsmbclient: [.openssl],
        .vulkan: [], .libshaderc: [], .lcms2: [],
        .libplacebo: [.vulkan, .libshaderc, .lcms2],
        .libdav1d: [], .libuavs3d: [],
        .libsrt: [.openssl], .libzvbi: [],
        .ffmpeg: [.openssl, .libass, .libsmbclient, .vulkan, .libshaderc, .lcms2,
                  .libplacebo, .libdav1d, .libuavs3d, .libbluray, .libsrt, .libzvbi],
        .libluajit: [],
        .libmpv: [.ffmpeg, .libass, .libplacebo, .libuchardet, .libluajit, .libbluray],
    ]

    static func topologicalOrder(for opt: BuildOptions) -> [Library] { ... }
    static func downstream(of lib: Library) -> Set<Library> { ... }
}
```

- 拓扑序在 `enableGPL=false` 时过滤掉 `libsmbclient`。
- `downstream(of: .ffmpeg)` 用于 `force=ffmpeg` 时连带重编 `libmpv`。
- 拓扑结果写入 `dependency-graph.txt`，每次 `dry-run` 或正式 build 启动时都先生成。

---

## 八、平台与编译细节（坑点，全部来自上一版与上游实践）

1. `x86_64` 与 `maccatalyst` → `--disable-asm --disable-neon`。
2. `libavcodec/videotoolbox.c` → 替换 `kCVPixelBufferOpenGLES*CompatibilityKey` 为 `Metal` 版本。
3. `libavutil/internal.h` 复制到 framework 后注释 `#include "timer.h"`。
4. FFmpeg 多个 internal header 需复制：`config.h / getenv_utf8.h / libm.h / thread.h / intmath.h / mem_internal.h / attributes_internal.h / mathops.h / os_support.h`。
5. `module.modulemap` 必须 `framework module Libxxx [system]`。
6. `Info.plist` 必须包含 `CFBundleSupportedPlatforms / MinimumOSVersion`，否则 XCFramework 在 Xcode 中校验失败。
7. `pkg-config` 路径要汇总所有已构建库 `lib/pkgconfig`，且必须 prepend 到系统默认 `pc_path` 之前。
8. MoltenVK 构建非常耗时（约 10 min/平台），可单独 `force=vulkan` 单测。
9. `libdovi`（Rust）：第一版仍包含在队列中，必须把工具链跑通；如发现某平台/架构受阻，先在 `LibDoviBuilder` 内 throw `BuildError.platformNotSupported`，pipeline 会写入 state 并继续后续库，**但 ffmpeg 默认不依赖 libdovi**，所以不影响主链路。
10. `libsmbclient` 走 waf，需要复制原 `libsmbclient/` 辅助文件目录（在 `Resources/Patch/libsmbclient/`）。
11. `libluajit` 仅在 macos host 平台需要可执行；其他平台只构建静态库给 mpv 链接。

---

## 九、生成 `Package.swift`

`PackageManifestGenerator` 扫描 `dist/*.xcframework`，输出 `dist/Package.swift`：

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MPVKit",
    platforms: [.macOS(.v10_15), .iOS(.v13), .tvOS(.v13), .visionOS(.v1)],
    products: [
        .library(name: "MPVKit", targets: [
            "Libmpv", "Libavcodec", "Libavformat", "Libavutil",
            "Libavfilter", "Libswresample", "Libswscale",
            "Libplacebo", "Libass", "Libssl", "Libcrypto", /* ... */
        ]),
    ],
    targets: [
        .binaryTarget(name: "Libmpv",       path: "Libmpv.xcframework"),
        .binaryTarget(name: "Libavcodec",   path: "Libavcodec.xcframework"),
        // …由生成器枚举 dist 下所有 .xcframework
    ]
)
```

模式开关：
- **本地模式**（默认）：`.binaryTarget(path:)`，直接指向 `dist/*.xcframework`，**本机消费用**。
- **远程模式**（`generate-package=remote releaseUrl=...`）：`.binaryTarget(url: ... checksum: ...)`，并自动写 `*.checksum.txt`，供 GitHub Release 用。

---

## 十、SwiftPM Package.swift（本工具自身）

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MPVKitBuilder",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MPVKitBuilder",
            path: "Sources/MPVKitBuilder",
            resources: [.copy("Resources/Patch")]
        ),
    ]
)
```

`make build` 实际等价于：

```bash
swift run --build-path ./.build MPVKitBuilder build "$@"
```

Makefile 提供：

```
make build [platform=...] [enable-debug] [disable-gpl] [force=ffmpeg]
make clean
make report
make force-ffmpeg          # 等价 make build force=libffmpeg
```

---

## 十一、错误分级

```swift
enum BuildError: Error {
    case missingTool(name: String, hint: String)         // brew install meson 等
    case configFailed(library: Library, phase: BuildPhase, log: URL)
    case processExited(code: Int32, command: String, log: URL)
    case platformNotSupported(library: Library, platform: PlatformType)
    case missingDependency(library: Library, requires: Library)
    case unexpected(String)
}
```

所有 `BuildError` 在 `BuildPipeline.run` 顶层 catch 后：
- 控制台用 logger 红色输出，包含 `日志文件路径`、`重试命令`。
- state.json 标记失败位置（`phase / platform / arch / errorDescription`）。
- 进程 `exit(1)`，下次 `swift run MPVKitBuilder build` 自动从该库恢复（不会从头）。

---

## 十二、实施步骤（建议顺序）

> 每步完成都 `swift build` 一次通过 + 至少跑一次 `swift run MPVKitBuilder dry-run` 验证依赖图与计划输出。

1. **M0 - 脚手架（半天）**
   - `swift package init --type executable --name MPVKitBuilder`
   - 创建目录：`Core / Domain / Pipeline / Builders / LibBuilders / Config / Packaging / Extensions / Resources/Patch`
   - 复制 `PlatformType.swift / ArchType.swift / URL+Path.swift` 来自旧项目；适配命名空间。
   - 写 `BuildOptions / BuildContext / BuildLogger / BuildState / ProcessRunner / BuildError`，可跑 `dry-run` 输出空依赖图。
2. **M1 - 单库打通（半天）**
   - 实现 `Builder` 基类 + `AutoconfBuilder` 策略。
   - 写 `LibOpenSSLBuilder`，目标：`platform=macos only=openssl` 在 `dist/` 产出 `Libssl.xcframework + Libcrypto.xcframework`。
   - 验证 `state.json` 写入、断点续编（重跑应直接 skip）。
3. **M2 - 三种构建系统（1 天）**
   - 实现 `CMakeBuilder / MesonBuilder / WafBuilder` 策略。
   - 跑 `lcms2`(autoconf) / `libdav1d`(meson) / 单测 `libsmbclient`(waf) 是否拼装无误。
4. **M3 - FFmpeg 主链路（1-2 天）**
   - 实现 `LibFFmpegBuilder` + `FFmpegOptions`。
   - 跑 `platform=macos only=openssl,libass-deps,vulkan,libshaderc,lcms2,libplacebo,libdav1d,libuavs3d,ffmpeg`。
   - 验证 `ffmpeg-configure.txt` 输出正确；命令行 `extra-ffmpeg=` 能改变它。
5. **M4 - mpv（半天）**
   - 实现 `LibMpvBuilder`（meson），含 `libluajit / libuchardet / libbluray` 依赖。
6. **M5 - 全平台扩展（1 天）**
   - 加 ios / isimulator / tvos / tvsimulator / maccatalyst，逐个补齐特殊参数。
   - 添加 xros / xrsimulator（最容易出问题的平台，可能需要平台条件化 vulkan filter）。
7. **M6 - libdovi 等可选库（半天）**
   - 把 `LibDoviBuilder` 跑通；遇到不支持的平台，按 §十一 `platformNotSupported` 优雅退。
8. **M7 - Package 生成 + 收尾（半天）**
   - 实现 `PackageManifestGenerator`。
   - 跑一个最小 Demo SwiftPM 工程引用 `dist/Package.swift` → 播放本地视频通过。

总工期评估：**5-7 个工作日**，纯编译时间不计。

---

## 十三、工具链准备（macOS host）

```bash
brew install cmake meson ninja pkg-config nasm autoconf automake libtool gettext sdl2
# libdovi 用
brew install rust
cargo install cargo-c
# samba 的 waf 需要 python3（系统自带通常够）
```

Xcode：Command Line Tools + 全部 SDK（iOS / tvOS / visionOS）。

---

## 十四、与 CLAUDE.md 全局规范的对应

- **P0 真实性**：所有库版本/路径/参数都基于已读取的源码与上游观察。
- **P1 架构**：分层 (`Core/Domain/Pipeline/Builders/LibBuilders/Config/Packaging`)；状态收口到 `BuildContext`，IO 收口到 `ProcessRunner` 与 `BuildLogger`；MVVM-C 的 "Coordinator" 类比 = `BuildPipeline`，"Service" 类比 = `Builders/*`，"Model" 类比 = `Domain/*`。
- **不使用 `private`/`fileprivate`**：所有访问默认 internal。
- **大文件治理**：`Builder.swift` ≤300 行，超出按 5 阶段拆 extension。
- **少注释**：注释只解释"为什么"（patch 原因、平台坑点）。
- **结构化日志 + 报告 txt**：满足"长任务可观察"的工程纪律。

---

## 十五、可观察性自检清单（开发完后逐项核对）

- [ ] `swift run MPVKitBuilder dry-run` 0 IO 仅打印计划 + 依赖图。
- [ ] 每个库开始前控制台打印 `[idx/total] ⏳ name version`。
- [ ] 每个 `(platform, arch)` 编译完成都有一行带耗时。
- [ ] 失败时立刻打印日志文件绝对路径 + 重新跑该步的命令。
- [ ] `.build/state.json` 在每个库成功/失败后立即 flush。
- [ ] 改 `Config/FFmpegOptions.swift` 后重跑，**只重编 ffmpeg + libmpv**，其它库自动 skip。
- [ ] `force=all` 后所有 `build/ + dist/ + state.json` 清空。
- [ ] `.build/reports/ffmpeg-configure.txt` 内容可直接复制到 `ffmpeg/` 目录 `./configure ...` 手动跑通。

---

## 十六、TODO（落地进度）

> 完成一个就打勾。每个里程碑结束时同步勾选并在 commit message 引用编号。

- [x] **M0** 脚手架：SwiftPM init、目录骨架、Core/Domain/Pipeline 核心类型、`swift run MPVKitBuilder dry-run` 打印依赖图与计划
- [x] **M1** 单库打通：`Builder` 基类 + `AutoconfBuilder` + `LibOpenSSLBuilder`，macOS arm64 单平台产出 `Libssl.xcframework / Libcrypto.xcframework`；验证 `state.json` 与断点续编
- [x] **M2** 三种构建系统策略：`CMakeBuilder / MesonBuilder / WafBuilder`；分别用 `lcms2 / libdav1d / libsmbclient` 单测
- [ ] **M3** FFmpeg 主链路：`LibFFmpegBuilder + FFmpegOptions`，`ffmpeg-configure.txt` 落盘并可被 `extra-ffmpeg=` 改写
- [ ] **M4** libmpv：`LibMpvBuilder`（meson）+ libluajit / libuchardet / libbluray 依赖打通
- [ ] **M5** 全平台扩展：ios / isimulator / tvos / tvsimulator / maccatalyst / xros / xrsimulator
- [ ] **M6** 可选库：`libdovi`（Rust + cargo-c），平台不支持时优雅 `platformNotSupported`
- [ ] **M7** Package 生成 + 收尾：`PackageManifestGenerator` 写 `dist/Package.swift`，最小 Demo SwiftPM 工程验证消费

---

文档已与你最终拍板的需求对齐。下方开始按 §十二 顺序落代码，从 M0 起。
