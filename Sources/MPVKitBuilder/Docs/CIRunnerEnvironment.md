# macos-15 Runner 环境实测

诊断 workflow `diagnose-env.yml` 于 2026-05-25 在 GitHub-hosted `macos-15` runner 上跑出的事实。用来给 `prebuild-vulkan.yml` / `build-platform.yml` 的环境准备步骤做依据，避免靠记忆和猜测改 CI。

## 锁定 Xcode 16.2 后的实际状况

`maxim-lobanov/setup-xcode@v1` + `xcode-version: '16.2'` 后：

- `xcode-select -p` → `/Applications/Xcode_16.2.app/Contents/Developer`
- `xcodebuild -version` → `Xcode 16.2 / Build 16C5032a`
- `DEVELOPER_DIR` 未导出，但 `xcode-select` 已经切过去

## SDK 全在 Xcode.app 里

`xcodebuild -showsdks` 给出全部目标平台 SDK：

- iOS 18.2 / iOS Simulator 18.2
- tvOS 18.2 / tvOS Simulator 18.2
- visionOS 2.2 / visionOS Simulator 2.2
- macOS 15.2
- watchOS 11.2 / watchOS Simulator 11.2
- DriverKit 24.2

直接看磁盘也对得上：

```
Xcode_16.2.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs
  iPhoneOS.sdk
  iPhoneOS18.2.sdk
Xcode_16.2.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs
  iPhoneSimulator.sdk
  iPhoneSimulator18.2.sdk
Xcode_16.2.app/Contents/Developer/Platforms/AppleTVOS.platform/Developer/SDKs
  AppleTVOS.sdk
  AppleTVOS18.2.sdk
Xcode_16.2.app/Contents/Developer/Platforms/AppleTVSimulator.platform/Developer/SDKs
  AppleTVSimulator.sdk
  AppleTVSimulator18.2.sdk
Xcode_16.2.app/Contents/Developer/Platforms/XROS.platform/Developer/SDKs
  XROS.sdk
  XROS2.2.sdk
Xcode_16.2.app/Contents/Developer/Platforms/XRSimulator.platform/Developer/SDKs
  XRSimulator.sdk
  XRSimulator2.2.sdk
```

结论：**Xcode 16.2 自带 iOS / iOS Simulator / tvOS / tvOS Simulator / visionOS / visionOS Simulator 全部设备 + 模拟器 SDK**。MoltenVK 的 `make ios / iossim / tvos / tvossim / visionos / visionossim` 全都跑 `xcodebuild build -destination "generic/platform=..."`，只需要 SDK 不需要启动 simulator runtime。但如果 Xcode 的 destination/platform registry 把已有平台误判为未安装，允许用 `xcodebuild -downloadPlatform` 作为 fallback 重新注册平台组件。

## 已安装的模拟器 runtime 跟 Xcode 不一样

`xcrun simctl list runtimes` 输出：

```
iOS 18.5 / 18.6 / 26.0 / 26.1 / 26.2
tvOS 18.5 / 26.1 / 26.2
watchOS 11.5 / 26.1 / 26.2
visionOS 2.3 / 2.4 / 2.5 / 26.1 / 26.2
```

关键观察：

- 没有 iOS 18.2、tvOS 18.2、visionOS 2.2 这些跟 Xcode 16.2 同版本的模拟器 runtime —— runner 镜像故意只装更新的，不装 Xcode 自带版本。
- 这**不影响**纯编译产物。`xcodebuild build` 链接的是 `iPhoneSimulator18.2.sdk`（在 Xcode.app 里），跟 simctl 列出的 runtime 是两件事。runtime 只在真正启动模拟器跑 App / 跑测试时才需要。
- MPVKitBuilder 这条 CI 链路只做静态库构建，不启动任何模拟器，所以 runtime 缺哪个版本都无所谓。

## CoreSimulator 目录布局变了

Xcode 15+ 起 simulator runtime 用 DMG 形式挂在 `/Library/Developer/CoreSimulator/Volumes/` 下，老路径 `/Library/Developer/CoreSimulator/Profiles/Runtimes/` 直接就**不存在**。

诊断时 dry-run 输出：

```
== would rm -rf /Library/Developer/CoreSimulator/Profiles/Runtimes ==
(already missing)
== would rm -rf $HOME/Library/Developer/CoreSimulator/Caches ==
total 0
```

所以原来 `prebuild-vulkan.yml` / `build-platform.yml` 里那两行：

