# MPVKit 消费端使用说明

## 1. 产物位置

每次成功构建后，`dist/` 下会同时产出：

- `*.xcframework` —— 各库的二进制产物
- `Package.swift` —— 由 `PackageManifestGenerator` 自动生成的 SwiftPM 清单

如需在不重新编译的情况下仅刷新 `dist/Package.swift`：

```bash
swift run --package-path . MPVKitBuilder package
# 或
make package
```

如需只声明本次产物实际支持的平台，可以传入构建平台列表：

```bash
swift run --package-path . MPVKitBuilder package package-platforms=ios,isimulator
```

## 2. 在其它 SwiftPM 工程中引用

`dist/Package.swift` 是一个完整的本地 Package，主 product 名为 `MPVKit`。在你的应用工程里：

```swift
// Package.swift
let package = Package(
    name: "MyPlayer",
    platforms: [.macOS(.v10_15), .iOS(.v13)],
    dependencies: [
        .package(path: "/abs/path/to/MPVKitBuilder/dist"),
    ],
    targets: [
        .executableTarget(
            name: "MyPlayer",
            dependencies: [
                .product(name: "MPVKit", package: "dist"),
            ]
        ),
    ]
)
```

也可以把整个 `dist/` 目录拷到自己仓库里（或建一个独立仓库专放产物），然后用 `.package(path: "Vendor/MPVKit")`。

## 3. Xcode 工程引用

`File → Add Package Dependencies… → Add Local…` 选 `dist/` 目录即可。Xcode 会把 `MPVKit` 作为一个 library product 加进来，里面包含所有 `*.xcframework` 作为 binaryTarget。

## 4. 最小验证 Demo

下面是一个最小验证工程的结构，用于确认 `Libmpv` 可链接、`mpv_create()` 可调用：

```text
Demo/
├── Package.swift
└── Sources/Demo/main.swift
```

`Demo/Package.swift`：

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Demo",
    platforms: [.macOS(.v10_15)],
    dependencies: [
        .package(path: "../dist"),
    ],
    targets: [
        .executableTarget(
            name: "Demo",
            dependencies: [.product(name: "MPVKit", package: "dist")]
        ),
    ]
)
```

`Demo/Sources/Demo/main.swift`：

```swift
import Libmpv

guard let h = mpv_create() else {
    print("mpv_create failed"); exit(1)
}
mpv_set_option_string(h, "vo", "libmpv")
mpv_set_option_string(h, "hwdec", "videotoolbox")
mpv_initialize(h)
print("mpv \(String(cString: mpv_client_api_version() == 0 ? "unknown" : "ok"))")
mpv_terminate_destroy(h)
```

`cd Demo && swift run` 能编译并打印 `mpv ok` 即视为消费端通路打通。

## 5. 已知约束

- 生成的 `platforms:` 会根据 `platform=` 或 `package-platforms=` 归一化声明，例如 `ios,isimulator` 会声明为 `iOS 13`。若 `dist/` 中某些 xcframework 缺少对应平台 slice，消费方在该平台上编译会报错；按需重新构建对应平台即可。
- 远程 `.binaryTarget(url:checksum:)` 模式暂未实现，第一版只支持本地 `path:` 引用。
