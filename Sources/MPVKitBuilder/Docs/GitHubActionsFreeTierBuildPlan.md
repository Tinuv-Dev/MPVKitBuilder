# GitHub Actions Free Tier Build Plan

## 背景

MPVKitBuilder 会为多个 Apple 平台交叉编译一组 C/C++/ASM 依赖，并最终组装为 XCFramework。完整一次性构建不适合直接放进单个 GitHub Actions job：本地已有构建目录约 6.1 GB，最终 `dist/` 约 430 MB，且 macOS GitHub-hosted runner 的单 job 时长和磁盘都有限。

本文只描述开源 public repository 场景下的 CI 拆分策略，不代表当前仓库已经实现对应 workflow。

## GitHub 免费层级约束

以下约束按 GitHub 官方文档在 2026-05-25 查证，GitHub 标注这些限制可能变化。

- Public repository 使用 standard GitHub-hosted runners 免费。
- Private repository 的 GitHub Free 免费额度是 2,000 minutes/month、500 MB artifact storage、10 GB cache storage。
- Larger runners 不包含在免费额度内，public repository 使用 larger runners 也会收费。
- Standard GitHub-hosted runner 单个 job 最长 6 小时。
- `ubuntu-slim` 单个 job 最长 15 分钟，不适合本项目重型构建。
- Standard runner 并发：GitHub Free 总并发 20，其中 macOS 最大并发 5。
- Standard macOS runner 可用 SSD 标称 14 GB。
- Artifact 和 log 默认保留 90 天；public repository 可配置为 1 到 90 天。
- Cache 默认 10 GB/repository，超过 7 天未访问的 cache 会被清理。

参考：

- https://docs.github.com/en/billing/concepts/product-billing/github-actions
- https://docs.github.com/en/actions/reference/limits
- https://docs.github.com/en/actions/reference/runners/github-hosted-runners
- https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching

## 当前工程事实

当前构建维度：

- 平台：`macos`, `ios`, `isimulator`, `tvos`, `tvsimulator`, `xros`, `xrsimulator`, `maccatalyst`
- 默认架构：大部分平台默认 arm64；部分平台支持 x86_64 或 arm64e 但默认不启用
- 构建产物：多个 `.xcframework`
- 构建入口：`make build platform=<platform>` 或 `swift run --package-path . MPVKitBuilder build platform=<platform>`

主要依赖链：

- `libass` 链：`libfreetype`, `libfribidi`, `libharfbuzz`, `libunibreak`
- TLS/SMB 链：`openssl`, `gmp`, `nettle`, `libgnutls`, `libsmbclient`, `libsrt`
- 渲染/视频链：`vulkan`, `libshaderc`, `lcms2`, `libplacebo`, `libdav1d`, `libuavs3d`
- 顶层：`ffmpeg` -> `libmpv`

当前 builder 的重要限制：

- 下游依赖查找依赖 `build/<lib>-build/<platform>/thin/<arch>`。
- 只上传最终 `.xcframework` 不足以让另一个 job 继续构建下游库。
- `enable-split-platform` 和 `disable-package` 目前只是 CLI 选项，尚未真正影响构建流程。
- `libsmbclient` 只构建当前 runner 可执行架构；在 arm64 Mac 上只会生成 arm64 slice。
- `vulkan` 的 MoltenVK 构建比较特殊，它自身会生成覆盖多个平台的 XCFramework，并额外写 `vulkan.pc` 给下游使用。

## 总体策略

优先目标不是节省免费分钟，而是避免触发单 job 6 小时、14 GB 磁盘、artifact storage 的限制。

推荐分三层：

1. PR 验证层：只验证 Swift 代码、dry-run、依赖图和配置报告。
2. 平台构建层：按平台拆分完整构建。
3. 汇总发布层：下载各平台产物，校验平台覆盖，组装或发布最终包。

不要在 GitHub Actions 上传完整 `build/`，也不要把完整 `build/` 放进 cache。

## 第一阶段方案：按平台拆分

这是最适合当前代码状态的拆分方式，因为不要求 builder 支持导入上游 thin 产物。

建议 job：

- `build-macos`
- `build-ios`
- `build-isimulator`
- `build-tvos`
- `build-tvsimulator`
- `build-xros`
- `build-xrsimulator`
- `build-maccatalyst`
- `aggregate-release`

每个构建 job 做自己的完整依赖链：

```bash
make build platform=ios
```

或者：

```bash
swift run --package-path . MPVKitBuilder build platform=ios
```

优点：

- 实现简单，最少改动当前工具。
- 每个平台构建状态独立，失败定位清晰。
- public repository 的 standard runner 免费，重复构建依赖的分钟浪费可以接受。
- 不需要在 job 之间传递复杂的 `thin` 中间产物。

缺点：

- 依赖会在多个平台 job 中重复 fetch 和 compile。
- 某些重型平台仍可能超过 6 小时。
- 多平台 artifacts 汇总后可能超过 GitHub Free 的 artifact storage 预算，需要短保留期和 release asset 策略。

## 第二阶段方案：平台内再按阶段拆分

如果某个平台 job 仍然超过 4 到 5 小时，应继续拆为平台内阶段。

建议阶段：

1. `base`
   - `openssl`
   - `libunibreak`
   - `libfreetype`
   - `libfribidi`
   - `libharfbuzz`
   - `libass`
   - `libuchardet`
2. `network-gpl`
   - `gmp`
   - `nettle`
   - `libgnutls`
   - `libsrt`
   - `libsmbclient`
   - `libzvbi`
   - `libbluray`
3. `render-codec`
   - `vulkan`
   - `libshaderc`
   - `lcms2`
   - `libplacebo`
   - `libdav1d`
   - `libuavs3d`
   - `libluajit`