```bash
sudo rm -rf /Library/Developer/CoreSimulator/Profiles/Runtimes
sudo rm -rf "$HOME/Library/Developer/CoreSimulator/Caches"
```

**两行都是 no-op**。Free disk 步骤实际什么都没清。

## 磁盘大头实际在哪

```
348G  /Library/Developer/CoreSimulator      ← 实际占用都在这里
1.8G  /Library/Developer/CommandLineTools
 72M  /Library/Developer/DeveloperDiskImages
 71M  /Library/Developer/CoreDevice
```

`/Library/Developer/CoreSimulator` 的 348GB 主要是 `Volumes/<runtime>.dmg.diskimage`。如果未来真的要回收空间，应该清的是 `Volumes/` 下不需要的 runtime DMG，不是已经空的 `Profiles/Runtimes/`。

各 Xcode 占用合计 ~40GB（runner 同时装了 16, 16.1, 16.2, 16.3, 16.4, 26.0.1, 26.1.1, 26.2, 26.3）：

```
4.3G  Xcode_16.1.app
4.4G  Xcode_16.2.app          ← 我们用的
4.7G  Xcode_16.3.app
4.6G  Xcode_16.4.app
4.4G  Xcode_16.app
4.2G  Xcode_26.0.1.app
4.3G  Xcode_26.1.1.app
4.3G  Xcode_26.2.app
4.3G  Xcode_26.3.app
```

`/Applications/Xcode.app` 默认指向 `Xcode_16.4.app`，所以 `xcode-version: '16.2'` 这一行是必要的，不锁就会走 16.4。

## 对原始 "iOS 18.2 is not installed" 报错的复盘

原始报错来源：`make ios` → `xcodebuild build -destination "generic/platform=iOS"` 在 prebuild-vulkan 早期 run 上失败。但本次诊断显示**同一个镜像 + 同一个 Xcode 16.2 上，所有 iOS/tvOS/visionOS SDK 全部就位**。后续实跑确认，即使 SDK 和 platform path 都存在，Xcode 的 destination registry 仍可能报 `iOS 18.2 is not installed`，此时需要 `xcodebuild -downloadPlatform iOS` 修复注册状态。

最可能的解释（仍待下一次实跑确认）：

- 旧顺序里 `Free disk` 步骤本身是 no-op 但留下了 `df -h` 副作用；真正失败的不是缺平台，而是 MoltenVK 工程里的 scheme 解析在某个不稳定 Xcode 状态下短暂返回不了 destination。
- 也不排除是网络/镜像准备阶段的 race，跟 setup-xcode 的 first-launch 注册有关。

无论原因为何，下列结论是稳的：

1. 不要默认每次预下载 `iOS / tvOS / visionOS`。Xcode 16.2 自带这些 SDK，强行下载会让 prebuild 多耗 10–15 分钟；但命中 destination/platform 未注册类错误时，应按需执行 `xcodebuild -downloadPlatform` 后重试。
2. **不需要** `sudo rm -rf /Library/Developer/CoreSimulator/Profiles/Runtimes` 这种 Free disk —— 目标路径根本不存在。
3. 加一行 `sudo xcodebuild -runFirstLaunch` 仍然是便宜的保险，能避免首次跑 Xcode 选 license / 注册的潜在卡点。
4. 真要省盘，去清 `/Library/Developer/CoreSimulator/Volumes/` 里我们不用的 runtime DMG。但因为本项目纯编译不启动模拟器，连这步都可以省。

## 对 workflow 的处置建议

依据上面四条以及"删未使用 Xcode 释放 ~35GB"这一点，`prebuild-vulkan.yml` 和 `build-platform.yml` 的环境准备段标准做法是：

```yaml
- name: Pin Xcode
  uses: maxim-lobanov/setup-xcode@v1
  with:
    xcode-version: '16.2'

- name: Free disk (drop unused Xcodes)
  run: |
    df -h /
    SELECTED=$(xcode-select -p)
    KEEP=$(dirname "$(dirname "$SELECTED")")
    echo "keeping $KEEP"
    for app in /Applications/Xcode*.app; do
      if [ "$app" != "$KEEP" ]; then
        echo "removing $app"
        sudo rm -rf "$app"
      fi
    done
    df -h /

- name: First launch
  run: sudo xcodebuild -runFirstLaunch

- name: Probe SDKs
  run: xcodebuild -showsdks
```

**强制要求**：任何会跑重型编译的 workflow，在 `Pin Xcode` 之后**必须**立刻删除未选中的 Xcode.app。理由：

