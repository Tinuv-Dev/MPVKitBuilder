# M7 远程发布模式设计草稿

> 状态：**草稿，未实现**。当前 `PackageManifestGenerator` 只支持 local 模式（`binaryTarget(path:)`）。
> 此文档记录如何把 M7 扩展为「GitHub Actions 远程构建 + 远程 binaryTarget」模式，留待后续实现。

---

## 一、问题本质

当前生成的 `dist/Package.swift` 用的是 `.binaryTarget(path: "Libmpv.xcframework")`，这只能在「Package.swift 和 xcframework 在同一个本地目录」时工作。CI 跑完后，xcframework 不会跟着提交到仓库（太大），消费方拿不到。

远程发布需要的形态：

```swift
.binaryTarget(
    url: "https://github.com/<owner>/<repo>/releases/download/<tag>/Libmpv.xcframework.zip",
    checksum: "<sha256 of the zip>"
)
```

SPM 强制要求 `checksum:`（SHA-256 of the zip 文件本身），不允许省略。

---

## 二、SPM 远程 binaryTarget 的硬约束

1. **必须是 .zip**：不能直接喂 `.xcframework` 目录。
2. **zip 根目录必须是 `XXX.xcframework/`**：解压后第一层就是 framework 本体，不能套一层 `dist/`。`ditto -c -k --sequesterRsrc --keepParent` 从 `dist/` 内部执行能保证这一点。
3. **checksum = SHA-256(zip 文件字节)**：等价于 `swift package compute-checksum file.zip`。可以直接用 `CryptoKit.SHA256` 算，不依赖 `swift package`。
4. **URL 必须稳定可下载**：一旦 release 发出去就不能改文件，否则消费方下次 resolve 时校验失败。
5. **Package.swift 必须托管在 git 仓库的某个 tag 上**：消费方 `.package(url:, from:)` 解析的是 git ref，不是 zip。Package.swift 自身不能放进 release asset 里。

---

## 三、CI 完整数据流（需要新增的环节）

现有：`build → dist/*.xcframework`

需要新增：

```
dist/*.xcframework
   ↓ ① zip（ditto，每个 framework 一个 zip）
dist/zip/*.xcframework.zip
   ↓ ② compute SHA-256（每个 zip 一个 64 字符 hex）
dist/zip/checksums.json     { "Libmpv": "ab12...", "Libavcodec": "cd34...", ... }
   ↓ ③ upload to GitHub Release（gh release create + upload）
https://github.com/.../releases/download/<tag>/<Name>.xcframework.zip
   ↓ ④ render remote Package.swift（用 baseURL + tag + checksums）
Package.swift（位于 repo 根，提交到 <tag> 这个 commit）
   ↓ ⑤ git tag <tag> + git push
消费方可用：.package(url: "https://github.com/<owner>/<repo>", exact: "<tag>")
```

这五个动作里，**①②④** 是 builder 程序的职责；**③⑤** 是 CI workflow 的职责（用 `gh` CLI + git push）。

---

## 四、`PackageManifestGenerator` 的对应扩展

需要把当前的「local-only」改成两段式：

```swift
enum Mode {
    case local                                          // 现在做的
    case remote(baseURL: String,                        // 例：https://.../releases/download/v0.1.0
                checksums: [String: String])            // target name -> sha256 hex
}
```

`render` 函数的区别只在 `targets:` 数组那段：

| 模式 | 一行的样子 |
|---|---|
| local | `.binaryTarget(name: "Libmpv", path: "Libmpv.xcframework")` |
| remote | `.binaryTarget(name: "Libmpv", url: "<baseURL>/Libmpv.xcframework.zip", checksum: "ab12...")` |

注意 remote 模式下，**Package.swift 不应该写在 `dist/`** —— 它要被 git 提交，而 `dist/` 是产物目录。建议写到 **仓库根目录的 `Package.swift`**（覆盖 builder 工具自身的 Package.swift 不行，会冲突——见 §六）。

---

## 五、需要新增的 CLI / 子命令

至少需要三个新的能力（可以塞进现有 `package` 子命令，也可以拆开）：

```bash
# 1. 把 dist/*.xcframework 全部打 zip + 写 checksums.json
swift run MPVKitBuilder zip

# 2. 生成 remote Package.swift
swift run MPVKitBuilder package \
    mode=remote \
    release-url=https://github.com/owner/repo/releases/download/v0.1.0 \
    output=./Package.swift                    # 默认 dist/Package.swift（local），remote 时强制指定
```

或者一步到位的复合命令（更适合 CI）：

```bash
swift run MPVKitBuilder release \
    tag=v0.1.0 \
    repo=owner/repo \
    output=./Package.swift
# 内部：zip + checksum + 生成 remote Package.swift
# 不负责上传，上传仍由 CI 的 gh CLI 做
```

新增的 BuildOptions 字段：

- `releaseMode: Mode`（local / remote）
- `releaseBaseURL: String?`
- `releaseTag: String?`（用于自动拼接 baseURL）
- `manifestOutputPath: URL?`

---

## 六、Package.swift 的物理位置：三种放法

这是**必须先拍板的决策点**，会影响 builder 和 CI 的接口。

### 方案 A：同仓库 + 独立 release 分支

- `main` 分支：builder 源码 + 当前的 `Package.swift`（builder 自己的 executable）
- `release` 分支：只有一个根 `Package.swift`（remote 模式）+ README，没有 builder 代码
- 消费方：`.package(url: "https://github.com/owner/MPVKitBuilder", branch: "release")` 或 `exact: "v0.1.0"`