4. `ffmpeg`
5. `libmpv`
6. `package`

这个方案需要工具层支持导出和导入中间产物：

- 导出 `build/<lib>-build/<platform>/thin/<arch>`
- 导出必要 headers、static libs、pkg-config files
- 导出 `.build/state.json` 中对应库状态
- 导入后保持当前 `BuildContext` 路径结构不变

如果不做这个能力，按库拆分会导致下游 job 找不到依赖。

## 第三阶段方案：按架构拆分

当 macOS universal 或 simulator x86_64 需要被稳定支持时，应引入 `platform + arch` 维度。

示例：

- `build-ios-arm64`
- `build-isimulator-arm64`
- `build-isimulator-x86_64`
- `build-macos-arm64`
- `build-macos-x86_64`

注意：

- `libsmbclient` 当前只构建当前 runner 可执行架构。
- arm64 slice 应在 arm64 macOS runner 上构建。
- x86_64 slice 应在 Intel macOS runner 上构建。
- 如果只在 arm64 runner 上构建，FFmpeg 的 x86_64 slice 可能不会启用 `libsmbclient`。

## 汇总发布设计

`aggregate-release` job 只做轻量操作：

1. 下载所有平台或架构 artifacts。
2. 检查每个 framework 是否包含预期平台 slice。
3. 对每个 framework 执行 `xcodebuild -create-xcframework`。
4. 生成 manifest，记录平台、架构、版本、GPL 状态、FFmpeg configure 参数。
5. 压缩最终产物。
6. 上传到 GitHub Release。

汇总 job 不应重新编译任何第三方库。

## Artifact 策略

必须控制 artifact 数量、大小和保留时间。

推荐上传：

- 每个平台的最终 framework slice 或 `.xcframework`
- `.build/reports/dependency-graph.txt`
- `.build/reports/ffmpeg-configure.txt`
- 失败时上传对应 `.build/reports/log/*.log`
- 汇总后的 manifest

不推荐上传：

- 完整 `build/`
- `scratch`
- `*-source-*`
- 第三方源码仓库的 `.git`
- 编译临时目录

建议：

- PR artifacts：`retention-days: 3`
- release 临时 artifacts：`retention-days: 1` 到 `3`
- 最终发布物：使用 GitHub Release assets，而不是长期保留 workflow artifacts

## Cache 策略

不要 cache 完整 `build/`。它体积大、命中不稳定，而且容易超过 10 GB cache budget。

可以考虑 cache：

- SwiftPM `.build` 中与本项目 Swift 编译相关的部分
- Homebrew 下载缓存，前提是 key 稳定且体积可控
- 第三方源码 bare mirror，前提是明确裁剪 `.git` 和历史深度

谨慎 cache：

- `thin` 中间产物。只有当导入/导出路径完全稳定时才值得做。

不建议 cache：

- FFmpeg scratch build
- Samba source/build
- MoltenVK full source/build
- 完整 `dist/`

## Workflow 建议

建议拆成三类 workflow。

### `ci.yml`

触发：

- pull_request
- push 到主分支

内容：

- `swift build`
- `make dry-run platform=ios`
- `make dry-run platform=macos`
- 生成并上传短保留期报告

目的：

- 快速发现 Swift 语法、依赖图、CLI 解析和报告生成问题。
- 不在 PR 上跑完整第三方库编译。

### `build-platform.yml`

设计为 reusable workflow。

输入：

- `platform`
- `arch`
- `enable-gpl`
- `extra-ffmpeg`

内容：

- 安装必需工具
- 执行 `make build platform=<platform>`
- 上传平台产物和报告

建议：

- `timeout-minutes` 设置为 330 到 350，避免直接撞 360 分钟。
- `retention-days` 设置为 1 到 3。
- `max-parallel` 不超过 5，避免 macOS 并发上限。

### `release.yml`

触发：

- tag
- manual dispatch

内容：

- 以 matrix 调用 `build-platform.yml`
- 等待全部平台 job 完成
- 执行 `aggregate-release`
- 上传 GitHub Release assets

## 是否默认启用 GPL

当前默认 `enableGPL = true`，会引入 `libsmbclient`。

开源发布时建议明确拆两条产物线：

- `gpl-on`：完整功能，包含 GPL 相关能力。
- `gpl-off`：跳过 `libsmbclient`，降低构建复杂度和授权传播风险。

PR 验证建议默认跑 `disable-gpl`，release 再跑 `enable-gpl`。

## 推荐落地顺序

1. 新增轻量 `ci.yml`，只跑 Swift build 和 dry-run。
2. 新增按平台 release workflow，先覆盖 `ios` 和 `macos` 两个平台。
3. 记录每个平台真实耗时和 artifact 大小。
4. 将 artifact retention 降到 1 到 3 天。
5. 补充汇总 job 的 manifest 和 slice 校验。
6. 如果某个平台超过 4 到 5 小时，再设计 thin 产物导出/导入。
7. 最后再考虑 `platform + arch` 维度，解决 x86_64 和 `libsmbclient` 一致性。

## 剩余风险

- GitHub-hosted macOS runner 的实际排队和性能波动较大，同一 job 耗时可能不稳定。
- `xros`/`xrsimulator` 依赖 runner 上 Xcode 版本，必须固定 `macos-*` image 或显式检查 SDK。
- Artifact storage 500 MB 对完整产物很紧，最终包需要压缩并尽快迁移到 Release assets。
- 按平台重复构建会放大上游源码仓库网络失败概率。
- 按阶段拆分需要新增工具能力，否则下游 job 无法复用上游静态库和 pkg-config 文件。
- SwiftPM target 内的 `Docs` 目录若未来触发 unhandled file 警告，需要在 `Package.swift` 中显式 exclude 或调整文档位置。