- runner 镜像同时预装 9 个 Xcode，约 ~40GB，我们只用其中一个，剩下 ~35GB 是死重。
- 删除写在 `Pin Xcode` 之后保证 `xcode-select -p` 指向的 Xcode 不会被误删；脚本读 `xcode-select -p` 推回 `Xcode_*.app` 路径，删其他所有 `Xcode*.app` 软/硬连接。
- `/Applications/Xcode.app` 默认指向 `Xcode_16.4.app`，删完会变成悬挂软链 —— 没问题，CI 全程都用 `xcode-select` 已经切好的绝对路径，不依赖那个软链。
- 不要去清 `/Library/Developer/CoreSimulator/Volumes/` 下的 runtime DMG，那一棵跟选中 Xcode 之间的依赖关系不清晰，删错会引入"iOS 18.2 is not installed"这类难排查问题。

剩下两步：
- `First launch` 跑 `-runFirstLaunch`，吃掉首跑 Xcode 的 license / 注册步骤。
- `Probe SDKs` 跑 `xcodebuild -showsdks`，把 CI log 里"这次 Xcode 看到哪些 SDK"留个证据。未来如果再出现 "iOS X.X is not installed" 这类报错，能第一时间确认是 SDK 缺失还是别的原因。

## Xcode 16.2 还是 26.x 的取舍

2026-05-25 讨论结果：CI 暂用 Xcode 16.2，若失败再考虑升级。完整背景记下来便于以后翻账。

### 事实

- 本地环境：macOS 26 + Xcode 26.x。本地构建已验证通过。
- macos-15 runner 镜像里 `Xcode_26.0.1.app` / `26.1.1.app` / `26.2.app` / `26.3.app` 全部预装，每个 ~4.3GB 实体目录，可用。Apple 允许 Xcode 26 直接跑在 macOS 15 上，**不需要换 `runs-on`**。
- GitHub 是否上线 `macos-26` runner 标签未确认。即便上线，对纯编译链路意义不大，因为关键工具链来自 Xcode.app 本身，跟 runner OS 关系小。

### 选 16.2 的理由（当前选择）

- 当前 prebuild-vulkan 第一次失败的根因还没复现确认。一次升级 Xcode 大版本会再叠一个变量，将来不好分辨。
- iOS 18.2 SDK 出来的 XCFramework，消费方 Xcode 16.x 和 26.x 都能链；反过来用 iOS 26 SDK 产出，消费方必须 Xcode 26+。对公开二进制分发面更窄。
- MoltenVK / FFmpeg / libplacebo / libmpv 这一摞 C/C++ 项目在新 Xcode 上的兼容性是不确定项。本地一台机器通过不等于干净 runner 上一定通过。

### 选 26.x 的理由（暂未采用）

- 跟本地完全对齐，消除 toolchain 这个变量。这是最强论点 —— "本地能跑"这条证据其实指向 26.x。
- 新 SDK / 新 compiler / 新 patch。
- runner 自带 iOS 26.x 等更新的 simulator runtime（虽然我们这条链路不需要 runtime）。

### 切换 26.x 的实际改法（备用）

如果 16.2 跑挂了：

```yaml
runs-on: macos-15           # 不动
- name: Pin Xcode
  uses: maxim-lobanov/setup-xcode@v1
  with:
    xcode-version: '26.2'   # 改成本地实际使用的小版本
```

`maxim-lobanov/setup-xcode` 等价于 `xcode-select` 切到对应 Xcode.app，没别的副作用。注意 pin 到具体小版本（26.0.1 / 26.1.1 / 26.2 / 26.3），不要用 `'26.x'` 浮动，避免 GitHub 镜像更新时 CI 行为悄悄变。

切换后还要复核 `Sources/MPVKitBuilder/Docs/` 里 SDK 版本相关的假设（iOS 18.2 → iOS 26.x，consumer minimum 跟着变），以及 [ConsumerUsage.md](ConsumerUsage.md) 里对最低 Xcode 的说明。

## 复跑诊断的方式

需要重新确认时手动跑 `Diagnose Env` workflow：

```
gh workflow run diagnose-env.yml --ref <branch>
```

输出包含 `xcode-select -p`、`xcodebuild -showsdks`、Xcode 内部 SDK 目录、`xcrun simctl list runtimes`、`df -h`、各 Xcode 大小、Free disk dry-run。约 1 分钟跑完，不会对 runner 状态产生影响。