✅ 优点：builder 仓库自身保持纯净；消费方 clone 体积小。
⚠️ 痛点：CI 需要切到 release 分支提交，多一次 `git worktree`。

### 方案 B：独立 release 仓库（推荐）

- `MPVKitBuilder`（本仓库）：builder 源码
- `MPVKit`（新仓库）：只有 `Package.swift` + tag

✅ 优点：职责彻底分离；release 仓库可以提供干净的 PR / Issue 区。
⚠️ 痛点：需要新建一个仓库 + CI 配 PAT/Deploy Key 跨仓库 push。

### 方案 C：同仓库根目录覆盖

- `main` 分支根目录的 `Package.swift` 同时承担两个角色：tag 上是 remote 模式（消费方用），HEAD 上是 builder executable（开发用）。
- 每次 release 时把 builder 的 Package.swift 临时换成 remote 版，打 tag，再换回来。

❌ 不推荐：违反「Git 提交语义稳定」原则，本地切换 tag 会破坏 IDE 状态。

---

## 七、Checksum 的两种算法选择

| 方式 | 实现 | 一致性 |
|---|---|---|
| `swift package compute-checksum file.zip` | 在 builder 里 `Process.launch` | 等价于 `shasum -a 256` 的 hex 输出 |
| CryptoKit `SHA256.hash(data:)` | builder 内部直接算 | 同上 |

两者结果**完全相同**（SPM 的 compute-checksum 就是 SHA-256 hex）。建议用 CryptoKit，少一次进程调用、不依赖 swift toolchain 的路径。

---

## 八、Workflow 端的拼装（不在 builder 代码里，但影响 builder 接口设计）

CI 大致：

```yaml
- name: Build all xcframeworks
  run: make build

- name: Zip + checksum + render Package.swift
  run: |
    swift run MPVKitBuilder release \
      tag=${{ github.ref_name }} \
      repo=${{ github.repository }} \
      output=Package.dist.swift

- name: Create release & upload zips
  run: |
    gh release create ${{ github.ref_name }} \
      dist/zip/*.xcframework.zip \
      --notes-file CHANGELOG.md

- name: Commit Package.swift to release branch
  run: |
    git switch release
    cp Package.dist.swift Package.swift
    git add Package.swift
    git commit -m "release ${{ github.ref_name }}"
    git tag ${{ github.ref_name }}
    git push --tags origin release
```

builder 程序对此完全不感知；只需要确保 `release` 子命令输出**单一文件**到指定路径，让 CI 拿去提交。

---

## 九、需要保留的「双模式」能力

local 模式**不能删**，它仍然有价值：

- 本地构建后立即在同机 Demo SwiftPM 工程里调试
- CI 上跑 smoke test（不依赖 release 已发出）
- 开发者 fork 仓库后直接本地 consume

最干净的做法：

- `package` 子命令默认 `mode=local`，写 `dist/Package.swift`
- 加 `mode=remote release-url=... output=...` 时切到远程模式，写到外部路径
- 两个文件**互不覆盖**：local 版永远写 `dist/Package.swift`，remote 版永远写 CLI 指定的路径

---

## 十、还需要先定的关键决策

按重要性排序：

1. **Package.swift 放哪儿**：方案 A（同仓库 release 分支）/ B（独立仓库）/ C（覆盖）。
2. **Release tag 命名**：`v0.1.0` 这种 SemVer？还是 `ffmpeg-n8.1.1+mpv-v0.41.0+1` 这种组合？后者把上游版本号编进 tag，回溯更容易，但 SemVer 对消费方更友好。
3. **每个库一个 zip，还是打成一个大 zip**：SPM 必须每个 binaryTarget 一个 zip，所以是 32 个文件，每个独立 checksum。这意味着 release 资产 = 32 个 `.xcframework.zip`。
4. **是否需要 stable URL 别名**：例如 `https://.../releases/latest/download/Libmpv.xcframework.zip`。✅ 别用——SPM 的 checksum 校验是和 URL 绑定到某个具体版本的，"latest" 一旦内容变化，消费方会 checksum mismatch 整个工程编不过。
5. **zip 的体积控制**：未压缩 xcframework 单个能上百 MB，所有 32 个加起来可能 > 1 GB。需要确认 GitHub Release 单资产 2 GB / 单 release 总量没有上限（实际无总量上限，但下载带宽有 quota）。
6. **是否在 release 里也带一个 `checksums.txt`**：方便消费方手工核对；也是 builder 顺手能产出的副产品。

---

## 十一、改动量预估

| 模块 | 改动 |
|---|---|
| `BuildOptions` | +5 个字段（mode/baseURL/tag/output/zipDir），+CLI 解析 |
| `PackageManifestGenerator` | +Mode 枚举，+remote 分支的 render 函数，~30 行 |
| 新文件 `Packaging/XCFrameworkZipper.swift` | ditto 调用 + 输出到 `dist/zip/` |
| 新文件 `Packaging/ChecksumCalculator.swift` | CryptoKit SHA-256 |
| `BuildPipeline` | +`release` / `zip` 子命令分发 |
| `BuildCommand` enum | +`release`, +`zip`（或合并） |
| Makefile | +`make release tag=...` |
| `Sources/MPVKitBuilder/Docs/ConsumerUsage.md` | 加 §远程消费小节 |

工作量约半天到一天，纯实现，不含 GitHub Actions workflow 调试。

---

## 十二、一句话总结

M7 现在只完成了「local 模式」的一半。要支撑 GitHub Actions 远程分发，需要在 builder 里再加 **zip + sha256 + remote-mode manifest** 三件事，并先定 **Package.swift 落在哪个 git 仓库/分支** 这个最关键的决策点（推荐方案 B：独立 release 仓库）。
